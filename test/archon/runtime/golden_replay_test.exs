# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.GoldenReplayTest do
  @moduledoc """
  The captured worker scenarios replayed through the application's processes with only
  `Archon.Runtime` and `Archon.Runtime.Tasks` (ADR 0018, decision 10, slice 3d): the SIMPLE,
  SWITCH and FORK_JOIN workflows end as the upstream server's `workflow_get_completed_*`, the
  polled tasks match the `task_poll_*` responses, and `task_get` and `task_poll_empty` are
  answered as captured. The `DO_WHILE` scenarios of `do_while_replay_test.exs` run the same way.

  The queues are the application's, shared with other tests, so each test first removes the
  messages left visible in the queues it polls.
  """

  use Archon.RuntimeCase

  import Archon.StepReplay, only: [assert_matches: 2]

  alias Archon.Contract
  alias Archon.Domain.{Task, TaskDef, TaskResult, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Tasks

  @worker "archon-contract"

  setup do
    for fixture <- ["metadata_get_workflow_switch", "metadata_get_workflow_fork"] do
      {:ok, definition} = WorkflowDef.from_json(Contract.fixture(fixture)["response"]["body"])
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

    drain(["archon_task_a", "archon_task_b"])
    :ok
  end

  defp drain(queues) do
    for queue <- queues, id <- pop_all(queue), do: Runtime.queue().remove(queue, id)
  end

  defp pop_all(queue) do
    case Runtime.queue().pop(queue, 100, 0) do
      [] -> []
      ids -> ids ++ pop_all(queue)
    end
  end

  # The task as the REST response encodes it, compared with a captured one.
  defp assert_task(%Task{} = task, expected) do
    actual = task |> Task.to_json() |> JSON.encode!() |> JSON.decode!()
    assert Contract.normalize(actual) == Contract.normalize(expected)
  end

  defp poll_fixture(fixture) do
    %{"request" => %{"path" => path}, "response" => %{"body" => body}} = Contract.fixture(fixture)
    %URI{path: "/api/tasks/poll/" <> type, query: query} = URI.parse(path)
    {type, URI.decode_query(query), body}
  end

  # The captured update with the replayed workflow and task IDs.
  defp result(fixture, workflow_id, %Task{task_id: task_id}) do
    json = Contract.fixture(fixture)["request"]["body"]
    assert Contract.normalize(json["workflowInstanceId"]) == Contract.normalize(workflow_id)

    {:ok, result} =
      TaskResult.from_json(
        Map.merge(json, %{"workflowInstanceId" => workflow_id, "taskId" => task_id})
      )

    result
  end

  describe "golden fixtures through processes" do
    test "the SIMPLE scenario, task_get and task_poll_empty" do
      start = Contract.fixture("workflow_start_simple")
      %URI{query: query} = URI.parse(start["request"]["path"])
      %{"correlationId" => correlation_id} = URI.decode_query(query)
      id = start_simple(start["request"]["body"], correlation_id: correlation_id)

      {type, %{"workerid" => @worker}, expected} = poll_fixture("task_poll_simple_a")
      assert {:ok, %Task{workflow_instance_id: ^id} = task_a} = Tasks.poll(type, @worker)
      assert_task(task_a, expected)

      update = Contract.fixture("task_update_simple_a")
      assert update["request"]["path"] == "/api/tasks"

      assert {:ok, %Task{status: :completed}} =
               Tasks.update(result("task_update_simple_a", id, task_a))

      {type, _query, expected} = poll_fixture("task_poll_simple_b")
      assert {:ok, %Task{workflow_instance_id: ^id} = task_b} = Tasks.poll(type, @worker)
      assert_task(task_b, expected)

      update_v2 = Contract.fixture("task_update_v2_simple_b")

      assert {update_v2["request"]["path"], update_v2["response"]["status"]} ==
               {"/api/tasks/update-v2", 204}

      assert Tasks.update_v2(result("task_update_v2_simple_b", id, task_b)) == {:ok, nil}

      {:ok, workflow} = Runtime.get_workflow(id)
      assert_matches(workflow, "workflow_get_completed_simple")

      get = Contract.fixture("task_get")

      assert Contract.normalize(get["request"]["path"]) ==
               Contract.normalize("/api/tasks/#{task_a.task_id}")

      assert {:ok, stored} = Tasks.get(task_a.task_id)
      assert_task(stored, get["response"]["body"])

      {type, %{"workerid" => worker}, nil} = poll_fixture("task_poll_empty")
      assert Contract.fixture("task_poll_empty")["response"]["status"] == 204
      assert Tasks.poll(type, worker) == {:ok, nil}
      await_down(id)
    end

    test "the SWITCH scenario" do
      request = Contract.fixture("workflow_start_request_switch")["request"]["body"]

      {:ok, id} =
        Runtime.start_workflow(%{
          name: request["name"],
          version: request["version"],
          correlation_id: request["correlationId"],
          input: request["input"]
        })

      {type, _query, expected} = poll_fixture("task_poll_switch_b")
      assert {:ok, %Task{workflow_instance_id: ^id} = task} = Tasks.poll(type, @worker)
      assert_task(task, expected)

      assert {:ok, %Task{status: :completed}} =
               Tasks.update(result("task_update_switch_b", id, task))

      {:ok, workflow} = Runtime.get_workflow(id)
      assert_matches(workflow, "workflow_get_completed_switch")
      await_down(id)
    end

    test "the FORK_JOIN scenario with a batch poll" do
      start = Contract.fixture("workflow_start_fork")
      "/api/workflow/" <> name = start["request"]["path"]
      {:ok, id} = Runtime.start_workflow(%{name: name, input: start["request"]["body"]})

      batch = Contract.fixture("task_batch_poll_fork_a")

      %URI{path: "/api/tasks/poll/batch/" <> type, query: query} =
        URI.parse(batch["request"]["path"])

      %{"workerid" => worker, "count" => count, "timeout" => timeout} = URI.decode_query(query)

      assert {:ok, [%Task{workflow_instance_id: ^id} = task_a] = tasks} =
               Tasks.batch_poll(
                 type,
                 worker,
                 nil,
                 String.to_integer(count),
                 String.to_integer(timeout)
               )

      assert length(tasks) == length(batch["response"]["body"])
      assert_task(task_a, hd(batch["response"]["body"]))

      assert {:ok, %Task{status: :completed}} =
               Tasks.update(result("task_update_fork_a", id, task_a))

      {type, _query, expected} = poll_fixture("task_poll_fork_b")
      assert {:ok, %Task{workflow_instance_id: ^id} = task_b} = Tasks.poll(type, @worker)
      assert_task(task_b, expected)

      assert {:ok, %Task{status: :completed}} =
               Tasks.update(result("task_update_fork_b", id, task_b))

      {:ok, workflow} = Runtime.get_workflow(id)
      assert_matches(workflow, "workflow_get_completed_fork")
      await_down(id)
    end
  end

  describe "DO_WHILE through processes" do
    # The scenarios of do_while_replay_test.exs; each worker task type is unique to this test.

    defp simple(ref, input \\ %{}) do
      name = "archon_dw_" <> ref

      %WorkflowTask{
        name: name,
        task_reference_name: ref,
        type: "SIMPLE",
        input_parameters: input,
        task_definition: %TaskDef{name: name, retry_count: 0}
      }
    end

    defp definition(loop) do
      %WorkflowDef{
        name: "archon_do_while",
        version: 1,
        schema_version: 2,
        tasks: [loop, simple("after", %{"loop" => "${loop.output}"})],
        output_parameters: %{"iterations" => "${loop.output.iteration}"}
      }
    end

    defp loop(fields) do
      struct!(
        %WorkflowTask{
          name: "loop",
          task_reference_name: "loop",
          type: "DO_WHILE",
          task_definition: %TaskDef{name: "loop", retry_count: 0, response_timeout_seconds: 0}
        },
        fields
      )
    end

    defp start(definition, input) do
      drain(Enum.map(["a", "after"], &("archon_dw_" <> &1)))
      {:ok, id} = Runtime.start_workflow(%{definition: definition, input: input})
      id
    end

    # Polls the task with the reference name from its queue and completes it.
    defp complete(id, ref, output) do
      type = "archon_dw_" <> String.replace(ref, ~r/__\d+$/, "")

      assert {:ok, %Task{workflow_instance_id: ^id, reference_task_name: ^ref} = task} =
               Tasks.poll(type, "worker")

      result = %TaskResult{
        workflow_instance_id: id,
        task_id: task.task_id,
        status: :completed,
        output_data: output,
        worker_id: "worker"
      }

      assert {:ok, %Task{status: :completed}} = Tasks.update(result)
      task
    end

    defp summary(id) do
      {:ok, workflow} = Runtime.get_workflow(id)
      Enum.map(workflow.tasks, &{&1.reference_task_name, &1.status, &1.iteration})
    end

    test "a counter loop runs its body until the condition is false, then the next task" do
      id =
        start(
          definition(loop(loop_over: [simple("a")], loop_condition: "$.loop['iteration'] < 2")),
          %{}
        )

      assert summary(id) == [{"loop", :in_progress, 1}, {"a__1", :scheduled, 1}]
      complete(id, "a__1", %{"n" => 1})

      assert summary(id) == [
               {"loop", :in_progress, 2},
               {"a__1", :completed, 1},
               {"a__2", :scheduled, 2}
             ]

      complete(id, "a__2", %{"n" => 2})
      loop = task(id, "loop")
      assert loop.status == :completed

      assert loop.output_data == %{
               "1" => %{"a" => %{"n" => 1}},
               "2" => %{"a" => %{"n" => 2}},
               "iteration" => 2
             }

      assert [{"after", :scheduled, 0}] = id |> summary() |> Enum.drop(3)
      assert task(id, "after").input_data == %{"loop" => loop.output_data}

      complete(id, "after", %{})
      {:ok, workflow} = Runtime.get_workflow(id)
      assert {workflow.status, workflow.output} == {:completed, %{"iterations" => 2}}
      await_down(id)
    end

    test "a list loop hands each item to its body and keepLastN drops the old iterations" do
      loop =
        loop(
          items: "${workflow.input.items}",
          loop_over: [simple("a", %{"item" => "${loop.output.loopItem}"})],
          input_parameters: %{"keepLastN" => 1}
        )

      id = start(definition(loop), %{"items" => ~w(x y z)})

      for {item, i} <- Enum.with_index(~w(x y z), 1) do
        task = complete(id, "a__#{i}", %{"seen" => item})
        assert task.input_data == %{"item" => item}
      end

      assert summary(id) == [
               {"loop", :completed, 3},
               {"a__3", :completed, 3},
               {"after", :scheduled, 0}
             ]

      assert task(id, "loop").output_data == %{
               "3" => %{"a" => %{"seen" => "z"}},
               "iteration" => 3,
               "loopIndex" => 2,
               "loopItem" => "z"
             }
    end

    test "an empty list completes the loop without running its body" do
      loop = loop(items: "${workflow.input.items}", loop_over: [simple("a")])
      id = start(definition(loop), %{"items" => []})

      assert summary(id) == [{"loop", :completed, 0}, {"after", :scheduled, 0}]
      assert Tasks.poll("archon_dw_a", "worker") == {:ok, nil}
    end
  end
end
