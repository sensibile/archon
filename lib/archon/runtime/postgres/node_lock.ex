# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Postgres.NodeLock do
  @moduledoc """
  Keeps a second node off the database (ADR 0021, decision 7).

  On start it opens its own Postgrex connection, outside `Archon.Repo`'s pool and linked to it,
  with `backoff_type: :stop` so that a lost connection is not silently replaced by one without
  the lock. It takes the session advisory lock on `Archon.Runtime.Postgres.node_lock_key/0`
  with `pg_try_advisory_lock`, trying again for `retry_timeout` (the lock of this node's
  previous connection may not be released by the server yet) and then failing with
  `{:stop, :another_node_holds_the_database}`. With the lock it raises the epoch in
  `node_lease` (`Archon.Runtime.Postgres.advance_epoch/1`) and publishes it
  (`Archon.Runtime.Postgres.put_epoch/1`), which lets the runtime's writes pass the fence.

  Every `check_interval` it checks, on its connection, that the same server process still holds
  the lock (`pg_locks`) and that `node_lease` still has its epoch. When the connection is lost
  (the linked connection exits), the lock is gone or another node has raised the epoch, it
  stops; `Archon.Runtime.Supervisor` is `rest_for_one`, so the runtime after it restarts and
  takes the lock again, or fails to start while another node holds it. Stopping withdraws the
  published epoch first, so the runtime's writes are fenced until the lock is held again; a
  normal shutdown also releases the lock and closes the connection.

  Options (the defaults come from `config :archon, Archon.Runtime`):

    * `:name` - the registered name, this module by default; `nil` for none.
    * `:instance` - the `Archon.Runtime.Postgres` whose `node_lease` holds the epoch,
      `Archon.Runtime.Postgres.runtime/0` by default.
    * `:lock_key` - the session advisory lock key, `Archon.Runtime.Postgres.node_lock_key/0`.
    * `:publish` - whether to publish the epoch for this node's writes, `true`. Tests that
      play a second node in the same VM turn it off.
    * `:retry_timeout` - `node_lock_retry_timeout`, 10 s; `:retry_interval` - 500 ms.
    * `:check_interval` - `node_lock_check_interval`, 5 s.
    * `:connection` - Postgrex options merged over the repository's connection options.
  """

  use GenServer

  require Logger

  alias Archon.Runtime
  alias Archon.Runtime.Postgres

  # The repository options that describe the connection; the pool and Ecto options are left out.
  @connection_keys ~w(hostname port username password database socket socket_dir ssl
                      parameters connect_timeout handshake_timeout ping_timeout prepare
                      transport_opts endpoints)a

  defmodule State do
    @moduledoc false
    defstruct [:conn, :backend_pid, :epoch, :instance, :lock_key, :publish, :check_interval]
  end

  @doc false
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The epoch this node lock took."
  @spec epoch(GenServer.server()) :: pos_integer()
  def epoch(server \\ __MODULE__), do: GenServer.call(server, :epoch)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %State{
      instance: Keyword.get(opts, :instance, Postgres.runtime()),
      lock_key: Keyword.get(opts, :lock_key, Postgres.node_lock_key()),
      publish: Keyword.get(opts, :publish, true),
      check_interval:
        Keyword.get(opts, :check_interval, Runtime.setting(:node_lock_check_interval, 5_000))
    }

    retry_timeout =
      Keyword.get(opts, :retry_timeout, Runtime.setting(:node_lock_retry_timeout, 10_000))

    deadline = System.monotonic_time(:millisecond) + retry_timeout

    with {:ok, conn} <- connect(state.instance, Keyword.get(opts, :connection, [])),
         state = %{state | conn: conn},
         {:ok, backend_pid} <- acquire(state, deadline, Keyword.get(opts, :retry_interval, 500)) do
      {:ok, epoch} = Postgres.advance_epoch(state.instance)
      if state.publish, do: Postgres.put_epoch(epoch)
      Logger.info("took the node lock with epoch #{epoch}")
      {:ok, schedule(%{state | backend_pid: backend_pid, epoch: epoch})}
    else
      {:stop, reason, conn} ->
        close(conn)
        {:stop, reason}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp connect(%Postgres{repo: repo}, overrides) do
    repo.config()
    |> Keyword.take(@connection_keys)
    |> Keyword.merge(overrides)
    |> Keyword.merge(backoff_type: :stop, pool_size: 1, name: nil)
    |> Postgrex.start_link()
  end

  defp acquire(%State{conn: conn, lock_key: key} = state, deadline, interval) do
    case Postgrex.query(conn, "SELECT pg_try_advisory_lock($1), pg_backend_pid()", [key]) do
      {:ok, %{rows: [[true, backend_pid]]}} ->
        {:ok, backend_pid}

      {:ok, %{rows: [[false, _backend_pid]]}} ->
        if System.monotonic_time(:millisecond) + interval > deadline do
          {:stop, :another_node_holds_the_database, conn}
        else
          Process.sleep(interval)
          acquire(state, deadline, interval)
        end

      {:error, exception} ->
        {:stop, {:node_lock_connection, exception}, conn}
    end
  end

  @impl GenServer
  def handle_call(:epoch, _from, state), do: {:reply, state.epoch, state}

  @impl GenServer
  def handle_info(:check, state) do
    case check(state) do
      :ok ->
        {:noreply, schedule(state)}

      {:error, reason} ->
        Logger.error("lost the node lock: #{inspect(reason)}")
        {:stop, {:node_lock_lost, reason}, state}
    end
  end

  def handle_info({:EXIT, conn, reason}, %State{conn: conn} = state) do
    Logger.error("lost the node lock connection: #{inspect(reason)}")
    {:stop, {:node_lock_lost, {:connection, reason}}, %{state | conn: nil}}
  end

  def handle_info({:EXIT, _other, reason}, state), do: {:stop, reason, state}

  def handle_info(_stale, state), do: {:noreply, state}

  # The lock is held by the same server process (a reconnected connection would have another),
  # and no other node has raised the epoch since.
  defp check(%State{conn: conn, lock_key: key, instance: instance} = state) do
    sql = """
    SELECT pg_backend_pid(),
           EXISTS (SELECT 1 FROM pg_locks
                   WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted
                     AND classid::bigint = ($1::bigint >> 32)
                     AND objid::bigint = ($1::bigint & 4294967295) AND objsubid = 1),
           (SELECT epoch FROM #{Postgres.table(instance, "node_lease")} WHERE id = 1)
    """

    case Postgrex.query(conn, sql, [key]) do
      {:ok, %{rows: [[backend_pid, true, epoch]]}}
      when backend_pid == state.backend_pid and epoch == state.epoch ->
        :ok

      {:ok, %{rows: [[backend_pid, held?, epoch]]}} ->
        {:error, %{backend_pid: backend_pid, lock_held: held?, epoch: epoch}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp schedule(%State{check_interval: interval} = state) do
    Process.send_after(self(), :check, interval)
    state
  end

  @impl GenServer
  def terminate(reason, %State{} = state) do
    if state.publish and state.epoch != nil and Postgres.epoch() == state.epoch,
      do: Postgres.clear_epoch()

    if graceful?(reason), do: unlock(state)
    close(state.conn)
  end

  defp graceful?(reason), do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  # Closing the connection releases the lock too; unlocking first frees it without waiting for
  # the server to notice the closed socket.
  defp unlock(%State{conn: nil}), do: :ok

  defp unlock(%State{conn: conn, lock_key: key}) do
    _result = Postgrex.query(conn, "SELECT pg_advisory_unlock($1)", [key])
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp close(nil), do: :ok

  defp close(conn) do
    if Process.alive?(conn), do: GenServer.stop(conn, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
