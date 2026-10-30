# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Step.Event do
  @moduledoc """
  What a workflow process received, as `Archon.Runtime.Step.run/3` takes it (ADR 0018,
  decision 2).

    * `{:start, workflow}` - creates the workflow and runs its first decide (upstream
      `startWorkflow`). `workflow` is the new instance the caller built: ID, definition with task
      definitions embedded, input, correlation ID, priority and the rest of upstream's
      `createWorkflowModel`.
    * `{:start_idempotent, workflow}` - creates the workflow without deciding, or answers with
      the stored one (upstream `startWorkflowIdempotent`). The first decide is a later `:wake`.
    * `{:poll, task_id, worker_id}` - a worker took the task from its queue.
    * `{:update, task_result}` - a worker's update.
    * `:wake` - the timer fired.
    * `:recover` - the recovery check, after activation and after an isolated exception.
    * `{:child_changed, task_id, child}` - a child workflow of a `SUB_WORKFLOW` task changed.
    * `{:sub_workflow_started, task_id, result}` - the result of a `:start_sub_workflow` effect:
      `{:ok, child}`, `{:error, :transient, message}` or `{:error, message}`.
    * `{:failure_workflow_started, {:error, message}}` - the failure workflow did not start.
    * `{:terminate, reason}` - a termination request (`DELETE /api/workflow/{id}`).
    * `{:cancel_by_parent, reason}` - the parent workflow ended.
    * `:pause`, `:resume` - upstream `pauseWorkflow`, `resumeWorkflow`.
    * `{:retry, push_parents?}` - upstream `retry`; without `push_parents?` the parent is not
      asked to revive (a parent retrying its failed child, `updateAndPushParents`).
    * `{:restart, definition}` - upstream `restart`, with the stored definition (`nil`) or the
      latest one.
    * `{:child_revived, task_id}` - the child of the `SUB_WORKFLOW` task runs again (one level of
      upstream `updateAndPushParents`).
  """

  alias Archon.Domain.{TaskResult, Workflow, WorkflowDef}

  @type sub_workflow_result ::
          {:ok, Workflow.t()} | {:error, :transient, String.t()} | {:error, String.t()}

  @type t ::
          {:start, Workflow.t()}
          | {:start_idempotent, Workflow.t()}
          | {:poll, String.t(), String.t() | nil}
          | {:update, TaskResult.t()}
          | :wake
          | :recover
          | {:child_changed, String.t(), Workflow.t()}
          | {:sub_workflow_started, String.t(), sub_workflow_result()}
          | {:failure_workflow_started, {:error, String.t()}}
          | {:terminate, String.t() | nil}
          | {:cancel_by_parent, String.t()}
          | :pause
          | :resume
          | {:retry, boolean()}
          | {:restart, WorkflowDef.t() | nil}
          | {:child_revived, String.t()}
end
