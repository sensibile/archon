# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

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
      workflow's outbox in this order (ADR 0021, decision 4).
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
end
