# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/TerminateTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour and reads
# the clock from the Decider context.

defmodule Archon.Decider.Mapper.Terminate do
  @moduledoc """
  Upstream `TerminateTaskMapper`: one `IN_PROGRESS` `TERMINATE` task whose input is
  `getTaskInputV2` without a task definition. `Archon.Decider.SystemTask.Terminate` executes it
  (ADR 0026, decision 3).
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.WorkflowTask

  @impl true
  def map(%WorkflowTask{}, %Context{} = context) do
    task = Context.create_task(context)

    {:ok,
     [
       %{
         task
         | task_type: "TERMINATE",
           start_time: context.decider.now,
           input_data: Context.task_input(context, nil),
           status: :in_progress
       }
     ]}
  end
end
