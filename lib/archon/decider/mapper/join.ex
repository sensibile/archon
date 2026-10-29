# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/JoinTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour.

defmodule Archon.Decider.Mapper.Join do
  @moduledoc """
  Upstream `JoinTaskMapper`: one `IN_PROGRESS` `JOIN` task whose input is the `joinOn` list.
  Whether it completes is decided by `Archon.Decider.SystemTask.Join.execute/2`.
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
         | task_type: "JOIN",
           task_def_name: "JOIN",
           start_time: context.decider.now,
           input_data: %{"joinOn" => wt.join_on},
           status: :in_progress,
           isolation_group_id: isolation_group_id(context.task_definition)
       }
     ]}
  end

  defp isolation_group_id(%TaskDef{isolation_group_id: id}), do: id
  defp isolation_group_id(nil), do: nil
end
