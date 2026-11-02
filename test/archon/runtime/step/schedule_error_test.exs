# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Step.ScheduleErrorTest do
  @moduledoc """
  A synchronous system task whose `start` fails (upstream's throws, as `JSON_JQ_TRANSFORM`'s
  cast of a `queryExpression` that is not a string) fails the scheduling: upstream's
  `scheduleTask` throws `Error scheduling tasks: [<IDs>], for workflow: <ID>` and the workflow
  terminates (ADR 0026, decision 6). Wherever the runtime schedules: the decide loop, the next
  `DO_WHILE` iteration and a retry.
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay, only: [apply_commit: 2]

  alias Archon.Decider.{SystemTask, SystemTasks}
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.Env

  # Starts as upstream's start would throw when its input asks for it on this iteration or
  # retry; otherwise fails or completes the task as its input says.
  defmodule Starting do
    @behaviour SystemTask

    @impl true
    def start(_workflow, %Task{input_data: input} = task, _context) do
      cond do
        task.iteration in List.wrap(input["throw_on_iteration"]) ->
          {:error, "boom"}

        task.retry_count in List.wrap(input["throw_on_retry"]) ->
          {:error, "boom"}

        input["fail"] == true and task.retry_count == 0 ->
          SystemTask.changed(%{task | status: :failed})

        true ->
          SystemTask.changed(%{task | status: :completed})
      end
    end

    @impl true
    def execute(_workflow, task, _context), do: SystemTask.unchanged(task)
  end

  @now 1_000_000

  # IDs stay unique across the steps of a test.
  defp env do
    Env.new(
      now: @now,
      new_id: fn -> "id-#{System.unique_integer([:positive, :monotonic])}" end,
      system_tasks:
        Map.put(SystemTasks.default(), "ARCHON_START", %SystemTasks.Spec{module: Starting})
    )
  end

  defp task(type, ref, fields \\ []) do
    struct!(
      %WorkflowTask{
        name: ref,
        task_reference_name: ref,
        type: type,
        task_definition: %TaskDef{name: ref, retry_count: 0, response_timeout_seconds: 0}
      },
      fields
    )
  end

  defp start(tasks) do
    workflow = %Workflow{
      workflow_id: "wf",
      status: :running,
      owner_app: "",
      workflow_definition: %WorkflowDef{name: "wf", version: 1, tasks: tasks}
    }

    run(nil, {:start, workflow})
  end

  defp run(workflow, event) do
    {_reply, stored, _pre, commit, _post} = Step.run(workflow, event, env())
    assert apply_commit(workflow, commit) == stored
    stored
  end

  test "the tasks scheduled together are named, and every one of them is canceled" do
    stored =
      start([
        task("FORK_JOIN", "fork",
          fork_tasks: [
            [task("SIMPLE", "worker")],
            [task("ARCHON_START", "start", input_parameters: %{"throw_on_iteration" => 0})]
          ]
        ),
        task("JOIN", "join", join_on: ["worker", "start"])
      ])

    assert stored.status == :failed
    ids = Enum.map_join(stored.tasks, ", ", & &1.task_id)
    assert stored.reason_for_incompletion == "Error scheduling tasks: [#{ids}], for workflow: wf"

    assert [
             %Task{task_type: "FORK", status: :completed},
             %Task{reference_task_name: "worker", status: :canceled},
             %Task{reference_task_name: "start", status: :canceled},
             %Task{task_type: "JOIN", status: :canceled}
           ] = stored.tasks
  end

  test "the next DO_WHILE iteration that fails to start terminates the workflow" do
    stored =
      start([
        task("DO_WHILE", "loop",
          loop_condition: "true",
          loop_over: [
            task("ARCHON_START", "start", input_parameters: %{"throw_on_iteration" => 2})
          ]
        )
      ])

    assert stored.status == :failed
    assert [%Task{task_type: "DO_WHILE"} = loop, first, second] = stored.tasks
    assert first.status == :completed
    assert second.iteration == 2
    assert second.status == :canceled
    assert loop.status == :canceled

    assert stored.reason_for_incompletion ==
             "Error scheduling tasks: [#{second.task_id}], for workflow: wf"
  end

  test "a retried task that fails to start terminates the workflow again" do
    stored =
      start([
        task("ARCHON_START", "start", input_parameters: %{"fail" => true, "throw_on_retry" => 1})
      ])

    assert stored.status == :failed
    assert [%Task{status: :failed}] = stored.tasks

    retried = run(stored, {:retry, true})
    assert retried.status == :failed
    assert [%Task{status: :failed}, %Task{retry_count: 1} = copy] = retried.tasks
    assert copy.status == :canceled

    assert retried.reason_for_incompletion ==
             "Error scheduling tasks: [#{copy.task_id}], for workflow: wf"
  end
end
