# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/ExclusiveJoinTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour and reads
# the clock from the Decider context.

defmodule Archon.Decider.Mapper.ExclusiveJoin do
  @moduledoc """
  Upstream `ExclusiveJoinTaskMapper`: one `IN_PROGRESS` `EXCLUSIVE_JOIN` task whose input is
  the `joinOn` list and, when the definition has one, the `defaultExclusiveJoinTask` list.
  `Archon.Decider.SystemTask.ExclusiveJoin` decides whether it is done (ADR 0026, decision 3).
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.WorkflowTask

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    task = Context.create_task(context)

    input =
      if wt.default_exclusive_join_task == nil,
        do: %{"joinOn" => wt.join_on},
        else: %{
          "joinOn" => wt.join_on,
          "defaultExclusiveJoinTask" => wt.default_exclusive_join_task
        }

    {:ok,
     [
       %{
         task
         | task_type: "EXCLUSIVE_JOIN",
           task_def_name: "EXCLUSIVE_JOIN",
           start_time: context.decider.now,
           input_data: input,
           status: :in_progress
       }
     ]}
  end
end
