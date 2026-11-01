# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/service/ExecutionService.java
# (poll, adjustDeciderQueuePostpone) and core/.../execution/WorkflowExecutorOps.java (updateTask,
# extendLease, isLazyEvaluateWorkflow) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the owning workflow process applies one polled task or one update to its
# state; queue changes become effects and the decider queue adjustment pulls the :wake timer
# (ADR 0018, decisions 6 and 7). A SUB_WORKFLOW task keeps its subWorkflowId (ADR 0024,
# decision 1).

defmodule Archon.Runtime.Step.Tasks do
  @moduledoc """
  The task state transitions of a worker poll and a task update (ADR 0018, decision 7).

    * `poll/3` - upstream `ExecutionService#poll` for one task taken from its queue: a task
      that is gone or terminal is removed from the queue, one over its definition's concurrent
      execution limit is put back for `task_execution_postpone_ms`, and otherwise it becomes
      `IN_PROGRESS` for the worker, its limit checked again by the store with the commit
      (ADR 0021, decision 5). Recording the poll data and acking the message stay with the
      caller, which polled the whole batch.
    * `update/2` - upstream `WorkflowExecutorOps#updateTask` up to the decide, which
      `lazy_evaluate?/2` (`isLazyEvaluateWorkflow`) may skip. A `SUB_WORKFLOW` task keeps the
      `subWorkflowId` the runtime gave it (ADR 0024, decision 1): the result's is ignored and an
      output `subWorkflowId` key takes the stored value (or is dropped without one).
  """

  alias Archon.Domain.{Task, TaskDef, TaskResult, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step.{Postpone, Schedule, State}

  @doc """
  Upstream `ExecutionService#poll` for one task. Returns the task given to the worker, or `nil`
  when it is skipped, with `{:error, :not_found}` for a task the workflow does not have.
  """
  @spec poll(State.t(), String.t(), String.t() | nil) ::
          {Task.t() | nil | {:error, :not_found}, State.t()}
  def poll(%State{env: env, now: now} = state, task_id, worker_id) do
    case State.task(state, task_id) do
      nil ->
        {{:error, :not_found}, state}

      %Task{} = task ->
        cond do
          Task.terminal?(task.status) ->
            {nil, State.post(state, {:queue_remove, Schedule.queue_name(task), task_id})}

          exceeds_in_progress_limit?(task, env) ->
            effect =
              {:queue_postpone, Schedule.queue_name(task), task_id, task.workflow_priority,
               env.task_execution_postpone_ms}

            {nil, State.post(state, effect)}

          true ->
            task = %{
              task
              | status: :in_progress,
                start_time: if(task.start_time == 0, do: now, else: task.start_time),
                callback_after_seconds: 0,
                # The retry delay was spent getting the task to the worker.
                callback_after_ms: 0,
                worker_id: worker_id,
                poll_count: task.poll_count + 1
            }

            state = state |> State.save_task(task) |> State.limit(task)
            {State.task(state, task_id), adjust_wake(state, task)}
        end
    end
  end

  @doc """
  Upstream `ExecutionDAOFacade#exceedsInProgressLimit`: the task's own definition has a
  `concurrentExecLimit` its `IN_PROGRESS` tasks already reach (ADR 0018: without upstream's
  arrival-order check). A task without an embedded definition has no limit.
  """
  @spec exceeds_in_progress_limit?(Task.t(), Archon.Runtime.Step.Env.t()) :: boolean()
  def exceeds_in_progress_limit?(task, env) do
    case Task.task_definition(task) do
      %TaskDef{concurrent_exec_limit: limit} when is_integer(limit) and limit > 0 ->
        Map.get(env.in_progress, Task.task_def_name(task), 0) >= limit

      _none ->
        false
    end
  end

  # adjustDeciderQueuePostpone: evaluate the workflow by the response timeout.
  defp adjust_wake(%State{now: now} = state, task) do
    case Postpone.response_timeout_seconds(task) do
      0 -> state
      seconds -> State.pull(state, now + seconds * 1000)
    end
  end

  @doc """
  Upstream `WorkflowExecutorOps#updateTask` before the decide. Returns the saved task (or the
  untouched one when the task or the workflow is already terminal) and what follows:
  `:decide`, `:lazy` when `lazy_evaluate?/2` skips the decide, or `:none` when the update was
  ignored. An `extendLease` result only refreshes `updateTime` and returns `nil`.
  """
  @spec update(State.t(), TaskResult.t()) ::
          {:ok, Task.t() | nil, State.t(), :decide | :lazy | :none} | {:error, :not_found}
  def update(%State{} = state, %TaskResult{task_id: task_id} = result) do
    case State.task(state, task_id) do
      nil -> {:error, :not_found}
      task -> apply_result(state, task, result)
    end
  end

  defp apply_result(state, task, %TaskResult{extend_lease: true}) do
    state = if Task.terminal?(task.status), do: state, else: State.save_task(state, task)
    {:ok, nil, state, :none}
  end

  defp apply_result(%State{wf: wf} = state, task, result) do
    remove = {:queue_remove, Schedule.queue_name(task), task.task_id}

    if Task.terminal?(task.status) or Workflow.terminal?(wf.status) do
      {:ok, task, queue(state, task, remove), :none}
    else
      task = result_task(state, task, result)
      state = state |> queue(task, queue_effect(task, result)) |> State.save_task(task)
      task = State.task(state, task.task_id)
      evaluate = if lazy_evaluate?(wf.workflow_definition, task), do: :lazy, else: :decide
      {:ok, task, state, evaluate}
    end
  end

  defp result_task(%State{env: env, now: now}, task, %TaskResult{} = result) do
    status =
      if not Schedule.system_task?(env, task) and result.status == :in_progress,
        do: :scheduled,
        else: result.status

    sub_workflow_id = sub_workflow_id(task, result)
    output = output_key(result.output_data || %{}, task, sub_workflow_id)

    task = %{
      task
      | status: status,
        reason_for_incompletion: result.reason_for_incompletion,
        worker_id: result.worker_id,
        callback_after_seconds: result.callback_after_seconds,
        callback_after_ms: 0,
        output_data: output,
        sub_workflow_id: sub_workflow_id
    }

    task =
      if blank?(result.external_output_payload_storage_path),
        do: task,
        else: %{
          task
          | external_output_payload_storage_path: result.external_output_payload_storage_path
        }

    if Task.terminal?(task.status), do: %{task | end_time: now}, else: task
  end

  # ADR 0024, decision 1: a SUB_WORKFLOW task keeps the child the runtime started; any other task
  # stores the result's, as upstream does.
  defp sub_workflow_id(%Task{task_type: "SUB_WORKFLOW", sub_workflow_id: id}, _result), do: id
  defp sub_workflow_id(_task, %TaskResult{sub_workflow_id: id}), do: id

  # An output subWorkflowId key follows the task's; a SUB_WORKFLOW without a child drops it.
  defp output_key(output, _task, _id) when not is_map_key(output, "subWorkflowId"), do: output

  defp output_key(output, %Task{task_type: "SUB_WORKFLOW"}, nil),
    do: Map.delete(output, "subWorkflowId")

  defp output_key(output, _task, id), do: Map.put(output, "subWorkflowId", id)

  defp queue_effect(%Task{status: status} = task, result) do
    if Task.terminal?(status),
      do: {:queue_remove, Schedule.queue_name(task), task.task_id},
      else:
        {:queue_postpone, Schedule.queue_name(task), task.task_id, task.workflow_priority,
         max(result.callback_after_seconds, 0) * 1000}
  end

  # Only worker tasks have a queue (ADR 0018, decision 3).
  defp queue(%State{env: env} = state, task, effect) do
    if Schedule.system_task?(env, task), do: state, else: State.post(state, effect)
  end

  @doc """
  Upstream `isLazyEvaluateWorkflow`: an update of a successful task in a static `FORK_JOIN`
  branch that a `JOIN` waits on skips the decide (the `JOIN` evaluation decides instead). A task
  inside a `DO_WHILE` never skips it.
  """
  @spec lazy_evaluate?(WorkflowDef.t(), Task.t()) :: boolean()
  def lazy_evaluate?(%WorkflowDef{} = definition, %Task{reference_task_name: ref} = task) do
    tasks = WorkflowDef.collect_tasks(definition)

    not Task.loop_over_task?(task) and
      Enum.any?(tasks, &(&1.type == "FORK_JOIN" and WorkflowTask.has?(&1, ref))) and
      Enum.any?(tasks, &(&1.type == "JOIN" and ref in (&1.join_on || []))) and
      Task.successful?(task.status)
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""
end
