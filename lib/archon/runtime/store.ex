# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/dal/ExecutionDAOFacade.java,
# core/src/main/java/com/netflix/conductor/dao/ExecutionDAO.java and PollDataDAO.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: reduced to the operations the MVP runtime uses (ADR 0018, decision 3);
# workflow and task writes are one atomic `Archon.Runtime.Commit` and the store never stamps times.

defmodule Archon.Runtime.Store do
  @moduledoc """
  Execution store behaviour: the MVP part of upstream `ExecutionDAOFacade` (ADR 0018, decision 3).

  The stored state is always "every `Archon.Runtime.Commit` up to some point": a commit is applied
  completely or not at all. Workflows and tasks keep their internal (`wire: false`) fields.

  Callbacks:

    * `c:commit/2` - applies a commit to `workflow_id`. A `create` whose ID exists is
      `{:error, :conflict}`, and so is upserting a task ID that belongs to another workflow. Any
      other change to a workflow that does not exist (after `create`) is `{:error, :not_found}`.
      Deleting a task ID the workflow does not have is ignored. Callers must pass a commit whose
      workflows and tasks belong to `workflow_id`.
    * `c:get_workflow/2` - the workflow, with its tasks ordered by `seq` when `include_tasks?`
      (upstream `getWorkflow(id, true)`), otherwise with `tasks: []`.
    * `c:get_task/1` - the task and the ID of its workflow.
    * `c:running_workflow_ids/0` - workflows whose status is not terminal (`RUNNING`, `PAUSED`).
    * `c:remove_workflow/1` - deletes a workflow and its tasks (queue messages are the caller's).
    * `c:in_progress_count/1` - tasks with this task definition name (`Task.task_def_name/1`) in
      `IN_PROGRESS` (upstream `getInProgressTaskCount`).
    * `c:put_poll_data/4`, `c:get_poll_data/2` - the last poll per task type and domain (upstream
      `PollDataDAO`; a `nil` domain is its own key, upstream's `DEFAULT`).
  """

  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.Commit

  @typedoc "Upstream `PollData`: the last poll of a task type in a domain."
  @type poll_data :: %{
          queue_name: String.t(),
          domain: String.t() | nil,
          worker_id: String.t() | nil,
          last_poll_time: integer()
        }

  @callback commit(workflow_id :: String.t(), Commit.t()) ::
              :ok | {:error, :conflict | :not_found}
  @callback get_workflow(id :: String.t(), include_tasks? :: boolean()) ::
              {:ok, Workflow.t()} | {:error, :not_found}
  @callback get_task(task_id :: String.t()) ::
              {:ok, Task.t(), workflow_id :: String.t()} | {:error, :not_found}
  @callback running_workflow_ids() :: [String.t()]
  @callback remove_workflow(id :: String.t()) :: :ok | {:error, :not_found}
  @callback in_progress_count(task_def_name :: String.t()) :: non_neg_integer()
  @callback put_poll_data(
              task_type :: String.t(),
              domain :: String.t() | nil,
              worker_id :: String.t() | nil,
              now :: integer()
            ) :: :ok
  @callback get_poll_data(task_type :: String.t(), domain :: String.t() | nil) ::
              {:ok, poll_data()} | {:error, :not_found}
end
