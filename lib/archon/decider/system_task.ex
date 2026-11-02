# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/WorkflowSystemTask.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: start and execute return the updated task (and workflow) with
# upstream's boolean instead of mutating them, take the Decider context instead of reading the
# clock, and do not take the WorkflowExecutor (ADR 0014, decision 5; ADR 0026, decision 2).

defmodule Archon.Decider.SystemTask do
  @moduledoc """
  The state-deciding part of upstream `WorkflowSystemTask`, as pure functions (ADR 0014,
  decision 5; ADR 0026, decision 2).

  A system task type implements this behaviour and is listed in the system task table
  (`Archon.Decider.SystemTasks`):

    * `start/3` (optional) - upstream `start`. The runtime calls it once, right after it
      schedules a synchronous system task (`Archon.Runtime.Step.Schedule`). It answers
      `{:error, reason}` where upstream's `start` throws: the scheduling then fails and the
      workflow terminates (`Error scheduling tasks: ...`). `reason` stands for upstream's exception,
      which upstream only logs.
    * `execute/3` - upstream `execute`. The decide loop calls it for a synchronous system task
      that is not terminal; the workflow process calls it for an asynchronous one it evaluates.

  Both return a `t:Archon.Decider.SystemTask.Result.t/0`. `changed?` is upstream's boolean: the
  task is saved only when it is `true`. The returned task is kept in the workflow either way,
  as upstream changes its task in place even when it answers `false`. `workflow` is set only by
  a type that changes the workflow outside its task (its `variables`); the runtime saves it.

  `start/2` and `execute/3` here dispatch by `Task.taskType` through `context.system_tasks`.
  `DO_WHILE` (`Archon.Decider.SystemTask.DoWhile`) schedules its next iteration and
  `SUB_WORKFLOW` (`Archon.Decider.SystemTask.SubWorkflow`) needs its child workflow, so the
  runtime calls those modules directly.
  """

  alias Archon.Decider.{Context, SystemTasks}
  alias Archon.Domain.{Task, Workflow}

  defmodule Result do
    @moduledoc "What `start` or `execute` of a system task answers (see `Archon.Decider.SystemTask`)."

    @enforce_keys [:changed?, :task]
    defstruct [:changed?, :task, workflow: nil]

    @type t :: %__MODULE__{
            changed?: boolean(),
            task: Task.t(),
            workflow: Workflow.t() | nil
          }
  end

  @callback start(Workflow.t(), Task.t(), Context.t()) :: Result.t() | {:error, String.t()}
  @callback execute(Workflow.t(), Task.t(), Context.t()) :: Result.t()
  @optional_callbacks start: 3

  @doc "A result that changed the task."
  @spec changed(Task.t()) :: Result.t()
  def changed(%Task{} = task), do: %Result{changed?: true, task: task}

  @doc "A result that leaves the task to be saved later, if at all."
  @spec unchanged(Task.t()) :: Result.t()
  def unchanged(%Task{} = task), do: %Result{changed?: false, task: task}

  @doc """
  Upstream `start` of the task's system task type, or `nil` when the type has none (upstream's
  default `start` does nothing). `{:error, reason}` is a `start` that throws upstream.
  """
  @spec start(Workflow.t(), Task.t(), Context.t()) :: Result.t() | {:error, String.t()} | nil
  def start(%Workflow{} = workflow, %Task{} = task, %Context{} = context) do
    case module(context, task) do
      nil ->
        nil

      module ->
        if function_exported?(module, :start, 3),
          do: module.start(workflow, task, context),
          else: nil
    end
  end

  @doc """
  Upstream `execute` of the task's system task type. A type without an implementation answers
  `false` with the task unchanged (upstream's default `execute`).
  """
  @spec execute(Workflow.t(), Task.t(), Context.t()) :: Result.t()
  def execute(%Workflow{} = workflow, %Task{} = task, %Context{} = context) do
    case module(context, task) do
      nil ->
        unchanged(task)

      module ->
        if function_exported?(module, :execute, 3),
          do: module.execute(workflow, task, context),
          else: unchanged(task)
    end
  end

  # Only a module that implements this behaviour: DO_WHILE's and SUB_WORKFLOW's modules have
  # functions of the same names with other contracts.
  defp module(%Context{system_tasks: registry}, %Task{task_type: type}) do
    with %SystemTasks.Spec{module: module} when module != nil <- SystemTasks.spec(registry, type),
         module = Code.ensure_loaded!(module),
         true <- __MODULE__ in behaviours(module) do
      module
    else
      _none -> nil
    end
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
end
