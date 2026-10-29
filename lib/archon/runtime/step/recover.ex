# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/org/conductoross/conductor/core/execution/WorkflowSweeper.java
# (sweep, isTaskRepairable, repairSubWorkflowTask, forceSetLastTaskAsNotExecuted)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the repair runs in the workflow's own process when it is activated, after
# an isolated exception and on a :wake that changed nothing, and also covers what the effects
# around a commit may have left undone (ADR 0018, decisions 2 and 7).

defmodule Archon.Runtime.Step.Recover do
  @moduledoc """
  The recovery check (ADR 0018, decisions 2 and 7), upstream's sweeper repair.

  For a running workflow:

    * a workflow whose parent ended and canceled its task, or whose parent is gone, terminates
      itself (the parent's child termination may have been lost);
    * `SCHEDULED` worker tasks without a queue message are pushed again, with what is left of
      their callback delay;
    * pending asynchronous system tasks are evaluated as on `:wake` (a `SUB_WORKFLOW` start that
      did not finish is started again with the same ID, a child that ended is reflected);
    * the workflow is decided, and when it is running without a task that is not terminal, its
      last task is marked not executed and it is decided again.

  For a terminal workflow nothing is decided: a failure workflow that the output names but the
  store does not have is started again, and the children of `CANCELED` `SUB_WORKFLOW` tasks that
  are still running are terminated.
  """

  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.Step.{Async, Decide, Schedule, State, Terminate}

  @doc "The recovery check of a `:recover` event."
  @spec recover(State.t()) :: State.t()
  def recover(%State{wf: wf} = state) do
    cond do
      Workflow.terminal?(wf.status) ->
        terminal(state)

      reason = orphaned(state) ->
        Terminate.by_parent(state, reason)

      true ->
        state = repair_queues(state)
        {state, _decide?} = Async.pass(state, :wake)
        state |> Decide.settle() |> unstick()
    end
  end

  @doc "The repair after a `:wake` that changed no task (upstream sweeps that change nothing)."
  @spec after_wake(State.t()) :: State.t()
  def after_wake(%State{changed?: true} = state), do: state

  def after_wake(%State{wf: wf} = state) do
    if Workflow.terminal?(wf.status), do: state, else: state |> repair_queues() |> unstick()
  end

  # The parent ended and canceled this workflow's task, or the parent is gone.
  defp orphaned(%State{wf: %Workflow{parent_workflow_id: nil}}), do: nil

  defp orphaned(%State{wf: wf, env: env}) do
    case Map.fetch(env.workflows, wf.parent_workflow_id) do
      :error ->
        nil

      {:ok, nil} ->
        "Parent workflow #{wf.parent_workflow_id} does not exist"

      {:ok, %Workflow{} = parent} ->
        with true <- Workflow.terminal?(parent.status),
             %Task{status: :canceled} = task <-
               Enum.find(parent.tasks, &(&1.task_id == wf.parent_workflow_task_id)) do
          {:terminate_sub_workflow, _id, reason} = Terminate.cancel_child(parent, task)
          reason
        else
          _running -> nil
        end
    end
  end

  # isTaskRepairable for worker tasks: SCHEDULED ones without a message are pushed again.
  defp repair_queues(%State{wf: wf, env: env, now: now} = state) do
    wf.tasks
    |> Enum.filter(&(&1.status == :scheduled and not Schedule.system_task?(env, &1)))
    |> Enum.reject(&MapSet.member?(env.queued, &1.task_id))
    |> Enum.reduce(state, fn task, state ->
      delay = max(Async.due_time(task) - now, 0)

      State.post(
        state,
        {:queue_push, Schedule.queue_name(task), task.task_id, task.workflow_priority, delay}
      )
    end)
  end

  # forceSetLastTaskAsNotExecuted: a running workflow with no task left to finish is decided
  # again from its last task.
  defp unstick(%State{halted?: true} = state), do: state

  defp unstick(%State{wf: %Workflow{status: :running, tasks: [_ | _] = tasks}} = state) do
    if Enum.all?(tasks, &Task.terminal?(&1.status)) do
      last = List.last(tasks)
      state |> State.save_task(%{last | executed: false}) |> Decide.settle()
    else
      state
    end
  end

  defp unstick(state), do: state

  defp terminal(%State{wf: wf, env: env} = state) do
    state =
      for task <- wf.tasks,
          task.task_type == "SUB_WORKFLOW",
          task.status == :canceled,
          {:terminate_sub_workflow, id, _reason} = effect = Terminate.cancel_child(wf, task),
          match?({:ok, %Workflow{}}, Map.fetch(env.workflows, id)),
          not Workflow.terminal?(env.workflows[id].status),
          reduce: state do
        state -> State.post(state, effect)
      end

    restart_failure_workflow(state)
  end

  defp restart_failure_workflow(%State{wf: wf, env: env} = state) do
    with id when is_binary(id) <- Map.get(wf.output, "conductor.failure_workflow"),
         {:ok, nil} <- Map.fetch(env.workflows, id),
         {:ok, start} <- Terminate.failure_start(wf, id) do
      State.post(state, {:start_failure_workflow, start})
    else
      _started -> state
    end
  end
end
