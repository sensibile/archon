# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Postgres.NodeLock do
  @moduledoc """
  Keeps a second node off the database (ADR 0021, decision 7).

  On start it opens its own Postgrex connection, outside `Archon.Repo`'s pool and linked to it,
  with `backoff_type: :stop` and `max_restarts: 0` so that a lost connection is not silently
  replaced by one without the lock: the connection exits instead. It takes the session advisory
  lock on `Archon.Runtime.Postgres.node_lock_key/0` with `pg_try_advisory_lock`, trying again
  for `retry_timeout` (the lock of this node's previous connection may not be released by the
  server yet) and then failing with
  `{:stop, :another_node_holds_the_database}`. A database it cannot reach is tried again for
  the same time on new connections (a restart or failover), then fails the start with
  `{:stop, {:node_lock_connection, reason}}`. With the lock it raises the epoch in
  `node_lease` on its connection (`Archon.Runtime.Postgres.advance_epoch/3`) and publishes it
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

  # The repository options that are not the connection's: Ecto's, the pool's and the name. Every
  # other option (endpoints with target_server_type, configure, ssl, ...) selects and opens the
  # same server as the repository.
  @repository_keys ~w(name otp_app repo url pool pool_size pool_count queue_target
                      queue_interval log stacktrace telemetry_prefix telemetry_options
                      migration_source migration_lock migration_primary_key
                      migration_timestamps migration_default_prefix migration_repo priv
                      start_apps_before_migration)a

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

    retry =
      {deadline, Keyword.get(opts, :retry_interval, 500), Keyword.get(opts, :connection, [])}

    case acquire(state, retry) do
      {:ok, conn, backend_pid, epoch} ->
        if state.publish, do: Postgres.put_epoch(epoch)
        Logger.info("took the node lock with epoch #{epoch}")
        {:ok, schedule(%{state | conn: conn, backend_pid: backend_pid, epoch: epoch})}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  # Tries until the deadline both while another node holds the lock and while the database
  # cannot be reached (a restart or failover), on a new connection after a failed one. A failure
  # to raise the epoch releases the lock (closing the connection) and is tried again too.
  defp acquire(%State{instance: instance} = state, {deadline, interval, overrides} = retry) do
    # Each attempt waits at most until the deadline, also on a connection that stalls.
    timeout = max(deadline - System.monotonic_time(:millisecond), 1)

    result =
      case connect(instance, overrides, timeout) do
        {:ok, conn} -> lock(conn, state, timeout)
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, _conn, _backend_pid, _epoch} = acquired ->
        acquired

      failure ->
        if System.monotonic_time(:millisecond) + interval > deadline do
          {:stop, stop_reason(failure)}
        else
          Process.sleep(interval)
          acquire(state, retry)
        end
    end
  end

  defp lock(conn, %State{instance: instance, lock_key: key}, timeout) do
    case try_lock(conn, key, timeout) do
      {:ok, true, backend_pid} ->
        case advance_epoch(instance, conn, timeout) do
          {:ok, epoch} ->
            {:ok, conn, backend_pid, epoch}

          {:error, reason} ->
            close(conn)
            {:error, reason}
        end

      {:ok, false, _backend_pid} ->
        close(conn)
        :held

      {:error, reason} ->
        close(conn)
        {:error, reason}
    end
  end

  defp stop_reason(:held), do: :another_node_holds_the_database
  defp stop_reason({:error, reason}), do: {:node_lock_connection, reason}

  # `max_restarts: 0`: the pool does not replace a lost connection with one that lacks the lock
  # but exits, and this process gets its {:EXIT, conn, _}.
  defp connect(%Postgres{repo: repo}, overrides, timeout) do
    config = Keyword.drop(repo.config(), @repository_keys)
    # Postgrex's defaults: 5 s to connect, 15 s for the handshake.
    connect_timeout = min(Keyword.get(config, :connect_timeout, 5_000), timeout)
    handshake_timeout = min(Keyword.get(config, :handshake_timeout, 15_000), timeout)

    config
    |> Keyword.merge(overrides)
    |> Keyword.merge(
      backoff_type: :stop,
      max_restarts: 0,
      pool_size: 1,
      connect_timeout: connect_timeout,
      handshake_timeout: handshake_timeout,
      queue_target: timeout,
      queue_interval: timeout
    )
    |> Postgrex.start_link()
  end

  # On this connection, so that the attempt is bounded by the deadline and does not wait for the
  # repository's pool to reconnect after an outage.
  defp advance_epoch(instance, conn, timeout) do
    Postgres.advance_epoch(instance, conn, timeout)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp try_lock(conn, key, timeout) do
    sql = "SELECT pg_try_advisory_lock($1), pg_backend_pid()"

    case Postgrex.query(conn, sql, [key], timeout: timeout) do
      {:ok, %{rows: [[held?, backend_pid]]}} -> {:ok, held?, backend_pid}
      {:error, exception} -> {:error, exception}
    end
  catch
    :exit, reason -> {:error, reason}
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

  # Unlinked first, so that its exit does not reach this process later as a lost connection.
  defp close(conn) do
    Process.unlink(conn)
    flush_exit(conn)
    if Process.alive?(conn), do: GenServer.stop(conn, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp flush_exit(conn) do
    receive do
      {:EXIT, ^conn, _reason} -> :ok
    after
      0 -> :ok
    end
  end
end
