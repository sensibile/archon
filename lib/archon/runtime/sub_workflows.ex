# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.SubWorkflows do
  @moduledoc """
  Runs the effects between workflows (ADR 0018, decisions 5 and 8 (a)) for
  `Archon.Runtime.Effects`. Slice 3c fixes the names and arguments; slice 3e implements them
  (ADR 0018, decision 12), and only this file changes then.

    * `start_child/1` - `{:start_sub_workflow, task_id, start}`: starts the child with
      `Archon.Runtime.start_workflow_idempotent/1`. Returns the
      `t:Archon.Runtime.Step.Event.sub_workflow_result/0` that `Archon.Runtime.WorkflowServer`
      feeds back as `{:sub_workflow_started, task_id, result}` in the same message: `{:ok, child}`
      (the stored child, new or existing), `{:error, :transient, message}` (the task stays
      `SCHEDULED` and is started again later) or `{:error, message}` (the task fails).
    * `terminate_child/2` - `{:terminate_sub_workflow, child_id, reason}`: sends
      `{:cancel_by_parent, reason}` to the child with
      `Archon.Runtime.WorkflowServer.cancel_by_parent/2` and returns `:ok` (also for a child that
      does not exist) or `{:error, reason}`, which fails the parent's step before its commit.
    * `notify_parent/3` - `{:notify_parent, parent_id, parent_task_id, child}`: casts
      `{:child_changed, parent_task_id, child}` with `Archon.Runtime.WorkflowServer.child_changed/3`.
      Always `:ok`; a lost notice is made good by the parent's 30 s re-evaluation.
    * `start_failure_workflow/1` - `{:start_failure_workflow, start}`: starts the failure
      workflow with `Archon.Runtime.start_workflow/1` (`start.workflow_id` is the ID already
      saved in the output). Returns `:ok` or `{:error, message}`, which is fed back as
      `{:failure_workflow_started, {:error, message}}`.

  The functions run inside the calling workflow's process. They may call child processes
  (parent → child is a `GenServer.call`), never the parent (child → parent is a cast), so there
  is no call cycle (ADR 0018, decision 1). An exception is caught by the workflow process.

  Until 3e, the starts report that sub-workflows are not available and the termination of a
  child fails, so a parent with a `SUB_WORKFLOW` task keeps its task `SCHEDULED`.
  """

  alias Archon.Domain.Workflow
  alias Archon.Runtime.Step.{Effect, Event}

  @unavailable "sub-workflows are not available before ADR 0018 slice 3e"

  # The specs are the contract for 3e; the placeholders return only part of them.
  @dialyzer {:nowarn_function, terminate_child: 2, start_failure_workflow: 1}

  @doc "Starts the child of a `SUB_WORKFLOW` task (placeholder until slice 3e)."
  @spec start_child(Effect.start()) :: Event.sub_workflow_result()
  def start_child(_start), do: {:error, :transient, @unavailable}

  @doc "Terminates a child because its parent ended (placeholder until slice 3e)."
  @spec terminate_child(String.t(), String.t()) :: :ok | {:error, term()}
  def terminate_child(_child_id, _reason), do: {:error, @unavailable}

  @doc "Tells the parent that its child changed (placeholder until slice 3e)."
  @spec notify_parent(String.t(), String.t() | nil, Workflow.t() | nil) :: :ok
  def notify_parent(_parent_id, _parent_task_id, _child), do: :ok

  @doc "Starts the failure workflow (placeholder until slice 3e)."
  @spec start_failure_workflow(Effect.start()) :: :ok | {:error, String.t()}
  def start_failure_workflow(_start), do: {:error, @unavailable}
end
