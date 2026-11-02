# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/JsonJQTransformTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; reads the
# clock and the task definition lookup from the Decider context (ADR 0026, decision 6).

defmodule Archon.Decider.Mapper.JsonJqTransform do
  @moduledoc """
  Upstream `JsonJQTransformTaskMapper`: one `IN_PROGRESS` `JSON_JQ_TRANSFORM` task whose input is
  `getTaskInputV2` of the workflow task's inputs with the task definition's `inputTemplate`.

  The task definition is the context's, else the one `task_def_lookup` reads by name (upstream's
  `MetadataDAO#getTaskDef` fallback). The query runs when the task is scheduled
  (`Archon.Decider.SystemTask.JsonJqTransform`).
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.{TaskDef, WorkflowTask}

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    task_def = context.task_definition || lookup(context, wt.name)
    task = Context.create_task(context)

    {:ok,
     [
       %{
         task
         | start_time: context.decider.now,
           input_data: Context.task_input(context, task_def),
           isolation_group_id: isolation_group_id(context.task_definition),
           status: :in_progress
       }
     ]}
  end

  defp lookup(%Context{decider: decider}, name) when is_binary(name) do
    case decider.task_def_lookup.(name) do
      {:ok, %TaskDef{} = task_def} -> task_def
      {:error, :not_found} -> nil
    end
  end

  defp lookup(_context, _name), do: nil

  defp isolation_group_id(%TaskDef{isolation_group_id: id}), do: id
  defp isolation_group_id(nil), do: nil
end
