# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (pauseWorkflow, resumeWorkflow, retry, findLastFailedSubWorkflowIfAny, restart) at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: what needs other workflows or the metadata is read here, and the
# operation itself is a message to the workflow's process (ADR 0018, decision 9); the retry goes
# down only to children that belong to their task (ADR 0024, decision 2).

defmodule Archon.Runtime.Lifecycle do
  @moduledoc """
  The lifecycle operations of the runtime API (ADR 0018, decision 9): upstream
  `pauseWorkflow`, `resumeWorkflow`, `retry` and `restart`. REST is Later (ADR 0001); these are
  the functions it will call.

  Each one is a message to the workflow's process (`Archon.Runtime.Step.Lifecycle` has the
  rules) and answers once its commit and the decide that follows are saved. A workflow that runs
  again because of a retry or a restart revives its parent, and that parent its own, by a message
  each (upstream `updateAndPushParents`), so the ancestors follow shortly after the answer.

  Errors are `{:error, :not_found}` for a workflow the store does not have, or
  `{:error, {kind, message}}` with upstream's exception (`:conflict`, `:not_found`,
  `:invalid_state` for `IllegalStateException`) and its message.
  """

  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime
  alias Archon.Runtime.Step.Lifecycle, as: Rules
  alias Archon.Runtime.WorkflowServer

  @doc "Upstream `pauseWorkflow`."
  @spec pause(String.t()) :: :ok | {:error, term()}
  def pause(id) when is_binary(id), do: WorkflowServer.pause(id)

  @doc "Upstream `resumeWorkflow`."
  @spec resume(String.t()) :: :ok | {:error, term()}
  def resume(id) when is_binary(id), do: WorkflowServer.resume(id)

  @doc """
  Upstream `retry(workflowId, resumeSubworkflowTasks)`. With `resume_subworkflow_tasks`, the
  retry goes to the deepest workflow under the first failed task (through failed `SUB_WORKFLOW`
  tasks, and for a `DO_WHILE` its failed `SUB_WORKFLOW` task), which revives the workflows above
  it instead of starting new children; a workflow without a failed task is left as it is.
  """
  @spec retry(String.t(), boolean()) :: :ok | {:error, term()}
  def retry(id, resume_subworkflow_tasks \\ false)

  def retry(id, false) when is_binary(id), do: WorkflowServer.retry(id, true)

  def retry(id, true) when is_binary(id) do
    with {:ok, wf} <- Runtime.get_workflow(id, true) do
      cond do
        not Workflow.terminal?(wf.status) ->
          {:error, {:not_found, "Workflow is still running.  status=#{status_name(wf.status)}"}}

        wf.tasks == [] ->
          {:error, {:conflict, "Workflow has not started yet"}}

        true ->
          retry_last_failed(wf)
      end
    end
  end

  defp retry_last_failed(%Workflow{workflow_id: id, tasks: tasks} = wf) do
    case Enum.find(tasks, &Rules.unsuccessful_terminal_task?/1) do
      nil -> :ok
      task -> WorkflowServer.retry(last_failed(task, wf, [id]).workflow_id, true)
    end
  end

  # findLastFailedSubWorkflowIfAny. A child that cannot be read, or one that does not belong to
  # the task (ADR 0024, decision 2), leaves the retry with the workflow above it, as upstream's
  # NotFoundException does. `seen` only guards against a store whose parent fields loop.
  defp last_failed(%Task{} = task, %Workflow{} = parent, seen) do
    cond do
      not Rules.unsuccessful_terminal_task?(task) ->
        parent

      task.task_type == "SUB_WORKFLOW" ->
        with id when is_binary(id) <- Task.sub_workflow_id(task),
             false <- id in seen,
             {:ok, child} <- Runtime.get_workflow(id, true),
             true <- owned?(child, parent, task),
             %Task{} = failed <- Enum.find(child.tasks, &Rules.unsuccessful_terminal_task?/1) do
          last_failed(failed, child, [id | seen])
        else
          _none -> parent
        end

      task.task_type == "DO_WHILE" ->
        parent.tasks
        |> Enum.find(&(&1.task_type == "SUB_WORKFLOW" and Rules.unsuccessful_terminal_task?(&1)))
        |> case do
          nil -> parent
          sub_workflow -> last_failed(sub_workflow, parent, seen)
        end

      true ->
        parent
    end
  end

  defp owned?(%Workflow{} = child, %Workflow{workflow_id: parent_id}, %Task{task_id: task_id}),
    do: child.parent_workflow_id == parent_id and child.parent_workflow_task_id == task_id

  @doc """
  Upstream `restart(workflowId, useLatestDefinitions)`. With `use_latest_definitions`, the
  workflow starts over with the latest version of its definition, task definitions embedded.
  """
  @spec restart(String.t(), boolean()) :: :ok | {:error, term()}
  def restart(id, use_latest_definitions \\ false)

  def restart(id, false) when is_binary(id), do: WorkflowServer.restart(id, nil)

  def restart(id, true) when is_binary(id) do
    with {:ok, wf} <- Runtime.get_workflow(id, false) do
      # A running workflow is refused before the definition is looked up, as upstream does.
      if Workflow.terminal?(wf.status),
        do: restart_latest(wf),
        else: WorkflowServer.restart(id, nil)
    end
  end

  defp restart_latest(%Workflow{workflow_id: id} = wf) do
    with {:ok, definition} <- latest_definition(wf), do: WorkflowServer.restart(id, definition)
  end

  defp latest_definition(%Workflow{workflow_id: id} = wf) do
    with name when is_binary(name) <- Workflow.workflow_name(wf),
         {:ok, definition} <- Runtime.metadata().get_latest_workflow_def(name),
         {:ok, definition} <- Runtime.populate(definition) do
      {:ok, definition}
    else
      {:error, {_kind, _message}} = error -> error
      _missing -> {:error, {:not_found, "Unable to find latest definition for #{id}"}}
    end
  end

  defp status_name(status), do: status |> Atom.to_string() |> String.upcase()
end
