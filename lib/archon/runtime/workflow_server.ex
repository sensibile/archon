# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (startWorkflow's cleanup, decide, updateTask, terminateWorkflow),
# org/conductoross/conductor/core/execution/WorkflowSweeper.java and ExecutorUtils.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: one process per workflow is the only writer of the workflow; it runs
# Archon.Runtime.Step and its effects instead of taking a lock, and its own timer replaces the
# decider queue (ADR 0018, decisions 1, 2, 6 and 7).

defmodule Archon.Runtime.WorkflowServer do
  @moduledoc """
  The process of one workflow (ADR 0018, decision 1): the only writer of the workflow and its
  tasks in the store.

  ## Messages

  Every message is one `t:Archon.Runtime.Step.Event.t/0`. The process fills an
  `Archon.Runtime.Step.Env` for it, runs `Archon.Runtime.Step.run/3`, runs the `pre` effects,
  writes the commit to the store, runs the `post` effects and only then answers (write-through),
  so a caller reads its own change from the store. Effects are run by `Archon.Runtime.Effects`;
  a result that goes back to the step (a `SUB_WORKFLOW` start, a failed failure-workflow start)
  is run as the next event within the same message, up to the decide iteration limit.

  The `Env` is filled from the store, the queue and the metadata for each event (`env/2`):
  `task_defs` for the definition's tasks that have no embedded definition,
  `latest_workflow_versions` for `SUB_WORKFLOW` tasks without a version, `poll_data` for the
  worker task types and the domains of `taskToDomain`, `in_progress` for every task definition
  with a `concurrentExecLimit`, and for `:wake` and `:recover` also `queued` (the `SCHEDULED`
  worker tasks that have a queue message) and `workflows` (the parent, the children of
  `IN_PROGRESS` and `CANCELED` `SUB_WORKFLOW` tasks and the failure workflow). For
  `{:child_revived, task_id}`, `workflows` holds the children of the `SUB_WORKFLOW` tasks that
  ended unsuccessfully and of the task that revives.

  ## Client functions

  `start/1`, `start_idempotent/1`, `poll/3`, `update/1`, `terminate_workflow/2`,
  `cancel_by_parent/2` and the lifecycle operations (`pause/1`, `resume/1`, `retry/2`,
  `restart/2`) call the workflow's process and `child_changed/3`, `child_revived/2` cast to it, starting the process first when
  it is not running (activation, `activate/2`). A call that meets a process just ending is tried
  once more. The call timeout is `config :archon, Archon.Runtime, call_timeout:` (30 s).

  ## Lifetime

    * Activation reads the stored workflow in `init` and runs `:recover` in `handle_continue`.
      An ID the store does not have is `:ignore` (`{:error, :not_found}` to the caller), except
      for a start, whose process waits for `{:start, workflow}`.
    * `{:start, workflow}` answers after the first decide; its `SUB_WORKFLOW` starts run after the
      answer. If it fails, the created workflow and its queue messages are removed and the
      process ends. `{:start_idempotent, workflow}` answers once the workflow is created and
      decides after the answer (a `:wake`).
    * After a request, a timer or a `:recover`, the process ends normally when the workflow is
      terminal and no other message is waiting. Activated with a terminal workflow, it waits `idle_timeout` for the request
      that activated it. A running workflow's process hibernates after `hibernate_after`.

  ## Timer

  One `:wake` timer, set by `{:wake_at, ms}` and pulled earlier by `{:wake_before, ms}`
  (ADR 0018, decision 6), through the configured `timer` function, and cancelled by
  `:cancel_wake` when the workflow is paused (decision 9). Sending `:wake` or
  `:recover` to the process runs that event at once.

  ## Exception isolation

  An exception or exit in the step or an effect is caught: the process keeps the last stored
  workflow, logs, answers `{:error, reason}` and runs `:recover` after
  `workflow_offset_timeout_ms` (ADR 0018, decision 1). A `pre` effect that fails leaves nothing
  committed. A workflow that the failed step already made terminal is not tried again: the
  process ends, as a terminal workflow's process does, and what its effects left undone is the
  Phase 4 recovery's (ADR 0018, 결과).

  For tests, the `hook` configuration is called with `(point, workflow_id, data)` at `:step`
  (before the step, with the event), `:effect` (before each effect), `:commit` (before the
  commit) and `:committed` (after it).
  """

  use GenServer, restart: :transient

  require Logger

  alias Archon.Decider.SystemTasks
  alias Archon.Domain.{SubWorkflowParams, Task, TaskDef, TaskResult, Workflow, WorkflowDef}
  alias Archon.Runtime
  alias Archon.Runtime.{Commit, Effects}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.{Env, Lifecycle, Schedule, Terminate}

  @registry Archon.Runtime.Registry
  @supervisor Archon.Runtime.WorkflowSupervisor

  defstruct [:id, :workflow, :timer, :journal]

  @type t :: %__MODULE__{
          id: String.t(),
          workflow: Workflow.t() | nil,
          timer:
            %{token: reference(), ref: term(), at: integer(), message: :wake | :recover} | nil,
          journal: %{committed?: boolean(), pushed: [{String.t(), String.t()}]} | nil
        }

  ## Client

  @doc false
  def start_link({id, mode}) when is_binary(id) and mode in [:new, :existing] do
    GenServer.start_link(__MODULE__, {id, mode},
      name: {:via, Registry, {@registry, id}},
      hibernate_after: Runtime.setting(:hibernate_after, 15_000)
    )
  end

  @doc "The process of the workflow, or `nil` when it is not running."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(id) do
    # The registry drops an ended process asynchronously; registering again replaces it.
    case Registry.lookup(@registry, id) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  rescue
    # The registry is restarting with the rest of the runtime tree.
    ArgumentError -> nil
  end

  @doc """
  The workflow's process, started when it is not running. `mode` is `:existing` (a workflow the
  store has, else `{:error, :not_found}`) or `:new` (a process waiting for a start).
  """
  @spec activate(String.t(), :new | :existing) :: {:ok, pid()} | {:error, term()}
  def activate(id, mode \\ :existing) do
    case whereis(id) do
      nil ->
        start_child(id, mode)

      pid ->
        {:ok, pid}
    end
  end

  defp start_child(id, mode) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {id, mode}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      :ignore -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  catch
    # The workflow supervisor is restarting with the rest of the runtime tree.
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "`{:start, workflow}`: `{:ok, workflow_id}` once the first decide is saved."
  @spec start(Workflow.t()) :: {:ok, String.t()} | {:error, term()}
  def start(%Workflow{workflow_id: id} = workflow), do: call(id, :new, {:start, workflow})

  @doc "`{:start_idempotent, workflow}`: `{:ok, stored}`, the new or the existing workflow."
  @spec start_idempotent(Workflow.t()) :: {:ok, Workflow.t()} | {:error, term()}
  def start_idempotent(%Workflow{workflow_id: id} = workflow),
    do: call(id, :new, {:start_idempotent, workflow})

  @doc """
  `{:poll, task_id, worker_id}`: a worker took the task from its queue. Returns the task given
  to the worker, `nil` when it is skipped (gone from the queue or postponed by the concurrent
  execution limit), or `{:error, :not_found}` (the caller removes the queue message). Acking
  the message and recording the poll data are the caller's (`Archon.Runtime.Tasks`).
  """
  @spec poll(String.t(), String.t(), String.t() | nil) :: Task.t() | nil | {:error, term()}
  def poll(workflow_id, task_id, worker_id),
    do: call(workflow_id, :existing, {:poll, task_id, worker_id})

  @doc """
  `{:update, task_result}` to the workflow `workflowInstanceId`: the saved task (`nil` for
  `extendLease`) once the decide that follows is saved, or `{:error, :not_found}`.
  """
  @spec update(TaskResult.t()) :: Task.t() | nil | {:error, term()}
  def update(%TaskResult{workflow_instance_id: id} = result) when is_binary(id),
    do: call(id, :existing, {:update, result})

  @doc "`{:terminate, reason}`: `:ok`, `{:error, :conflict}` or `{:error, :not_found}`."
  @spec terminate_workflow(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def terminate_workflow(id, reason), do: call(id, :existing, {:terminate, reason})

  @doc """
  `{:cancel_by_parent, reason}` from the parent: `:ok`, or `{:error, :not_found}` when the child
  does not exist.
  """
  @spec cancel_by_parent(String.t(), String.t()) :: :ok | {:error, term()}
  def cancel_by_parent(id, reason), do: call(id, :existing, {:cancel_by_parent, reason})

  @doc "`:pause`: `:ok` or `{:error, {:conflict, message}}` (`Archon.Runtime.Step.Lifecycle`)."
  @spec pause(String.t()) :: :ok | {:error, term()}
  def pause(id), do: call(id, :existing, :pause)

  @doc "`:resume`: `:ok` or `{:error, {:invalid_state, message}}`."
  @spec resume(String.t()) :: :ok | {:error, term()}
  def resume(id), do: call(id, :existing, :resume)

  @doc """
  `{:retry, push_parents?}`: `:ok` or `{:error, {kind, message}}`. Without `push_parents?` the
  parent is not asked to revive.
  """
  @spec retry(String.t(), boolean()) :: :ok | {:error, term()}
  def retry(id, push_parents?), do: call(id, :existing, {:retry, push_parents?})

  @doc "`{:restart, definition}`: `:ok` or `{:error, {kind, message}}`."
  @spec restart(String.t(), WorkflowDef.t() | nil) :: :ok | {:error, term()}
  def restart(id, definition), do: call(id, :existing, {:restart, definition})

  @doc "Casts `{:child_revived, task_id}` to the parent."
  @spec child_revived(String.t(), String.t()) :: :ok | {:error, term()}
  def child_revived(parent_id, task_id) do
    with {:ok, pid} <- activate(parent_id) do
      GenServer.cast(pid, {:child_revived, task_id})
    end
  end

  @doc "Casts `{:child_changed, task_id, child}` to the parent."
  @spec child_changed(String.t(), String.t(), Workflow.t()) :: :ok | {:error, term()}
  def child_changed(parent_id, task_id, %Workflow{} = child) do
    with {:ok, pid} <- activate(parent_id) do
      GenServer.cast(pid, {:child_changed, task_id, child})
    end
  end

  defp call(id, mode, request, retry? \\ true) do
    with {:ok, pid} <- activate(id, mode) do
      try do
        GenServer.call(pid, request, Runtime.setting(:call_timeout, 30_000))
      catch
        # A process that ends :normal has answered every call it took; one that is shut down
        # may have stopped after its commit, so that call is not sent again.
        :exit, {reason, _call} when retry? and reason in [:noproc, :normal] ->
          call(id, mode, request, false)

        :exit, {reason, _call} ->
          {:error, reason}
      end
    end
  end

  ## Server

  @impl GenServer
  def init({id, mode}) do
    case Runtime.store().get_workflow(id, true) do
      {:ok, workflow} ->
        {:ok, %__MODULE__{id: id, workflow: workflow}, {:continue, :recover}}

      {:error, :not_found} when mode == :new ->
        {:ok, %__MODULE__{id: id}, idle_timeout()}

      {:error, :not_found} ->
        :ignore
    end
  end

  @impl GenServer
  def handle_continue(:recover, state) do
    terminal? = terminal?(state.workflow)
    {_reply, state} = handle_event(:recover, state)
    if terminal?, do: idle(state), else: settle(state)
  end

  def handle_continue({:effects, effects}, state) do
    state =
      case run_effects(state, effects, budget()) do
        {:ok, state, _deferred, _budget} -> state
        {:error, reason, state} -> isolate(state, reason)
      end

    settle(state)
  end

  def handle_continue(:wake, state) do
    {_reply, state} = handle_event(:wake, state)
    settle(state)
  end

  @impl GenServer
  def handle_call({:start, %Workflow{}} = event, _from, %__MODULE__{} = state) do
    state = %{state | journal: %{committed?: false, pushed: []}}

    case cycle(state, event, true, budget()) do
      {:ok, reply, state, [], _budget} ->
        reply_and_settle(reply, %{state | journal: nil})

      {:ok, reply, state, deferred, _budget} ->
        {:reply, reply, %{state | journal: nil}, {:continue, {:effects, deferred}}}

      {:error, reason, %__MODULE__{journal: %{committed?: true}} = state} ->
        Logger.error("workflow #{state.id} failed to start: #{inspect(reason)}")
        remove_started(state)
        {:stop, :normal, {:error, reply_reason(reason)}, %{state | workflow: nil}}

      {:error, reason, state} ->
        Logger.error("workflow #{state.id} failed to start: #{inspect(reason)}")

        state = %{state | journal: nil}

        if state.workflow,
          do: idle(state, {:error, reply_reason(reason)}),
          else: stop(state, reply_reason(reason))
    end
  end

  def handle_call({:start_idempotent, %Workflow{}} = event, _from, state) do
    created? = state.workflow == nil

    case cycle(state, event, false, budget()) do
      {:ok, {:ok, _stored} = reply, state, _deferred, _budget} when created? ->
        {:reply, reply, state, {:continue, :wake}}

      {:ok, reply, state, _deferred, _budget} ->
        reply_and_settle(reply, state)

      {:error, reason, %__MODULE__{workflow: nil} = state} ->
        stop(state, reply_reason(reason))

      {:error, reason, state} ->
        reply_and_settle({:error, reply_reason(reason)}, isolate(state, reason))
    end
  end

  def handle_call(_event, _from, %__MODULE__{workflow: nil} = state),
    do: {:reply, {:error, :not_found}, state, idle_timeout()}

  def handle_call(event, _from, state) do
    {reply, state} = handle_event(event, state)
    reply_and_settle(reply, state)
  end

  @impl GenServer
  def handle_cast(_event, %__MODULE__{workflow: nil} = state),
    do: {:noreply, state, idle_timeout()}

  def handle_cast({:child_changed, _task_id, %Workflow{}} = event, state) do
    {_reply, state} = handle_event(event, state)
    settle(state)
  end

  def handle_cast({:child_revived, _task_id} = event, state) do
    {_reply, state} = handle_event(event, state)
    settle(state)
  end

  @impl GenServer
  def handle_info({:timer, token}, %__MODULE__{timer: %{token: token, message: message}} = state) do
    state = %{state | timer: nil}
    handle_info(message, state)
  end

  def handle_info({:timer, _stale}, state), do: noreply(state)

  def handle_info(event, %__MODULE__{workflow: %Workflow{}} = state)
      when event in [:wake, :recover] do
    {_reply, state} = handle_event(event, state)
    settle(state)
  end

  def handle_info(:timeout, state) do
    if state.workflow == nil or terminal?(state.workflow),
      do: {:stop, :normal, state},
      else: {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.warning("workflow #{state.id} ignored #{inspect(message)}")
    noreply(state)
  end

  ## Running events

  # One event with exception isolation.
  defp handle_event(event, state) do
    case cycle(state, event, false, budget()) do
      {:ok, reply, state, _deferred, _budget} -> {reply, state}
      {:error, reason, state} -> {{:error, reply_reason(reason)}, isolate(state, reason)}
    end
  end

  # The reason given to the caller: the exception without its stack, which is logged.
  defp reply_reason({tag, reason}) when tag in [:pre_effect, :post_effect, :commit],
    do: {tag, reply_reason(reason)}

  defp reply_reason({%{__exception__: true} = exception, stack}) when is_list(stack),
    do: exception

  defp reply_reason(reason), do: reason

  # Step, pre effects, commit, post effects, then the events the effects fed back.
  # `defer?` keeps SUB_WORKFLOW starts for after the answer (a top-level start). `budget` is
  # the step runs this message may still make, shared by every fed-back event; the rest is
  # returned.

  defp cycle(%__MODULE__{} = state, event, defer?, budget) do
    with {:ok, env} <- guard(fn -> env(state.workflow, event) end),
         {:ok, {reply, stored, pre, commit, post}} <-
           guard(fn ->
             hook(state, :step, event)
             Step.run(state.workflow, event, env)
           end),
         :ok <- run_pre(state, pre),
         {:ok, state} <- commit(state, commit, stored),
         {:ok, state, deferred, budget} <- run_post(state, post, defer?, budget - 1) do
      {:ok, reply, state, deferred, budget}
    else
      {:error, reason} -> {:error, reason, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp run_pre(state, effects) do
    Enum.reduce_while(effects, :ok, fn effect, :ok ->
      case run_effect(state, effect) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:pre_effect, reason}}}
        {:event, event} -> {:halt, {:error, {:pre_effect, {:unexpected_event, event}}}}
      end
    end)
  end

  defp commit(state, %Commit{} = commit, stored) do
    if empty?(commit) do
      {:ok, %{state | workflow: stored}}
    else
      result =
        guard(fn ->
          hook(state, :commit, commit)
          Runtime.store().commit(state.id, commit)
        end)

      case result do
        {:ok, :ok} ->
          state = %{state | workflow: stored, journal: journal_commit(state.journal)}
          hook(state, :committed, stored)
          {:ok, state}

        {:ok, {:error, reason}} ->
          {:error, {:commit, reason}}

        {:error, reason} ->
          {:error, {:commit, reason}}
      end
    end
  end

  defp empty?(%Commit{create: nil, workflow: nil, upsert_tasks: [], delete_task_ids: []}),
    do: true

  defp empty?(%Commit{}), do: false

  # Runs post effects; fed-back events run once all effects of this step ran.
  defp run_post(state, effects, defer?, budget) do
    result =
      Enum.reduce_while(effects, {:ok, state, [], []}, &post_step(&1, &2, defer?))

    with {:ok, state, events, deferred} <- result,
         {:ok, state, budget} <- feed_back(state, Enum.reverse(events), budget) do
      {:ok, state, Enum.reverse(deferred), budget}
    end
  end

  defp post_step({:start_sub_workflow, _task_id, _start} = effect, acc, true) do
    {:ok, state, events, deferred} = acc
    {:cont, {:ok, state, events, [effect | deferred]}}
  end

  defp post_step(effect, {:ok, state, events, deferred}, _defer?) do
    case post_effect(state, effect) do
      {:ok, state} -> {:cont, {:ok, state, events, deferred}}
      {:event, event, state} -> {:cont, {:ok, state, [event | events], deferred}}
      {:error, reason, state} -> {:halt, {:error, {:post_effect, reason}, state}}
    end
  end

  defp run_effects(state, effects, budget), do: run_post(state, effects, false, budget)

  defp feed_back(state, [], budget), do: {:ok, state, budget}

  defp feed_back(state, events, budget) when budget <= 0 do
    Logger.warning(
      "workflow #{state.id} reached the decide iteration limit; #{length(events)} results " <>
        "are left to the recovery check"
    )

    {:ok, set_timer(state, :wake, Runtime.now()), budget}
  end

  defp feed_back(state, [event | events], budget) do
    case cycle(state, event, false, budget) do
      {:ok, _reply, state, _deferred, budget} -> feed_back(state, events, budget)
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp post_effect(state, {:wake_at, at} = effect),
    do: timer_effect(state, effect, &set_timer(&1, :wake, at))

  defp post_effect(state, {:wake_before, at} = effect) do
    timer_effect(state, effect, fn
      %__MODULE__{timer: %{at: current}} = state when current <= at -> state
      state -> set_timer(state, :wake, at)
    end)
  end

  # A paused workflow is not woken (ADR 0018, decision 9); a :recover after an isolated
  # exception still runs.
  defp post_effect(state, :cancel_wake = effect) do
    timer_effect(state, effect, fn
      %__MODULE__{timer: %{message: :wake} = timer} = state ->
        cancel_timer(timer)
        %{state | timer: nil}

      state ->
        state
    end)
  end

  defp post_effect(state, effect) do
    case run_effect(state, effect) do
      :ok ->
        {:ok, journal_push(state, effect)}

      {:event, event} ->
        {:event, event, state}

      # upstream scheduleTask logs a failed addTaskToQueue and goes on; the recovery check
      # pushes the task again (ADR 0018, decisions 1 and 2).
      {:error, reason} when elem(effect, 0) == :queue_push ->
        Logger.warning(
          "workflow #{state.id} could not queue #{inspect(effect)}: #{inspect(reason)}"
        )

        {:ok, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp timer_effect(state, effect, fun) do
    case guard(fn -> hook(state, :effect, effect) end) do
      {:ok, _result} -> {:ok, fun.(state)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp run_effect(state, effect) do
    case guard(fn ->
           hook(state, :effect, effect)
           Effects.run(effect)
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:event, event}} -> {:event, event}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # The queue messages a start pushed, removed again if the start fails.
  defp journal_push(%__MODULE__{journal: %{} = journal} = state, {:queue_push, queue, id, _, _}),
    do: %{state | journal: %{journal | pushed: [{queue, id} | journal.pushed]}}

  defp journal_push(state, _effect), do: state

  defp journal_commit(nil), do: nil
  defp journal_commit(journal), do: %{journal | committed?: true}

  # startWorkflow's cleanup (ExecutionDAOFacade#removeWorkflow): the workflow and its tasks,
  # then the queue messages this process pushed.
  defp remove_started(state) do
    removals =
      [{:workflow, fn -> Runtime.store().remove_workflow(state.id) end}] ++
        for {queue, id} <- state.journal.pushed,
            do: {{:queue, queue, id}, fn -> Runtime.queue().remove(queue, id) end}

    for {what, fun} <- removals do
      case guard(fun) do
        {:ok, :ok} ->
          :ok

        failed ->
          Logger.error("could not remove #{inspect(what)} of #{state.id}: #{inspect(failed)}")
      end
    end

    :ok
  end

  defp guard(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, {exception, __STACKTRACE__}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end

  # Keeps the last stored workflow and tries again with :recover (ADR 0018, decision 1).
  defp isolate(state, reason) do
    Logger.error("workflow #{state.id} step failed: #{inspect(reason)}")

    state =
      case guard(fn -> Runtime.store().get_workflow(state.id, true) end) do
        {:ok, {:ok, workflow}} -> %{state | workflow: workflow}
        _unread -> state
      end

    set_timer(state, :recover, Runtime.now() + offset_timeout())
  end

  ## Timer

  defp set_timer(state, message, at) do
    cancel_timer(state.timer)
    token = make_ref()
    delay = max(at - Runtime.now(), 0)

    ref =
      Runtime.invoke(Runtime.setting(:timer, &Process.send_after/3), [
        self(),
        {:timer, token},
        delay
      ])

    %{state | timer: %{token: token, ref: ref, at: at, message: message}}
  end

  defp cancel_timer(%{ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timer(_timer), do: :ok

  ## Lifetime

  defp terminal?(nil), do: false
  defp terminal?(%Workflow{status: status}), do: Workflow.terminal?(status)

  # A process whose workflow ended stops once its mailbox is empty (a zero timeout fires only
  # then), so a message already waiting, such as a child asking it to revive, is still handled.
  defp reply_and_settle(reply, state) do
    if state.workflow == nil or terminal?(state.workflow),
      do: {:reply, reply, state, 0},
      else: {:reply, reply, state}
  end

  defp settle(state) do
    if state.workflow == nil or terminal?(state.workflow),
      do: {:noreply, state, 0},
      else: noreply(state)
  end

  defp idle(state), do: {:noreply, state, idle_timeout()}
  defp idle(state, reply), do: {:reply, reply, state, idle_timeout()}

  defp stop(state, reason), do: {:stop, :normal, {:error, reason}, state}

  defp noreply(state) do
    if state.workflow == nil or terminal?(state.workflow),
      do: {:noreply, state, idle_timeout()},
      else: {:noreply, state}
  end

  defp idle_timeout, do: Runtime.setting(:idle_timeout, 5_000)
  defp budget, do: Keyword.get(settings(), :max_decide_iterations, 100)
  defp offset_timeout, do: Keyword.get(settings(), :workflow_offset_timeout_ms, 30_000)
  defp settings, do: Runtime.setting(:settings, [])

  defp hook(state, point, data) do
    case Runtime.setting(:hook, nil) do
      nil -> :ok
      fun -> Runtime.invoke(fun, [point, state.id, data])
    end
  end

  ## Env

  @doc false
  # The outside values one event reads (ADR 0018, decision 2).
  @spec env(Workflow.t() | nil, Step.Event.t()) :: Env.t()
  def env(workflow, event) do
    env =
      Env.new([now: Runtime.now(), new_id: &Runtime.new_id/0] ++ Runtime.setting(:settings, []))

    case subject(workflow, event) do
      nil -> env
      subject -> fill(env, subject, event)
    end
  end

  defp subject(_workflow, {start, %Workflow{} = workflow})
       when start in [:start, :start_idempotent],
       do: workflow

  defp subject(workflow, _event), do: workflow

  defp fill(env, %Workflow{} = wf, event) do
    workflow_tasks = workflow_tasks(wf.workflow_definition)
    task_defs = task_defs(workflow_tasks, wf.tasks)

    env = %{
      env
      | task_defs: task_defs,
        latest_workflow_versions: latest_versions(workflow_tasks)
    }

    env = %{
      env
      | poll_data: poll_data(env, wf, workflow_tasks),
        in_progress: in_progress(workflow_tasks, task_defs, wf.tasks)
    }

    case event do
      event when event in [:wake, :recover] ->
        %{env | queued: queued(env, wf), workflows: workflows(wf)}

      {:child_revived, task_id} ->
        %{env | workflows: failed_children(wf, task_id)}

      _other ->
        env
    end
  end

  defp workflow_tasks(%WorkflowDef{} = definition), do: WorkflowDef.collect_tasks(definition)
  defp workflow_tasks(nil), do: []

  # The names whose definition the Decider looks up: tasks with none embedded.
  defp task_defs(workflow_tasks, tasks) do
    names =
      Enum.flat_map(workflow_tasks, fn wt ->
        if wt.task_definition == nil and is_binary(wt.name), do: [wt.name], else: []
      end) ++
        for(task <- tasks, Task.task_definition(task) == nil, do: Task.task_def_name(task))

    names
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      case Runtime.metadata().get_task_def(name) do
        {:ok, task_def} -> [{name, task_def}]
        {:error, :not_found} -> []
      end
    end)
    |> Map.new()
  end

  defp latest_versions(workflow_tasks) do
    for %{type: "SUB_WORKFLOW", sub_workflow_param: %SubWorkflowParams{} = params} <-
          workflow_tasks,
        SubWorkflowParams.version(params) == nil,
        name = SubWorkflowParams.name(params),
        is_binary(name),
        {:ok, %WorkflowDef{version: version}} <- [
          Runtime.metadata().get_latest_workflow_def(name)
        ],
        into: %{},
        do: {name, version}
  end

  # getActiveDomain reads the last poll of each worker task type in each mapped domain.
  defp poll_data(_env, %Workflow{task_to_domain: mapping}, _workflow_tasks)
       when mapping in [nil, %{}],
       do: %{}

  defp poll_data(env, %Workflow{task_to_domain: mapping} = wf, workflow_tasks) do
    domains =
      mapping
      |> Map.values()
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.upcase(&1) == "NO_DOMAIN"))
      |> Enum.uniq()

    types =
      (Enum.map(workflow_tasks, &if(&1.type == "SIMPLE", do: &1.name, else: &1.type)) ++
         Enum.map(wf.tasks, & &1.task_type))
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&SystemTasks.system_task?(env.system_tasks, &1))
      |> Enum.uniq()

    for type <- types,
        domain <- domains,
        {:ok, %{last_poll_time: time}} <- [Runtime.store().get_poll_data(type, domain)],
        into: %{},
        do: {{type, domain}, time}
  end

  # The IN_PROGRESS counts of the tasks whose definition has a concurrentExecLimit, keyed as
  # the step and the store count them (`Task.task_def_name/1`).
  defp in_progress(workflow_tasks, task_defs, tasks) do
    names =
      Enum.flat_map(workflow_tasks, &if(limited?(&1.task_definition), do: [&1.name], else: [])) ++
        Enum.flat_map(task_defs, fn {name, task_def} ->
          if limited?(task_def), do: [name], else: []
        end) ++
        for(task <- tasks, limited?(Task.task_definition(task)), do: Task.task_def_name(task))

    names
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(&{&1, Runtime.store().in_progress_count(&1)})
  end

  defp limited?(%TaskDef{concurrent_exec_limit: limit}), do: is_integer(limit) and limit > 0
  defp limited?(_none), do: false

  defp queued(env, %Workflow{tasks: tasks}) do
    for task <- tasks,
        task.status == :scheduled,
        not Schedule.system_task?(env, task),
        Runtime.queue().contains?(Schedule.queue_name(task), task.task_id),
        into: MapSet.new(),
        do: task.task_id
  end

  # The other workflows the recovery check and the SUB_WORKFLOW evaluation read.
  defp workflows(%Workflow{} = wf) do
    children =
      Enum.flat_map(wf.tasks, fn
        %Task{task_type: "SUB_WORKFLOW", status: :in_progress} = task ->
          List.wrap(Task.sub_workflow_id(task))

        %Task{task_type: "SUB_WORKFLOW", status: :canceled} = task ->
          {:terminate_sub_workflow, id, _reason} = Terminate.cancel_child(wf, task)
          [id]

        _other ->
          []
      end)

    failure =
      case Map.get(wf.output, "conductor.failure_workflow") do
        id when is_binary(id) -> if String.starts_with?(id, "Error workflow "), do: [], else: [id]
        _none -> []
      end

    read_workflows([wf.parent_workflow_id | children] ++ failure)
  end

  # The children of the SUB_WORKFLOW tasks that ended unsuccessfully, which a reviving workflow
  # follows or retries (updateAndPushParents), and the child of the task that revives.
  defp failed_children(%Workflow{tasks: tasks}, task_id) do
    tasks
    |> Enum.filter(
      &(&1.task_type == "SUB_WORKFLOW" and
          (&1.task_id == task_id or Lifecycle.unsuccessful_terminal_task?(&1)))
    )
    |> Enum.map(&Task.sub_workflow_id/1)
    |> read_workflows()
  end

  defp read_workflows(ids) do
    ids
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Map.new(fn id ->
      case Runtime.store().get_workflow(id, true) do
        {:ok, other} -> {id, other}
        {:error, :not_found} -> {id, nil}
      end
    end)
  end
end
