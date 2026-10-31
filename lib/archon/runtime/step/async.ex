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
# event calls for it instead of polling a system task queue (ADR 0018, decision 6).

defmodule Archon.Runtime.Step.Async do
  @moduledoc """
  Upstream `AsyncSystemTaskExecutor#execute` for the asynchronous system tasks (`JOIN`, `WAIT`,
  `SUB_WORKFLOW`), run by the workflow's own process (ADR 0018, decision 6).

  `pass/2` evaluates the tasks an event calls for: the ones marked due (just scheduled without a
  delay), the `JOIN`s waiting on a task a save made terminal, and on `:wake` every pending one
  whose delay is over. Each evaluation counts in `pollCount`. A task that finishes (or an
  `isAsyncComplete` task that is no longer `SCHEDULED`) asks for a decide; one that goes on keeps
  its evaluation offset in `callbackAfterSeconds`.
  """

  alias Archon.Decider.{SystemTask, SystemTasks}
  alias Archon.Decider.SystemTask.Join
  alias Archon.Decider.SystemTask.SubWorkflow, as: SubWorkflowTask
  alias Archon.Domain.{Task, Workflow, WorkflowTask}
  alias Archon.Runtime.Step.{Schedule, State, SubWorkflow, Tasks}

  # TaskDef.ONE_HOUR
  @one_hour 3600

  @doc """
  Evaluates the asynchronous system tasks the step calls for. `:wake` adds every pending one
  that is due. Returns whether one asks for a decide.
  """
  @spec pass(State.t(), :events | :wake) :: {State.t(), boolean()}
  def pass(%State{wf: wf} = state, mode) do
    ids =
      for task <- wf.tasks,
          Schedule.async?(task),
          not Task.terminal?(task.status),
          MapSet.member?(state.due, task.task_id) or triggered?(state, task) or
            (mode == :wake and due?(state, task)),
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
    do: Map.has_key?(env.workflows, Task.sub_workflow_id(task) || "")

  defp due?(%State{now: now}, task), do: due_time(task) <= now

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

      exceeded_response_timeout?(task, now) and task.task_type != "SUB_WORKFLOW" ->
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

  defp run(state, task, async_complete?),
    do: dispose(state, execute(state, task), async_complete?)

  # A started task left IN_PROGRESS holds a slot of its definition's limit (ADR 0021, decision 5).
  defp limit_started(state, task_id) do
    case State.task(state, task_id) do
      %Task{} = task -> State.limit(state, task)
      nil -> state
    end
  end

  # WorkflowSystemTask#start: only SUB_WORKFLOW has one among the asynchronous system tasks. Its
  # result comes back as {:sub_workflow_started, ...}.
  defp start(state, %Task{task_type: "SUB_WORKFLOW"} = task, _async_complete?) do
    case SubWorkflow.start(state, task) do
      {:started, state} -> {state, false}
      {:failed, task} -> dispose(state, task, true)
    end
  end

  # Wait#start
  defp start(state, %Task{task_type: "WAIT"} = task, async_complete?),
    do: dispose(state, %{task | status: :in_progress}, async_complete?)

  defp start(state, task, async_complete?), do: dispose(state, task, async_complete?)

  defp execute(%State{wf: wf}, %Task{task_type: "JOIN"} = task),
    do: wf |> Join.execute(task) |> elem(1)

  defp execute(%State{env: env}, %Task{task_type: "SUB_WORKFLOW"} = task) do
    child = Map.get(env.workflows, Task.sub_workflow_id(task) || "")
    task |> SubWorkflowTask.execute(child) |> elem(1)
  end

  defp execute(%State{wf: wf, now: now}, task),
    do: wf |> SystemTask.execute(task, now) |> elem(1)

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
