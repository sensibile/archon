# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# `check!/2` is derived from conductor-oss sqlite-persistence/src/main/java/com/netflix/conductor/sqlite/dao/SqliteExecutionDAO.java
# (createTasks and validate) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the task checks run on a whole `Archon.Runtime.Commit` before any store
# writes, together with checks of the commit's own fields (ADR 0018, decision 2; ADR 0021,
# decision 3).

defmodule Archon.Runtime.Commit do
  @moduledoc """
  One atomic change to a workflow and its tasks in `Archon.Runtime.Store` (ADR 0018, decision 2;
  ADR 0021, decision 3).

    * `create` - a new workflow with its tasks, or `nil`. The store refuses it with
      `{:error, :conflict}` when the ID already exists.
    * `workflow` - the changed workflow, or `nil`. Its `tasks` field is ignored.
    * `upsert_tasks` - tasks to insert or replace.
    * `delete_task_ids` - tasks to delete (DO_WHILE `keepLastN`).
    * `outbox_ack` - IDs of the workflow's outbox entries to delete. IDs the workflow does not
      have are ignored.
    * `outbox` - work on other workflows (`t:Archon.Runtime.Step.Effect.t/0`), appended to the
      workflow's outbox in this order (ADR 0021, decision 4). Only `:terminate_sub_workflow`,
      `:notify_parent`, `:revive_parent`, `:retry_sub_workflow` and `:start_failure_workflow` go
      there; slice 4e settles their stored shape.
    * `wake` - the workflow's stored re-evaluation time (ADR 0021, decision 6): `:keep` leaves it,
      `{:at, ms}` sets it, `{:before, ms}` sets it to `ms` unless it is set earlier, and `:none`
      clears it.
    * `limits` - `%{task_def_name => limit}`: after the change, the number of `IN_PROGRESS` tasks
      of each name (`Archon.Runtime.Store.in_progress_count/1`) must not exceed its limit, or the
      store refuses the commit with `{:error, {:limit, name}}` (ADR 0021, decision 5).
    * `queue` - worker queue operations (`Archon.Runtime.Queue`), applied in this order. They take
      the epoch time `deliver_on` a message becomes visible instead of a delay.

  The store applies the fields in that order, checks the limits, and applies the queue operations
  last, all or none, and never stamps times: `Archon.Runtime.Step` sets the `updateTime`/`endTime`
  values upstream's `ExecutionDAOFacade` stamps when it saves.
  """

  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.Step.Effect

  defstruct create: nil,
            workflow: nil,
            upsert_tasks: [],
            delete_task_ids: [],
            outbox_ack: [],
            outbox: [],
            wake: :keep,
            limits: %{},
            queue: []

  @typedoc "A worker queue operation; `deliver_on` is epoch milliseconds."
  @type queue_op ::
          {:push, queue :: String.t(), id :: String.t(), priority :: integer(),
           deliver_on :: integer()}
          | {:remove, queue :: String.t(), id :: String.t()}
          | {:postpone, queue :: String.t(), id :: String.t(), priority :: integer(),
             deliver_on :: integer()}

  @type wake :: :keep | {:at, integer()} | {:before, integer()} | :none

  @type t :: %__MODULE__{
          create: Workflow.t() | nil,
          workflow: Workflow.t() | nil,
          upsert_tasks: [Task.t()],
          delete_task_ids: [String.t()],
          outbox_ack: [pos_integer()],
          outbox: [Effect.t()],
          wake: wake(),
          limits: %{optional(String.t()) => pos_integer()},
          queue: [queue_op()]
        }

  @doc """
  The checks every store makes before it applies `commit` to `workflow_id`, raising
  `ArgumentError` in the caller: the workflows belong to `workflow_id` and have a known status,
  the tasks have IDs and reference names and belong to `workflow_id`, and `outbox_ack`, `outbox`,
  `wake` and `limits` have their shapes. The queue operations are checked by the store's queue.
  """
  @spec check!(String.t(), t()) :: :ok
  # Upstream ExecutionDAO#createTasks rejects these before writing; a bad commit is a bug in the
  # caller, so it raises there instead of crashing the store.
  def check!(workflow_id, %__MODULE__{create: create, workflow: workflow} = commit) do
    for %Workflow{workflow_id: id, status: status} <- [create, workflow] do
      if id != workflow_id,
        do: raise(ArgumentError, "commit for #{workflow_id} carries workflow #{inspect(id)}")

      if status not in Workflow.statuses(),
        do: raise(ArgumentError, "workflow #{id} has status #{inspect(status)}")
    end

    created_tasks = if create, do: create.tasks, else: []
    Enum.each(created_tasks ++ commit.upsert_tasks, &check_task!(workflow_id, &1))
    check_outbox!(commit.outbox, commit.outbox_ack)
    check_wake!(commit.wake)
    check_limits!(commit.limits)
    :ok
  end

  defp check_outbox!(outbox, acks) do
    unless is_list(outbox) and is_list(acks) and Enum.all?(acks, &(is_integer(&1) and &1 > 0)),
      do: raise(ArgumentError, "invalid outbox #{inspect(outbox)} or acks #{inspect(acks)}")
  end

  defp check_wake!(wake) when wake in [:keep, :none], do: :ok
  defp check_wake!({tag, ms}) when tag in [:at, :before] and is_integer(ms), do: :ok
  defp check_wake!(wake), do: raise(ArgumentError, "invalid wake #{inspect(wake)}")

  defp check_limits!(limits) do
    valid? = fn {name, limit} -> is_binary(name) and is_integer(limit) and limit > 0 end

    unless is_map(limits) and Enum.all?(limits, valid?),
      do: raise(ArgumentError, "invalid limits #{inspect(limits)}")
  end

  defp check_task!(workflow_id, %Task{} = task) do
    cond do
      task.task_id in [nil, ""] ->
        raise ArgumentError, "Task id cannot be null"

      task.workflow_instance_id in [nil, ""] ->
        raise ArgumentError, "Workflow instance id cannot be null"

      task.workflow_instance_id != workflow_id ->
        raise ArgumentError, "task #{task.task_id} belongs to #{task.workflow_instance_id}"

      task.reference_task_name in [nil, ""] ->
        raise ArgumentError, "Task reference name cannot be null"

      true ->
        :ok
    end
  end
end
