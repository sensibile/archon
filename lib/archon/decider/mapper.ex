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

  `module_for/1` picks the mapper by `WorkflowTask.type`. Types without a mapper go to
  `Archon.Decider.Mapper.UserDefined`, as upstream falls back to `USER_DEFINED`
  (ADR 0014, decision 5).
  """

  alias Archon.Decider.Mapper.{
    Context,
    Decision,
    DoWhile,
    ForkJoin,
    Join,
    Simple,
    SubWorkflow,
    Switch,
    UserDefined,
    Wait
  }

  alias Archon.Domain.{Task, WorkflowTask}

  @callback map(WorkflowTask.t(), Context.t()) :: {:ok, [Task.t()]} | {:terminate, String.t()}

  @mappers %{
    "SIMPLE" => Simple,
    "SWITCH" => Switch,
    "DECISION" => Decision,
    "FORK_JOIN" => ForkJoin,
    "JOIN" => Join,
    "DO_WHILE" => DoWhile,
    "SUB_WORKFLOW" => SubWorkflow,
    "WAIT" => Wait
  }

  @doc "The mapper for a task type, `UserDefined` when none is registered."
  @spec module_for(String.t() | nil) :: module()
  def module_for(type), do: Map.get(@mappers, type, UserDefined)
end
