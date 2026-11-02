# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/ForkJoinTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; an empty
# branch is passed over instead of throwing IndexOutOfBoundsException; the FORK task and the
# JOIN lookup are shared with the FORK_JOIN_DYNAMIC mapper.

defmodule Archon.Decider.Mapper.ForkJoin do
  @moduledoc """
  Upstream `ForkJoinTaskMapper`: a `COMPLETED` `FORK` task, the first task of every branch in
  order, then the `JOIN` that follows the fork in the definition.

  The workflow terminates when the fork is not followed by a `JOIN`. Upstream throws
  `IndexOutOfBoundsException` on an empty branch; here that branch schedules nothing.

  `fork_task/2` and `next_join/2` are shared with `Archon.Decider.Mapper.ForkJoinDynamic`.
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.{Codec, Task, TaskDef, WorkflowDef, WorkflowTask}

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    fork_task = %{
      fork_task(context, context.task_input)
      | isolation_group_id: isolation_group_id(context.task_definition)
    }

    with {:ok, branch_tasks} <- schedule_branches(wt.fork_tasks, context),
         {:ok, join} <- join_task(context.workflow.workflow_definition, wt),
         {:ok, join_tasks} <- Context.tasks_to_be_scheduled(context, join, nil) do
      {:ok, [fork_task | branch_tasks] ++ join_tasks}
    end
  end

  defp schedule_branches(branches, context) do
    Enum.reduce_while(branches, {:ok, []}, fn
      [first | _rest], {:ok, scheduled} ->
        case Context.tasks_to_be_scheduled(context, first, nil) do
          {:ok, tasks} -> {:cont, {:ok, scheduled ++ tasks}}
          {:terminate, reason} -> {:halt, {:terminate, reason}}
        end

      _empty, acc ->
        {:cont, acc}
    end)
  end

  defp join_task(definition, %WorkflowTask{task_reference_name: ref}) do
    case next_join(definition, ref) do
      %WorkflowTask{} = join ->
        {:ok, join}

      nil ->
        {:terminate, "Fork task definition is not followed by a join task.  Check the blueprint"}
    end
  end

  @doc """
  The `COMPLETED` `FORK` task both fork mappers start with, scheduled, started and ended at
  `decider.now`, with `input`.
  """
  @spec fork_task(Context.t(), Codec.json_object()) :: Task.t()
  def fork_task(%Context{} = context, input) do
    now = context.decider.now

    %{
      Context.create_task(context)
      | task_type: "FORK",
        task_def_name: "FORK",
        start_time: now,
        end_time: now,
        input_data: input,
        status: :completed
    }
  end

  @doc "The `JOIN` that follows the task named `ref` in the definition, or `nil`."
  @spec next_join(WorkflowDef.t(), String.t()) :: WorkflowTask.t() | nil
  def next_join(%WorkflowDef{} = definition, ref) do
    case WorkflowDef.next_task(definition, ref) do
      %WorkflowTask{type: "JOIN"} = join -> join
      _other -> nil
    end
  end

  defp isolation_group_id(%TaskDef{isolation_group_id: id}), do: id
  defp isolation_group_id(nil), do: nil
end
