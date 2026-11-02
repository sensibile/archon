# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/StartWorkflowTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour.

defmodule Archon.Decider.Mapper.StartWorkflow do
  @moduledoc """
  Upstream `StartWorkflowTaskMapper`: one `SCHEDULED` `START_WORKFLOW` task with the task input
  and `callbackAfterSeconds` = `startDelay`. The workflow process starts it
  (`Archon.Runtime.Step.StartWorkflow`, ADR 0026, decision 7).
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.WorkflowTask

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    task = Context.create_task(context)

    {:ok,
     [
       %{
         task
         | task_type: "START_WORKFLOW",
           input_data: context.task_input,
           status: :scheduled,
           callback_after_seconds: wt.start_delay
       }
     ]}
  end
end
