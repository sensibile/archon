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

  The queue effects of `post` are not run: they go into the commit's `queue`, their delays added
  to the event's `Env.now`, so the store writes them with the workflow (ADR 0021, decision 3).
  The effects of `post` on other workflows (a child termination, a notice or a revival request to
  the parent, a child retry, the failure workflow start) go into the commit's `outbox`, which
  the workflow's outbox runner runs (`Archon.Runtime.Outbox`, ADR 0021, decision 4). A
  commit the store refuses with `{:error, {:limit, name}}` (the step's `Commit.limits`, ADR 0021,
  decision 5) runs the same event again with `in_progress[name]` at the limit, which counts
  toward the decide iteration limit.

  The `Env` is filled from the store, the queue and the metadata for each event (`env/2`):
  `task_defs` for the definition's tasks that have no embedded definition,
  `latest_workflow_versions` for `SUB_WORKFLOW` tasks without a version, `poll_data` for the
  worker task types and the domains of `taskToDomain`, `in_progress` for every task definition
  with a `concurrentExecLimit`, and for `:wake` and `:recover` also `queued` (the `SCHEDULED`
  worker tasks that have a queue message) and `workflows` (the parent, the children of
  `IN_PROGRESS` and `CANCELED` `SUB_WORKFLOW` tasks and the failure workflow), and for `:recover`
  `outbox_pending?`. For `{:child_revived, task_id}`, `workflows` holds the parent and the
  children of the `SUB_WORKFLOW` tasks that ended unsuccessfully and of the task that revives;
  for `{:retry, _}` and `{:restart, _}` the parent (its `endCount`, ADR 0021, L2).

  ## Client functions

  `start/1`, `start_idempotent/1`, `poll/3`, `update/1`, `terminate_workflow/2`,
  `cancel_by_parent/3`, the lifecycle operations (`pause/1`, `resume/1`, `retry/2`,
  `restart/2`) and the outbox notices `child_changed/3`, `child_revived/2` call the workflow's
  process, starting it first when it is not running (activation, `activate/2`). A call that
  meets a process just ending is tried once more. The call timeout is
  `config :archon, Archon.Runtime, call_timeout:` (30 s).

  ## Lifetime

    * Activation reads the stored workflow in `init` and runs `:recover` in `handle_continue`.
      An ID the store does not have is `:ignore` (`{:error, :not_found}` to the caller), except
      for a start, whose process waits for `{:start, workflow}`.
    * `{:start, workflow}` answers after the first decide; its `SUB_WORKFLOW` starts run after the
      answer. If it fails, the created workflow and its queue messages are removed and the
      process ends. `{:start_idempotent, workflow}` answers once the workflow is created and
      decides after the answer (a `:wake`).
    * After a request, a timer or a `:recover`, the process ends normally when the workflow is
      terminal, its outbox runner is done and no other message is waiting. Activated with a
      terminal workflow, it waits `idle_timeout` for the request that activated it. A running
      workflow's process hibernates after `hibernate_after`.

  ## Outbox

  The process keeps one outbox runner (`Archon.Runtime.Outbox`, ADR 0021, decision 4): started
  after a commit that added entries and after activation when entries are left. When it is done
  the process starts it again if entries were added meanwhile; when it stopped on a failure, it
  starts it again after a delay that begins at `outbox_retry_ms` (1 s) and doubles up to
  `workflow_offset_timeout_ms` (30 s). When the runner of an earlier process still runs, the
  process waits for it to end (the same answer again waits the delay). A failure workflow that
  could not start comes back as `{:failure_workflow_started, {:error, message}}`, whose commit
  deletes the entry (`Commit.outbox_ack`).

  ## Timer

  One `:wake` timer, set by `{:wake_at, ms}` and pulled earlier by `{:wake_before, ms}`
  (ADR 0018, decision 6), through the configured `timer` function, and cancelled by
  `:cancel_wake` when the workflow is paused (decision 9). Sending `:wake` or
  `:recover` to the process runs that event at once.

  ## Exception isolation

  An exception or exit in the step or an effect is caught: the process keeps the last stored
  workflow, logs, answers `{:error, reason}` and runs `:recover` after
  `workflow_offset_timeout_ms` (ADR 0018, decision 1). The reason is tagged with where it
  happened: `{:env, _}` (reading the env), `{:pre_effect, _}`, `{:commit, _}` (also a queue
  operation that failed with the commit) or `{:post_effect, _}`; an exception in the step itself
  is untagged. A `pre` effect that fails leaves nothing committed. A workflow that the failed
  step already made terminal is not tried again: the process ends, as a terminal workflow's
  process does, and what its effects left undone is the Phase 4 recovery's (ADR 0018, 결과).

  For tests, the `hook` configuration is called with `(point, workflow_id, data)` at `:env`
  (before the env is read, with the event), `:step` (before the step, with the event), `:effect`
  (before each effect), `:commit` (before the commit) and `:committed` (after it), and by the
  outbox runner at `:outbox` and `:outbox_ack`.
  """

  use GenServer, restart: :transient

  require Logger

  alias Archon.Decider.SystemTasks
  alias Archon.Domain.{SubWorkflowParams, Task, TaskDef, TaskResult, Workflow, WorkflowDef}
  alias Archon.Runtime
  alias Archon.Runtime.{Commit, Effects, Outbox}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.{Env, Lifecycle, Schedule, Terminate}

  @registry Archon.Runtime.Registry
  @supervisor Archon.Runtime.WorkflowSupervisor

  defstruct [
    :id,
    :workflow,
    :timer,
    :journal,
    :runner,
    :blocker,
    :outbox_delay,
    kick?: false,
    ack: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          workflow: Workflow.t() | nil,
          timer:
            %{token: reference(), ref: term(), at: integer(), message: :wake | :recover} | nil,
          journal: %{committed?: boolean(), pushed: [{String.t(), String.t()}]} | nil,
          runner:
            {:running, Elixir.Task.t()}
            | {:blocked, reference(), pid()}
            | {:delayed, reference()}
            | nil,
          blocker: pid() | nil,
          outbox_delay: pos_integer() | nil,
          kick?: boolean(),
          ack: [Archon.Runtime.Store.outbox_id()]
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
  `{:cancel_by_parent, reason, parent_end_count}` from the parent: `:ok`, or
  `{:error, :not_found}` when the child does not exist. `parent_end_count` is the parent's
  `endCount` for a termination from its outbox, `nil` for one before its commit.
  """
  @spec cancel_by_parent(String.t(), String.t(), non_neg_integer() | nil) ::
          :ok | {:error, term()}
  def cancel_by_parent(id, reason, parent_end_count \\ nil),
    do: call(id, :existing, {:cancel_by_parent, reason, parent_end_count})

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

  @doc """
  `{:child_revived, task_id}` to the parent, from the child's outbox runner: `:ok` once the
  parent saved it, or `{:error, reason}`.
  """
  @spec child_revived(String.t(), String.t()) :: :ok | {:error, term()}
  def child_revived(parent_id, task_id),
    do: call(parent_id, :existing, {:child_revived, task_id})

  @doc """
  `{:child_changed, task_id, child}` to the parent, from the child's outbox runner: `:ok` once
  the parent saved it, or `{:error, reason}`.
  """
  @spec child_changed(String.t(), String.t(), Workflow.t()) :: :ok | {:error, term()}
  def child_changed(parent_id, task_id, %Workflow{} = child),
    do: call(parent_id, :existing, {:child_changed, task_id, child})

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
    state = check_outbox(state)
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

  # The outbox runner (ADR 0021, decision 4).
  def handle_info({ref, result}, %__MODULE__{runner: {:running, %Elixir.Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    %{state | runner: nil} |> outbox_result(result) |> settle()
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %__MODULE__{runner: {:running, %Elixir.Task{ref: ref}}} = state
      ) do
    Logger.error("the outbox runner of workflow #{state.id} failed: #{inspect(reason)}")
    %{state | runner: nil} |> delay_outbox() |> settle()
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %__MODULE__{runner: {:blocked, ref, _}} = state
      ),
      do: settle(%{state | runner: nil, kick?: true})

  def handle_info({:outbox_retry, token}, %__MODULE__{runner: {:delayed, token}} = state),
    do: settle(%{state | runner: nil, kick?: true})

  def handle_info(:timeout, state) do
    if ending?(state),
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
  defp reply_reason({tag, reason}) when tag in [:env, :pre_effect, :post_effect, :commit],
    do: {tag, reply_reason(reason)}

  defp reply_reason({%{__exception__: true} = exception, stack}) when is_list(stack),
    do: exception

  defp reply_reason(reason), do: reason

  # Step, pre effects, commit, post effects, then the events the effects fed back.
  # `defer?` keeps SUB_WORKFLOW starts for after the answer (a top-level start). `budget` is
  # the step runs this message may still make, shared by every fed-back event; the rest is
  # returned.

  defp cycle(%__MODULE__{} = state, event, defer?, budget) do
    # A store that fails while the env is read is down, not wrong: {:env, _} is transient for a
    # child start (ADR 0021, L5).
    case guard(fn ->
           hook(state, :env, event)
           env(state.workflow, event)
         end) do
      {:ok, env} -> attempt(state, event, env, defer?, budget)
      {:error, reason} -> {:error, {:env, reason}, state}
    end
  end

  defp attempt(state, event, env, defer?, budget) do
    case guard(fn ->
           hook(state, :step, event)
           Step.run(state.workflow, event, env)
         end) do
      {:ok, {reply, stored, pre, commit, post}} ->
        {commit, post} = take_queue(commit, post, env.now)
        {commit, post} = take_outbox(commit, post)
        commit = %{commit | outbox_ack: commit.outbox_ack ++ state.ack}

        case commit_step(state, pre, commit, stored) do
          {:ok, state} ->
            post_step_result(reply, run_post(state, post, defer?, budget - 1))

          # ADR 0021, decision 5: another workflow took the last slot since the env was read;
          # the same event runs again seeing the limit reached. Only this attempt's own commit
          # counts, not a fed-back event's. The pre effects run again, so they must stay
          # idempotent (a child termination is).
          {:error, {:commit, {:limit, name}}}
          when budget > 1 and is_map_key(commit.limits, name) ->
            in_progress = Map.put(env.in_progress, name, Map.fetch!(commit.limits, name))
            attempt(state, event, %{env | in_progress: in_progress}, defer?, budget - 1)

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp commit_step(state, pre, commit, stored) do
    with :ok <- run_pre(state, pre), do: commit(state, commit, stored)
  end

  defp post_step_result(reply, {:ok, state, deferred, budget}),
    do: {:ok, reply, state, deferred, budget}

  defp post_step_result(_reply, {:error, reason, state}), do: {:error, reason, state}

  # ADR 0021, decision 3: the queue effects are written with the commit, their delays turned
  # into delivery times from the event's clock.
  defp take_queue(%Commit{} = commit, post, now) do
    {ops, post} = Enum.split_with(post, &queue_effect?/1)

    ops =
      Enum.map(ops, fn
        {:queue_push, queue, id, priority, delay} ->
          {:push, queue, id, priority, now + delay}

        {:queue_remove, queue, id} ->
          {:remove, queue, id}

        {:queue_postpone, queue, id, priority, delay} ->
          {:postpone, queue, id, priority, now + delay}
      end)

    {%{commit | queue: commit.queue ++ ops}, post}
  end

  defp queue_effect?(effect),
    do: is_tuple(effect) and elem(effect, 0) in [:queue_push, :queue_remove, :queue_postpone]

  # ADR 0021, decision 4: the work on other workflows is saved with the commit and run by the
  # outbox runner. A notice names its child (this workflow), which the runner reads when it runs.
  defp take_outbox(%Commit{} = commit, post) do
    {entries, post} = Enum.split_with(post, &outbox_effect?/1)

    entries =
      Enum.map(entries, fn
        {:notify_parent, parent, task, _child} -> {:notify_parent, parent, task, nil}
        effect -> effect
      end)

    {%{commit | outbox: commit.outbox ++ entries}, post}
  end

  defp outbox_effect?(effect) do
    is_tuple(effect) and
      elem(effect, 0) in [
        :terminate_sub_workflow,
        :notify_parent,
        :revive_parent,
        :retry_sub_workflow,
        :start_failure_workflow
      ]
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
          state = %{
            state
            | workflow: stored,
              journal: journal_commit(state.journal, commit),
              ack: [],
              kick?: state.kick? or commit.outbox != []
          }

          hook(state, :committed, stored)
          {:ok, state}

        {:ok, {:error, reason}} ->
          {:error, {:commit, reason}}

        {:error, reason} ->
          {:error, {:commit, reason}}
      end
    end
  end

  # A commit of only the fields ADR 0021 adds is not empty (decision 4).
  defp empty?(%Commit{
         create: nil,
         workflow: nil,
         upsert_tasks: [],
         delete_task_ids: [],
         outbox_ack: [],
         outbox: [],
         wake: :keep,
         limits: limits,
         queue: []
       })
       when map_size(limits) == 0,
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
        {:ok, state}

      {:event, event} ->
        {:event, event, state}

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
           Effects.run(effect, state.id)
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:event, event}} -> {:event, event}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # The queue messages a start's commits pushed, removed again if the start fails.
  defp journal_commit(nil, _commit), do: nil

  defp journal_commit(journal, %Commit{queue: ops}) do
    pushed = for {:push, queue, id, _priority, _at} <- ops, do: {queue, id}
    %{journal | committed?: true, pushed: Enum.reverse(pushed, journal.pushed)}
  end

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
  # It does not stop while its outbox runner works (ADR 0021, decision 4).
  defp reply_and_settle(reply, state) do
    state = kick(state)

    if ending?(state),
      do: {:reply, reply, state, 0},
      else: {:reply, reply, state}
  end

  defp settle(state) do
    state = kick(state)

    if ending?(state),
      do: {:noreply, state, 0},
      else: noreply(state)
  end

  defp idle(state), do: {:noreply, kick(state), idle_timeout()}
  defp idle(state, reply), do: {:reply, reply, kick(state), idle_timeout()}

  defp stop(state, reason), do: {:stop, :normal, {:error, reason}, state}

  defp noreply(state) do
    if ending?(state),
      do: {:noreply, state, idle_timeout()},
      else: {:noreply, state}
  end

  defp ending?(state),
    do: (state.workflow == nil or terminal?(state.workflow)) and state.runner == nil

  ## Outbox

  # Starts the runner when entries were added and none is running; a running, blocked or
  # delayed runner reads them when it starts again.
  defp kick(%__MODULE__{kick?: false} = state), do: state

  defp kick(%__MODULE__{runner: nil} = state) do
    {:running, Outbox.start(state.id)}
  catch
    # The task supervisor is restarting with the rest of the runtime tree.
    :exit, reason ->
      Logger.error("workflow #{state.id} could not start its outbox runner: #{inspect(reason)}")
      delay_outbox(%{state | kick?: false})
  else
    runner -> %{state | runner: runner, kick?: false}
  end

  defp kick(state), do: %{state | kick?: false}

  # Entries left after activation (or a store that cannot tell) start the runner.
  defp check_outbox(state) do
    case guard(fn -> Runtime.store().pending_outbox(state.id) != [] end) do
      {:ok, pending?} -> %{state | kick?: state.kick? or pending?}
      {:error, reason} -> outbox_unread(state, reason)
    end
  end

  defp outbox_unread(state, reason) do
    Logger.error("workflow #{state.id} could not read its outbox: #{inspect(reason)}")
    delay_outbox(state)
  end

  defp outbox_result(state, :done),
    do: check_outbox(%{state | outbox_delay: nil, blocker: nil})

  # Only returned once the owner is gone, so not seen by a live process; read the outbox again.
  defp outbox_result(state, :owner_down), do: %{state | kick?: true}

  defp outbox_result(state, {:retry, reason}) do
    Logger.warning("workflow #{state.id} retries its outbox: #{inspect(reason)}")
    delay_outbox(%{state | blocker: nil})
  end

  defp outbox_result(state, {:feedback, entry, event}) do
    {reply, state} = handle_event(event, %{state | ack: [entry], blocker: nil})
    state = %{state | ack: []}

    case reply do
      :ok -> %{state | kick?: true}
      {:error, _reason} -> delay_outbox(state)
    end
  end

  # The runner of an earlier process still runs: wait for it to end, and when the registry
  # still names the same one, wait the delay (it drops an ended process asynchronously).
  defp outbox_result(%__MODULE__{blocker: pid} = state, {:already_registered, pid}),
    do: delay_outbox(state)

  defp outbox_result(state, {:already_registered, pid}),
    do: %{state | runner: {:blocked, Process.monitor(pid), pid}, blocker: pid}

  defp delay_outbox(state) do
    delay =
      case state.outbox_delay do
        nil -> Runtime.setting(:outbox_retry_ms, 1_000)
        delay -> min(delay * 2, offset_timeout())
      end

    token = make_ref()
    Process.send_after(self(), {:outbox_retry, token}, delay)
    %{state | runner: {:delayed, token}, outbox_delay: delay, kick?: false}
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
      :recover ->
        %{
          env
          | queued: queued(env, wf),
            workflows: workflows(wf),
            outbox_pending?:
              Workflow.terminal?(wf.status) and
                Runtime.store().pending_outbox(wf.workflow_id) != []
        }

      :wake ->
        %{env | queued: queued(env, wf), workflows: workflows(wf)}

      {:child_revived, task_id} ->
        %{env | workflows: Map.merge(failed_children(wf, task_id), parent(wf))}

      {lifecycle, _arg} when lifecycle in [:retry, :restart] ->
        %{env | workflows: parent(wf)}

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

  defp parent(%Workflow{parent_workflow_id: parent}), do: read_workflows([parent])

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
