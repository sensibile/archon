# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (decide, endExecution, completeWorkflow, scheduleNextIteration) and
# core/.../execution/tasks/DoWhile.java (removeIterations)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: a pure loop over the step state; the lock lease guard became an
# iteration limit and the decider queue push a :wake effect (ADR 0018, decision 4).

defmodule Archon.Runtime.Step.Decide do
  @moduledoc """
  Upstream `WorkflowExecutorOps#decide(WorkflowModel)`: runs `Archon.Decider.decide/2` and
  applies its outcome until nothing changes (ADR 0018, decision 4).

  A decide first runs `Archon.Runtime.Step.Lifecycle.adjust/1`
  (`adjustStateIfSubWorkflowChanged`). Each iteration adds the new tasks (domains, deduplication, `scheduleTask`), executes the
  synchronous system tasks among the tasks to schedule (a `DO_WHILE` also schedules its next
  iteration and deletes the iterations `keepLastN` drops), and saves the tasks to update. It
  iterates again while a synchronous system task started or changed. A complete outcome ends
  the workflow (`endExecution`), a termination goes to `Archon.Runtime.Step.Terminate`.

  After `max_decide_iterations` iterations in one step the workflow is saved and an immediate
  `{:wake_at, now}` is asked for instead of iterating (upstream re-queues the workflow when its
  lock lease is about to expire).
  """

  alias Archon.Decider
  alias Archon.Decider.{Outcome, Parameters, SystemTask, Termination}
  alias Archon.Decider.SystemTask.DoWhile
  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.Step.{Async, Env, Lifecycle, Schedule, State, Terminate}

  @doc """
  Decides the workflow, then evaluates the asynchronous system tasks that calls for, and decides
  again while one of them finished (ADR 0018, decisions 2 and 6).
  """
  @spec settle(State.t()) :: State.t()
  def settle(state), do: state |> decide() |> evaluate_async()

  defp evaluate_async(%State{halted?: true} = state), do: state

  defp evaluate_async(%State{wf: wf} = state) do
    if Workflow.terminal?(wf.status) do
      state
    else
      case Async.pass(state, :events) do
        {state, true} -> settle(state)
        {state, false} -> state
      end
    end
  end

  @doc "Decides the workflow in memory."
  @spec decide(State.t()) :: State.t()
  def decide(%State{wf: %Workflow{status: status}} = state) do
    cond do
      Workflow.successful?(status) and Workflow.terminal?(status) -> state
      Workflow.terminal?(status) -> Terminate.cancel_non_terminal(state, :post)
      true -> loop(%{Lifecycle.adjust(state) | decided?: true})
    end
  end

  defp loop(%State{halted?: true} = state), do: state

  defp loop(%State{env: env} = state) do
    if state.iterations >= env.max_decide_iterations do
      halt(state)
    else
      state = %{state | iterations: state.iterations + 1}

      case Decider.decide(state.wf, Env.context(env)) do
        {:ok, %Outcome{complete?: true} = outcome} ->
          state |> State.put_workflow(outcome.workflow) |> end_execution(outcome.terminate_task)

        {:ok, %Outcome{} = outcome} ->
          state |> State.put_workflow(outcome.workflow) |> apply_outcome(outcome)

        {:terminate, termination, outcome} ->
          state |> State.put_workflow(outcome.workflow) |> Terminate.by_decider(termination)
      end
    end
  end

  # Saves the workflow and asks to be woken at once (upstream pushes it to the decider queue).
  defp halt(%State{now: now} = state),
    do: %{State.post(State.save_workflow(state), {:wake_at, now}) | halted?: true}

  defp apply_outcome(%State{env: env} = state, %Outcome{} = outcome) do
    scheduled = Schedule.set_task_domains(outcome.tasks_to_be_scheduled, state.wf, env)
    {state, new} = Schedule.dedup_and_add(state, scheduled)
    {state, started?} = Schedule.schedule(state, new)

    case execute_sync(state, scheduled, outcome.tasks_to_be_updated) do
      {:ok, state, updated, executed?} ->
        changed? = started? or executed?
        persist? = updated != [] or new != []

        state =
          if persist?,
            do: Enum.reduce(updated, state, &State.save_current(&2, &1.task_id)),
            else: state

        cond do
          changed? -> loop(state)
          persist? -> State.save_workflow(state)
          true -> state
        end

      {:terminate, termination, state} ->
        Terminate.by_decider(state, termination)
    end
  end

  # The decide loop's pass over the tasks to schedule: synchronous system tasks that are not
  # terminal are executed, and those that changed join the tasks to update.
  defp execute_sync(state, scheduled, updated) do
    Enum.reduce_while(scheduled, {:ok, state, updated, false}, fn task,
                                                                  {:ok, state, updated, any?} ->
      case execute_scheduled(state, State.task(state, task.task_id)) do
        {:ok, state, true} -> {:cont, {:ok, state, updated ++ [task], true}}
        {:ok, state, false} -> {:cont, {:ok, state, updated, any?}}
        {:terminate, termination, state} -> {:halt, {:terminate, termination, state}}
      end
    end)
  end

  defp execute_scheduled(%State{env: env} = state, %Task{} = task) do
    if Schedule.sync_system_task?(env, task) and not Task.terminal?(task.status),
      do: execute(state, task),
      else: {:ok, state, false}
  end

  defp execute_scheduled(state, nil), do: {:ok, state, false}

  defp execute(%State{env: env} = state, %Task{task_type: "DO_WHILE"} = task) do
    case DoWhile.execute(state.wf, task, Env.context(env)) do
      {:ok, %DoWhile{} = result} ->
        state = State.delete_tasks(state, result.removed_task_ids)

        if result.changed? do
          state = State.put_task(state, result.task)
          {:ok, schedule_next_iteration(state, result.tasks_to_be_scheduled), true}
        else
          {:ok, state, false}
        end

      {:terminate, %Termination{} = termination} ->
        {:terminate, termination, state}
    end
  end

  defp execute(%State{now: now} = state, task) do
    case SystemTask.execute(state.wf, task, now) do
      {true, task} -> {:ok, State.put_task(state, task), true}
      {false, _task} -> {:ok, state, false}
    end
  end

  # WorkflowExecutorOps#scheduleNextIteration: domains, scheduleTask, then the tasks join the
  # workflow.
  defp schedule_next_iteration(%State{env: env} = state, tasks) do
    tasks = Schedule.set_task_domains(tasks, state.wf, env)
    {state, _started?} = Schedule.schedule(state, tasks)
    state
  end

  # endExecution: a TERMINATE task with a FAILED or TERMINATED terminationStatus terminates the
  # workflow; anything else completes it. Tasks still running are canceled afterwards.
  defp end_execution(state, nil),
    do: state |> complete() |> Terminate.cancel_non_terminal(:post)

  defp end_execution(%State{wf: wf} = state, %Task{input_data: input} = terminate_task) do
    status = Map.get(input, "terminationStatus")
    reason = Map.get(input, "terminationReason")

    reason =
      if blank?(reason),
        do:
          "Workflow is #{Parameters.java_string(status)} by TERMINATE task: " <>
            Parameters.java_string(terminate_task.task_id),
        else: reason

    case status do
      "FAILED" ->
        terminate(state, reason, :failed, terminate_task)

      "TERMINATED" ->
        terminate(state, reason, :terminated, terminate_task)

      _completed ->
        state
        |> State.put_workflow(%{wf | reason_for_incompletion: reason})
        |> complete()
        |> Terminate.cancel_non_terminal(:post)
    end
  end

  defp terminate(%State{wf: wf} = state, reason, status, task) do
    state
    |> State.put_workflow(State.set_status(wf, status))
    |> Terminate.by_decider(Termination.new(reason, status, task))
  end

  # completeWorkflow
  defp complete(%State{wf: wf} = state) do
    wf =
      wf
      |> Decider.Retry.update_output(nil)
      |> State.set_status(:completed)
      |> Terminate.add_failed_task_names()

    state
    |> State.put_workflow(wf)
    |> State.save_workflow()
    |> Terminate.notify_parent()
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
