# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/HTTPTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour, and the
# change to the definition's workflow task is returned instead of made in place (ADR 0026,
# decision 7).

defmodule Archon.Decider.Mapper.Http do
  @moduledoc """
  Upstream `HTTPTaskMapper`: one `SCHEDULED` `HTTP` task. The workflow process sends its request
  (`Archon.Runtime.Step.Http`, ADR 0026, decision 7).

  Before the input is resolved, the workflow task's `inputParameters.asyncComplete` is set to its
  `asyncComplete`, so an expression given there is replaced. Upstream makes the change on the
  definition object; here the changed workflow task is the task's `workflow_task`, which
  `Archon.Decider` writes back into the definition (`c:Archon.Decider.Mapper.changes_definition?/0`).

  The input is `getTaskInputV2` with the embedded task definition, else the one the metadata has.
  A definition is not needed; when there is one, its rate limit, `isolationGroupId` and
  `executionNameSpace` are copied. `responseTimeoutSeconds` is not (upstream's mapper does not
  set it), so the task's response timeout is upstream's default hour.
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.{TaskDef, WorkflowTask}

  @impl true
  def changes_definition?, do: true

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    wt = %{
      wt
      | input_parameters: Map.put(wt.input_parameters || %{}, "asyncComplete", wt.async_complete)
    }

    context = %{context | workflow_task: wt}
    task_def = task_definition(context)
    task = Context.create_task(context)

    task = %{
      task
      | task_type: "HTTP",
        input_data: Context.task_input(context, task_def),
        status: :scheduled,
        retry_count: context.retry_count,
        callback_after_seconds: wt.start_delay
    }

    {:ok, [copy_definition(task, task_def)]}
  end

  defp task_definition(%Context{task_definition: %TaskDef{} = task_def}), do: task_def

  defp task_definition(%Context{workflow_task: wt, decider: decider}) do
    case decider.task_def_lookup.(wt.name) do
      {:ok, task_def} -> task_def
      {:error, :not_found} -> nil
    end
  end

  defp copy_definition(task, nil), do: task

  defp copy_definition(task, %TaskDef{} = task_def) do
    %{
      task
      | rate_limit_per_frequency: task_def.rate_limit_per_frequency,
        rate_limit_frequency_in_seconds: task_def.rate_limit_frequency_in_seconds,
        isolation_group_id: task_def.isolation_group_id,
        execution_name_space: task_def.execution_name_space
    }
  end
end
