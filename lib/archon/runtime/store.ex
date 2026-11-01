# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/dal/ExecutionDAOFacade.java,
# core/src/main/java/com/netflix/conductor/dao/ExecutionDAO.java and PollDataDAO.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: reduced to the operations the MVP runtime uses (ADR 0018, decision 3);
# workflow and task writes are one atomic `Archon.Runtime.Commit` and the store never stamps times;
# a commit also carries queue operations, an outbox, a re-evaluation time and limits (ADR 0021);
# the queries by name and correlation ID are ordered (ADR 0025, decision 4).

defmodule Archon.Runtime.Store do
  @moduledoc """
  Execution store behaviour: the MVP part of upstream `ExecutionDAOFacade` (ADR 0018, decision 3;
  ADR 0021, decisions 3 to 6).

  The stored state is always "every `Archon.Runtime.Commit` up to some point": a commit is applied
  completely or not at all. Workflows and tasks keep their internal (`wire: false`) fields.

  Callbacks:

    * `c:commit/2` - applies a commit to `workflow_id`. A `create` whose ID exists is
      `{:error, :conflict}`, and so is upserting a task ID that belongs to another workflow. Any
      other change to a workflow that does not exist (after `create`) is `{:error, :not_found}`.
      Deleting a task ID the workflow does not have is ignored. Callers must pass a commit whose
      workflows and tasks belong to `workflow_id`. A commit that would leave more `IN_PROGRESS`
      tasks of a name than its `limits` entry is `{:error, {:limit, name}}`, naming the first such
      name in binary order. A Postgres store whose node lost the database refuses with
      `{:error, :fenced}` (ADR 0021, decision 7). A refused commit changes nothing, queues included.
      The queue operations go to the queue of the same backend (`Archon.Runtime.Queue`).
    * `c:get_workflow/2` - the workflow, with its tasks ordered by `seq` when `include_tasks?`
      (upstream `getWorkflow(id, true)`), otherwise with `tasks: []`.
    * `c:get_task/1` - the task and the ID of its workflow.
    * `c:running_workflow_ids/0` - workflows whose status is not terminal (`RUNNING`, `PAUSED`).
    * `c:correlated_workflows/4` - workflows of a definition name (any version) whose
      correlation ID is one of `correlation_ids` (upstream `getWorkflowsByCorrelationId` and
      `getWorkflowInstances` for each ID, read at once), only the `RUNNING` ones unless
      `include_closed?`, with their tasks ordered by `seq` when `include_tasks?` (else
      `tasks: []`).
    * `c:pending_workflow_ids/1` - IDs of the workflows of a definition name (any version) whose
      status is not terminal (upstream `getRunningWorkflowIds`, which does not use the version).
    * `c:workflow_ids_created_between/4` - IDs of the workflows of a definition name and version,
      in any status, whose `create_time` is from `start_ms` to `end_ms`, both included (upstream
      `getWorkflowsByType` and the executor's version filter).
    * `c:remove_workflow/1` - deletes a workflow, its tasks and its outbox (queue messages are the
      caller's).
    * `c:in_progress_count/1` - tasks with this task definition name (`Task.task_def_name/1`) in
      `IN_PROGRESS` (upstream `getInProgressTaskCount`).
    * `c:pending_outbox/1` - the workflow's outbox entries `{id, effect}` in ID order (`[]` for a
      workflow that does not exist). IDs are positive integers that grow with every entry added.
    * `c:ack_outbox/2` - deletes these outbox entries of the workflow; other IDs are ignored.
    * `c:outbox_workflow_ids/2` - IDs of workflows with outbox entries, in binary order, after
      `cursor` (`nil` for the first page), at most `limit`.
    * `c:due_workflow_ids/3` - `RUNNING` workflows whose re-evaluation time is at most
      `before_ms` or not set, as `{wake_key, workflow_id}` ordered by that pair, after `cursor`
      (the last pair of the previous page, `nil` for the first), at most `limit`. `wake_key` is the
      stored time, or 0 when it is not set.
    * `c:put_poll_data/4`, `c:get_poll_data/2` - the last poll per task type and domain (upstream
      `PollDataDAO`; a `nil` domain shares the key of the domain `"DEFAULT"`, as in
      `SqlitePollDataDAO`, and the returned value keeps the domain it was written with).

  The three queries by name answer in `create_time` order and then workflow ID in binary order
  (upstream leaves the order unspecified; ADR 0025, decision 4). A name or correlation ID that
  cannot be stored in an index column (NUL or invalid UTF-8) matches no workflow on every store.

  Unlike upstream `ExecutionDAO#createTasks`, a commit does not skip tasks whose reference name
  and retry count already exist; `Archon.Runtime.Step` deduplicates them (`dedupAndAddTasks`).
  """

  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.Commit
  alias Archon.Runtime.Step.Effect

  @typedoc "Upstream `PollData`: the last poll of a task type in a domain."
  @type poll_data :: %{
          queue_name: String.t(),
          domain: String.t() | nil,
          worker_id: String.t() | nil,
          last_poll_time: integer()
        }

  @typedoc "An outbox entry's ID."
  @type outbox_id :: pos_integer()

  @typedoc "A due workflow's place in `c:due_workflow_ids/3`: its re-evaluation time (0 unset) and ID."
  @type due_key :: {wake_key :: integer(), workflow_id :: String.t()}

  @callback commit(workflow_id :: String.t(), Commit.t()) ::
              :ok | {:error, :conflict | :not_found | :fenced | {:limit, String.t()}}
  @callback get_workflow(id :: String.t(), include_tasks? :: boolean()) ::
              {:ok, Workflow.t()} | {:error, :not_found}
  @callback get_task(task_id :: String.t()) ::
              {:ok, Task.t(), workflow_id :: String.t()} | {:error, :not_found}
  @callback running_workflow_ids() :: [String.t()]
  @callback correlated_workflows(
              name :: String.t(),
              correlation_ids :: [String.t()],
              include_closed? :: boolean(),
              include_tasks? :: boolean()
            ) :: [Workflow.t()]
  @callback pending_workflow_ids(name :: String.t()) :: [String.t()]
  @callback workflow_ids_created_between(
              name :: String.t(),
              version :: integer(),
              start_ms :: integer(),
              end_ms :: integer()
            ) :: [String.t()]
  @callback remove_workflow(id :: String.t()) :: :ok | {:error, :not_found}
  @callback in_progress_count(task_def_name :: String.t()) :: non_neg_integer()
  @callback pending_outbox(workflow_id :: String.t()) :: [{outbox_id(), Effect.t()}]
  @callback ack_outbox(workflow_id :: String.t(), [outbox_id()]) :: :ok
  @callback outbox_workflow_ids(cursor :: String.t() | nil, limit :: non_neg_integer()) ::
              [String.t()]
  @callback due_workflow_ids(
              before_ms :: integer(),
              cursor :: due_key() | nil,
              limit :: non_neg_integer()
            ) :: [due_key()]
  @callback put_poll_data(
              task_type :: String.t(),
              domain :: String.t() | nil,
              worker_id :: String.t() | nil,
              now :: integer()
            ) :: :ok
  @callback get_poll_data(task_type :: String.t(), domain :: String.t() | nil) ::
              {:ok, poll_data()} | {:error, :not_found}
end
