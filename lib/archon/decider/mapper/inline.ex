# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/InlineTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; reads the
# clock from the Decider context and a missing task definition from its task_defs or
# task_def_lookup.

defmodule Archon.Decider.Mapper.Inline do
  @moduledoc """
  Upstream `InlineTaskMapper`: one `IN_PROGRESS` `INLINE` task whose input is the resolved
  `inputParameters` merged with the task definition's `inputTemplate` (`getTaskInputV2`).
  `Archon.Decider.SystemTask.Inline` evaluates it in the same decide (ADR 0026, decision 5).
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.{TaskDef, WorkflowTask}

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    task = Context.create_task(context)

    {:ok,
     [
       %{
         task
         | task_type: "INLINE",
           start_time: context.decider.now,
           input_data: Context.task_input(context, task_definition(wt, context)),
           isolation_group_id: isolation_group_id(context.task_definition),
           status: :in_progress
       }
     ]}
  end

  # Optional.ofNullable(getTaskDefinition()).orElseGet(() -> metadataDAO.getTaskDef(name)): the
  # definitions the caller filled first, as `UserDefined` reads them, then the store.
  @doc false
  @spec task_definition(WorkflowTask.t(), Context.t()) :: TaskDef.t() | nil
  def task_definition(_wt, %Context{task_definition: %TaskDef{} = task_def}), do: task_def

  def task_definition(%WorkflowTask{name: name}, %Context{decider: decider})
      when is_binary(name) do
    with nil <- Map.get(decider.task_defs, name),
         {:ok, %TaskDef{} = task_def} <- decider.task_def_lookup.(name) do
      task_def
    else
      %TaskDef{} = task_def -> task_def
      {:error, :not_found} -> nil
    end
  end

  def task_definition(_wt, _context), do: nil

  defp isolation_group_id(%TaskDef{isolation_group_id: id}), do: id
  defp isolation_group_id(nil), do: nil
end
