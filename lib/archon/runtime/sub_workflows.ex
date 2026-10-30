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
    * `revive_parent/2` - `{:revive_parent, parent_id, parent_task_id}`: casts
      `{:child_revived, parent_task_id}` with `Archon.Runtime.WorkflowServer.child_revived/2`
      (upstream `updateAndPushParents`). Always `:ok`.
    * `retry_child/1` - `{:retry_sub_workflow, child_id}`: a reviving parent retries a child that
      failed, without the child asking its parent back. Always `:ok`; a failure is logged and the
      parent's re-evaluation reads the child.

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
  alias Archon.Runtime.Step.{Effect, Event, SubWorkflow}
  alias Archon.Runtime.WorkflowServer

  @registry Archon.Runtime.Registry

  @doc "Starts the child of a `SUB_WORKFLOW` task (upstream `startWorkflowIdempotent`)."
  @spec start_child(Effect.start()) :: Event.sub_workflow_result()
  def start_child(%{workflow_id: id, parent_workflow_id: id} = start) when is_binary(id) do
    # A task whose subWorkflowId (worker-supplied, ADR 0018) names its own workflow: the
    # process cannot call itself, so the ownership check upstream would fail it runs here.
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

  defp message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp message(reason), do: inspect(reason)

  @doc """
  Terminates a child because its parent ended (upstream `SubWorkflow#cancel`). A child that does
  not exist, or one that is the calling workflow itself, counts as terminated; an ancestor of the
  calling workflow is cancelled from another process (ADR 0018, decision 5).
  """
  @spec terminate_child(String.t(), String.t()) :: :ok | {:error, term()}
  def terminate_child(child_id, reason) do
    # A worker-supplied subWorkflowId (ADR 0018) may name the parent itself or one of its
    # ancestors. The parent itself is ending already (upstream terminates it again). An ancestor
    # would call back into this process while it waits (its own cancel reaches this workflow),
    # so it is cancelled from another process once this one is free; upstream's result is kept.
    case own_ids() do
      [^child_id] ->
        :ok

      [own_id] ->
        if ancestor?(own_id, child_id, []),
          do: cancel_later(child_id, reason),
          else: cancel(child_id, reason)

      _not_a_workflow ->
        cancel(child_id, reason)
    end
  end

  # The calling workflow's ID; none outside a workflow process or while the registry restarts.
  defp own_ids do
    Registry.keys(@registry, self())
  rescue
    ArgumentError -> []
  end

  defp ancestor?(id, target, seen) do
    with false <- id in seen,
         {:ok, %Workflow{parent_workflow_id: parent}} when parent not in [nil, ""] <-
           Runtime.get_workflow(id, false) do
      parent == target or ancestor?(parent, target, [id | seen])
    else
      _root -> false
    end
  end

  defp cancel_later(child_id, reason) do
    {:ok, _pid} =
      Elixir.Task.start(fn ->
        with {:error, error} <- cancel(child_id, reason),
             do: Logger.warning("workflow #{child_id} was not cancelled: #{inspect(error)}")
      end)

    :ok
  end

  defp cancel(child_id, reason) do
    case WorkflowServer.cancel_by_parent(child_id, reason) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Tells the parent that its child changed (upstream `updateParentWorkflowTask`). Without the parent
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
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @doc """
  Asks the parent to revive because its child runs again (one level of upstream
  `updateAndPushParents`). A parent that cannot be reached is logged.
  """
  @spec revive_parent(String.t(), String.t() | nil) :: :ok
  def revive_parent(parent_id, parent_task_id) when is_binary(parent_task_id) do
    with {:error, reason} <- WorkflowServer.child_revived(parent_id, parent_task_id) do
      Logger.warning("parent #{parent_id} could not be asked to revive: #{inspect(reason)}")
    end

    :ok
  end

  def revive_parent(_parent_id, _parent_task_id), do: :ok

  @doc """
  Retries a failed child for a reviving parent (upstream `updateAndPushParents` calls `retry`
  on it). The child does not ask its parent back. A child that is the calling workflow or one of
  its ancestors (a worker-supplied `subWorkflowId`, ADR 0018) is not called, as that call could
  not be answered; a failure is logged.
  """
  @spec retry_child(String.t()) :: :ok
  def retry_child(child_id) do
    own = own_ids()

    cond do
      own == [child_id] ->
        Logger.warning("workflow #{child_id} names itself as a child to retry; skipped")

      match?([_id], own) and ancestor?(hd(own), child_id, []) ->
        Logger.warning("workflow #{hd(own)} names its ancestor #{child_id} to retry; skipped")

      true ->
        with {:error, reason} <- WorkflowServer.retry(child_id, false) do
          Logger.warning("child workflow #{child_id} was not retried: #{inspect(reason)}")
        end
    end

    :ok
  end
end
