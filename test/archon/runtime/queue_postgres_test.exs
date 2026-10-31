# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.QueuePostgresTest do
  @moduledoc """
  `Archon.Runtime.Queue.Postgres` against the queue contract and its Postgres cases (ADR 0021,
  decisions 3, 7 and 9).
  """

  use Archon.PostgresCase
  use Archon.Runtime.QueueContract

  alias Archon.Runtime.Postgres.FencedError
  alias Archon.Runtime.Queue.Postgres, as: PgQueue

  setup %{instance: instance} do
    offset = :atomics.new(1, [])
    clock = fn -> System.system_time(:millisecond) + :atomics.get(offset, 1) end
    %{impl: PgQueue, server: %{instance | clock: clock}, advance: &:atomics.add(offset, 1, &1)}
  end

  test "concurrent pops never hand out the same message", %{server: server} do
    ids = for i <- 1..200, do: "m#{i}"
    Enum.each(ids, &PgQueue.push(server, "race", &1, 0, 0))

    pop_all = fn ->
      Stream.repeatedly(fn -> PgQueue.pop(server, "race", 7, 0) end)
      |> Enum.take_while(&(&1 != []))
      |> List.flatten()
    end

    popped =
      1..8
      |> Enum.map(fn _ -> Task.async(pop_all) end)
      |> Enum.flat_map(&Task.await(&1, 30_000))

    assert Enum.sort(popped) == Enum.sort(ids)
  end

  # The memory implementation's case: equal delivery times need a clock that stands still.
  test "equal delivery times pop in the order added, and postpone goes behind", %{
    instance: instance
  } do
    server = %{instance | clock: fn -> 1_000 end}

    for id <- ~w(a b c), do: PgQueue.push(server, "order", id, 0, 0)
    assert PgQueue.pop(server, "order", 3, 0) == ~w(a b c)

    for id <- ~w(a b c), do: PgQueue.postpone(server, "order", id, 0, 0)
    PgQueue.postpone(server, "order", "a", 0, 0)
    PgQueue.push(server, "order", "b", 0, 0)
    assert PgQueue.pop(server, "order", 3, 0) == ~w(b c a)
  end

  test "an unacked message comes back in its place by delivery time", %{server: server} = ctx do
    PgQueue.push(server, "unack", "a", 0, 0)
    assert PgQueue.pop(server, "unack", 1, 0) == ["a"]
    ctx.advance.(1)
    PgQueue.push(server, "unack", "b", 0, 0)
    ctx.advance.(60_000)
    assert PgQueue.pop(server, "unack", 2, 0) == ["a", "b"]
  end

  test "times come from the instance's clock", %{instance: instance} do
    server = %{instance | clock: fn -> 5_000 end}
    PgQueue.push(server, "clock", "a", 3, 250)

    assert Repo.query!("SELECT priority, deliver_on, popped, unack_on FROM #{table(instance)}").rows ==
             [[3, 5_250, false, nil]]

    later = %{instance | clock: fn -> 5_250 end}
    assert PgQueue.pop(later, "clock", 1, 0) == ["a"]

    assert Repo.query!("SELECT popped, unack_on FROM #{table(instance)}").rows == [
             [true, 65_250]
           ]
  end

  describe "apply_ops/2" do
    test "applies the operations in order in the caller's transaction", %{server: server} do
      now = Postgres.now(server)
      PgQueue.push(server, "ops", "old", 0, 0)

      assert Postgres.transaction(server, fn ->
               PgQueue.apply_ops(server, [
                 {:push, "ops", "a", 1, now},
                 {:push, "ops", "b", 5, now + 60_000},
                 {:remove, "ops", "old"},
                 {:postpone, "ops", "b", 9, now},
                 {:remove, "ops", "missing"}
               ])
             end) == {:ok, :ok}

      assert PgQueue.pop(server, "ops", 5, 0) == ["b", "a"]
    end

    test "rolls back with the transaction", %{server: server} do
      PgQueue.push(server, "ops", "old", 0, 0)

      assert Postgres.transaction(server, fn ->
               PgQueue.apply_ops(server, [
                 {:push, "ops", "a", 0, 0},
                 {:remove, "ops", "old"}
               ])

               Postgres.rollback(server, :nope)
             end) == {:error, :nope}

      assert PgQueue.pop(server, "ops", 5, 0) == ["old"]
    end

    test "refuses a list that is not one", %{server: server} do
      assert_raise ArgumentError, fn ->
        Repo.transaction(fn -> PgQueue.apply_ops(server, {:push, "ops", "a", 0, 0}) end)
      end
    end

    test "refuses to run outside a transaction", %{server: server} do
      assert_raise ArgumentError, ~r/inside the commit's transaction/, fn ->
        PgQueue.apply_ops(server, [{:push, "ops", "a", 0, 0}])
      end

      assert PgQueue.size(server, "ops") == 0
    end

    test "refuses malformed operations before writing", %{server: server} do
      for op <- [{:push, "ops", "a", 0}, {:pop, "ops", "a"}, {:remove, "ops", 1}, :push] do
        assert {:error, %ArgumentError{}} =
                 Repo.transaction(fn ->
                   try do
                     PgQueue.apply_ops(server, [{:push, "ops", "first", 0, 0}, op])
                   rescue
                     error in ArgumentError -> Repo.rollback(error)
                   end
                 end)
      end

      assert PgQueue.size(server, "ops") == 0
    end
  end

  describe "the write fence" do
    setup %{server: server} do
      on_exit(&Postgres.clear_epoch/0)
      Postgres.clear_epoch()
      %{fenced: %{server | fence: :runtime}}
    end

    test "every write raises with a stale epoch and changes nothing", ctx do
      %{server: server, fenced: fenced} = ctx
      PgQueue.push(server, "fence", "a", 0, 0)

      for {fun, args} <- [
            push: ["fence", "b", 0, 0],
            pop: ["fence", 1, 0],
            pop: ["fence", 1, 150],
            ack: ["fence", "a"],
            remove: ["fence", "a"],
            postpone: ["fence", "a", 5, 1_000]
          ] do
        assert_raise FencedError, fn -> apply(PgQueue, fun, [fenced | args]) end
      end

      assert Repo.query!(
               "SELECT message_id, priority, deliver_on <= $1, popped FROM #{table(server)}",
               [Postgres.now(server)]
             ).rows == [["a", 0, true, false]]

      # Reads are not fenced.
      assert PgQueue.size(fenced, "fence") == 1
      assert PgQueue.contains?(fenced, "fence", "a")
    end

    test "writes with the published epoch", %{fenced: fenced} do
      {:ok, epoch} = Postgres.advance_epoch(fenced)
      Postgres.put_epoch(epoch)

      assert PgQueue.push(fenced, "fence", "a", 0, 0) == :ok
      assert PgQueue.postpone(fenced, "fence", "a", 1, 0) == :ok
      assert PgQueue.pop(fenced, "fence", 1, 0) == ["a"]
      assert PgQueue.ack(fenced, "fence", "a")
      assert PgQueue.remove(fenced, "fence", "a") == :ok
    end

    test "a waiting pop holds no transaction and is fenced on its next try", %{fenced: fenced} do
      {:ok, epoch} = Postgres.advance_epoch(fenced)
      Postgres.put_epoch(epoch)

      waiting =
        Task.async(fn ->
          try do
            PgQueue.pop(fenced, "fence", 1, 5_000)
          rescue
            error in FencedError -> error
          end
        end)

      Process.sleep(150)
      # The exclusive fence lock waits for every transaction holding the shared one.
      advancer = Task.async(fn -> Postgres.advance_epoch(fenced) end)
      assert Task.await(advancer, 1_000) == {:ok, epoch + 1}
      assert %FencedError{} = Task.await(waiting, 1_000)
    end
  end

  describe "NUL or invalid UTF-8 in a queue name or message ID" do
    test "cannot be added", %{server: server} do
      for {queue, id} <- [{"q\u0000", "a"}, {"q", "a\u0000"}, {<<0xFF>>, "a"}, {"q", <<0xFF>>}] do
        assert_raise ArgumentError, ~r/UTF-8 without NUL/, fn ->
          PgQueue.push(server, queue, id, 0, 0)
        end

        assert_raise ArgumentError, ~r/UTF-8 without NUL/, fn ->
          PgQueue.postpone(server, queue, id, 0, 0)
        end

        assert_raise ArgumentError, ~r/UTF-8 without NUL/, fn ->
          Repo.transaction(fn -> PgQueue.apply_ops(server, [{:push, queue, id, 0, 0}]) end)
        end
      end
    end

    test "is absent everywhere else", %{server: server} do
      PgQueue.push(server, "q", "a", 0, 0)

      refute PgQueue.contains?(server, "q", "a\u0000")
      refute PgQueue.contains?(server, "q\u0000", "a")
      refute PgQueue.contains?(server, "q", <<0xFF>>)
      assert PgQueue.size(server, <<0xFF>>) == 0
      assert PgQueue.size(server, "q\u0000") == 0
      refute PgQueue.ack(server, "q", "a\u0000")
      assert PgQueue.remove(server, "q\u0000", "a") == :ok
      assert PgQueue.pop(server, "q\u0000", 1, 0) == []

      assert Repo.transaction(fn -> PgQueue.apply_ops(server, [{:remove, "q", "a\u0000"}]) end) ==
               {:ok, :ok}

      assert PgQueue.size(server, "q") == 1
    end
  end

  defp table(instance), do: Postgres.table(instance, "queue_message")
end
