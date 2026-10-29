# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/UserDefinedTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; the
# MetadataDAO lookup reads the Decider context's task definitions.

defmodule Archon.Decider.Mapper.UserDefined do
  @moduledoc """
  Upstream `UserDefinedTaskMapper`: one `SCHEDULED` task for a type no other mapper handles.

  The task definition is the embedded one, else the one named like the `WorkflowTask` in the
  context's `task_defs`. Without either the workflow terminates.
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.WorkflowTask

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    case context.task_definition || Map.get(context.decider.task_defs, wt.name) do
      nil ->
        {:terminate,
         "Invalid task specified. Cannot find task by name #{java_string(wt.name)} in the task definitions"}

      task_def ->
        task = Context.create_task(context)

        {:ok,
         [
           %{
             task
             | input_data: Context.task_input(context, task_def),
               status: :scheduled,
               retry_count: context.retry_count,
               callback_after_seconds: wt.start_delay,
               rate_limit_per_frequency: task_def.rate_limit_per_frequency,
               rate_limit_frequency_in_seconds: task_def.rate_limit_frequency_in_seconds
           }
         ]}
    end
  end

  defp java_string(nil), do: "null"
  defp java_string(name), do: name
end
