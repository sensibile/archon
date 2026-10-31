# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss postgres-persistence/src/main/java/com/netflix/conductor/postgres/dao/PostgresQueueDAO.java
# and sqlite-persistence/src/main/java/com/netflix/conductor/sqlite/dao/SqliteQueueDAO.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: pops in SqliteQueueDAO order (priority first) instead of PostgresQueueDAO's
# delivery time first; the pop query also takes popped messages whose unack time has passed,
# counted from the pop, instead of a periodic processAllUnacks; times are epoch milliseconds from
# the application clock instead of the database's current_timestamp; every write is fenced by the
# node epoch, and `apply_ops/2` applies a store commit's queue operations in the commit's
# transaction (ADR 0021, decisions 2, 3 and 7).

defmodule Archon.Runtime.Queue.Postgres do
  @moduledoc """
  PostgreSQL `Archon.Runtime.Queue` on the `queue_message` table (ADR 0021, decisions 2 and 3).

  Each function takes an optional first argument, an `Archon.Runtime.Postgres` instance
  (`Archon.Runtime.Postgres.runtime/0` by default); the arities without it are the behaviour
  callbacks.

  A row keeps the message's priority, its delivery time `deliver_on`, a `popped` mark and the
  time `unack_on` a popped message becomes visible again, and a `seq` that orders messages added
  in the same millisecond. A message is visible when it is not popped and `deliver_on` has
  passed, or when it is popped and `unack_on` has passed: there is no sweep like upstream's
  `processAllUnacks`, and the unack timeout (60 seconds) counts from the pop. A pop takes the
  visible rows in `SqliteQueueDAO` order (`priority DESC, deliver_on, seq`) with
  `FOR UPDATE SKIP LOCKED`, so concurrent pops never hand out the same message. With nothing
  visible it asks again every 100 milliseconds until `timeout_ms`, each try its own transaction,
  as upstream's `pollMessages` does; it never holds a transaction while it waits.

  Every time comes from the instance's clock, never the database's `now()`.

  ## Writes

  `push`, `pop`, `ack`, `remove` and `postpone` each run in `Archon.Runtime.Postgres.transaction!/2`,
  so they raise `Archon.Runtime.Postgres.FencedError` when the node epoch is stale (ADR 0021,
  decision 7). `apply_ops/2` is for `Archon.Runtime.Store.Postgres`: it applies a commit's queue
  operations in the caller's transaction, which has already passed the fence.

  Queue names and message IDs are index columns of plain `text`, which cannot hold NUL (as in
  upstream). Adding a message with NUL in either raises `ArgumentError`; the other operations
  treat such a message as absent.
  """

  @behaviour Archon.Runtime.Queue

  alias Archon.Runtime.{Commit, Postgres, Queue}

  @unack_timeout 60_000
  @poll_interval 100

  @impl Queue
  @spec push(Postgres.t(), String.t(), String.t(), integer(), integer()) :: :ok
  def push(instance \\ Postgres.runtime(), queue, id, priority, delay_ms)
      when is_binary(queue) and is_binary(id) and is_integer(priority) and is_integer(delay_ms) do
    check_storable!(queue, id)

    Postgres.transaction!(instance, fn ->
      push_at(instance, queue, id, priority, Postgres.now(instance) + delay_ms)
    end)
  end

  @doc """
  Applies `t:Archon.Runtime.Commit.queue_op/0`s in order inside the caller's transaction, which
  must have passed `Archon.Runtime.Postgres.check_fence/1`; it does not check the fence again.
  Each operation means the callback of the same name with the delay that ends at `deliver_on`.
  Raises `ArgumentError` for a malformed operation or outside a transaction.
  """
  @spec apply_ops(Postgres.t(), [Commit.queue_op()]) :: :ok
  def apply_ops(%Postgres{repo: repo} = instance, ops) when is_list(ops) do
    Enum.each(ops, &check_op!/1)

    unless repo.in_transaction?(),
      do: raise(ArgumentError, "apply_ops/2 must run inside the commit's transaction")

    Enum.each(ops, &apply_op(instance, &1))
  end

  @impl Queue
  @spec pop(Postgres.t(), String.t(), integer(), integer()) :: [String.t()]
  def pop(instance \\ Postgres.runtime(), queue, count, timeout_ms)

  def pop(_instance, queue, count, timeout_ms)
      when is_binary(queue) and is_integer(count) and is_integer(timeout_ms) and count <= 0,
      do: []

  def pop(instance, queue, count, timeout_ms)
      when is_binary(queue) and is_integer(count) and is_integer(timeout_ms) do
    poll(instance, queue, count, monotonic_ms() + max(timeout_ms, 0))
  end

  @impl Queue
  @spec ack(Postgres.t(), String.t(), String.t()) :: boolean()
  def ack(instance \\ Postgres.runtime(), queue, id) when is_binary(queue) and is_binary(id),
    do: Postgres.transaction!(instance, fn -> delete(instance, queue, id) end)

  @impl Queue
  @spec remove(Postgres.t(), String.t(), String.t()) :: :ok
  def remove(instance \\ Postgres.runtime(), queue, id) when is_binary(queue) and is_binary(id) do
    _found? = ack(instance, queue, id)
    :ok
  end

  @impl Queue
  @spec postpone(Postgres.t(), String.t(), String.t(), integer(), integer()) :: :ok
  def postpone(instance \\ Postgres.runtime(), queue, id, priority, delay_ms)
      when is_binary(queue) and is_binary(id) and is_integer(priority) and is_integer(delay_ms) do
    check_storable!(queue, id)

    Postgres.transaction!(instance, fn ->
      postpone_at(instance, queue, id, priority, Postgres.now(instance) + delay_ms)
    end)
  end

  @impl Queue
  @spec contains?(Postgres.t(), String.t(), String.t()) :: boolean()
  def contains?(instance \\ Postgres.runtime(), queue, id)
      when is_binary(queue) and is_binary(id) do
    storable?(queue) and storable?(id) and
      query!(
        instance,
        "SELECT EXISTS (SELECT 1 FROM #{table(instance)} WHERE queue_name = $1 AND message_id = $2)",
        [queue, id]
      ).rows == [[true]]
  end

  @impl Queue
  @spec size(Postgres.t(), String.t()) :: non_neg_integer()
  def size(instance \\ Postgres.runtime(), queue) when is_binary(queue) do
    if storable?(queue) do
      %{rows: [[size]]} =
        query!(instance, "SELECT count(*) FROM #{table(instance)} WHERE queue_name = $1", [queue])

      size
    else
      0
    end
  end

  defp poll(instance, queue, count, deadline) do
    case Postgres.transaction!(instance, fn -> take(instance, queue, count) end) do
      [] ->
        case deadline - monotonic_ms() do
          left when left > 0 ->
            Process.sleep(min(left, @poll_interval))
            poll(instance, queue, count, deadline)

          _passed ->
            []
        end

      ids ->
        ids
    end
  end

  # Pops up to `count` visible messages in SqliteQueueDAO order: priority DESC, deliver_on,
  # created_on (seq). A popped message stays, hidden until the unack timeout.
  defp take(instance, queue, count) do
    if storable?(queue) do
      now = Postgres.now(instance)
      table = table(instance)

      %{rows: rows} =
        query!(
          instance,
          """
          WITH due AS (
            SELECT queue_name, message_id FROM #{table}
            WHERE queue_name = $1
              AND ((NOT popped AND deliver_on <= $2) OR (popped AND unack_on <= $2))
            ORDER BY priority DESC, deliver_on, seq
            LIMIT $3
            FOR UPDATE SKIP LOCKED
          )
          UPDATE #{table} AS m SET popped = true, unack_on = $4
          FROM due
          WHERE m.queue_name = due.queue_name AND m.message_id = due.message_id
          RETURNING m.message_id, m.priority, m.deliver_on, m.seq
          """,
          [queue, now, count, now + @unack_timeout]
        )

      rows
      |> Enum.sort_by(fn [_id, priority, deliver_on, seq] -> {-priority, deliver_on, seq} end)
      |> Enum.map(&hd/1)
    else
      []
    end
  end

  # SqliteQueueDAO#pushMessage: an existing ID only gets the new delivery time and loses its
  # popped mark; its priority and place among equals stay.
  defp push_at(instance, queue, id, priority, deliver_on) do
    query!(
      instance,
      """
      INSERT INTO #{table(instance)} (queue_name, message_id, priority, deliver_on)
      VALUES ($1, $2, $3, $4)
      ON CONFLICT (queue_name, message_id)
      DO UPDATE SET deliver_on = EXCLUDED.deliver_on, popped = false, unack_on = NULL
      """,
      [queue, id, priority, deliver_on]
    )

    :ok
  end

  # QueueDAO#postpone: remove, then push, so the message also goes behind its equals.
  defp postpone_at(instance, queue, id, priority, deliver_on) do
    _found? = delete(instance, queue, id)
    push_at(instance, queue, id, priority, deliver_on)
  end

  defp delete(instance, queue, id) do
    storable?(queue) and storable?(id) and
      query!(
        instance,
        "DELETE FROM #{table(instance)} WHERE queue_name = $1 AND message_id = $2",
        [queue, id]
      ).num_rows > 0
  end

  defp apply_op(instance, {:push, queue, id, priority, at}),
    do: push_at(instance, queue, id, priority, at)

  defp apply_op(instance, {:postpone, queue, id, priority, at}),
    do: postpone_at(instance, queue, id, priority, at)

  defp apply_op(instance, {:remove, queue, id}), do: delete(instance, queue, id)

  defp check_op!({kind, queue, id, priority, at})
       when kind in [:push, :postpone] and is_binary(queue) and is_binary(id) and
              is_integer(priority) and is_integer(at),
       do: check_storable!(queue, id)

  defp check_op!({:remove, queue, id}) when is_binary(queue) and is_binary(id), do: :ok
  defp check_op!(op), do: raise(ArgumentError, "invalid queue operation #{inspect(op)}")

  defp check_storable!(queue, id) do
    unless storable?(queue) and storable?(id) do
      raise ArgumentError,
            "a queue name or message ID cannot contain NUL: #{inspect({queue, id})}"
    end

    :ok
  end

  defp storable?(name), do: not String.contains?(name, <<0>>)

  defp query!(%Postgres{repo: repo}, sql, params), do: repo.query!(sql, params)

  defp table(instance), do: Postgres.table(instance, "queue_message")

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
