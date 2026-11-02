# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/SystemTaskRegistry.java,
# core/.../execution/tasks/WorkflowSystemTask.java, core/.../execution/tasks/SubWorkflow.java,
# common/.../metadata/tasks/TaskType.java (isBuiltIn) and
# core/.../execution/WorkflowExecutorOps.java (taskToBeRescheduled)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the registry became a map from task type to the properties upstream
# spreads over WorkflowSystemTask subclasses; only the system tasks Archon runs are registered
# by default (ADR 0026, decision 2).

defmodule Archon.Decider.SystemTasks do
  @moduledoc """
  The system task table (ADR 0026, decision 2): `Task.taskType` to the properties of the system
  task of that type. Keyed by the task's type, not the workflow task's: `FORK` is the type of the
  task the `FORK_JOIN` mapper schedules, and a type that only has a mapper (`DYNAMIC`) is not a
  system task. The mapper table keyed by `WorkflowTask.type` is `Archon.Decider.Mapper`.

  Each entry is a `t:Archon.Decider.SystemTasks.Spec.t/0`:

    * `module` - the `Archon.Decider.SystemTask` implementation (`execute/3`, optional
      `start/3`), or `nil` for a type with neither (upstream's default `execute` answers
      `false`). `DO_WHILE` and `SUB_WORKFLOW` have their own entry points the runtime calls
      (`Archon.Decider.SystemTask.DoWhile`, `Archon.Decider.SystemTask.SubWorkflow`).
    * `async?` - upstream `isAsync`: the workflow process evaluates the task
      (`Archon.Runtime.Step.Async`) instead of the decide loop.
    * `async_complete` - upstream `isAsyncComplete`: `:by_task` (upstream's default: the task's
      `asyncComplete` input when that key is present, else `workflowTask.asyncComplete`) or a
      fixed boolean (`SubWorkflow` always answers `true`).
    * `start_idempotent?` - upstream `isStartIdempotent`: an asynchronous start may run again
      after a redelivery (ADR 0026, decision 7).

  Two properties are upstream's static sets of type names rather than registry entries, so they
  hold for a type whether or not it is registered: `built_in?/1` (`TaskType.isBuiltIn`, never
  retried) and `in_place?/1` (retried in place, `taskToBeRescheduled`).

  `default/0` registers the system tasks Archon runs: `DECISION`, `SWITCH`, `FORK`, `JOIN`,
  `DO_WHILE`, `SUB_WORKFLOW` and `WAIT` (ADR 0014, decision 5), and `TERMINATE`,
  `SET_VARIABLE`, `NOOP`, `HUMAN` and `EXCLUSIVE_JOIN` (ADR 0026, decision 3). Phase 7 slices
  add their own lines.
  """

  alias Archon.Decider.SystemTask
  alias Archon.Domain.{Task, WorkflowTask}

  defmodule Spec do
    @moduledoc "One entry of the system task table (see `Archon.Decider.SystemTasks`)."

    defstruct module: nil, async?: false, async_complete: :by_task, start_idempotent?: false

    @type t :: %__MODULE__{
            module: module() | nil,
            async?: boolean(),
            async_complete: :by_task | boolean(),
            start_idempotent?: boolean()
          }
  end

  @type t :: %{optional(String.t()) => Spec.t()}

  # TaskType.isBuiltIn
  @built_in ~w(DECISION SWITCH FORK JOIN EXCLUSIVE_JOIN DO_WHILE)

  # WorkflowExecutorOps#retry: taskToBeRescheduled keeps the task ID of these types.
  @in_place ~w(DO_WHILE FORK_JOIN JOIN EXCLUSIVE_JOIN)

  @doc "The registry of the system tasks Archon runs."
  @spec default() :: t()
  def default do
    %{
      "DECISION" => %Spec{module: SystemTask.Decision},
      "SWITCH" => %Spec{module: SystemTask.Decision},
      "FORK" => %Spec{module: SystemTask.Fork},
      "JOIN" => %Spec{module: SystemTask.Join, async?: true},
      "DO_WHILE" => %Spec{module: SystemTask.DoWhile},
      "SUB_WORKFLOW" => %Spec{
        module: SystemTask.SubWorkflow,
        async?: true,
        async_complete: true,
        start_idempotent?: true
      },
      "WAIT" => %Spec{module: SystemTask.Wait, async?: true},
      "TERMINATE" => %Spec{module: SystemTask.Terminate},
      "SET_VARIABLE" => %Spec{module: SystemTask.SetVariable},
      "NOOP" => %Spec{module: SystemTask.Noop},
      "HUMAN" => %Spec{module: SystemTask.Human},
      "EXCLUSIVE_JOIN" => %Spec{module: SystemTask.ExclusiveJoin}
    }
  end

  @doc "The entry of a type, or `nil` when it is not a system task."
  @spec spec(t(), String.t() | nil) :: Spec.t() | nil
  def spec(registry, type), do: Map.get(registry, type)

  @doc "Upstream `SystemTaskRegistry#isSystemTask`."
  @spec system_task?(t(), String.t() | nil) :: boolean()
  def system_task?(registry, type), do: is_map_key(registry, type)

  @doc "Upstream `WorkflowSystemTask#isAsync` of a registered system task; `false` otherwise."
  @spec async?(t(), String.t() | nil) :: boolean()
  def async?(registry, type), do: match?(%Spec{async?: true}, spec(registry, type))

  @doc "Upstream `WorkflowSystemTask#isStartIdempotent`; `false` for an unregistered type."
  @spec start_idempotent?(t(), String.t() | nil) :: boolean()
  def start_idempotent?(registry, type),
    do: match?(%Spec{start_idempotent?: true}, spec(registry, type))

  @doc "Upstream `TaskType.isBuiltIn`: a type that is never retried."
  @spec built_in?(String.t() | nil) :: boolean()
  def built_in?(type), do: type in @built_in

  @doc "A type upstream retries in place, keeping the task ID (`taskToBeRescheduled`)."
  @spec in_place?(String.t() | nil) :: boolean()
  def in_place?(type), do: type in @in_place

  @doc """
  Upstream `DeciderService#isAyncCompleteSystemTask`: a registered system task whose
  `isAsyncComplete` answers `true`.
  """
  @spec async_complete?(t(), Task.t()) :: boolean()
  def async_complete?(registry, %Task{task_type: type} = task) do
    case spec(registry, type) do
      nil -> false
      %Spec{async_complete: :by_task} -> by_task(task)
      %Spec{async_complete: fixed} -> fixed
    end
  end

  defp by_task(%Task{input_data: %{"asyncComplete" => value}}), do: value == true

  defp by_task(%Task{workflow_task: %WorkflowTask{async_complete: value}}), do: value == true
  defp by_task(%Task{}), do: false
end
