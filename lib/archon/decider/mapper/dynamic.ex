# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/DynamicTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; the
# workflow task changed in place is returned in the task (changes_definition?/0); the
# MetadataDAO lookup reads the Decider context.

defmodule Archon.Decider.Mapper.Dynamic do
  @moduledoc """
  Upstream `DynamicTaskMapper`: one `SCHEDULED` task whose type is the name the
  `dynamicTaskNameParam` input resolves to (`String.valueOf`), so a system task type takes its
  own path (ADR 0026, decision 4).

  The task definition is the one embedded in the workflow task, else the one the context's
  `task_def_lookup` finds by the resolved name; without either the workflow terminates. A started
  workflow always has one embedded: the runtime gives every task without a registered definition
  an ad-hoc one named like the workflow task (`Archon.Runtime.populate/1`), so a name without a
  definition is scheduled as it is (`p7_dynamic_missing_get`).

  Upstream sets the name and the task definition on the definition's workflow task, which the
  workflow's stored definition then shows. The changed workflow task is the task's
  `workflow_task`, and `Archon.Decider` writes it back (`c:Archon.Decider.Mapper.changes_definition?/0`).
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Decider.Parameters
  alias Archon.Domain.{TaskDef, WorkflowTask}

  @impl true
  def changes_definition?, do: true

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    with {:ok, name} <- task_name(context.task_input, wt.dynamic_task_name_param),
         wt = %{wt | name: name},
         {:ok, task_def} <- task_definition(wt, context) do
      wt = %{wt | task_definition: task_def}
      context = %{context | workflow_task: wt, task_definition: task_def}
      task = Context.create_task(context)

      {:ok,
       [
         %{
           task
           | task_type: name,
             start_delay_in_seconds: wt.start_delay,
             input_data: Context.task_input(context, task_def),
             status: :scheduled,
             retry_count: context.retry_count,
             callback_after_seconds: wt.start_delay,
             response_timeout_seconds: task_def.response_timeout_seconds,
             retried_task_id: context.retry_task_id
         }
       ]}
    end
  end

  # getDynamicTaskName
  defp task_name(input, param) do
    case Map.get(input, param) do
      nil ->
        {:terminate,
         "Cannot map a dynamic task based on the parameter and input. " <>
           "Parameter= #{Parameters.java_string(param)}, input= #{Parameters.java_string(input)}"}

      value ->
        {:ok, Parameters.java_string(value)}
    end
  end

  # getDynamicTaskDefinition
  defp task_definition(%WorkflowTask{task_definition: %TaskDef{} = task_def}, _context),
    do: {:ok, task_def}

  defp task_definition(%WorkflowTask{name: name}, context) do
    case lookup(context.decider.task_def_lookup, name) do
      {:ok, %TaskDef{} = task_def} ->
        {:ok, task_def}

      _not_found ->
        {:terminate,
         "Invalid task specified.  Cannot find task by name #{name} in the task definitions"}
    end
  end

  defp lookup(nil, _name), do: {:error, :not_found}
  defp lookup(fun, name), do: fun.(name)
end
