# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss sqlite-persistence/src/main/java/com/netflix/conductor/sqlite/dao/SqliteQueueDAO.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: an in-memory GenServer (ADR 0018, decision 3); a waiting pop is a deferred
# reply woken by pushes and visibility timers instead of a 100 ms polling loop, and the unack
# timeout counts from the pop instead of the original delivery time.

defmodule Archon.Runtime.Queue.Memory do
  @moduledoc """
  In-memory `Archon.Runtime.Queue` for development and tests (ADR 0018, decision 3).

  One GenServer holds every queue. A `pop/4` that finds nothing visible is answered later: when a
  push makes a message visible, when a delayed or unacked message becomes visible, or with `[]`
  at `timeout_ms`. Waiting pops on one queue are served in arrival order (this implementation's
  choice; the behaviour does not promise it). Messages are kept in a map per queue and sorted on
  each pop, which is enough for development and tests. Data is lost when the
  process stops. Each function takes an optional first argument, the server (this module's name by
  default); the arities without it are the behaviour callbacks.

  A popped message that is not acked becomes visible again `:unack_timeout` after the pop.
  Upstream `SqliteQueueDAO` makes it visible 60 seconds after its original delivery time, checked
  by a sweep every 60 seconds, so there it reappears somewhere between at once and about 120 seconds
  after the pop. It keeps its place by original delivery time either way.

  Options of `start_link/1`:

    * `:name` - this module by default.
    * `:clock` - a zero-arity function returning the time in milliseconds,
      `System.system_time(:millisecond)` by default. Delays and the unack timeout use it.
    * `:unack_timeout` - milliseconds, 60 000 (upstream `UNACK_SCHEDULE_MS`).
  """

  @behaviour Archon.Runtime.Queue

  use GenServer

  alias Archon.Runtime.Queue

  @unack_timeout 60_000
  @call_margin 5_000

  @doc false
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl Queue
  @spec push(GenServer.server(), String.t(), String.t(), integer(), integer()) :: :ok
  def push(server \\ __MODULE__, queue, id, priority, delay_ms)
      when is_binary(queue) and is_binary(id) and is_integer(priority) and is_integer(delay_ms) do
    GenServer.call(server, {:push, queue, id, priority, delay_ms})
  end

  @impl Queue
  @spec pop(GenServer.server(), String.t(), integer(), integer()) :: [String.t()]
  def pop(server \\ __MODULE__, queue, count, timeout_ms)
      when is_binary(queue) and is_integer(count) and is_integer(timeout_ms) do
    GenServer.call(server, {:pop, queue, count, timeout_ms}, max(timeout_ms, 0) + @call_margin)
  end

  @impl Queue
  @spec ack(GenServer.server(), String.t(), String.t()) :: boolean()
  def ack(server \\ __MODULE__, queue, id), do: GenServer.call(server, {:delete, queue, id})

  @impl Queue
  @spec remove(GenServer.server(), String.t(), String.t()) :: :ok
  def remove(server \\ __MODULE__, queue, id) do
    GenServer.call(server, {:delete, queue, id})
    :ok
  end

  @impl Queue
  @spec postpone(GenServer.server(), String.t(), String.t(), integer(), integer()) :: :ok
  def postpone(server \\ __MODULE__, queue, id, priority, delay_ms)
      when is_binary(queue) and is_binary(id) and is_integer(priority) and is_integer(delay_ms) do
    GenServer.call(server, {:postpone, queue, id, priority, delay_ms})
  end

  @impl Queue
  @spec contains?(GenServer.server(), String.t(), String.t()) :: boolean()
  def contains?(server \\ __MODULE__, queue, id),
    do: GenServer.call(server, {:contains?, queue, id})

  @impl Queue
  @spec size(GenServer.server(), String.t()) :: non_neg_integer()
  def size(server \\ __MODULE__, queue), do: GenServer.call(server, {:size, queue})

  @impl GenServer
  def init(opts) do
    state = %{
      clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end),
      unack_timeout: Keyword.get(opts, :unack_timeout, @unack_timeout),
      # queue => id => %{priority, deliver_at, visible_at, seq}
      queues: %{},
      seq: 0,
      # queue => waiter refs in arrival order; ref => waiter
      waiting: %{},
      waiters: %{},
      tick: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:push, queue, id, priority, delay_ms}, _from, state) do
    at = state.clock.() + delay_ms

    state =
      case state.queues do
        %{^queue => %{^id => message}} ->
          put_message(state, queue, id, %{message | deliver_at: at, visible_at: at})

        %{} ->
          insert(state, queue, id, priority, at)
      end

    {:reply, :ok, state |> serve(queue) |> schedule_tick()}
  end

  def handle_call({:postpone, queue, id, priority, delay_ms}, _from, state) do
    state = state |> delete(queue, id) |> insert(queue, id, priority, state.clock.() + delay_ms)
    {:reply, :ok, state |> serve(queue) |> schedule_tick()}
  end

  def handle_call({:pop, _queue, count, _timeout_ms}, _from, state) when count <= 0 do
    {:reply, [], state}
  end

  def handle_call({:pop, queue, count, timeout_ms}, {pid, _tag} = from, state) do
    # Messages that became visible before their tick was handled go to earlier waiting pops first.
    state = serve(state, queue)

    case take(state, queue, count) do
      {[], state} when timeout_ms > 0 ->
        ref = make_ref()

        waiter = %{
          queue: queue,
          count: count,
          from: from,
          timer: Process.send_after(self(), {:pop_timeout, ref}, timeout_ms),
          monitor: Process.monitor(pid)
        }

        state = %{
          state
          | waiters: Map.put(state.waiters, ref, waiter),
            waiting: Map.update(state.waiting, queue, [ref], &(&1 ++ [ref]))
        }

        {:noreply, schedule_tick(state)}

      {ids, state} ->
        {:reply, ids, state}
    end
  end

  def handle_call({:delete, queue, id}, _from, state) do
    found? = match?(%{^queue => %{^id => _}}, state.queues)
    {:reply, found?, delete(state, queue, id)}
  end

  def handle_call({:contains?, queue, id}, _from, state) do
    {:reply, match?(%{^queue => %{^id => _}}, state.queues), state}
  end

  def handle_call({:size, queue}, _from, state) do
    {:reply, map_size(Map.get(state.queues, queue, %{})), state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    state = Enum.reduce(Map.keys(state.waiting), state, &serve(&2, &1))
    {:noreply, schedule_tick(state)}
  end

  def handle_info({:pop_timeout, ref}, state) do
    case state.waiters do
      %{^ref => waiter} ->
        GenServer.reply(waiter.from, [])
        {:noreply, state |> drop_waiter(ref) |> schedule_tick()}

      %{} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.waiters, fn {_ref, waiter} -> waiter.monitor == monitor end) do
      {ref, _waiter} -> {:noreply, state |> drop_waiter(ref) |> schedule_tick()}
      nil -> {:noreply, state}
    end
  end

  defp insert(state, queue, id, priority, at) do
    message = %{priority: priority, deliver_at: at, visible_at: at, seq: state.seq}
    put_message(%{state | seq: state.seq + 1}, queue, id, message)
  end

  defp put_message(state, queue, id, message) do
    %{
      state
      | queues: Map.update(state.queues, queue, %{id => message}, &Map.put(&1, id, message))
    }
  end

  defp delete(state, queue, id) do
    case state.queues do
      %{^queue => %{^id => _} = messages} when map_size(messages) == 1 ->
        %{state | queues: Map.delete(state.queues, queue)}

      %{^queue => messages} ->
        %{state | queues: %{state.queues | queue => Map.delete(messages, id)}}

      %{} ->
        state
    end
  end

  # Pops up to `count` visible messages in SqliteQueueDAO order: priority DESC, deliver_on,
  # created_on. A popped message stays, hidden until the unack timeout.
  defp take(state, queue, count) do
    now = state.clock.()
    messages = Map.get(state.queues, queue, %{})

    ids =
      for({id, %{visible_at: at} = message} <- messages, at <= now, do: {id, message})
      |> Enum.sort_by(fn {_id, m} -> {-m.priority, m.deliver_at, m.seq} end)
      |> Enum.take(count)
      |> Enum.map(&elem(&1, 0))

    hidden_until = now + state.unack_timeout

    state =
      Enum.reduce(ids, state, fn id, state ->
        put_message(state, queue, id, %{messages[id] | visible_at: hidden_until})
      end)

    {ids, state}
  end

  defp serve(state, queue) do
    case Map.get(state.waiting, queue, []) do
      [] ->
        state

      [ref | _rest] ->
        waiter = state.waiters[ref]

        case take(state, queue, waiter.count) do
          {[], state} ->
            state

          {ids, state} ->
            # A caller that died before its :DOWN arrived loses these IDs until the unack timeout,
            # the same window as upstream between pop and ack.
            GenServer.reply(waiter.from, ids)
            state |> drop_waiter(ref) |> serve(queue)
        end
    end
  end

  defp drop_waiter(state, ref) do
    {waiter, waiters} = Map.pop!(state.waiters, ref)
    Process.cancel_timer(waiter.timer)
    Process.demonitor(waiter.monitor, [:flush])

    waiting =
      case List.delete(state.waiting[waiter.queue], ref) do
        [] -> Map.delete(state.waiting, waiter.queue)
        refs -> Map.put(state.waiting, waiter.queue, refs)
      end

    %{state | waiters: waiters, waiting: waiting}
  end

  # One timer for the earliest time a hidden message of a queue with waiting pops becomes visible.
  defp schedule_tick(state) do
    if state.tick, do: Process.cancel_timer(state.tick)
    now = state.clock.()

    hidden =
      for queue <- Map.keys(state.waiting),
          {_id, %{visible_at: at}} <- Map.get(state.queues, queue, %{}),
          at > now,
          do: at

    tick =
      case hidden do
        [] -> nil
        times -> Process.send_after(self(), :tick, Enum.min(times) - now)
      end

    %{state | tick: tick}
  end
end
