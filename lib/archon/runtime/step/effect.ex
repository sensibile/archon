# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Step.Effect do
  @moduledoc """
  What `Archon.Runtime.WorkflowServer` does outside the store after a step (ADR 0018,
  decision 2). `Archon.Runtime.Step.run/3` returns them as `pre` (before the commit) and `post`
  (after it) lists, in the order to run them.

    * `{:queue_push, queue, task_id, priority, delay_ms}`, `{:queue_remove, queue, task_id}`,
      `{:queue_postpone, queue, task_id, priority, delay_ms}` - worker task queues
      (`Archon.Runtime.Queue`). Only tasks that are not system tasks are queued.
    * `{:start_sub_workflow, task_id, start}` - starts the child of a `SUB_WORKFLOW` task with
      `Archon.Runtime.start_workflow_idempotent/1`. The result goes back to the step as
      `{:sub_workflow_started, task_id, result}`.
    * `{:terminate_sub_workflow, workflow_id, reason}` - sends `{:cancel_by_parent, reason}` to
      a child. A child that does not exist counts as done (ADR 0018, decision 5).
    * `{:notify_parent, parent_workflow_id, parent_task_id, workflow}` - casts
      `{:child_changed, parent_task_id, workflow}` to the parent. `workflow` is the stored child.
    * `{:start_failure_workflow, start}` - starts the failure workflow. A failure goes back as
      `{:failure_workflow_started, {:error, reason}}`.
    * `{:wake_at, ms}` - sets the `:wake` timer to the epoch time `ms`, replacing the current
      one. `ms` equal to `now` asks for the next `:wake` at once.
    * `{:wake_before, ms}` - moves the `:wake` timer to `ms` only when it is set later than that
      (an event that did not decide).
  """

  alias Archon.Domain.{Workflow, WorkflowDef}

  @typedoc """
  A workflow to start, as upstream's `StartWorkflowInput`: the definition is `definition`, or
  looked up by `name` and `version` (`nil` is the latest).
  """
  @type start :: %{
          workflow_id: String.t(),
          name: String.t() | nil,
          version: integer() | nil,
          definition: WorkflowDef.t() | nil,
          input: map(),
          correlation_id: String.t() | nil,
          priority: integer() | nil,
          task_to_domain: %{optional(String.t()) => String.t() | nil} | nil,
          parent_workflow_id: String.t() | nil,
          parent_workflow_task_id: String.t() | nil,
          triggering_workflow_id: String.t() | nil,
          idempotency_key: String.t() | nil,
          idempotency_strategy: String.t() | nil
        }

  @type t ::
          {:queue_push, String.t(), String.t(), integer(), non_neg_integer()}
          | {:queue_remove, String.t(), String.t()}
          | {:queue_postpone, String.t(), String.t(), integer(), non_neg_integer()}
          | {:start_sub_workflow, String.t(), start()}
          | {:terminate_sub_workflow, String.t(), String.t()}
          | {:notify_parent, String.t(), String.t() | nil, Workflow.t() | nil}
          | {:start_failure_workflow, start()}
          | {:wake_at, integer()}
          | {:wake_before, integer()}
end
