# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/SimpleTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour.

defmodule Archon.Decider.Mapper.Simple do
  @moduledoc """
  Upstream `SimpleTaskMapper`: one `SCHEDULED` task for a `SIMPLE` worker task.

  The task type is the `WorkflowTask` name, so workers poll by task definition name. Without an
  embedded task definition the `TaskDef` defaults apply (upstream `new TaskDef()`); the
  runtime embeds definitions when it starts a workflow.
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.{TaskDef, WorkflowTask}

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    task_def = wt.task_definition || %TaskDef{}
    task = Context.create_task(context)

    {:ok,
     [
       %{
         task
         | task_type: wt.name,
           start_delay_in_seconds: wt.start_delay,
           input_data: Context.task_input(context, task_def),
           status: :scheduled,
           retry_count: context.retry_count,
           callback_after_seconds: wt.start_delay,
           response_timeout_seconds: task_def.response_timeout_seconds,
           retried_task_id: context.retry_task_id,
           rate_limit_per_frequency: task_def.rate_limit_per_frequency,
           rate_limit_frequency_in_seconds: task_def.rate_limit_frequency_in_seconds
       }
     ]}
  end
end
