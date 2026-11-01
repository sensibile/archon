# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/SubWorkflow.java
# (start's exception handling, cancel, terminateSubWorkflow) and
# core/.../execution/WorkflowExecutorOps.java (terminateWorkflow's failure workflow start,
# updateParentWorkflowTask, updateAndPushParents) at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: each call is an effect of the calling workflow's process or of its outbox
# runner, and a parent hears of its child by a call instead of the decider queue (ADR 0018,
# decisions 1 and 5; ADR 0021, decision 4), and a child is checked to belong to the caller before
# it is cancelled or retried (ADR 0024, decision 2).

defmodule Archon.Runtime.SubWorkflows do
  @moduledoc """
  Runs the effects between workflows (ADR 0018, decisions 5 and 8 (a); ADR 0021, decision 4).

    * `start_child/1` - `{:start_sub_workflow, task_id, start}`, in the parent's process: starts
      the child with `Archon.Runtime.start_workflow_idempotent/1`. Returns the
      `t:Archon.Runtime.Step.Event.sub_workflow_result/0` that `Archon.Runtime.WorkflowServer`
      feeds back as `{:sub_workflow_started, task_id, result}` in the same message: `{:ok, child}`
      (the stored child, new or existing), `{:error, :transient, message}` (the task stays
      `SCHEDULED` and is started again later) or `{:error, message}` (the task fails).
    * `terminate_child/4` - `{:terminate_sub_workflow, child_id, reason}` before the parent's
      commit (in its process) or `{:terminate_sub_workflow, child_id, reason, parent_end_count}`
      from its outbox: sends `{:cancel_by_parent, reason, parent_end_count}` to the child with
      `Archon.Runtime.WorkflowServer.cancel_by_parent/3`.
    * `notify_parent/3`, `revive_parent/2` - `{:notify_parent, ...}`, `{:revive_parent, ...}`
      from the child's outbox: call the parent with `{:child_changed, parent_task_id, child}` or
      `{:child_revived, parent_task_id}`.
    * `retry_child/2` - `{:retry_sub_workflow, child_id}` from a reviving parent's outbox.
    * `start_failure_workflow/1` - `{:start_failure_workflow, start}` from the outbox.

  The outbox functions return the other workflow's answer, which `Archon.Runtime.Outbox`
  classifies; they run in the workflow's outbox runner, outside its process, so calling the
  parent cannot wait on a call back into the same process. The parent's own process only calls
  its children (ADR 0018, decision 1). The workflow's ID is passed in (`owner_id`).

  Upstream `SubWorkflow#start` leaves the task `SCHEDULED` on a `TransientException` (a backend
  failure) and fails it on any other exception. Here the refusals that come before any workflow
  is created (no definition, a `nil` input, a `SUB_WORKFLOW` without a definition, a child that
  belongs to another parent) and an exception raised while the child handled the start fail the
  task; the rest (the child's process could not be reached or answered late, or its commit
  failed) is transient.
  """

  require Logger

  alias Archon.Domain.Workflow
  alias Archon.Runtime
  alias Archon.Runtime.Step.{Effect, Event, SubWorkflow}
  alias Archon.Runtime.WorkflowServer

  @doc "Starts the child of a `SUB_WORKFLOW` task (upstream `startWorkflowIdempotent`)."
  @spec start_child(Effect.start()) :: Event.sub_workflow_result()
  def start_child(%{workflow_id: id, parent_workflow_id: id} = start) when is_binary(id) do
    # A task whose subWorkflowId names its own workflow (stored before ADR 0024): the process
    # cannot call itself, so the ownership check upstream would fail it runs here.
    case Runtime.get_workflow(id, false) do
      {:ok, existing} ->
        owner = %Workflow{
          parent_workflow_id: id,
          parent_workflow_task_id: Map.get(start, :parent_workflow_task_id)
        }

        case SubWorkflow.owned_by?(existing, owner) do
          {:error, message} -> {:error, message}
          :ok -> {:error, "Workflow id #{id} cannot be its own sub workflow"}
        end

      {:error, reason} ->
        start_error(reason)
    end
  end

  def start_child(start) do
    case Runtime.start_workflow_idempotent(start) do
      {:ok, %Workflow{} = child} -> {:ok, child}
      {:error, reason} -> start_error(reason)
    end
  end

  defp start_error({tag, message}) when tag in [:not_found, :invalid, :terminate],
    do: {:error, message}

  # validateIdempotentWorkflowOwnership
  defp start_error(message) when is_binary(message), do: {:error, message}
  defp start_error(%{__exception__: true} = exception), do: {:error, Exception.message(exception)}
  defp start_error(reason), do: {:error, :transient, message(reason)}

  # The message of an error, as upstream's `getMessage()` of the exception it caught.
  defp message({tag, %{__exception__: true} = exception}) when is_atom(tag),
    do: "#{tag}: #{Exception.message(exception)}"

  # A call that exited (WorkflowServer.call/4) reads as its reason, as before ADR 0025.
  defp message({:exit, reason}), do: message(reason)
  defp message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp message(reason), do: inspect(reason)

  @doc """
  Terminates a child because its parent ended (upstream `SubWorkflow#cancel`). The child is read
  from the store first and called only when its `parentWorkflowId` is `owner_id` (ADR 0024,
  decision 2): a child that does not exist, one that belongs to another parent and `owner_id`
  itself count as terminated. A failed read raises, which the caller handles as it does a failed
  cancel.

  Options:

    * `end_count:` - the parent's `endCount` after the commit that saved this termination (an
      outbox entry, ADR 0021, decision 4). A child that ran again after reading that end of its
      parent is left running. `nil` (the default, a `pre` termination) skips the check.
  """
  @spec terminate_child(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def terminate_child(owner_id, child_id, reason, opts \\ []) do
    # The parent itself is ending already (upstream terminates it again); the process cannot
    # call itself.
    if child_id != owner_id and owned?(owner_id, child_id),
      do: cancel(child_id, reason, Keyword.get(opts, :end_count)),
      else: :ok
  end

  # The sender's ownership check (ADR 0024, decision 2), before the other workflow's process is
  # called: an ancestor is never its descendant's child, so a pre termination cannot call back
  # into its own chain (L6, L7), and an unrelated workflow is not touched (L8).
  defp owned?(owner_id, child_id) do
    case Runtime.get_workflow(child_id, false) do
      {:ok, %Workflow{parent_workflow_id: parent}} -> parent == owner_id
      {:error, :not_found} -> false
    end
  end

  defp cancel(child_id, reason, end_count) do
    case WorkflowServer.cancel_by_parent(child_id, reason, end_count) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Tells the parent that its child changed (upstream `updateParentWorkflowTask`) with
  `Archon.Runtime.WorkflowServer.child_changed/3` and returns its answer. Without the parent task
  there is nothing to tell (`:ok`).
  """
  @spec notify_parent(String.t(), String.t() | nil, Workflow.t()) :: :ok | {:error, term()}
  def notify_parent(parent_id, parent_task_id, %Workflow{} = child)
      when is_binary(parent_task_id),
      do: WorkflowServer.child_changed(parent_id, parent_task_id, child)

  def notify_parent(_parent_id, _parent_task_id, _child), do: :ok

  @doc """
  Starts the failure workflow (upstream `terminateWorkflow`). An ID that exists already is the
  workflow an earlier attempt started with this saved ID, so it counts as started. A refusal is
  `{:error, message}` and a failure that may pass (the store or the process) is
  `{:error, :transient, message}`, as for `start_child/1`.
  """
  @spec start_failure_workflow(Effect.start()) ::
          :ok | {:error, String.t()} | {:error, :transient, String.t()}
  def start_failure_workflow(start) do
    case Runtime.start_workflow(start) do
      {:ok, _id} -> :ok
      {:error, :conflict} -> :ok
      {:error, reason} -> start_error(reason)
    end
  end

  @doc """
  Asks the parent to revive because its child runs again (one level of upstream
  `updateAndPushParents`) with `Archon.Runtime.WorkflowServer.child_revived/2` and returns its
  answer.
  """
  @spec revive_parent(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def revive_parent(parent_id, parent_task_id) when is_binary(parent_task_id),
    do: WorkflowServer.child_revived(parent_id, parent_task_id)

  def revive_parent(_parent_id, _parent_task_id), do: :ok

  @doc """
  Retries a failed child for a reviving parent `owner_id` (upstream `updateAndPushParents` calls
  `retry` on it) and returns its answer. The child does not ask its parent back. A child that is
  `owner_id` itself, does not exist or belongs to another parent (ADR 0024, decision 2) is
  skipped with a warning; a failed read raises.
  """
  @spec retry_child(String.t(), String.t()) :: :ok | {:error, term()}
  def retry_child(owner_id, child_id) do
    cond do
      owner_id == child_id ->
        Logger.warning("workflow #{child_id} names itself as a child to retry; skipped")

      owned?(owner_id, child_id) ->
        WorkflowServer.retry(child_id, false)

      true ->
        Logger.warning("workflow #{child_id} is not a child of #{owner_id} to retry; skipped")
    end
  end
end
