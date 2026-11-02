# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Step.DynamicStepTest do
  @moduledoc """
  `DYNAMIC` in the decide loop (ADR 0026, decision 4): a name that is a registered synchronous
  system task type takes that type's path in the same step (`p7_dynamic_system_get` once NOOP is
  registered, slice 7b), and the definition the mapper changed is in the step's commit.
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay, only: [apply_commit: 2]

  alias Archon.Decider.{SystemTask, SystemTasks}
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.Env

  # Like NOOP: completes when executed.
  defmodule NoopLike do
    @behaviour SystemTask

    @impl true
    def execute(_workflow, task, _context), do: SystemTask.changed(%{task | status: :completed})
  end

  @now 1_000_000

  defp env do
    counter = :counters.new(1, [])

    Env.new(
      now: @now,
      new_id: fn ->
        :counters.add(counter, 1, 1)
        "id-#{:counters.get(counter, 1)}"
      end,
      system_tasks:
        Map.put(SystemTasks.default(), "ARCHON_NOOP", %SystemTasks.Spec{module: NoopLike})
    )
  end

  defp start(name) do
    dynamic = %WorkflowTask{
      name: "dyn",
      task_reference_name: "dyn_ref",
      type: "DYNAMIC",
      dynamic_task_name_param: "taskToExecute",
      input_parameters: %{"taskToExecute" => "${workflow.input.task}"},
      task_definition: %TaskDef{name: "dyn", retry_count: 0, response_timeout_seconds: 0}
    }

    workflow = %Workflow{
      workflow_id: "wf",
      status: :running,
      owner_app: "",
      input: %{"task" => name},
      workflow_definition: %WorkflowDef{name: "wf", version: 1, tasks: [dynamic]}
    }

    {{:ok, "wf"}, stored, _pre, commit, _post} = Step.run(nil, {:start, workflow}, env())
    assert apply_commit(nil, commit) == stored
    # a new workflow is created by its first commit
    {stored, commit.workflow || commit.create}
  end

  test "a registered system type runs in the same step and the workflow completes" do
    {stored, %Workflow{} = saved} = start("ARCHON_NOOP")

    assert stored.status == :completed

    assert [%Task{task_type: "ARCHON_NOOP", task_def_name: "ARCHON_NOOP", status: :completed}] =
             stored.tasks

    assert [%WorkflowTask{name: "ARCHON_NOOP"}] = saved.workflow_definition.tasks
  end

  test "a worker name is scheduled and the changed definition is saved in that step" do
    {stored, %Workflow{} = saved} = start("worker")

    assert stored.status == :running
    assert [%Task{task_type: "worker", status: :scheduled}] = stored.tasks

    assert [%WorkflowTask{name: "worker", task_definition: %TaskDef{name: "dyn"}}] =
             saved.workflow_definition.tasks
  end
end
