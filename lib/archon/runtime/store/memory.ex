# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/dal/ExecutionDAOFacade.java,
# sqlite-persistence/src/main/java/com/netflix/conductor/sqlite/dao/SqliteExecutionDAO.java and
# SqlitePollDataDAO.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: an in-memory GenServer holding the structs as they are (ADR 0018,
# decision 3); a commit is applied in one message, so readers never see half of it, and also holds
# the outbox, re-evaluation times and limit checks of ADR 0021, and the ordered queries by name
# of ADR 0025.

defmodule Archon.Runtime.Store.Memory do
  @moduledoc """
  In-memory `Archon.Runtime.Store` for development and tests (ADR 0018, decision 3).

  One GenServer holds the workflows (without tasks), the tasks, the outbox, the re-evaluation times
  and the poll data. Data is lost when the process stops. Each function takes an optional first
  argument, the server (this module's name by default); the arities without it are the behaviour
  callbacks.

  A commit's queue operations go to an `Archon.Runtime.Queue.Memory` (`apply_ops/2`) after every
  other field is checked, since they cannot be undone (ADR 0021, decision 3). If that call exits,
  the commit is not applied and the caller exits with the same reason; a call that timed out may
  still have applied the queue operations.

  Options of `start_link/1`:

    * `:name` - this module by default.
    * `:queue` - the `Archon.Runtime.Queue.Memory` server for queue operations, that module's
      name by default.
  """

  @behaviour Archon.Runtime.Store

  use GenServer

  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.{Commit, Store}
  alias Archon.Runtime.Queue.Memory, as: Queue
  alias Archon.Runtime.Step.Effect

  @queue_timeout 5_000

  @doc false
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Store
  @spec commit(GenServer.server(), String.t(), Commit.t()) ::
          :ok | {:error, :conflict | :not_found | {:limit, String.t()}}
  def commit(server \\ __MODULE__, workflow_id, %Commit{} = commit) when is_binary(workflow_id) do
    Commit.check!(workflow_id, commit)
    Queue.check_ops!(commit.queue)

    # Longer than the queue call, so a slow queue ends as an unapplied commit and an exit.
    case GenServer.call(server, {:commit, workflow_id, commit}, @queue_timeout + 5_000) do
      {:exit, reason} -> exit(reason)
      reply -> reply
    end
  end

  @impl Store
  @spec get_workflow(GenServer.server(), String.t(), boolean()) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow(server \\ __MODULE__, id, include_tasks?) when is_boolean(include_tasks?) do
    GenServer.call(server, {:get_workflow, id, include_tasks?})
  end

  @impl Store
  @spec get_task(GenServer.server(), String.t()) ::
          {:ok, Task.t(), String.t()} | {:error, :not_found}
  def get_task(server \\ __MODULE__, task_id), do: GenServer.call(server, {:get_task, task_id})

  @impl Store
  @spec running_workflow_ids(GenServer.server()) :: [String.t()]
  def running_workflow_ids(server \\ __MODULE__),
    do: GenServer.call(server, :running_workflow_ids)

  @impl Store
  @spec correlated_workflows(GenServer.server(), String.t(), String.t(), boolean(), boolean()) ::
          [Workflow.t()]
  def correlated_workflows(
        server \\ __MODULE__,
        name,
        correlation_id,
        include_closed?,
        include_tasks?
      )
      when is_binary(name) and is_binary(correlation_id) and is_boolean(include_closed?) and
             is_boolean(include_tasks?) do
    if storable?(name) and storable?(correlation_id),
      do:
        GenServer.call(
          server,
          {:correlated_workflows, name, correlation_id, include_closed?, include_tasks?}
        ),
      else: []
  end

  @impl Store
  @spec pending_workflow_ids(GenServer.server(), String.t()) :: [String.t()]
  def pending_workflow_ids(server \\ __MODULE__, name) when is_binary(name) do
    if storable?(name), do: GenServer.call(server, {:pending_workflow_ids, name}), else: []
  end

  @impl Store
  @spec workflow_ids_created_between(
          GenServer.server(),
          String.t(),
          integer(),
          integer(),
          integer()
        ) ::
          [String.t()]
  def workflow_ids_created_between(server \\ __MODULE__, name, version, start_ms, end_ms)
      when is_binary(name) and is_integer(version) and is_integer(start_ms) and
             is_integer(end_ms) do
    if storable?(name),
      do:
        GenServer.call(server, {:workflow_ids_created_between, name, version, start_ms, end_ms}),
      else: []
  end

  # The Postgres store's index columns cannot hold these, so no stored workflow matches them.
  defp storable?(value), do: String.valid?(value) and not String.contains?(value, <<0>>)

  @impl Store
  @spec remove_workflow(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def remove_workflow(server \\ __MODULE__, id),
    do: GenServer.call(server, {:remove_workflow, id})

  @impl Store
  @spec in_progress_count(GenServer.server(), String.t()) :: non_neg_integer()
  def in_progress_count(server \\ __MODULE__, task_def_name) do
    GenServer.call(server, {:in_progress_count, task_def_name})
  end

  @impl Store
  @spec pending_outbox(GenServer.server(), String.t()) :: [{Store.outbox_id(), Effect.t()}]
  def pending_outbox(server \\ __MODULE__, workflow_id) when is_binary(workflow_id),
    do: GenServer.call(server, {:pending_outbox, workflow_id})

  @impl Store
  @spec ack_outbox(GenServer.server(), String.t(), [Store.outbox_id()]) :: :ok
  def ack_outbox(server \\ __MODULE__, workflow_id, ids)
      when is_binary(workflow_id) and is_list(ids),
      do: GenServer.call(server, {:ack_outbox, workflow_id, ids})

  @impl Store
  @spec outbox_workflow_ids(GenServer.server(), String.t() | nil, non_neg_integer()) ::
          [String.t()]
  def outbox_workflow_ids(server \\ __MODULE__, cursor, limit)
      when (is_binary(cursor) or is_nil(cursor)) and is_integer(limit) and limit >= 0,
      do: GenServer.call(server, {:outbox_workflow_ids, cursor, limit})

  @impl Store
  @spec due_workflow_ids(GenServer.server(), integer(), Store.due_key() | nil, non_neg_integer()) ::
          [Store.due_key()]
  def due_workflow_ids(server \\ __MODULE__, before_ms, cursor, limit)
      when is_integer(before_ms) and is_integer(limit) and limit >= 0 do
    case cursor do
      nil -> :ok
      {key, id} when is_integer(key) and is_binary(id) -> :ok
      _other -> raise ArgumentError, "invalid cursor #{inspect(cursor)}"
    end

    GenServer.call(server, {:due_workflow_ids, before_ms, cursor, limit})
  end

  @impl Store
  @spec put_poll_data(
          GenServer.server(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          integer()
        ) ::
          :ok
  def put_poll_data(server \\ __MODULE__, task_type, domain, worker_id, now)
      when is_binary(task_type) and is_integer(now) do
    poll_data = %{
      queue_name: task_type,
      domain: domain,
      worker_id: worker_id,
      last_poll_time: now
    }

    GenServer.call(server, {:put_poll_data, poll_data})
  end

  @impl Store
  @spec get_poll_data(GenServer.server(), String.t(), String.t() | nil) ::
          {:ok, Store.poll_data()} | {:error, :not_found}
  def get_poll_data(server \\ __MODULE__, task_type, domain) do
    GenServer.call(server, {:get_poll_data, task_type, domain})
  end

  @impl GenServer
  def init(opts) do
    state = %{
      queue: Keyword.get(opts, :queue, Queue),
      workflows: %{},
      tasks: %{},
      task_ids: %{},
      # workflow ID => [{outbox ID, effect}] in ID order
      outbox: %{},
      outbox_seq: 0,
      # workflow ID => epoch ms (no key: not set)
      wake_at: %{},
      poll_data: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:commit, workflow_id, commit}, _from, state) do
    with {:ok, new_state} <- apply_commit(state, workflow_id, commit),
         :ok <- apply_queue(state.queue, commit.queue) do
      {:reply, :ok, new_state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      {:exit, _reason} = exit -> {:reply, exit, state}
    end
  end

  def handle_call({:pending_outbox, workflow_id}, _from, state) do
    {:reply, Map.get(state.outbox, workflow_id, []), state}
  end

  def handle_call({:ack_outbox, workflow_id, ids}, _from, state) do
    {:reply, :ok, ack(state, workflow_id, ids)}
  end

  def handle_call({:outbox_workflow_ids, cursor, limit}, _from, state) do
    ids =
      state.outbox
      |> Map.keys()
      |> Enum.filter(&(cursor == nil or &1 > cursor))
      |> Enum.sort()
      |> Enum.take(limit)

    {:reply, ids, state}
  end

  def handle_call({:due_workflow_ids, before_ms, cursor, limit}, _from, state) do
    # An unset time is due, with the key 0 (COALESCE(wake_at, 0) in the Postgres store).
    keys =
      for {id, %Workflow{status: :running}} <- state.workflows,
          wake_at <- [Map.get(state.wake_at, id)],
          wake_at == nil or wake_at <= before_ms,
          key <- [{wake_at || 0, id}],
          cursor == nil or key > cursor,
          do: key

    {:reply, keys |> Enum.sort() |> Enum.take(limit), state}
  end

  def handle_call({:get_workflow, id, include_tasks?}, _from, state) do
    reply =
      case state.workflows do
        %{^id => workflow} when include_tasks? -> {:ok, %{workflow | tasks: tasks_of(state, id)}}
        %{^id => workflow} -> {:ok, workflow}
        %{} -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:get_task, task_id}, _from, state) do
    reply =
      case state.tasks do
        %{^task_id => task} -> {:ok, task, task.workflow_instance_id}
        %{} -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:running_workflow_ids, _from, state) do
    ids =
      for {id, %Workflow{status: status}} <- state.workflows,
          not Workflow.terminal?(status),
          do: id

    {:reply, Enum.sort(ids), state}
  end

  def handle_call({:correlated_workflows, name, correlation_id, closed?, tasks?}, _from, state) do
    workflows =
      state
      |> by_name(name)
      |> Enum.filter(
        &(&1.correlation_id == correlation_id and (closed? or &1.status == :running))
      )
      |> Enum.map(&if(tasks?, do: %{&1 | tasks: tasks_of(state, &1.workflow_id)}, else: &1))

    {:reply, workflows, state}
  end

  def handle_call({:pending_workflow_ids, name}, _from, state) do
    ids =
      for workflow <- by_name(state, name),
          not Workflow.terminal?(workflow.status),
          do: workflow.workflow_id

    {:reply, ids, state}
  end

  def handle_call({:workflow_ids_created_between, name, version, start_ms, end_ms}, _from, state) do
    ids =
      for %Workflow{create_time: time} = workflow <- by_name(state, name),
          Workflow.workflow_version(workflow) == version,
          is_integer(time) and time >= start_ms and time <= end_ms,
          do: workflow.workflow_id

    {:reply, ids, state}
  end

  def handle_call({:remove_workflow, id}, _from, state) do
    if Map.has_key?(state.workflows, id) do
      state = %{
        state
        | workflows: Map.delete(state.workflows, id),
          tasks: Map.drop(state.tasks, MapSet.to_list(state.task_ids[id])),
          task_ids: Map.delete(state.task_ids, id),
          outbox: Map.delete(state.outbox, id),
          wake_at: Map.delete(state.wake_at, id)
      }

      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:in_progress_count, task_def_name}, _from, state) do
    {:reply, in_progress_count_of(state, task_def_name), state}
  end

  def handle_call({:put_poll_data, poll_data}, _from, state) do
    key = {poll_data.queue_name, poll_key(poll_data.domain)}
    {:reply, :ok, %{state | poll_data: Map.put(state.poll_data, key, poll_data)}}
  end

  def handle_call({:get_poll_data, task_type, domain}, _from, state) do
    reply = Map.fetch(state.poll_data, {task_type, poll_key(domain)})
    {:reply, if(reply == :error, do: {:error, :not_found}, else: reply), state}
  end

  # SqlitePollDataDAO stores a nil domain under "DEFAULT".
  defp poll_key(nil), do: "DEFAULT"
  defp poll_key(domain), do: domain

  defp apply_commit(state, workflow_id, %Commit{} = commit) do
    with {:ok, state} <- apply_create(state, workflow_id, commit.create),
         :ok <- check_exists(state, workflow_id),
         :ok <- check_owner(state, workflow_id, commit.upsert_tasks) do
      state =
        state
        |> put_workflow(commit.workflow)
        |> put_tasks(workflow_id, commit.upsert_tasks)
        |> delete_tasks(workflow_id, commit.delete_task_ids)
        |> ack(workflow_id, commit.outbox_ack)
        |> append_outbox(workflow_id, commit.outbox)
        |> put_wake(workflow_id, commit.wake)

      with :ok <- check_limits(state, commit.limits), do: {:ok, state}
    end
  end

  # The queue cannot be rolled back, so it goes last; an exit is the caller's, not the store's.
  defp apply_queue(_queue, []), do: :ok

  defp apply_queue(queue, ops) do
    Queue.apply_ops(queue, ops, @queue_timeout)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp ack(state, _workflow_id, []), do: state

  defp ack(state, workflow_id, ids) do
    acked = MapSet.new(ids)
    entries = Map.get(state.outbox, workflow_id, [])

    case Enum.reject(entries, fn {id, _effect} -> MapSet.member?(acked, id) end) do
      [] -> %{state | outbox: Map.delete(state.outbox, workflow_id)}
      left -> %{state | outbox: Map.put(state.outbox, workflow_id, left)}
    end
  end

  defp append_outbox(state, _workflow_id, []), do: state

  defp append_outbox(state, workflow_id, effects) do
    seq = state.outbox_seq
    entries = Enum.with_index(effects, fn effect, i -> {seq + i + 1, effect} end)

    %{
      state
      | outbox: Map.update(state.outbox, workflow_id, entries, &(&1 ++ entries)),
        outbox_seq: seq + length(effects)
    }
  end

  defp put_wake(state, _workflow_id, :keep), do: state

  defp put_wake(state, workflow_id, :none),
    do: %{state | wake_at: Map.delete(state.wake_at, workflow_id)}

  defp put_wake(state, workflow_id, {:at, ms}),
    do: %{state | wake_at: Map.put(state.wake_at, workflow_id, ms)}

  defp put_wake(state, workflow_id, {:before, ms}),
    do: %{state | wake_at: Map.update(state.wake_at, workflow_id, ms, &min(&1, ms))}

  # ADR 0021, decision 5: names in binary order, as the Postgres store takes its locks.
  defp check_limits(state, limits) do
    limits
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {name, limit} ->
      if in_progress_count_of(state, name) > limit, do: {:error, {:limit, name}}
    end)
  end

  defp in_progress_count_of(state, task_def_name) do
    Enum.count(state.tasks, fn {_id, task} ->
      task.status == :in_progress and Task.task_def_name(task) == task_def_name
    end)
  end

  defp apply_create(state, _workflow_id, nil), do: {:ok, state}

  defp apply_create(state, workflow_id, %Workflow{tasks: tasks} = workflow) do
    if Map.has_key?(state.workflows, workflow_id) do
      {:error, :conflict}
    else
      with :ok <- check_owner(state, workflow_id, tasks) do
        state = %{state | task_ids: Map.put(state.task_ids, workflow_id, MapSet.new())}
        {:ok, state |> put_workflow(workflow) |> put_tasks(workflow_id, tasks)}
      end
    end
  end

  defp check_exists(state, workflow_id) do
    if Map.has_key?(state.workflows, workflow_id), do: :ok, else: {:error, :not_found}
  end

  defp check_owner(state, workflow_id, tasks) do
    owned_elsewhere? = fn %Task{task_id: id} ->
      match?(%{^id => %Task{workflow_instance_id: owner}} when owner != workflow_id, state.tasks)
    end

    if Enum.any?(tasks, owned_elsewhere?), do: {:error, :conflict}, else: :ok
  end

  defp put_workflow(state, nil), do: state

  defp put_workflow(state, %Workflow{workflow_id: id} = workflow) do
    %{state | workflows: Map.put(state.workflows, id, %{workflow | tasks: []})}
  end

  defp put_tasks(state, workflow_id, tasks) do
    Enum.reduce(tasks, state, fn %Task{task_id: id} = task, state ->
      %{
        state
        | tasks: Map.put(state.tasks, id, task),
          task_ids: Map.update!(state.task_ids, workflow_id, &MapSet.put(&1, id))
      }
    end)
  end

  defp delete_tasks(state, workflow_id, task_ids) do
    owned = Enum.filter(task_ids, &MapSet.member?(state.task_ids[workflow_id], &1))

    %{
      state
      | tasks: Map.drop(state.tasks, owned),
        task_ids:
          Map.update!(state.task_ids, workflow_id, &MapSet.difference(&1, MapSet.new(owned)))
    }
  end

  # Workflows of a definition name, by create time and then ID (a nil time last, as in Postgres).
  defp by_name(state, name) do
    state.workflows
    |> Map.values()
    |> Enum.filter(&(Workflow.workflow_name(&1) == name))
    |> Enum.sort_by(&{&1.create_time == nil, &1.create_time, &1.workflow_id})
  end

  defp tasks_of(state, workflow_id) do
    state.task_ids[workflow_id]
    |> Enum.map(&Map.fetch!(state.tasks, &1))
    |> Enum.sort_by(&{&1.seq, &1.task_id})
  end
end
