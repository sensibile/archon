# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (startWorkflow, startWorkflowIdempotent, createWorkflowModel, decide, updateTask,
# terminateWorkflow) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: one pure function per event of a workflow's process, returning what to
# store and what to do around it instead of writing and queueing (ADR 0018, decision 2).

defmodule Archon.Runtime.Step do
  @moduledoc """
  The runtime's rules as a pure function (ADR 0018, decision 2): what one event does to a
  workflow. `Archon.Runtime.WorkflowServer` runs the result.

      {reply, workflow, pre, commit, post} = Step.run(workflow, event, env)

    * `workflow` - the stored workflow with its tasks (`nil` before `{:start, ...}`), and the
      returned one is the workflow as stored once `commit` is applied. Changes upstream makes in
      memory without saving them are not in it.
    * `event` - `t:Archon.Runtime.Step.Event.t/0`; `env` - `t:Archon.Runtime.Step.Env.t/0`.
    * `pre` - effects to run before the commit; `commit` - `t:Archon.Runtime.Commit.t/0`;
      `post` - effects to run after it (`t:Archon.Runtime.Step.Effect.t/0`). A running workflow
      that was decided ends `post` with its next `{:wake_at, ms}`.

  Replies:

    * `{:start, workflow}` - `{:ok, workflow_id}`, or `{:error, :conflict}` when it exists.
    * `{:start_idempotent, workflow}` - `{:ok, stored}` (the new or the existing workflow), or
      `{:error, message}` when the existing one belongs to another parent task.
    * `{:poll, ...}` - the task given to the worker, `nil` when skipped, or
      `{:error, :not_found}`.
    * `{:update, ...}` - the saved task (`nil` for `extendLease`), or `{:error, :not_found}`.
    * `{:terminate, reason}` - `:ok` or `{:error, :conflict}` for a `COMPLETED` workflow.
    * `:pause`, `:resume`, `{:retry, push_parents?}`, `{:restart, definition}`,
      `{:skip_task, ref}`, `:reset_callbacks`, `{:rerun, request}`, `{:rerun_parent, request}` - `:ok`
      or `{:error, {kind, message}}`
      (`Archon.Runtime.Step.Lifecycle`).
    * any other event - `:ok`.

  Decide loop, scheduling and termination follow upstream `WorkflowExecutorOps`
  (`Archon.Runtime.Step.Decide`, `Archon.Runtime.Step.Schedule`,
  `Archon.Runtime.Step.Terminate`); asynchronous system tasks are evaluated by the process itself
  (`Archon.Runtime.Step.Async`, `Archon.Runtime.Step.SubWorkflow`,
  `Archon.Runtime.Step.StartWorkflow`); the next `:wake` is
  `Archon.Runtime.Step.Postpone`; `:recover` is `Archon.Runtime.Step.Recover`; the lifecycle
  operations are `Archon.Runtime.Step.Lifecycle`.
  """

  alias Archon.Domain.{Task, TaskResult, Workflow}
  alias Archon.Runtime.Commit

  alias Archon.Runtime.Step.{
    Async,
    Decide,
    Effect,
    Env,
    Event,
    Http,
    Lifecycle,
    Postpone,
    Recover,
    StartWorkflow,
    State,
    SubWorkflow,
    Tasks,
    Terminate
  }

  @type result :: {term(), Workflow.t() | nil, [Effect.t()], Commit.t(), [Effect.t()]}

  @doc "Runs one event against the stored workflow."
  @spec run(Workflow.t() | nil, Event.t(), Env.t()) :: result()
  def run(workflow, event, %Env{} = env) do
    {reply, state} = handle(event, State.new(workflow, env))
    finish(reply, state)
  end

  # startWorkflow: create the workflow, then its first decide.
  defp handle({:start, %Workflow{}}, %State{stored: %Workflow{}} = state),
    do: {{:error, :conflict}, state}

  # The first decide runs on the workflow object whose variables are its definition's
  # (`State`'s `shared_variables?`).
  defp handle({:start, %Workflow{} = workflow}, state) do
    state =
      state
      |> State.create(new_workflow(workflow, state.now))
      |> Map.put(:shared_variables?, true)
      |> Decide.settle()

    {{:ok, workflow.workflow_id}, state}
  end

  # startWorkflowIdempotent: create the workflow, or answer with the one the start may reuse.
  defp handle({:start_idempotent, %Workflow{} = workflow}, %State{stored: nil} = state) do
    state = State.create(state, new_workflow(workflow, state.now))
    {{:ok, state.stored}, state}
  end

  defp handle({:start_idempotent, %Workflow{} = workflow}, %State{stored: stored} = state) do
    case SubWorkflow.owned_by?(stored, workflow) do
      :ok -> {{:ok, stored}, state}
      {:error, message} -> {{:error, message}, state}
    end
  end

  defp handle({:poll, task_id, worker_id}, state), do: Tasks.poll(state, task_id, worker_id)

  defp handle({:update, %TaskResult{} = result}, state) do
    case Tasks.update(state, result) do
      {:ok, task, state, :decide} ->
        {task, Decide.settle(state)}

      {:ok, task, state, :lazy} ->
        {task, evaluate_without_decide(state)}

      {:ok, task, state, :none} ->
        {task, state}

      {:error, :not_found} ->
        {{:error, :not_found}, state}
    end
  end

  defp handle(:wake, %State{wf: wf} = state) do
    if Workflow.terminal?(wf.status) do
      {:ok, state}
    else
      {state, _decide?} = Async.pass(state, :wake)
      {:ok, state |> Decide.settle() |> Recover.after_wake()}
    end
  end

  defp handle(:recover, state), do: {:ok, Recover.recover(state)}

  defp handle({:child_changed, task_id, %Workflow{} = child}, state) do
    state =
      case SubWorkflow.child_changed(state, task_id, child) do
        nil -> state
        task -> State.save_task(state, task)
      end

    {:ok, Decide.settle(state)}
  end

  defp handle({:sub_workflow_started, task_id, result}, state) do
    case Async.attempt(state, task_id, nil) do
      nil -> {:ok, state}
      task -> {:ok, started(state, SubWorkflow.started(state, task, result))}
    end
  end

  # ADR 0026, decision 7: the result of the attempt that sent the request, else dropped. Its
  # startTime tells it from an attempt with the same pollCount after a rerun reset the count.
  defp handle({:http_completed, task_id, poll_count, started_at, result}, %State{wf: wf} = state) do
    with false <- Workflow.terminal?(wf.status),
         %Task{start_time: ^started_at} = task <- Async.attempt(state, task_id, poll_count) do
      {:ok, started(state, Http.completed(state, task, result))}
    else
      _dropped -> {:ok, state}
    end
  end

  defp handle({:workflow_started, task_id, result}, state) do
    case Async.attempt(state, task_id, nil) do
      nil -> {:ok, state}
      task -> {:ok, started(state, StartWorkflow.started(state, task, result))}
    end
  end

  # A workflow retried or restarted since the start was refused keeps its new run's output
  # (the outbox may report it later, ADR 0021, decision 4).
  defp handle({:failure_workflow_started, {:error, reason}}, %State{wf: wf} = state) do
    if Workflow.terminal?(wf.status),
      do: {:ok, Terminate.failure_workflow_failed(state, reason)},
      else: {:ok, state}
  end

  defp handle({:terminate, reason}, state), do: Terminate.by_request(state, reason)

  # ADR 0021, decision 4: an outbox termination run again must not end a child that ran again
  # after reading this end of its parent.
  defp handle({:cancel_by_parent, _reason, parent_end_count}, %State{wf: wf} = state)
       when is_integer(parent_end_count) and wf.revived_parent_end_count != 0 and
              wf.revived_parent_end_count >= parent_end_count,
       do: {:ok, state}

  defp handle({:cancel_by_parent, reason, _parent_end_count}, state),
    do: {:ok, Terminate.by_parent(state, reason)}

  defp handle(:pause, state), do: Lifecycle.pause(state)
  defp handle(:resume, state), do: Lifecycle.resume(state)
  defp handle({:retry, push_parents?}, state), do: Lifecycle.retry(state, push_parents?)
  defp handle({:restart, definition}, state), do: Lifecycle.restart(state, definition)

  defp handle({:child_revived, task_id, operation, chain}, state),
    do: {:ok, Lifecycle.child_revived(state, task_id, {operation, chain})}

  # A revival an outbox entry stored before ADR 0027 asks for: no log.
  defp handle({:child_revived, task_id}, state),
    do: {:ok, Lifecycle.child_revived(state, task_id, nil)}

  defp handle({:skip_task, ref}, state), do: Lifecycle.skip_task(state, ref)
  defp handle(:reset_callbacks, state), do: Lifecycle.reset_callbacks(state)
  defp handle({:rerun, request}, state), do: Lifecycle.rerun(state, request)

  defp handle({:rerun_parent, request}, state), do: Lifecycle.rerun_parent(state, request)

  # What AsyncSystemTaskExecutor does after a start returned. A task that goes on (a transient
  # error) is evaluated again when its callback is over, as upstream postpones its message.
  defp started(state, :ignore), do: state
  defp started(_state, {:retry, state}), do: state

  defp started(state, {:done, task}) do
    case Async.finish(state, task) do
      {state, true} -> Decide.settle(state)
      {state, false} -> State.pull(state, Postpone.wake_at(state.wf, state.env))
    end
  end

  # createWorkflowModel: a running workflow created now.
  defp new_workflow(%Workflow{} = workflow, now) do
    %{
      workflow
      | status: :running,
        create_time: if(workflow.create_time == 0, do: now, else: workflow.create_time),
        tasks: []
    }
  end

  # An update whose decide is skipped (isLazyEvaluateWorkflow) still lets the JOINs waiting on
  # the task evaluate, and a JOIN that finished decides (AsyncSystemTaskExecutor).
  defp evaluate_without_decide(%State{wf: wf, env: env} = state) do
    if Workflow.terminal?(wf.status) do
      state
    else
      case Async.pass(state, :events) do
        {state, true} -> Decide.settle(state)
        {state, false} -> State.pull(state, Postpone.wake_at(state.wf, env))
      end
    end
  end

  defp finish(reply, %State{} = state) do
    end_count = if state.stored, do: state.stored.end_count, else: 0

    post =
      state.post
      |> Enum.reverse()
      |> Enum.map(fn
        {:notify_parent, parent, task, _child} -> {:notify_parent, parent, task, state.stored}
        {:terminate_sub_workflow, id, reason} -> {:terminate_sub_workflow, id, reason, end_count}
        effect -> effect
      end)
      |> Enum.filter(&still_wanted?(state, &1))

    {reply, state.stored, Enum.reverse(state.pre), State.commit(state), post ++ wake(state)}
  end

  # A child start asked for earlier in the step is dropped when the same step ended its task
  # (the parent terminated): the child termination already ran before the commit, so a start
  # after it would leave the child running (ADR 0018, decision 8). A START_WORKFLOW task ended
  # that way does not start its workflow either, as upstream's executor cancels it first.
  defp still_wanted?(state, {start, task_id, _start})
       when start in [:start_sub_workflow, :start_workflow],
       do: match?(%{status: :scheduled}, State.task(state, task_id))

  defp still_wanted?(state, {:http_request, task_id, poll_count, _request}),
    do: match?(%{status: :scheduled, poll_count: ^poll_count}, State.task(state, task_id))

  defp still_wanted?(_state, _effect), do: true

  defp wake(%State{stored: nil}), do: []
  defp wake(%State{halted?: true}), do: []

  defp wake(%State{wf: wf, env: env} = state) do
    cond do
      Workflow.terminal?(wf.status) or wf.status == :paused -> []
      state.decided? -> [{:wake_at, Postpone.wake_at(wf, env)}]
      state.pull != nil -> [{:wake_before, state.pull}]
      true -> []
    end
  end
end
