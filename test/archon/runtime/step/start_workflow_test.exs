# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Cases derived from conductor-oss core/src/test/groovy/com/netflix/conductor/core/execution/tasks/StartWorkflowSpec.groovy
# and test-harness/src/test/groovy/com/netflix/conductor/test/integration/StartWorkflowSpec.groovy
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the start is an effect of the workflow's step whose result is an event
# (ADR 0026, decision 7), so the cases run the step with the result the effect would give.

defmodule Archon.Runtime.Step.StartWorkflowTest do
  @moduledoc """
  `START_WORKFLOW` and the common asynchronous start through `Archon.Runtime.Step.run/3`
  (ADR 0026, decision 7): the mapper, the start effect and its request, the result event and the
  attempt it must be for, the recovery's restart of a start-idempotent task, and the captured
  `p7_start_workflow_*` workflows of the starting side.
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay, only: [apply_commit: 2, assert_matches: 2]

  alias Archon.Contract
  alias Archon.Decider.{Context, Parameters, SystemTask, SystemTasks}
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.{Env, StartWorkflow}

  @now 1_000_000

  # An asynchronous type whose start is not idempotent and that stays SCHEDULED, as HTTP will.
  defmodule Pending do
    @behaviour SystemTask

    @impl true
    def start(_workflow, task, _context), do: SystemTask.unchanged(task)

    @impl true
    def execute(_workflow, task, _context), do: SystemTask.unchanged(task)
  end

  defp env(now, opts \\ []) do
    counter = :counters.new(1, [])

    [
      now: now,
      new_id: fn ->
        :counters.add(counter, 1, 1)
        "id-#{now}-#{:counters.get(counter, 1)}"
      end,
      system_tasks:
        Map.put(SystemTasks.default(), "ARCHON_PENDING", %SystemTasks.Spec{
          module: Pending,
          async?: true
        })
    ]
    |> Keyword.merge(opts)
    |> Env.new()
  end

  defp start_task(fields \\ []) do
    struct!(
      %WorkflowTask{
        name: "start",
        task_reference_name: "start_ref",
        type: "START_WORKFLOW",
        input_parameters: %{"startWorkflow" => "${workflow.input.request}"},
        task_definition: %TaskDef{name: "start", retry_count: 0, response_timeout_seconds: 0}
      },
      fields
    )
  end

  defp start(input, fields \\ [], tasks \\ [start_task()]) do
    workflow =
      struct!(
        %Workflow{
          workflow_id: "wf",
          status: :running,
          owner_app: "",
          correlation_id: "corr",
          task_to_domain: %{"*" => "mine"},
          input: input,
          workflow_definition: %WorkflowDef{name: "starter", version: 1, tasks: tasks}
        },
        fields
      )

    {{:ok, "wf"}, stored, _pre, commit, post} = Step.run(nil, {:start, workflow}, env(@now))
    assert apply_commit(nil, commit) == stored
    {stored, post}
  end

  defp run(workflow, event, now) do
    {reply, stored, pre, commit, post} = Step.run(workflow, event, env(now))
    assert apply_commit(workflow, commit) == stored
    {reply, stored, pre, post}
  end

  defp starts(post), do: for({:start_workflow, _id, start} <- post, do: start)

  defp only_task(%Workflow{tasks: [task]}), do: task

  @request %{"name" => "target", "version" => 2, "input" => %{"a" => 1}}

  describe "the mapper and the start" do
    test "the task is SCHEDULED, started at once and asks for the workflow with its own ID" do
      {stored, post} = start(%{"request" => @request})
      task = only_task(stored)

      assert %Task{
               task_type: "START_WORKFLOW",
               status: :scheduled,
               poll_count: 1,
               start_time: @now,
               callback_after_seconds: 0,
               input_data: %{"startWorkflow" => @request}
             } = task

      id = StartWorkflow.workflow_id("wf", task)

      assert id ==
               "startworkflow:wf:#{task.task_id}:0:#{@now}"
               |> then(&:crypto.hash(:md5, &1))
               |> uuid3()

      assert [
               %{
                 workflow_id: ^id,
                 name: "target",
                 version: 2,
                 definition: nil,
                 input: %{"a" => 1},
                 correlation_id: "corr",
                 priority: 0,
                 task_to_domain: %{"*" => "mine"},
                 parent_workflow_id: nil,
                 parent_workflow_task_id: nil,
                 triggering_workflow_id: "wf",
                 idempotency_key: nil,
                 idempotency_strategy: nil
               }
             ] = starts(post)

      assert stored.status == :running
    end

    test "the request's correlationId, taskToDomain and priority win; idempotency is not used" do
      request =
        Map.merge(@request, %{
          "correlationId" => "own",
          "taskToDomain" => %{"x" => "d"},
          "priority" => 7,
          "idempotencyKey" => "k",
          "idempotencyStrategy" => "RETURN_EXISTING"
        })

      {_stored, post} = start(%{"request" => request})

      assert [
               %{
                 correlation_id: "own",
                 task_to_domain: %{"x" => "d"},
                 priority: 7,
                 idempotency_key: nil,
                 idempotency_strategy: nil
               }
             ] = starts(post)
    end

    test "a blank correlationId and an empty taskToDomain take the starting workflow's" do
      request = Map.merge(@request, %{"correlationId" => " ", "taskToDomain" => %{}})
      {_stored, post} = start(%{"request" => request})
      assert [%{correlation_id: "corr", task_to_domain: %{"*" => "mine"}}] = starts(post)
    end

    test "an inline workflowDef is started without a name lookup" do
      definition = %{
        "name" => "inline",
        "tasks" => [%{"name" => "t", "taskReferenceName" => "t", "type" => "SIMPLE"}]
      }

      {_stored, post} = start(%{"request" => %{"name" => "inline", "workflowDef" => definition}})
      assert [%{definition: %WorkflowDef{name: "inline"}, name: "inline"}] = starts(post)
    end

    test "startDelay delays the start: the task waits for its callback" do
      {stored, post} = start(%{"request" => @request}, [], [start_task(start_delay: 5)])

      assert %Task{status: :scheduled, poll_count: 0, callback_after_seconds: 5} =
               only_task(stored)

      assert starts(post) == []
      assert {:wake_at, @now + 5000} in post

      {:ok, stored, _pre, post} = run(stored, :wake, @now + 5000)
      assert %Task{poll_count: 1, start_time: started} = only_task(stored)
      assert started == @now + 5000
      assert [%{}] = starts(post)
    end

    # ADR 0018, decision 8: the :wake starts the task, then its decide times the workflow out
    # and cancels the task, so the start asked for in the same step is dropped.
    test "a start whose task the same step ended is not made" do
      {stored, _post} = start(%{"request" => @request}, [], [start_task(start_delay: 20)])

      definition = %{
        stored.workflow_definition
        | timeout_seconds: 10,
          timeout_policy: :time_out_wf
      }

      stored = %{stored | workflow_definition: definition}

      {:ok, stored, _pre, post} = run(stored, :wake, @now + 20_000)
      assert stored.status == :timed_out
      assert %Task{status: :canceled, poll_count: 1} = only_task(stored)
      assert starts(post) == []
    end
  end

  describe "a request that cannot start" do
    defp failed_with(input) do
      {stored, post} = start(input)
      assert starts(post) == []
      assert stored.status == :failed
      task = only_task(stored)
      assert %Task{status: :failed, poll_count: 1} = task
      assert stored.reason_for_incompletion =~ task.reason_for_incompletion
      task.reason_for_incompletion
    end

    test "startWorkflow parameter is missing" do
      assert failed_with(%{}) == "Missing 'startWorkflow' in input data."
    end

    test "a value that is not a StartWorkflowRequest" do
      assert failed_with(%{"request" => "I can't be converted to StartWorkflowRequest"}) ==
               "Error reading StartWorkflowRequest. must be object"
    end

    test "a violation is upstream's message" do
      assert failed_with(%{"request" => %{"version" => 1}}) ==
               "startWorkflow validation failed. 'name' -> Workflow name cannot be null or empty. "
    end

    test "several violations are joined in path order" do
      request = %{"priority" => 100, "workflowDef" => %{"tasks" => []}}

      assert failed_with(%{"request" => request}) ==
               "startWorkflow validation failed. " <>
                 "'name' -> Workflow name cannot be null or empty. " <>
                 "'priority' -> priority: 100 should be maximum 99. " <>
                 "'workflowDef.name' -> WorkflowDef name cannot be null or empty. " <>
                 "'workflowDef.tasks' -> WorkflowTask list cannot be empty. "
    end

    test "a blank name without a definition is upstream's lookup argument error" do
      assert failed_with(%{"request" => %{"name" => " "}}) ==
               "Workflow name must be specified when searching for a definition"
    end

    test "an external input path without an input cannot be downloaded" do
      request = %{"name" => "target", "externalInputPayloadStoragePath" => "p/in.json"}

      assert failed_with(%{"request" => request}) ==
               "Unable to download payload from external storage path: p/in.json"
    end
  end

  describe "the result event" do
    defp started(stored, result, now \\ @now + 10) do
      task = only_task(stored)
      run(stored, {:workflow_started, task.task_id, result}, now)
    end

    test "the started workflow completes the task with its ID and the workflow decides" do
      {stored, _post} = start(%{"request" => @request})
      id = StartWorkflow.workflow_id("wf", only_task(stored))

      {:ok, stored, _pre, post} =
        started(stored, {:ok, %Workflow{workflow_id: id, create_time: @now + 5}})

      assert %Task{status: :completed, end_time: end_time, output_data: %{"workflowId" => ^id}} =
               only_task(stored)

      assert end_time == @now + 10
      assert stored.status == :completed
      assert starts(post) == []
    end

    test "a transient error leaves the task SCHEDULED and the next start waits its callback" do
      {stored, _post} = start(%{"request" => @request})

      {:ok, stored, _pre, post} = started(stored, {:error, :transient, "commit: store down"})

      assert %Task{
               status: :scheduled,
               reason_for_incompletion: nil,
               callback_after_seconds: 30,
               output_data: %{}
             } = only_task(stored)

      assert stored.status == :running
      assert {:wake_before, @now + 10 + 30_000} in post

      {:ok, stored, _pre, post} = run(stored, :wake, @now + 20)
      assert %Task{poll_count: 1} = only_task(stored)
      assert starts(post) == []

      {:ok, stored, _pre, post} = run(stored, :wake, @now + 10 + 30_000)
      assert %Task{poll_count: 2} = only_task(stored)
      assert [%{}] = starts(post)
    end

    test "WorkflowExecutor throws a NotFoundException or another exception: FAILED" do
      {stored, _post} = start(%{"request" => @request})
      message = "No such workflow defined. name=target, version=2"

      {:ok, stored, _pre, _post} = started(stored, {:error, message})

      assert %Task{status: :failed, reason_for_incompletion: ^message} = only_task(stored)
      assert stored.status == :failed
    end

    test "a result for a task that ended, or that does not exist, is dropped" do
      {stored, _post} = start(%{"request" => @request})
      id = StartWorkflow.workflow_id("wf", only_task(stored))

      {:ok, done, _pre, _post} =
        started(stored, {:ok, %Workflow{workflow_id: id, create_time: @now + 5}})

      assert done.status == :completed

      for workflow <- [done, stored] do
        {:ok, after_event, _pre, post} =
          run(workflow, {:workflow_started, "unknown", {:error, "late"}}, @now + 20)

        assert after_event == workflow
        assert starts(post) == []
      end

      {:ok, after_event, _pre, _post} = started(done, {:error, "late"}, @now + 20)
      assert after_event == done
    end

    test "a workflow the task does not ask for is ignored" do
      {stored, _post} = start(%{"request" => @request})
      {:ok, after_event, _pre, post} = started(stored, {:ok, %Workflow{workflow_id: "other"}})
      assert after_event == stored
      assert starts(post) == []
    end

    # A rerun keeps the task's ID and retry count and schedules it anew.
    test "a task run again in place asks for another workflow than its first run's" do
      {stored, _post} = start(%{"request" => @request})
      task = only_task(stored)
      rerun = %{task | scheduled_time: @now + 60_000}
      assert StartWorkflow.workflow_id("wf", rerun) != StartWorkflow.workflow_id("wf", task)
    end

    # Codex cross review r2: a rerun in the millisecond the task was first scheduled.
    test "a rerun in the millisecond of the first scheduling still asks for another workflow" do
      {stored, _post} = start(%{"request" => @request})
      task = only_task(stored)
      first = StartWorkflow.workflow_id("wf", task)

      {:ok, done, _pre, _post} =
        run(stored, {:workflow_started, task.task_id, {:ok, %Workflow{workflow_id: first}}}, @now)

      assert done.status == :completed

      request = %{
        task_id: task.task_id,
        task_input: nil,
        workflow_input: nil,
        correlation_id: nil
      }

      {:ok, rerun, _pre, post} = run(done, {:rerun, request}, @now)

      assert %Task{scheduled_time: scheduled} = only_task(rerun)
      assert scheduled == @now + 1
      assert [%{workflow_id: second}] = starts(post)
      assert second != first
    end
  end

  describe "the recovery and the response timeout" do
    test "the recovery starts a start-idempotent task again at once" do
      {stored, _post} = start(%{"request" => @request}, [], [start_task(start_delay: 60)])
      {:ok, stored, _pre, [_ | _]} = run(stored, :wake, @now)
      assert %Task{poll_count: 0} = only_task(stored)
      {:ok, stored, _pre, post} = run(stored, :wake, @now + 60_000)
      assert [%{}] = starts(post)
      assert %Task{poll_count: 1, callback_after_seconds: 60} = only_task(stored)

      # a :wake waits for the delay, as the queue would
      {:ok, waited, _pre, post} = run(stored, :wake, @now + 61_000)
      assert starts(post) == []
      assert only_task(waited).poll_count == 1

      {:ok, stored, _pre, post} = run(stored, :recover, @now + 61_000)
      task = only_task(stored)
      assert %Task{status: :scheduled, poll_count: 2, start_time: start} = task
      assert start == @now + 61_000
      assert [%{workflow_id: id}] = starts(post)
      assert id == StartWorkflow.workflow_id("wf", task)
    end

    test "the recovery does not start again a task whose start is not idempotent" do
      pending = %WorkflowTask{
        name: "pending",
        task_reference_name: "pending",
        type: "ARCHON_PENDING",
        task_definition: %TaskDef{name: "pending", retry_count: 0, response_timeout_seconds: 0}
      }

      {stored, _post} = start(%{}, [], [pending])
      assert %Task{status: :scheduled, poll_count: 1} = only_task(stored)

      {:ok, stored, _pre, _post} = run(stored, :recover, @now + 1000)
      assert %Task{status: :scheduled, poll_count: 1} = only_task(stored)
    end

    test "past its response timeout a start-idempotent task starts again, another times out" do
      # A system task's own responseTimeoutSeconds is 0, upstream's one hour.
      {stored, _post} = start(%{"request" => @request})
      later = @now + 3_600_000

      {:ok, stored, _pre, post} = run(stored, :recover, later)
      assert %Task{status: :scheduled, poll_count: 2} = only_task(stored)
      assert [%{}] = starts(post)

      pending = %WorkflowTask{
        name: "pending",
        task_reference_name: "pending",
        type: "ARCHON_PENDING",
        task_definition: %TaskDef{name: "pending", retry_count: 0}
      }

      {stored, _post} = start(%{}, [], [pending])
      {:ok, stored, _pre, _post} = run(stored, :wake, later)

      assert %Task{
               status: :timed_out,
               reason_for_incompletion:
                 "Task did not complete within its responseTimeout of 3600s"
             } = only_task(stored)
    end
  end

  # The starting side of the captured scenarios: the started workflow's own run is replayed by
  # the contract replay once NOOP is mapped.
  describe "the captured p7_start_workflow scenarios" do
    defp replay_start(start_fixture, get_fixture) do
      start = Contract.fixture(start_fixture)
      expected = Contract.fixture(get_fixture)["response"]["body"]
      {:ok, definition} = WorkflowDef.from_json(expected["workflowDefinition"])

      workflow = %Workflow{
        workflow_id: start["response"]["body"],
        status: :running,
        owner_app: "",
        workflow_definition: definition,
        input: Parameters.workflow_input(definition, start["request"]["body"])
      }

      env = env(@now, new_id: &Context.uuid4/0)
      {{:ok, _id}, stored, _pre, commit, post} = Step.run(nil, {:start, workflow}, env)
      assert apply_commit(nil, commit) == stored
      {stored, post, expected}
    end

    test "p7_start_workflow_get: the task completes with the started workflow's ID" do
      {stored, post, expected} =
        replay_start("p7_start_workflow_start", "p7_start_workflow_get")

      task = only_task(stored)

      assert [%{name: "archon_p7_noop", version: 1, correlation_id: "archon-p7"} = start] =
               starts(post)

      assert start.input == %{"a" => 2}
      started_id = expected["output"]["workflowId"]

      {:ok, stored, _pre, _post} =
        run(
          stored,
          {:workflow_started, task.task_id,
           {:ok, %Workflow{workflow_id: start.workflow_id, create_time: @now + 5}}},
          @now + 10
        )

      assert_matches(stored, "p7_start_workflow_get")

      assert Contract.normalize(only_task(stored).output_data["workflowId"]) ==
               Contract.normalize(started_id)
    end

    test "p7_start_workflow_invalid_get and _missing_get fail at the start" do
      for {start, get} <- [
            {"p7_start_workflow_invalid_start", "p7_start_workflow_invalid_get"},
            {"p7_start_workflow_missing_start", "p7_start_workflow_missing_get"}
          ] do
        {stored, post, _expected} = replay_start(start, get)
        assert starts(post) == []
        assert_matches(stored, get)
      end
    end
  end

  defp uuid3(<<a::48, _::4, b::12, _::2, c::62>>) do
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> =
      Base.encode16(<<a::48, 3::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end
