# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/SetVariableTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour and reads
# the clock from the Decider context.

defmodule Archon.Decider.Mapper.SetVariable do
  @moduledoc """
  Upstream `SetVariableTaskMapper`: one `IN_PROGRESS` `SET_VARIABLE` task whose input is the
  mapper context's task input (resolved without a task ID). `Archon.Decider.SystemTask.SetVariable`
  executes it (ADR 0026, decision 3).
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
         | start_time: context.decider.now,
           input_data: context.task_input,
           status: :in_progress
       }
     ]}
  end
end
