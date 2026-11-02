# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Step.SystemTaskRegistryTest do
  @moduledoc """
  The system task table and behaviour as the runtime uses them (ADR 0026, decision 2): a type
  registered in `env.system_tasks` with an `Archon.Decider.SystemTask` module is started when
  scheduled and executed by the decide loop, the task it answers is kept, and a workflow it
  answers is saved even when the loop ends with nothing else to save.
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay, only: [apply_commit: 2]

  alias Archon.Decider.{Context, SystemTask, SystemTasks}
  alias Archon.Domain.{Task, TaskDef, TaskResult, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Commit
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.Env

  # A synchronous type like SET_VARIABLE: `start` marks the task, `execute` completes it and
  # puts its input into the workflow's variables.
  defmodule SetLike do
    @behaviour SystemTask

    @impl true
    def start(_workflow, task, _context),
      do: SystemTask.changed(%{task | output_data: %{"started" => true}})

    @impl true
    def execute(workflow, task, _context) do
      %SystemTask.Result{
        changed?: true,
        task: %{task | status: :completed},
        workflow: %{workflow | variables: Map.merge(workflow.variables, task.input_data)}
      }
    end
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
        Map.put(SystemTasks.default(), "ARCHON_SET", %SystemTasks.Spec{module: SetLike})
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
      variables: %{"keep" => 1},
      workflow_definition: %WorkflowDef{name: "wf", version: 1, tasks: tasks}
    }

    {{:ok, "wf"}, stored, _pre, commit, _post} = Step.run(nil, {:start, workflow}, env())
    assert apply_commit(nil, commit) == stored
    stored
  end

  defp run(workflow, event) do
    {reply, stored, _pre, commit, _post} = Step.run(workflow, event, env())
    assert apply_commit(workflow, commit) == stored
    {reply, stored, commit}
  end

  test "a registered synchronous type is started, executed and saves the workflow it answers" do
    stored =
      start([task("ARCHON_SET", "set", input_parameters: %{"v" => 1}), task("SIMPLE", "worker")])

    assert [
             %Task{
               task_type: "ARCHON_SET",
               status: :completed,
               output_data: %{"started" => true}
             },
             %Task{reference_task_name: "worker", status: :scheduled}
           ] = stored.tasks

    assert stored.variables == %{"keep" => 1, "v" => 1}
  end

  # ADR 0026, decision 2: the decide loop ends with a JOIN still waiting, which saves nothing of
  # its own, so the workflow the task answered has to be saved when the task gives it.
  test "the workflow answered at the end of a FORK branch is saved" do
    workflow =
      start([
        task("FORK_JOIN", "fork",
          fork_tasks: [
            [task("SIMPLE", "worker")],
            [task("SIMPLE", "first"), task("ARCHON_SET", "set", input_parameters: %{"v" => 2})]
          ]
        ),
        task("JOIN", "join", join_on: ["worker", "set"])
      ])

    first = Enum.find(workflow.tasks, &(&1.reference_task_name == "first"))
    {%Task{}, workflow, _commit} = run(workflow, {:poll, first.task_id, "w"})

    result = %TaskResult{
      workflow_instance_id: "wf",
      task_id: first.task_id,
      status: :completed
    }

    {_reply, stored, %Commit{workflow: %Workflow{} = saved}} = run(workflow, {:update, result})

    assert %Task{status: :completed} = Enum.find(stored.tasks, &(&1.reference_task_name == "set"))
    assert %Task{status: :in_progress} = Enum.find(stored.tasks, &(&1.task_type == "JOIN"))
    assert saved.variables == %{"keep" => 1, "v" => 2}
    assert stored.variables == saved.variables
  end

  test "a type without start or execute leaves the task as it is" do
    context = Context.new(now: @now)
    workflow = %Workflow{}
    task = %Task{task_type: "SUB_WORKFLOW", status: :scheduled}

    # SUB_WORKFLOW's module has execute/2 for the runtime, not this behaviour.
    assert SystemTask.start(workflow, task, context) == nil

    assert SystemTask.execute(workflow, task, context) ==
             %SystemTask.Result{changed?: false, task: task}

    unregistered = %Task{task_type: "SIMPLE"}
    assert SystemTask.start(workflow, unregistered, context) == nil
    assert SystemTask.execute(workflow, unregistered, context).task == unregistered
  end
end
