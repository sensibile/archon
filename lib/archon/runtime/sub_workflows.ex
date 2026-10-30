# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/SubWorkflow.java
# (start's exception handling, cancel, terminateSubWorkflow) and
# core/.../execution/WorkflowExecutorOps.java (terminateWorkflow's failure workflow start,
# updateParentWorkflow) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: each call is an effect of the calling workflow's process, and a parent
# hears of its child by a message instead of the decider queue (ADR 0018, decisions 1 and 5).

defmodule Archon.Runtime.SubWorkflows do
  @moduledoc """
  Runs the effects between workflows (ADR 0018, decisions 5 and 8 (a)) for
  `Archon.Runtime.Effects`.

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
  alias Archon.Runtime.Step.{Effect, Event}
  alias Archon.Runtime.WorkflowServer

  @doc "Starts the child of a `SUB_WORKFLOW` task (upstream `startWorkflowIdempotent`)."
  @spec start_child(Effect.start()) :: Event.sub_workflow_result()
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
  defp start_error(reason), do: {:error, :transient, inspect(reason)}

  @doc """
  Terminates a child because its parent ended (upstream `SubWorkflow#cancel`). A child that does
  not exist counts as terminated (ADR 0018, decision 5).
  """
  @spec terminate_child(String.t(), String.t()) :: :ok | {:error, term()}
  def terminate_child(child_id, reason) do
    case WorkflowServer.cancel_by_parent(child_id, reason) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Tells the parent that its child changed (upstream `updateParentWorkflow`). Without the parent
  task, or when the parent cannot be reached, the notice is dropped: the parent's re-evaluation
  reads the child from the store.
  """
  @spec notify_parent(String.t(), String.t() | nil, Workflow.t() | nil) :: :ok
  def notify_parent(parent_id, parent_task_id, %Workflow{} = child)
      when is_binary(parent_task_id) do
    case WorkflowServer.child_changed(parent_id, parent_task_id, child) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "workflow #{child.workflow_id} could not notify its parent #{parent_id}: " <>
            inspect(reason)
        )
    end

    :ok
  end

  def notify_parent(_parent_id, _parent_task_id, _child), do: :ok

  @doc """
  Starts the failure workflow (upstream `terminateWorkflow`). An ID that exists already is the
  workflow an earlier attempt started with this saved ID, so it counts as started.
  """
  @spec start_failure_workflow(Effect.start()) :: :ok | {:error, String.t()}
  def start_failure_workflow(start) do
    case Runtime.start_workflow(start) do
      {:ok, _id} -> :ok
      {:error, :conflict} -> :ok
      {:error, {tag, message}} when tag in [:not_found, :invalid, :terminate] -> {:error, message}
      {:error, %{__exception__: true} = exception} -> {:error, Exception.message(exception)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
