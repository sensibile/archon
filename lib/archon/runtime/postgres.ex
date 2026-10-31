# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Postgres do
  @moduledoc """
  An instance of the Postgres implementations of `Archon.Runtime.Store`, `Archon.Runtime.Queue`
  and `Archon.Runtime.Metadata`, and the write fencing they share (ADR 0021, decisions 1 and 7).

  Like the memory implementations, each Postgres function takes the instance as an optional
  first argument; the arities without it are the behaviour callbacks and use the runtime
  instance. The fields are:

    * `:repo` - the `Ecto.Repo`, `Archon.Repo` by default.
    * `:prefix` - the Postgres schema holding the tables: `runtime_prefix/0` for the runtime and
      `contract_prefix/0` for the contract tests, so the runtime never touches contract rows.
    * `:clock` - a zero-arity function returning epoch milliseconds, `Archon.Runtime.now/0` by
      default. Every stored time (delivery, unack, wake) comes from it, not from the database's
      `now()`, so a test that injects a clock controls queue visibility.
    * `:fence` - `:runtime` checks every write transaction against the node epoch (see
      `check_fence/1`); `nil` (the contract tests) skips the check.

  ## Write fencing

  Only one node may write (ADR 0021, decision 7). `Archon.Runtime.Postgres.NodeLock` holds a
  session advisory lock on `node_lock_key/0` and, right after taking it, raises the epoch in the
  one-row `node_lease` table with `advance_epoch/1` and publishes it with `put_epoch/1`. Every
  write transaction then begins with `check_fence/1`, which takes the shared transaction lock on
  `fence_key/0` and reads the epoch in a second statement: under READ COMMITTED each statement
  takes its own snapshot, so the read sees an epoch raised by a node that held the exclusive
  lock while this transaction waited. A write whose epoch is stale rolls back with
  `{:error, :fenced}`. The fence key differs from the node lock key, or the node lock's session
  lock would block every shared lock.
  """

  defstruct repo: Archon.Repo,
            prefix: "public",
            clock: &Archon.Runtime.now/0,
            fence: nil

  @type t :: %__MODULE__{
          repo: module(),
          prefix: String.t(),
          clock: (-> integer()),
          fence: :runtime | nil
        }

  # "Archon" in ASCII followed by a counter: fixed 64-bit advisory lock keys.
  @node_lock_key 0x417263686F6E_0001
  @fence_key 0x417263686F6E_0002

  @epoch_key {__MODULE__, :epoch}

  @doc """
  Builds an instance. `:prefix` must be a plain lower-case Postgres identifier because it is
  written into SQL text.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    instance = struct!(__MODULE__, opts)
    _quoted = quote_identifier(instance.prefix)

    unless instance.fence in [:runtime, nil] do
      raise ArgumentError,
            "expected :fence to be :runtime or nil, got: #{inspect(instance.fence)}"
    end

    instance
  end

  @doc """
  The runtime instance: the runtime schema, `Archon.Runtime.now/0` and the write fence. The
  behaviour arities of the Postgres implementations use it.
  """
  @spec runtime() :: t()
  def runtime, do: %__MODULE__{fence: :runtime}

  @doc "The Postgres schema of the runtime's tables."
  @spec runtime_prefix() :: String.t()
  def runtime_prefix, do: "public"

  @doc "The Postgres schema of the contract tests' tables (ADR 0021, decision 9)."
  @spec contract_prefix() :: String.t()
  def contract_prefix, do: "archon_contract"

  @doc "The session advisory lock key of `Archon.Runtime.Postgres.NodeLock`."
  @spec node_lock_key() :: 0x417263686F6E_0001
  def node_lock_key, do: @node_lock_key

  @doc "The transaction advisory lock key of the write fence."
  @spec fence_key() :: 0x417263686F6E_0002
  def fence_key, do: @fence_key

  @doc "The current time in epoch milliseconds from the instance's clock."
  @spec now(t()) :: integer()
  def now(%__MODULE__{clock: clock}), do: clock.()

  @doc ~S"""
  The schema-qualified, quoted name of `table` for SQL text: `"public"."workflow"`.
  """
  @spec table(t(), String.t()) :: String.t()
  def table(%__MODULE__{prefix: prefix}, table),
    do: quote_identifier(prefix) <> "." <> quote_identifier(table)

  @doc """
  Quotes a Postgres identifier for SQL text. Only plain lower-case identifiers (letters, digits
  and `_`, not starting with a digit, at most 63 bytes) are accepted; anything else raises.
  """
  @spec quote_identifier(String.t()) :: String.t()
  def quote_identifier(name) when is_binary(name) do
    if name =~ ~r/\A[a-z_][a-z0-9_]{0,62}\z/ do
      ~s("#{name}")
    else
      raise ArgumentError, "invalid Postgres identifier: #{inspect(name)}"
    end
  end

  @doc """
  Runs `fun` in a transaction that begins with `check_fence/1`.

  Returns `{:ok, value}` with `fun`'s result, `{:error, :fenced}` when the fence check fails, or
  `{:error, reason}` when `fun` calls `rollback/2`. Exceptions and exits from `fun` roll the
  transaction back and propagate.

  Do not nest it in another transaction: the fence must run first in the outer transaction, so
  code that opens its own (a `Store.commit/2` with queue writes) calls `check_fence/1` first
  instead.
  """
  @spec transaction(t(), (-> value)) :: {:ok, value} | {:error, term()} when value: term()
  def transaction(%__MODULE__{repo: repo} = instance, fun) when is_function(fun, 0) do
    repo.transaction(fn ->
      case check_fence(instance) do
        :ok -> fun.()
        {:error, :fenced} -> repo.rollback(:fenced)
      end
    end)
  end

  @doc """
  Like `transaction/2`, for writes whose callers cannot take an error tuple (the queue and
  metadata callbacks): returns `fun`'s result and raises `Archon.Runtime.Postgres.FencedError`
  when the fence check fails, which the runtime's exception isolation handles (ADR 0021,
  decision 7). `fun` must not call `rollback/2`: any other rollback raises `ArgumentError`.
  """
  @spec transaction!(t(), (-> value)) :: value when value: term()
  def transaction!(%__MODULE__{} = instance, fun) do
    case transaction(instance, fun) do
      {:ok, value} -> value
      {:error, :fenced} -> raise __MODULE__.FencedError
      {:error, reason} -> raise ArgumentError, "transaction!/2 got a rollback: #{inspect(reason)}"
    end
  end

  @doc "Rolls back the transaction `transaction/2` is running with `{:error, reason}`."
  @spec rollback(t(), term()) :: no_return()
  def rollback(%__MODULE__{repo: repo}, reason), do: repo.rollback(reason)

  @doc """
  The write fence (ADR 0021, decision 7). Call it only inside a transaction, before any other
  statement: `transaction/2` does. Outside a transaction the lock ends with its statement and
  fences nothing. With `fence: nil` it does nothing.

  With `fence: :runtime` it first sets the transaction to READ COMMITTED (the epoch read needs
  its own snapshot even when the server default is stricter, and the setting fails loudly if a
  statement already ran), takes `pg_advisory_xact_lock_shared` on `fence_key/0` and then, in a
  separate statement, reads the epoch in `node_lease`. It returns `{:error, :fenced}` when that
  epoch differs from the one `put_epoch/1` published, or when none was published.
  """
  @spec check_fence(t()) :: :ok | {:error, :fenced}
  def check_fence(%__MODULE__{fence: nil}), do: :ok

  def check_fence(%__MODULE__{fence: :runtime, repo: repo} = instance) do
    repo.query!("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
    repo.query!("SELECT pg_advisory_xact_lock_shared($1)", [@fence_key])

    %{rows: [[epoch]]} =
      repo.query!("SELECT epoch FROM #{table(instance, "node_lease")} WHERE id = 1")

    if epoch == epoch(), do: :ok, else: {:error, :fenced}
  end

  @doc """
  Raises the epoch in `node_lease` under the exclusive transaction lock on `fence_key/0` and
  returns it. The exclusive lock waits for every write transaction holding the shared lock, and
  a write that starts after it reads the new epoch, so once this returns no write of an older
  epoch can commit. `Archon.Runtime.Postgres.NodeLock` calls it after taking the node lock.
  """
  @spec advance_epoch(t()) :: {:ok, pos_integer()}
  def advance_epoch(%__MODULE__{repo: repo} = instance) do
    repo.transaction(fn ->
      repo.query!("SELECT pg_advisory_xact_lock($1)", [@fence_key])

      %{rows: [[epoch]]} =
        repo.query!(
          "UPDATE #{table(instance, "node_lease")} SET epoch = epoch + 1 WHERE id = 1 RETURNING epoch"
        )

      epoch
    end)
  end

  @doc "Publishes this node's epoch for `check_fence/1`."
  @spec put_epoch(pos_integer()) :: :ok
  def put_epoch(epoch) when is_integer(epoch) and epoch > 0,
    do: :persistent_term.put(@epoch_key, epoch)

  @doc "This node's published epoch, `nil` before `put_epoch/1`."
  @spec epoch() :: pos_integer() | nil
  def epoch, do: :persistent_term.get(@epoch_key, nil)

  @doc "Withdraws the published epoch, so `check_fence/1` fences every runtime write."
  @spec clear_epoch() :: :ok
  def clear_epoch do
    _erased = :persistent_term.erase(@epoch_key)
    :ok
  end
end
