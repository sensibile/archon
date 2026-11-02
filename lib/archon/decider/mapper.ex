# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/TaskMapper.java
# and core/.../execution/DeciderService.java (mapper lookup)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the mapper interface became a behaviour returning values instead of
# throwing; the Spring bean map became a static registry.

defmodule Archon.Decider.Mapper do
  @moduledoc """
  Turns one `WorkflowTask` into the tasks to schedule (upstream `TaskMapper`).

  The mapper table (ADR 0026, decision 2) is keyed by `WorkflowTask.type`; the tasks a mapper
  makes are looked up by their own `taskType` in the system task table
  (`Archon.Decider.SystemTasks`). `module_for/1` picks the mapper. Types without a mapper go to
  `Archon.Decider.Mapper.UserDefined`, as upstream falls back to `USER_DEFINED`
  (ADR 0014, decision 5). Phase 7 slices add their own lines.
  """

  alias Archon.Decider.Mapper.{
    Context,
    Decision,
    DoWhile,
    Dynamic,
    ForkJoin,
    ForkJoinDynamic,
    Join,
    Simple,
    SubWorkflow,
    Switch,
    UserDefined,
    Wait
  }

  alias Archon.Domain.{Task, WorkflowTask}

  @callback map(WorkflowTask.t(), Context.t()) :: {:ok, [Task.t()]} | {:terminate, String.t()}

  @doc """
  Whether the mapper changes its workflow task the way upstream's changes the definition object
  in place (`DYNAMIC` sets its name and task definition, `HTTP` its `asyncComplete` input),
  which then shows in the workflow's stored definition (ADR 0026, decisions 4 and 7). Such a
  mapper puts the changed workflow task in the `workflow_task` of the tasks it returns, and
  `Archon.Decider` writes it back into `Outcome.workflow`'s definition
  (`Outcome.changed_workflow_tasks`). Optional; `false` without it.
  """
  @callback changes_definition?() :: boolean()
  @optional_callbacks changes_definition?: 0

  @mappers %{
    "SIMPLE" => Simple,
    "SWITCH" => Switch,
    "DECISION" => Decision,
    "FORK_JOIN" => ForkJoin,
    "JOIN" => Join,
    "DO_WHILE" => DoWhile,
    "SUB_WORKFLOW" => SubWorkflow,
    "WAIT" => Wait,
    "DYNAMIC" => Dynamic,
    "FORK_JOIN_DYNAMIC" => ForkJoinDynamic
  }

  @doc "The mapper for a task type, `UserDefined` when none is registered."
  @spec module_for(String.t() | nil) :: module()
  def module_for(type), do: Map.get(@mappers, type, UserDefined)

  @doc "Whether the mapper of a workflow task type changes the definition (`c:changes_definition?/0`)."
  @spec changes_definition?(String.t() | nil) :: boolean()
  def changes_definition?(type) do
    module = Code.ensure_loaded!(module_for(type))
    function_exported?(module, :changes_definition?, 0) and module.changes_definition?()
  end

  @doc "Whether a workflow task type has a mapper of its own (is not mapped as `UserDefined`)."
  @spec mapped?(String.t() | nil) :: boolean()
  def mapped?(type), do: is_map_key(@mappers, type)
end
