# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.TasksTest do
  @moduledoc """
  `Archon.Runtime.Tasks` with the application's processes (ADR 0018, decision 7, slice 3d): the
  poll checks of upstream `ExecutionService#poll` (queue cleanup, the concurrent execution limit,
  a failed poll, poll data and acks), domain queues, and the update, update-v2 and get calls.

  The queues are the application's, shared with other tests, so each test first empties the
  queues it polls and stops what would fill them again (`Archon.RuntimeCase.isolate_queues/1`).
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{Task, TaskDef, TaskResult, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Tasks

  setup do
    isolate_queues(["archon_task_a", "archon_task_b"])
  end

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp completed(id, task, output \\ %{}) do
    %TaskResult{
      workflow_instance_id: id,
      task_id: task.task_id,
      status: :completed,
      worker_id: "w",
      output_data: output
    }
  end

  describe "batch_poll/5 and poll/3" do
    test "a long poll timeout over 5 s is refused" do
      assert Tasks.batch_poll("archon_task_a", "w", nil, 1, 5_001) ==
               {:error, {:invalid, "Long Poll Timeout value cannot be more than 5 seconds"}}

      assert Tasks.batch_poll("archon_task_a", "w", nil, 0, 5_000) == {:ok, []}
    end

    test "a polled task is saved IN_PROGRESS for the worker and its message acked" do
      id = start_simple(%{"x" => 1})
      scheduled = task(id, "task_a_ref")

      assert {:ok, %Task{task_id: task_id, status: :in_progress, worker_id: "w", poll_count: 1}} =
               Tasks.poll("archon_task_a", "w")

      assert task_id == scheduled.task_id
      assert %Task{status: :in_progress, worker_id: "w"} = task(id, "task_a_ref")
      refute Runtime.queue().contains?("archon_task_a", task_id)
    end

    test "every poll records the poll data, also an empty one" do
      RuntimeHooks.install(clock: 1_000_000)
      domain = unique("empty")

      assert Tasks.poll("archon_task_b", "w-empty", domain) == {:ok, nil}

      assert {:ok, %{worker_id: "w-empty", domain: ^domain, last_poll_time: 1_000_000}} =
               Runtime.store().get_poll_data("archon_task_b", domain)

      RuntimeHooks.advance(5)
      assert Tasks.batch_poll("archon_task_b", "w-batch", domain, 3, 0) == {:ok, []}

      assert {:ok, %{worker_id: "w-batch", last_poll_time: 1_000_005}} =
               Runtime.store().get_poll_data("archon_task_b", domain)
    end

    test "a message whose task the store does not have is removed" do
      :ok = Runtime.queue().push("archon_task_a", "tasks-ghost", 0, 0)

      assert Tasks.poll("archon_task_a", "w") == {:ok, nil}
      refute Runtime.queue().contains?("archon_task_a", "tasks-ghost")
    end

    test "a message of a terminal task is removed" do
      id = start_simple(%{"x" => 1})
      {:ok, task} = Tasks.poll("archon_task_a", "w")
      assert {:ok, %Task{status: :completed}} = Tasks.update(completed(id, task))

      :ok = Runtime.queue().push("archon_task_a", task.task_id, 0, 0)

      assert Tasks.poll("archon_task_a", "w") == {:ok, nil}
      refute Runtime.queue().contains?("archon_task_a", task.task_id)
      assert task(id, "task_a_ref").poll_count == 1
    end

    test "a poll that fails in the workflow's process is postponed for 60 s" do
      RuntimeHooks.install(clock: 2_000_000)
      id = start_simple(%{"x" => 1})
      task_id = task(id, "task_a_ref").task_id

      RuntimeHooks.install(
        hook: fn
          :step, ^id, {:poll, _task_id, _worker} -> raise "poll failed"
          _point, _id, _data -> :ok
        end
      )

      assert Tasks.poll("archon_task_a", "w") == {:ok, nil}
      assert Runtime.queue().contains?("archon_task_a", task_id)
      assert %Task{status: :scheduled, poll_count: 0} = task(id, "task_a_ref")

      RuntimeHooks.install(hook: fn _point, _id, _data -> :ok end)
      assert Tasks.poll("archon_task_a", "w") == {:ok, nil}

      RuntimeHooks.advance(60_000)

      assert {:ok, %Task{task_id: ^task_id, status: :in_progress}} =
               Tasks.poll("archon_task_a", "w")
    end
  end

  describe "the concurrent execution limit" do
    setup do
      name = unique("archon_limited")
      :ok = Runtime.metadata().update_task_def(%TaskDef{name: name, concurrent_exec_limit: 1})

      definition = %WorkflowDef{
        name: unique("archon_limit_wf"),
        version: 1,
        schema_version: 2,
        tasks: [%WorkflowTask{name: name, task_reference_name: "limited", type: "SIMPLE"}]
      }

      %{name: name, definition: definition}
    end

    test "a task over the limit is postponed until a slot is free", ctx do
      RuntimeHooks.install(clock: 3_000_000)

      ids =
        for _ <- 1..2 do
          {:ok, id} = Runtime.start_workflow(%{definition: ctx.definition, input: %{}})
          id
        end

      assert {:ok, [%Task{workflow_instance_id: first} = given]} =
               Tasks.batch_poll(ctx.name, "w", nil, 2, 100)

      [second] = ids -- [first]
      assert Runtime.store().in_progress_count(ctx.name) == 1
      assert %Task{status: :scheduled, poll_count: 0} = task(second, "limited")
      assert Runtime.queue().size(ctx.name) == 1

      # Still over the limit while the first one runs, and postponed by 60 s.
      RuntimeHooks.advance(60_000)
      assert Tasks.poll(ctx.name, "w") == {:ok, nil}

      assert {:ok, %Task{status: :completed}} = Tasks.update(completed(first, given))
      assert Tasks.poll(ctx.name, "w") == {:ok, nil}

      RuntimeHooks.advance(60_000)

      assert {:ok, %Task{workflow_instance_id: ^second, status: :in_progress}} =
               Tasks.poll(ctx.name, "w")
    end

    # ADR 0021, decision 5 (L10): both read the free slot before either saves.
    test "of two polls that saw the same free slot, the store lets one through", ctx do
      ids =
        for _ <- 1..2 do
          {:ok, id} = Runtime.start_workflow(%{definition: ctx.definition, input: %{}})
          id
        end

      test = self()

      RuntimeHooks.install(
        hook: fn
          :step, id, {:poll, _task_id, _worker} ->
            # each process waits once, after reading its env
            if id in ids and Process.put(:held, true) == nil do
              send(test, {:held, self()})

              receive do
                :go -> :ok
              after
                5_000 -> :ok
              end
            end

          _point, _id, _data ->
            :ok
        end
      )

      polls =
        for id <- ids do
          task_id = task(id, "limited").task_id
          Elixir.Task.async(fn -> WorkflowServer.poll(id, task_id, "w") end)
        end

      for _ <- ids, do: assert_receive({:held, _pid})
      for id <- ids, do: send(WorkflowServer.whereis(id), :go)

      results = Enum.map(polls, &Elixir.Task.await/1)
      assert [%Task{status: :in_progress, workflow_instance_id: given}] = results -- [nil]
      assert nil in results
      assert Runtime.store().in_progress_count(ctx.name) == 1
      [refused] = ids -- [given]
      assert %Task{status: :scheduled, poll_count: 0} = task(refused, "limited")
    end
  end

  describe "domains" do
    test "a task mapped to a domain is polled from the domain's queue" do
      domain = unique("dom")
      id = start_simple(%{"x" => 1}, task_to_domain: %{"archon_task_a" => domain})
      assert %Task{domain: ^domain, task_id: task_id} = task(id, "task_a_ref")
      assert Runtime.queue().contains?("#{domain}:archon_task_a", task_id)

      assert Tasks.poll("archon_task_a", "w") == {:ok, nil}

      assert {:ok, %Task{task_id: ^task_id, domain: ^domain}} =
               Tasks.poll("archon_task_a", "w", domain)

      refute Runtime.queue().contains?("#{domain}:archon_task_a", task_id)

      assert {:ok, %{worker_id: "w", domain: ^domain}} =
               Runtime.store().get_poll_data("archon_task_a", domain)
    end

    test "the recorded polls choose the active domain of a new task" do
      [idle, active, last] = Enum.map(1..3, fn _ -> unique("dom") end)

      assert Tasks.poll("archon_task_a", "w", active) == {:ok, nil}

      id = start_simple(%{"x" => 1}, task_to_domain: %{"*" => "#{idle},#{active}"})
      assert %Task{domain: ^active} = task(id, "task_a_ref")

      id = start_simple(%{"x" => 1}, task_to_domain: %{"*" => "#{idle},#{last}"})
      assert %Task{domain: ^last} = task(id, "task_a_ref")
    end
  end

  describe "update/1 and update_v2/1" do
    test "an unknown workflow or a result without one is not found" do
      result = %TaskResult{workflow_instance_id: "tasks-none", task_id: "t", status: :completed}
      assert Tasks.update(result) == {:error, :not_found}
      assert Tasks.update(%{result | workflow_instance_id: nil}) == {:error, :not_found}

      id = start_simple(%{"x" => 1})
      assert Tasks.update(%{result | workflow_instance_id: id}) == {:error, :not_found}
    end

    test "an extendLease result answers nil" do
      id = start_simple(%{"x" => 1})
      {:ok, task} = Tasks.poll("archon_task_a", "w")

      assert Tasks.update(%TaskResult{
               workflow_instance_id: id,
               task_id: task.task_id,
               extend_lease: true
             }) == {:ok, nil}

      assert %Task{status: :in_progress} = task(id, "task_a_ref")
    end

    test "update_v2 needs the workflow and task IDs" do
      assert {:error, {:invalid, errors}} = Tasks.update_v2(%TaskResult{status: :completed})

      assert errors == [
               {"workflowInstanceId", "Workflow Id cannot be null or empty"},
               {"taskId", "Task ID cannot be null or empty"}
             ]
    end

    test "update_v2 of a task still in progress answers nil and schedules it again" do
      id = start_simple(%{"x" => 1})
      {:ok, task} = Tasks.poll("archon_task_a", "w")

      assert Tasks.update_v2(%{completed(id, task) | status: :in_progress}) == {:ok, nil}
      assert %Task{status: :scheduled} = task(id, "task_a_ref")
      assert Runtime.queue().contains?("archon_task_a", task.task_id)
    end

    test "update_v2 of a terminal task polls the next task of its type for the worker" do
      ids = [start_simple(%{"x" => 1}), start_simple(%{"x" => 2})]
      {:ok, task} = Tasks.poll("archon_task_a", "w")
      [other] = ids -- [task.workflow_instance_id]

      assert {:ok, %Task{workflow_instance_id: ^other, worker_id: "w", status: :in_progress}} =
               Tasks.update_v2(completed(task.workflow_instance_id, task))

      assert %Task{status: :completed} = task(task.workflow_instance_id, "task_a_ref")
      assert %Task{status: :scheduled} = task(task.workflow_instance_id, "task_b_ref")
    end

    test "update_v2 polls the next task in the updated task's domain for the result's worker" do
      domain = unique("dom")
      mapping = %{"archon_task_a" => domain}

      ids = [
        start_simple(%{"x" => 1}, task_to_domain: mapping),
        start_simple(%{"x" => 2}, task_to_domain: mapping)
      ]

      {:ok, task} = Tasks.poll("archon_task_a", "w1", domain)
      [other] = ids -- [task.workflow_instance_id]

      result = %{completed(task.workflow_instance_id, task) | worker_id: "w2"}

      assert {:ok, %Task{workflow_instance_id: ^other, domain: ^domain, worker_id: "w2"}} =
               Tasks.update_v2(result)

      assert {:ok, %{worker_id: "w2"}} = Runtime.store().get_poll_data("archon_task_a", domain)
    end

    test "update_v2 of an unknown workflow is not found" do
      result = %TaskResult{workflow_instance_id: "tasks-none", task_id: "t", status: :completed}
      assert Tasks.update_v2(result) == {:error, :not_found}
    end
  end

  describe "get/1" do
    test "the stored task, or not found" do
      id = start_simple(%{"x" => 1})
      scheduled = task(id, "task_a_ref")

      assert Tasks.get(scheduled.task_id) == {:ok, scheduled}
      assert Tasks.get("tasks-none") == {:error, :not_found}
    end
  end
end
