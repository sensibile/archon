# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (pauseWorkflow, resumeWorkflow, retry, findLastFailedSubWorkflowIfAny, restart,
# skipTaskFromWorkflow, resetCallbacksForWorkflow, rerun, rerunWF) and
# core/.../service/WorkflowServiceImpl.java (deleteWorkflow, terminateRemove) at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: what needs other workflows or the metadata is read here, and the
# operation itself is a message to the workflow's process (ADR 0018, decision 9); the retry goes
# down only to children that belong to their task (ADR 0024, decision 2); a removal asks again
# until the workflow's outbox is empty (ADR 0025, decision 3).

defmodule Archon.Runtime.Lifecycle do
  @moduledoc """
  The lifecycle operations of the runtime API (ADR 0018, decision 9; ADR 0025, decisions 2 and 3):
  upstream `pauseWorkflow`, `resumeWorkflow`, `retry`, `restart`, `rerun`, `skipTaskFromWorkflow`,
  `resetCallbacksForWorkflow`, `deleteWorkflow` (`remove/2`) and `terminateRemove`. The workflow
  lifecycle REST (`ArchonWeb.WorkflowLifecycleController`) calls only these.

  Each one is a message to the workflow's process (`Archon.Runtime.Step.Lifecycle` has the
  rules) and answers once its commit and the decide that follows are saved. A workflow that runs
  again because of a retry or a restart revives its parent, and that parent its own, by a message
  each (upstream `updateAndPushParents`), so the ancestors follow shortly after the answer.

  Errors are `{:error, :not_found}` for a workflow the store does not have, or
  `{:error, {kind, message}}` with upstream's exception (`:conflict`, `:not_found`,
  `:invalid_state` for `IllegalStateException`, `:invalid` for `IllegalArgumentException`) and its
  message. A process that did not answer is `{:error, {:exit, reason}}` and a failure of the step
  `{:error, {tag, reason}}` (`Archon.Runtime.WorkflowServer`), both transient.
  """

  require Logger

  alias Archon.Domain.{RerunWorkflowRequest, Task, Workflow}
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

  @doc """
  Upstream `rerun` (ADR 0025, decision 2): the workflow or, with `reRunFromTaskId`, the task
  runs again; the answer comes once every workflow on the way is `RUNNING` and decided.

  Upstream's recursive `rerunWF` is done in three steps:

    1. Reading only: a workflow that has not ended is a conflict, then the task is looked for in
       the workflow and, when it is not there, in the child of each `SUB_WORKFLOW` task in turn,
       depth first. A child on the way that has not ended is a conflict, one the store does not
       have (or that does not belong to its task, ADR 0024, decision 2) is not found, as upstream
       answers for the first child it cannot rerun. Found nowhere is `{:invalid, "Task <id> not
       found"}`.
    2. The workflow that has the task reruns from it (`{:rerun, request}`, cases 1 and 2); it
       takes the input and correlation ID only when it is the top one (upstream passes `null`
       down).
    3. Each workflow above it, from its parent to the top, reruns its `SUB_WORKFLOW` task that
       leads there (`{:rerun_parent, ...}`, case 3); only the top one takes the input and
       correlation ID. A message each, after the answer below and once the outbox of the
       workflow below is empty (its notices and revivals of this one delivered, as upstream does
       them before it writes the parent), so a parent does not decide while its child is still
       `FAILED` and a later notice does not undo the rerun. A workflow above that already runs
       again (revived by the one below) is no error.
  """
  @spec rerun(String.t(), RerunWorkflowRequest.t()) :: :ok | {:error, term()}
  def rerun(id, %RerunWorkflowRequest{} = request) when is_binary(id) do
    with {:ok, wf} <- Runtime.get_workflow(id, true),
         :ok <- rerunnable(wf),
         {:ok, path} <- rerun_path(wf, request.re_run_from_task_id) do
      run_rerun(path, request)
    end
  end

  defp rerunnable(%Workflow{} = wf) do
    if Workflow.terminal?(wf.status),
      do: :ok,
      else:
        {:error,
         {:conflict,
          "Workflow: #{Rules.long_string(wf)} is not in terminal state, unable to rerun."}}
  end

  # [{workflow, sub_workflow_task_id} ...] as read, from the top down to the workflow that has
  # the task, whose entry has no task (`nil`).
  defp rerun_path(%Workflow{} = wf, nil), do: {:ok, [{wf, nil}]}

  defp rerun_path(%Workflow{} = wf, task_id) do
    case find_task(wf, task_id, [wf.workflow_id]) do
      {:ok, path} -> {:ok, path}
      :none -> {:error, {:invalid, "Task #{task_id} not found"}}
      {:error, _reason} = error -> error
    end
  end

  defp find_task(%Workflow{tasks: tasks} = wf, task_id, seen) do
    if Enum.any?(tasks, &(&1.task_id == task_id)) do
      {:ok, [{wf, nil}]}
    else
      tasks
      |> Enum.filter(&(&1.task_type == "SUB_WORKFLOW"))
      |> Enum.reduce_while(:none, &find_below(wf, &1, task_id, seen, &2))
    end
  end

  defp find_below(wf, task, task_id, seen, :none) do
    case find_in_child(wf, task, task_id, seen) do
      {:ok, path} -> {:halt, {:ok, [{wf, task.task_id} | path]}}
      :none -> {:cont, :none}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  # rerunWF(subWorkflowId, ...) of upstream: the child is read, must have ended, then searched.
  defp find_in_child(%Workflow{} = parent, %Task{} = task, task_id, seen) do
    child_id = Task.sub_workflow_id(task)

    with false <- child_id in seen,
         {:ok, child} <- Runtime.get_workflow(child_id || "", true),
         true <- owned?(child, parent, task) do
      case rerunnable(child) do
        :ok -> find_task(child, task_id, [child_id | seen])
        error -> error
      end
    else
      _missing -> {:error, {:not_found, "No such workflow found by id: #{child_id || "null"}"}}
    end
  end

  defp run_rerun(path, %RerunWorkflowRequest{} = request) do
    [{%Workflow{workflow_id: top}, _task} | _rest] = path
    [{%Workflow{workflow_id: target}, nil} | above] = Enum.reverse(path)

    input = fn id -> if id == top, do: request.workflow_input end
    correlation_id = fn id -> if id == top, do: request.correlation_id end

    rerun = %{
      task_id: request.re_run_from_task_id,
      task_input: request.task_input,
      workflow_input: input.(target),
      correlation_id: correlation_id.(target)
    }

    with :ok <- not_found_as(WorkflowServer.rerun(target, rerun), target) do
      above
      |> Enum.zip([target | Enum.map(above, &elem(&1, 0).workflow_id)])
      |> Enum.reduce_while(:ok, &rerun_above(&1, &2, input, correlation_id))
    end
  end

  defp rerun_above({{%Workflow{} = wf, task_id}, below}, :ok, input, correlation_id) do
    await_outbox(below)
    id = wf.workflow_id
    task = Enum.find(wf.tasks, &(&1.task_id == task_id))

    request = %{
      task_id: task_id,
      workflow_input: input.(id),
      correlation_id: correlation_id.(id),
      last_retried_time: wf.last_retried_time,
      task_status: task.status,
      task_update_time: task.update_time,
      task_retried: task.retried
    }

    case not_found_as(WorkflowServer.rerun_parent(id, request), id) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  # A workflow removed since it was read is named, not the one in the path.
  defp not_found_as({:error, :not_found}, id),
    do: {:error, {:not_found, "No such workflow found by id: #{id}"}}

  defp not_found_as(result, _id), do: result

  # A store that cannot tell does not hold the rerun up: it goes on, as past the deadline.
  defp outbox_empty?(id) do
    Runtime.store().pending_outbox(id) == []
  rescue
    exception ->
      Logger.warning("rerun goes on above #{id}: #{Exception.message(exception)}")
      true
  catch
    :exit, reason ->
      Logger.warning("rerun goes on above #{id}: #{inspect(reason)}")
      true
  end

  # Upstream reruns the workflows below synchronously, their notices and revivals of the parent
  # included, before it writes the parent. Here those go through the outbox of the workflow
  # below (ADR 0021, decision 4), so the parent's message waits until it is empty, asking every
  # `rerun_retry_ms` (100 ms) up to `rerun_timeout` (10 s); past that it goes on, logged.
  defp await_outbox(id) do
    deadline = System.monotonic_time(:millisecond) + Runtime.setting(:rerun_timeout, 10_000)
    await_outbox(id, deadline)
  end

  defp await_outbox(id, deadline) do
    cond do
      outbox_empty?(id) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("rerun goes on above #{id} before its outbox is empty")

      true ->
        Process.sleep(Runtime.setting(:rerun_retry_ms, 100))
        await_outbox(id, deadline)
    end
  end

  @doc """
  Upstream `skipTaskFromWorkflow`: a `SKIPPED` task for `reference_name`, then a decide. The
  request's `SkipTaskRequest` is not used (ADR 0025, decision 2).
  """
  @spec skip_task(String.t(), String.t()) :: :ok | {:error, term()}
  def skip_task(id, reference_name) when is_binary(id) and is_binary(reference_name),
    do: WorkflowServer.skip_task(id, reference_name)

  @doc """
  Upstream `resetCallbacksForWorkflow`: the `SCHEDULED` worker tasks with a callback delay are due
  now and lose the delay (only those whose queue message is there).
  """
  @spec reset_callbacks(String.t()) :: :ok | {:error, term()}
  def reset_callbacks(id) when is_binary(id), do: WorkflowServer.reset_callbacks(id)

  @doc """
  Upstream `deleteWorkflow(workflowId, archiveWorkflow)` on the default server (ADR 0025,
  decision 3): with `archive_workflow` only a terminal workflow (`{:error, {:invalid, message}}`
  otherwise); the workflow, its tasks, its outbox and its tasks' queue messages are deleted and
  its process ends. Children and parent are left as they are.

  The workflow's process removes it only once its outbox is empty, so the work its termination
  left for other workflows (a child termination, the notice to its parent) is not lost. While it
  is not, this asks again every `remove_retry_ms` (100 ms) until `remove_timeout` (10 s) has
  passed, then answers `{:error, :outbox_pending}` with nothing removed (a retryable 500). Each
  try is decided again by the process, so a workflow another client revived meanwhile meets the
  `archive_workflow` check again.
  """
  @spec remove(String.t(), boolean()) :: :ok | {:error, term()}
  def remove(id, archive_workflow \\ true) when is_binary(id) and is_boolean(archive_workflow) do
    deadline = System.monotonic_time(:millisecond) + Runtime.setting(:remove_timeout, 10_000)
    remove_until(id, archive_workflow, deadline)
  end

  defp remove_until(id, archive_workflow, deadline) do
    case WorkflowServer.remove(id, archive_workflow) do
      {:error, :outbox_pending} = pending ->
        left = deadline - System.monotonic_time(:millisecond)

        if left > 0 do
          Process.sleep(min(left, Runtime.setting(:remove_retry_ms, 100)))
          remove_until(id, archive_workflow, deadline)
        else
          pending
        end

      result ->
        result
    end
  end

  @doc """
  Upstream `terminateRemove`: `Archon.Runtime.terminate_workflow/2`, then `remove/2`. A
  `COMPLETED` workflow is not terminated (`{:error, :conflict}`) and so not removed; a `FAILED`
  or `TIMED_OUT` one is `TERMINATED` first.
  """
  @spec terminate_remove(String.t(), String.t() | nil, boolean()) :: :ok | {:error, term()}
  def terminate_remove(id, reason, archive_workflow \\ true)
      when is_binary(id) and is_boolean(archive_workflow) do
    with :ok <- Runtime.terminate_workflow(id, reason), do: remove(id, archive_workflow)
  end

  defp status_name(status), do: status |> Atom.to_string() |> String.upcase()
end
