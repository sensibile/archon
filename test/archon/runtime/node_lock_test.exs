# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Postgres.NodeLockTest do
  @moduledoc """
  `Archon.Runtime.Postgres.NodeLock` (ADR 0021, decision 7, slice 4h): one node holds the
  database, a second one is refused after retrying, a node that loses its connection or whose
  epoch another node has passed stops, and once a new node has raised the epoch no write of the
  old epoch commits, including one that waited for the raise.

  The tests run on the contract test schema's `node_lease` with lock keys of their own, so they
  do not touch the runtime's lock when it runs on Postgres. Nodes are played by node locks in
  this VM; one that plays another machine does not publish its epoch (`publish: false`).
  """

  use Archon.PostgresCase

  @moduletag :capture_log

  alias Archon.Runtime.Postgres.NodeLock

  @key Postgres.node_lock_key() + 100
  @other_key Postgres.node_lock_key() + 101

  # Every test stops the node locks it started before it ends: a node lock withdraws the epoch
  # it published when it stops, and keep_epoch/0 restores the runtime's after the test.
  setup do
    keep_epoch()
    Postgres.clear_epoch()
    Process.flag(:trap_exit, true)
    :ok
  end

  defp start(instance, opts \\ []) do
    instance
    |> options(opts)
    |> NodeLock.start_link()
  end

  # A node lock started in a task and not linked to it, so it outlives the task; stopped by the
  # test.
  defp start_unlinked(instance, opts) do
    Elixir.Task.async(fn -> GenServer.start(NodeLock, options(instance, opts)) end)
  end

  # Awaits start_unlinked/2; the lock is stopped even when the test fails before it does.
  defp await_unlinked(task) do
    result = Elixir.Task.await(task)

    with {:ok, pid} <- result,
         do: on_exit(fn -> Process.exit(pid, :shutdown) end)

    result
  end

  defp options(instance, opts),
    do: Keyword.merge([name: nil, instance: instance, lock_key: @key, check_interval: 50], opts)

  # The server process holding the advisory lock `key` in this database (advisory locks are per
  # database; other test databases on the server hold the same keys), or nil.
  defp holder(key) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT pid FROM pg_locks
        WHERE locktype = 'advisory'
          AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
          AND granted AND objsubid = 1
          AND classid::bigint = ($1::bigint >> 32) AND objid::bigint = ($1::bigint & 4294967295)
        """,
        [key]
      )

    case rows do
      [[pid]] -> pid
      [] -> nil
    end
  end

  # How many requests for the fence lock in `mode` wait.
  defp fence_waiters(mode) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'advisory'
          AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
          AND NOT granted AND mode = $2 AND objsubid = 1
          AND classid::bigint = ($1::bigint >> 32) AND objid::bigint = ($1::bigint & 4294967295)
        """,
        [Postgres.fence_key(), mode]
      )

    count
  end

  defp insert(instance, name) do
    Repo.query!(
      "INSERT INTO #{Postgres.table(instance, "meta_task_def")} (name, json_data) VALUES ($1, '{}')",
      [name]
    )

    :inserted
  end

  defp names(instance) do
    %{rows: rows} =
      Repo.query!("SELECT name FROM #{Postgres.table(instance, "meta_task_def")} ORDER BY name")

    List.flatten(rows)
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts > 0 -> Process.sleep(10) && eventually(fun, attempts - 1)
      true -> flunk("condition not met")
    end
  end

  test "takes the lock, raises the epoch and publishes it", %{instance: instance} do
    {:ok, lock} = start(instance)

    assert NodeLock.epoch(lock) == 1
    assert Postgres.epoch() == 1
    assert holder(@key) != nil

    fenced = %{instance | fence: :runtime}
    assert Postgres.transaction(fenced, fn -> insert(fenced, "a") end) == {:ok, :inserted}
    :ok = GenServer.stop(lock)
  end

  test "a second node is refused after retrying", %{instance: instance} do
    {:ok, lock} = start(instance)
    started = System.monotonic_time(:millisecond)

    assert start(instance, retry_timeout: 300, retry_interval: 50, publish: false) ==
             {:error, :another_node_holds_the_database}

    assert System.monotonic_time(:millisecond) - started >= 250
    assert Postgres.epoch() == 1
    :ok = GenServer.stop(lock)
  end

  test "a database it cannot reach is tried again, then fails the start", %{instance: instance} do
    started = System.monotonic_time(:millisecond)

    assert {:error, {:node_lock_connection, _reason}} =
             start(instance, connection: [port: 1], retry_timeout: 300, retry_interval: 50)

    assert System.monotonic_time(:millisecond) - started >= 250
    assert Postgres.epoch() == nil
  end

  test "takes the lock its previous holder released while retrying", %{instance: instance} do
    {:ok, first} = start(instance)
    second = start_unlinked(instance, retry_timeout: 5_000, retry_interval: 20)
    Process.sleep(100)

    :ok = GenServer.stop(first)
    assert {:ok, lock} = await_unlinked(second)
    assert NodeLock.epoch(lock) == 2
    assert Postgres.epoch() == 2
    :ok = GenServer.stop(lock)
  end

  test "a normal stop releases the lock and withdraws the epoch", %{instance: instance} do
    {:ok, lock} = start(instance)
    :ok = GenServer.stop(lock)

    assert holder(@key) == nil
    assert Postgres.epoch() == nil
  end

  test "stops when its connection is lost, and withdraws the epoch", %{instance: instance} do
    {:ok, lock} = start(instance)
    ref = Process.monitor(lock)

    Repo.query!("SELECT pg_terminate_backend($1)", [holder(@key)])

    assert_receive {:DOWN, ^ref, :process, ^lock, {:node_lock_lost, _reason}}, 2_000
    assert Postgres.epoch() == nil
    eventually(fn -> holder(@key) == nil end)
  end

  test "stops when another node has raised the epoch", %{instance: instance} do
    {:ok, lock} = start(instance)
    ref = Process.monitor(lock)

    {:ok, 2} = Postgres.advance_epoch(instance)

    assert_receive {:DOWN, ^ref, :process, ^lock, {:node_lock_lost, %{epoch: 2}}}, 2_000
    assert Postgres.epoch() == nil
  end

  test "once a new node raised the epoch no write of the old one commits, also one that waited",
       %{instance: instance} do
    {:ok, old} = start(instance, check_interval: 60_000)
    old_epoch = Postgres.epoch()
    fenced = %{instance | fence: :runtime}
    test = self()

    # A write of the old node already past the fence when the new node comes.
    in_flight =
      Elixir.Task.async(fn ->
        Postgres.transaction(fenced, fn ->
          send(test, :passed)
          receive do: (:commit -> insert(fenced, "in-flight"))
        end)
      end)

    assert_receive :passed

    # The new node, on another lock key as if the old node had lost its lock unawares.
    new = start_unlinked(instance, lock_key: @other_key, publish: false, check_interval: 60_000)

    eventually(fn -> fence_waiters("ExclusiveLock") == 1 end)

    # A write of the old node that starts while the new one waits to raise the epoch.
    waiting =
      Elixir.Task.async(fn -> Postgres.transaction(fenced, fn -> insert(fenced, "late") end) end)

    eventually(fn -> fence_waiters("ShareLock") >= 1 end)
    refute Elixir.Task.yield(new, 50)

    send(in_flight.pid, :commit)
    assert Elixir.Task.await(in_flight) == {:ok, :inserted}
    assert {:ok, new_lock} = await_unlinked(new)
    assert NodeLock.epoch(new_lock) == old_epoch + 1

    assert Elixir.Task.await(waiting) == {:error, :fenced}
    assert Postgres.transaction(fenced, fn -> insert(fenced, "after") end) == {:error, :fenced}
    assert names(instance) == ["in-flight"]

    # The old node's next check sees the epoch it no longer holds.
    ref = Process.monitor(old)
    send(old, :check)
    assert_receive {:DOWN, ^ref, :process, ^old, {:node_lock_lost, _reason}}
    :ok = GenServer.stop(new_lock)
  end

  # The runtime's own node lock (ADR 0021, decision 8) on the Postgres backend.
  @tag backend: :postgres
  test "the runtime's node lock holds the database and refuses a second node" do
    %{rows: [[epoch]]} = Repo.query!("SELECT epoch FROM public.node_lease WHERE id = 1")
    assert NodeLock.epoch() == epoch
    assert holder(Postgres.node_lock_key()) != nil

    assert NodeLock.start_link(name: nil, retry_timeout: 200, retry_interval: 50, publish: false) ==
             {:error, :another_node_holds_the_database}
  end
end
