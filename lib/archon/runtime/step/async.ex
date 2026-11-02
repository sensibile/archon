# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/AsyncSystemTaskExecutor.java
# (execute, hasExceededResponseTimeout, effectiveResponseTimeoutSeconds),
# core/.../execution/tasks/Join.java (getEvaluationOffset) and core/.../execution/tasks/Wait.java
# (getEvaluationOffset) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the workflow process evaluates its asynchronous system tasks when an
# event calls for it instead of polling a system task queue (ADR 0018, decision 6), and a
# SUB_WORKFLOW reads its child only when the child belongs to it (ADR 0024, decision 2); a start
# that is an effect comes back as an event checked against the attempt, and the recovery starts
# a start-idempotent task again at once (ADR 0026, decision 7).

defmodule Archon.Runtime.Step.Async do
  @moduledoc """
  Upstream `AsyncSystemTaskExecutor#execute` for the asynchronous system tasks (`async?` in
  `Archon.Decider.SystemTasks`), run by the workflow's own process (ADR 0018, decision 6).

  `pass/2` evaluates the tasks an event calls for: the ones marked due (just scheduled without a
  delay), the `JOIN`s waiting on a task a save made terminal, and on `:wake` every pending one
  whose delay is over. Each evaluation counts in `pollCount`. A task that finishes (or an
  `isAsyncComplete` task that is no longer `SCHEDULED`) asks for a decide; one that goes on keeps
  its evaluation offset in `callbackAfterSeconds`.

  Starting a `SCHEDULED` task saves its `pollCount` and `startTime` first (ADR 0026, decision 7).
  A type whose start is work outside the process has a starter module here (`SUB_WORKFLOW`:
  `Archon.Runtime.Step.SubWorkflow`, `START_WORKFLOW`: `Archon.Runtime.Step.StartWorkflow`) with
  `start(state, task) :: {:started, state} | {:failed, task}`: `:started` posts the effect, which
  runs after the commit, and its result comes back as an event. The event's handler takes the task
  from `attempt/3` (still `SCHEDULED`, the same `pollCount` when the event has one; else the
  result is dropped) and ends with `finish/2`. Any other type's start is
  `Archon.Decider.SystemTask.start/3`.

  The start of a type whose `start_idempotent?` is set may run again: such a task left
  `SCHEDULED` past its response timeout is started again instead of being `TIMED_OUT` (upstream
  `isStartIdempotent`), and the recovery (`pass(state, :recover)`) starts one that was started
  but has no result again at once.
  """

  alias Archon.Decider.{SystemTask, SystemTasks}
  alias Archon.Decider.SystemTask.SubWorkflow, as: SubWorkflowTask
  alias Archon.Domain.{Task, Workflow, WorkflowTask}
  alias Archon.Runtime.Step.{Env, Schedule, StartWorkflow, State, SubWorkflow, Tasks}

  # TaskDef.ONE_HOUR
  @one_hour 3600

  # The types whose start is an effect (see the moduledoc).
  @starters %{"SUB_WORKFLOW" => SubWorkflow, "START_WORKFLOW" => StartWorkflow}

  @doc """
  Evaluates the asynchronous system tasks the step calls for. `:wake` adds every pending one
  that is due; `:recover` also adds every start-idempotent task that was started and is still
  `SCHEDULED`. Returns whether one asks for a decide.
  """
  @spec pass(State.t(), :events | :wake | :recover) :: {State.t(), boolean()}
  def pass(%State{wf: wf} = state, mode) do
    ids =
      for task <- wf.tasks,
          Schedule.async?(state.env, task),
          not Task.terminal?(task.status),
          MapSet.member?(state.due, task.task_id) or triggered?(state, task) or
            (mode in [:wake, :recover] and due?(state, task)) or
            (mode == :recover and restart?(state, task)),
          do: task.task_id

    state = %{state | due: MapSet.new(), terminated_refs: MapSet.new()}

    Enum.reduce(ids, {state, false}, fn id, {state, decide?} ->
      {state, finished?} = evaluate(state, State.task(state, id))
      {state, decide? or finished?}
    end)
  end

  # A JOIN waits on a task a save made terminal. A SCHEDULED one with a delay waits for it first
  # (ADR 0018, decision 6: no evaluation of any kind before the delay is over).
  defp triggered?(%State{now: now} = state, %Task{task_type: "JOIN", status: :scheduled} = task)
       when task.callback_after_ms > 0 or task.callback_after_seconds > 0 do
    if due_time(task) > now, do: false, else: triggered_join?(state, task)
  end

  defp triggered?(state, %Task{task_type: "JOIN"} = task), do: triggered_join?(state, task)
  defp triggered?(_state, _task), do: false

  defp triggered_join?(%State{terminated_refs: refs}, task),
    do: Enum.any?(join_on(task), &MapSet.member?(refs, &1))

  defp join_on(%Task{input_data: input} = task) do
    refs = Map.get(input, "joinOn") || []
    if Task.loop_over_task?(task), do: Enum.map(refs, &"#{&1}__#{task.iteration}"), else: refs
  end

  # Due on a :wake: a SCHEDULED task once its delay is over, a running JOIN or WAIT, and a running
  # SUB_WORKFLOW whose child was read.
  # Due on a :wake: a task whose delay is over (a running SUB_WORKFLOW also needs its child to
  # have been read).
  defp due?(%State{env: env}, %Task{task_type: "SUB_WORKFLOW", status: :in_progress} = task),
    do: Env.child(env, task, Task.sub_workflow_id(task)) != :error

  defp due?(%State{now: now}, task), do: due_time(task) <= now

  # Started (its pollCount counted the start) without a result that ended or kept it: a
  # start-idempotent type starts again (ADR 0026, decision 7).
  defp restart?(%State{env: env}, %Task{status: :scheduled, poll_count: count} = task)
       when count > 0,
       do: SystemTasks.start_idempotent?(env.system_tasks, task.task_type)

  defp restart?(_state, _task), do: false

  @doc """
  When a task's queue delay is over, as upstream's queue would show it again: its last save (or
  its scheduling) plus `callbackAfterMs`, else `callbackAfterSeconds`. A `SUB_WORKFLOW` whose
  start was saved (its `pollCount` counted it) but whose result never came back (no
  `subWorkflowLaunchError`) is due at once.
  """
  @spec due_time(Task.t()) :: integer()
  def due_time(%Task{task_type: "SUB_WORKFLOW", status: :scheduled, poll_count: count} = task)
      when count > 0 do
    if Map.has_key?(task.output_data || %{}, "subWorkflowLaunchError"),
      do: task.update_time + Schedule.delay_ms(task),
      else: task.update_time
  end

  def due_time(%Task{} = task) do
    base = if task.update_time > 0, do: task.update_time, else: task.scheduled_time
    base + Schedule.delay_ms(task)
  end

  @doc "Upstream `AsyncSystemTaskExecutor#execute` of one task."
  @spec evaluate(State.t(), Task.t()) :: {State.t(), boolean()}
  def evaluate(%State{wf: wf} = state, %Task{} = task) do
    cond do
      Task.terminal?(task.status) ->
        {state, false}

      Workflow.terminal?(wf.status) ->
        status = wf.status |> Atom.to_string() |> String.upcase()

        task = %{
          task
          | status: :canceled,
            reason_for_incompletion: "Workflow is in #{status} state"
        }

        {State.save_task(state, task), false}

      true ->
        async_complete? = SystemTasks.async_complete?(state.env.system_tasks, task)

        task =
          if task.status == :scheduled or not async_complete?,
            do: %{task | poll_count: task.poll_count + 1},
            else: task

        run(state, task, async_complete?)
    end
  end

  defp run(%State{now: now, env: env} = state, %Task{status: :scheduled} = task, async_complete?) do
    cond do
      # The concurrent execution limit puts the task back; the process looks again on a later
      # :wake instead of after taskExecutionPostponeDuration.
      Tasks.exceeds_in_progress_limit?(task, env) ->
        {state, false}

      exceeded_response_timeout?(task, now) and
          not SystemTasks.start_idempotent?(env.system_tasks, task.task_type) ->
        reason =
          "Task did not complete within its responseTimeout of #{response_timeout(task)}s"

        dispose(
          state,
          %{task | status: :timed_out, reason_for_incompletion: reason},
          async_complete?
        )

      true ->
        task = %{task | start_time: now}
        {state, decide?} = start(State.save_task(state, task), task, async_complete?)
        {limit_started(state, task.task_id), decide?}
    end
  end

  defp run(state, task, async_complete?) do
    {state, task} = execute(state, task)
    dispose(state, task, async_complete?)
  end

  # A started task left IN_PROGRESS holds a slot of its definition's limit (ADR 0021, decision 5).
  defp limit_started(state, task_id) do
    case State.task(state, task_id) do
      %Task{} = task -> State.limit(state, task)
      nil -> state
    end
  end

  # WorkflowSystemTask#start. A starter's result comes back as an event; another type's start,
  # if it has one, is its Archon.Decider.SystemTask.start/3.
  defp start(%State{env: env} = state, task, async_complete?) do
    case Map.fetch(@starters, task.task_type) do
      {:ok, starter} ->
        case starter.start(state, task) do
          {:started, state} -> {state, false}
          {:failed, task} -> dispose(state, task, async_complete?)
        end

      :error ->
        case SystemTask.start(state.wf, task, Env.context(env)) do
          nil ->
            dispose(state, task, async_complete?)

          # No asynchronous type fails its start; upstream's executor would only log it.
          {:error, _reason} ->
            dispose(state, task, async_complete?)

          result ->
            state |> Schedule.apply_result(result) |> dispose(result.task, async_complete?)
        end
    end
  end

  @doc """
  The task a started task's result is for: the task `task_id` while it is still `SCHEDULED`
  and, when the event carries one, has the same `pollCount`; `nil` when the result is to be
  dropped (the task ended, was removed or is another attempt).
  """
  @spec attempt(State.t(), String.t(), non_neg_integer() | nil) :: Task.t() | nil
  def attempt(%State{} = state, task_id, poll_count) do
    case State.task(state, task_id) do
      %Task{status: :scheduled} = task when poll_count in [nil, task.poll_count] -> task
      _gone -> nil
    end
  end

  @doc "`dispose/3` of a task a started task's result changed (see `attempt/3`)."
  @spec finish(State.t(), Task.t()) :: {State.t(), boolean()}
  def finish(%State{env: env} = state, %Task{} = task),
    do: dispose(state, task, SystemTasks.async_complete?(env.system_tasks, task))

  defp execute(%State{env: env} = state, %Task{task_type: "SUB_WORKFLOW"} = task) do
    child =
      case Env.child(env, task, Task.sub_workflow_id(task)) do
        {:ok, child} -> child
        :error -> nil
      end

    {state, task |> SubWorkflowTask.execute(child) |> elem(1)}
  end

  defp execute(%State{wf: wf, env: env} = state, task) do
    result = SystemTask.execute(wf, task, Env.context(env))
    {Schedule.apply_result(state, result), result.task}
  end

  @doc """
  What follows an evaluation: an `isAsyncComplete` task no longer `SCHEDULED` and a terminal
  task (with its `endTime`) ask for a decide; any other keeps its evaluation offset.
  """
  @spec dispose(State.t(), Task.t(), boolean()) :: {State.t(), boolean()}
  def dispose(%State{now: now} = state, %Task{} = task, async_complete?) do
    cond do
      async_complete? and task.status != :scheduled ->
        {State.save_task(state, task), true}

      Task.terminal?(task.status) ->
        {State.save_task(state, %{task | end_time: now}), true}

      true ->
        # Upstream postpones the message by the offset; a retry's callbackAfterMs only delayed
        # the first enqueue, so it no longer counts.
        offset = evaluation_offset(state, task)
        task = %{task | callback_after_seconds: offset, callback_after_ms: 0}
        {State.save_task(state, task), false}
    end
  end

  # getEvaluationOffset, or systemTaskWorkerCallbackDuration when the task type has none.
  defp evaluation_offset(%State{env: env}, %Task{task_type: "JOIN"} = task) do
    threshold = env.system_task_postpone_threshold

    cond do
      match?(%WorkflowTask{join_mode: :sync}, task.workflow_task) ->
        0

      task.poll_count <= threshold ->
        0

      # 1.2^64 is past any offset cap; the exponent is bounded so the float cannot overflow.
      true ->
        min(
          trunc(:math.pow(1.2, min(task.poll_count - threshold, 64))),
          env.system_task_callback_seconds
        )
    end
  end

  defp evaluation_offset(%State{now: now}, %Task{task_type: "WAIT", wait_timeout: timeout})
       when timeout > 0 do
    case Integer.floor_div(timeout - now, 1000) do
      0 -> 1
      seconds -> seconds
    end
  end

  defp evaluation_offset(%State{env: env}, _task), do: env.system_task_callback_seconds

  defp exceeded_response_timeout?(task, now) do
    task.start_time > 0 and task.update_time > 0 and
      now - task.update_time >= response_timeout(task) * 1000
  end

  defp response_timeout(%Task{response_timeout_seconds: seconds}) when seconds > 0, do: seconds
  defp response_timeout(%Task{}), do: @one_hour
end
