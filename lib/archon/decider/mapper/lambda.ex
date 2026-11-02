# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/LambdaTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; reads the
# clock from the Decider context and a missing task definition from its task_defs or
# task_def_lookup.

defmodule Archon.Decider.Mapper.Lambda do
  @moduledoc """
  Upstream `LambdaTaskMapper` (deprecated upstream in favour of `INLINE`): one `IN_PROGRESS`
  `LAMBDA` task with the input `getTaskInputV2` resolves. Unlike `INLINE` it sets no isolation
  group. `Archon.Decider.SystemTask.Lambda` evaluates it in the same decide (ADR 0026,
  decision 5).
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.{Context, Inline}
  alias Archon.Domain.WorkflowTask

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    task = Context.create_task(context)

    {:ok,
     [
       %{
         task
         | task_type: "LAMBDA",
           start_time: context.decider.now,
           input_data: Context.task_input(context, Inline.task_definition(wt, context)),
           status: :in_progress
       }
     ]}
  end
end
