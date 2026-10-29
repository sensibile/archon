# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss sqlite-persistence/src/test/java/com/netflix/conductor/sqlite/dao/SqliteQueueDAOTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: ported to ExUnit as a shared contract for every `Archon.Runtime.Queue`
# implementation (ADR 0018, decision 10); time moves by an injected clock instead of sleeping, and
# cases for priority order, postpone and unack timeouts were added.

defmodule Archon.Runtime.QueueContract do
  @moduledoc """
  Shared cases for `Archon.Runtime.Queue` implementations (ADR 0018, decision 10).

      defmodule MyQueueTest do
        use ExUnit.Case, async: true
        use Archon.Runtime.QueueContract

        setup do
          %{impl: MyQueue, server: ..., advance: fn ms -> ... end}
        end
      end

  The setup gives:

    * `:impl` - the module under test. Every callback is called as `impl.fun(server, args...)`.
    * `:server` - the instance under test, empty at the start of each case.
    * `:advance` - a function moving the implementation's clock forward by some milliseconds. The
      clock must also move with real time, as waiting pops are checked against real time.

  The unack timeout must be the upstream default, 60 seconds.
  """

  defmacro __using__(_opts) do
    quote do
      unquote(helpers())
      unquote(pop_cases())
      unquote(contains_cases())
      unquote(timing_cases())
    end
  end

  defp helpers do
    quote do
      defp q(ctx, fun, args), do: apply(ctx.impl, fun, [ctx.server | args])

      defp push_all(ctx, queue, ids, delay \\ 0),
        do: Enum.each(ids, &q(ctx, :push, [queue, &1, 0, delay]))
    end
  end

  defp pop_cases do
    quote do
      describe "Queue contract: pop and ack" do
        # SqliteQueueDAOTest#complexQueueTest (pushIfNotExists, queuesDetail and flush are not
        # part of the behaviour).
        test "push, pop, ack, contains? and remove", ctx do
          ids = for i <- 0..9, do: "msg#{i}"
          push_all(ctx, "TestQueue", ids)
          assert q(ctx, :size, ["TestQueue"]) == 10

          popped = q(ctx, :pop, ["TestQueue", 10, 100])
          assert Enum.sort(popped) == Enum.sort(ids)
          # Popped but not acked messages still count.
          assert q(ctx, :size, ["TestQueue"]) == 10

          Enum.each(popped, &assert(q(ctx, :ack, ["TestQueue", &1])))
          assert q(ctx, :size, ["TestQueue"]) == 0
          assert q(ctx, :pop, ["TestQueue", 10, 100]) == []

          push_all(ctx, "TestQueue", ids)
          assert q(ctx, :size, ["TestQueue"]) == 10

          for id <- ids do
            assert q(ctx, :contains?, ["TestQueue", id])
            assert q(ctx, :remove, ["TestQueue", id]) == :ok
          end

          assert q(ctx, :size, ["TestQueue"]) == 0
        end

        # SqliteQueueDAOTest#pollMessagesReturnsPromptlyWhenFewerThanCountAvailable
        test "pop returns at once when fewer than count are visible", ctx do
          q(ctx, :push, ["issue142_testQueue", "issue142-msg-0", 0, 0])
          {elapsed, popped} = :timer.tc(fn -> q(ctx, :pop, ["issue142_testQueue", 5, 10_000]) end)
          assert popped == ["issue142-msg-0"]
          assert elapsed < 5_000_000
        end

        # SqliteQueueDAOTest#pollMessagesReturnsImmediatelyWhenCountIsZero
        test "pop with count 0 returns [] at once", ctx do
          q(ctx, :push, ["issue142_zeroCountQueue", "issue142-msg-0", 0, 0])

          {elapsed, popped} =
            :timer.tc(fn -> q(ctx, :pop, ["issue142_zeroCountQueue", 0, 10_000]) end)

          assert popped == []
          assert elapsed < 5_000_000
          assert q(ctx, :size, ["issue142_zeroCountQueue"]) == 1
        end

        # SqliteQueueDAOTest#pollMessagesTest, plus the order the POP_QUERY gives.
        test "pop takes higher priorities first and leaves the rest", ctx do
          queue = "issue399_testQueue"

          for i <- 0..9 do
            priority = if rem(i, 2) == 0, do: 99 - i, else: 0
            q(ctx, :push, [queue, "testmsg-#{i}", priority, 0])
          end

          assert q(ctx, :size, [queue]) == 10
          assert q(ctx, :pop, [queue, 0, 10_000]) == []
          assert q(ctx, :pop, [queue, 3, 10_000]) == ["testmsg-0", "testmsg-2", "testmsg-4"]

          assert [first, second, third, fourth] = q(ctx, :pop, [queue, 4, 10_000])
          assert [first, second] == ["testmsg-6", "testmsg-8"]

          assert Enum.all?(
                   [third, fourth],
                   &(&1 in ~w(testmsg-1 testmsg-3 testmsg-5 testmsg-7 testmsg-9))
                 )

          assert q(ctx, :size, [queue]) == 10
          assert length(q(ctx, :pop, [queue, 10, 0])) == 3
        end
      end
    end
  end

  defp contains_cases do
    quote do
      describe "Queue contract: contains? and delays" do
        # SqliteQueueDAOTest#containsMessageTest
        test "contains? is false after remove", ctx do
          ids = for i <- 0..9, do: "msg#{i}"
          push_all(ctx, "TestQueue", ids)

          for id <- ids do
            assert q(ctx, :contains?, ["TestQueue", id])
            q(ctx, :remove, ["TestQueue", id])
          end

          refute Enum.any?(ids, &q(ctx, :contains?, ["TestQueue", &1]))
        end

        # SqliteQueueDAOTest#pollDeferredMessagesTest
        test "delayed messages become visible after their delay", ctx do
          queue = "issue448_testQueue"

          for i <- 0..9 do
            delay =
              cond do
                i < 5 -> 0
                i in [6, 7] -> 5_000
                true -> (10_000 + i) * 1_000
              end

            q(ctx, :push, [queue, "testmsg-#{i}", 0, delay])
          end

          assert q(ctx, :size, [queue]) == 10
          first = q(ctx, :pop, [queue, 4, 100])
          assert length(first) == 4
          assert Enum.all?(first, &(&1 in ~w(testmsg-0 testmsg-1 testmsg-2 testmsg-3 testmsg-4)))

          ctx.advance.(5_000)
          second = q(ctx, :pop, [queue, 13, 100])

          assert Enum.sort(second) ==
                   Enum.sort(
                     ~w(testmsg-0 testmsg-1 testmsg-2 testmsg-3 testmsg-4 testmsg-6 testmsg-7) --
                       first
                   )

          assert q(ctx, :size, [queue]) == 10
        end
      end
    end
  end

  defp timing_cases do
    quote do
      describe "Queue contract: timing" do
        # SqliteQueueDAO#processAllUnacks: popped messages that are not acked come back.
        test "an unacked message becomes visible again after the unack timeout", ctx do
          q(ctx, :push, ["unack", "a", 0, 0])
          q(ctx, :push, ["unack", "b", 0, 0])
          assert q(ctx, :pop, ["unack", 2, 0]) == ["a", "b"]
          assert q(ctx, :ack, ["unack", "b"])

          ctx.advance.(58_000)
          assert q(ctx, :pop, ["unack", 2, 0]) == []
          ctx.advance.(2_000)
          assert q(ctx, :pop, ["unack", 2, 0]) == ["a"]
          assert q(ctx, :pop, ["unack", 2, 0]) == []
        end

        test "ack and remove of a missing message", ctx do
          refute q(ctx, :ack, ["missing", "a"])
          assert q(ctx, :remove, ["missing", "a"]) == :ok
          refute q(ctx, :contains?, ["missing", "a"])
          assert q(ctx, :size, ["missing"]) == 0
        end

        # SqliteQueueDAO#pushMessage: UPDATE ... SET deliver_on = now + offset, popped = false.
        test "pushing an existing ID resets its delay and popped mark but keeps its priority",
             ctx do
          q(ctx, :push, ["repush", "a", 5, 0])
          assert q(ctx, :pop, ["repush", 1, 0]) == ["a"]

          q(ctx, :push, ["repush", "a", 0, 1_000])
          assert q(ctx, :size, ["repush"]) == 1
          assert q(ctx, :pop, ["repush", 1, 0]) == []

          q(ctx, :push, ["repush", "b", 1, 0])
          ctx.advance.(1_000)
          assert q(ctx, :pop, ["repush", 2, 0]) == ["a", "b"]
        end

        # QueueDAO#postpone: remove, then push with the new priority and delay.
        test "postpone hides the message for the delay with the new priority", ctx do
          q(ctx, :push, ["postpone", "a", 9, 0])
          q(ctx, :push, ["postpone", "b", 5, 0])
          assert q(ctx, :pop, ["postpone", 1, 0]) == ["a"]

          assert q(ctx, :postpone, ["postpone", "a", 1, 10_000]) == :ok
          assert q(ctx, :size, ["postpone"]) == 2
          ctx.advance.(5_000)
          assert q(ctx, :pop, ["postpone", 2, 0]) == ["b"]

          q(ctx, :ack, ["postpone", "b"])
          q(ctx, :push, ["postpone", "c", 2, 0])
          ctx.advance.(5_000)
          assert q(ctx, :pop, ["postpone", 2, 0]) == ["c", "a"]
        end

        test "postpone of a missing message adds it", ctx do
          q(ctx, :postpone, ["postpone", "a", 0, 0])
          assert q(ctx, :contains?, ["postpone", "a"])
        end

        # POP_QUERY: ORDER BY priority DESC, deliver_on, created_on.
        test "equal priorities pop by visible time, then by the order they were added", ctx do
          q(ctx, :push, ["order", "late", 0, 2_000])
          q(ctx, :push, ["order", "early", 0, 1_000])
          q(ctx, :push, ["order", "first", 0, 3_000])
          q(ctx, :push, ["order", "second", 0, 3_000])
          ctx.advance.(3_000)
          assert q(ctx, :pop, ["order", 4, 0]) == ["early", "late", "first", "second"]
        end

        test "postpone puts the message behind its equals", ctx do
          q(ctx, :push, ["order", "a", 0, 0])
          q(ctx, :push, ["order", "b", 0, 0])
          ctx.advance.(1)
          q(ctx, :postpone, ["order", "a", 0, 0])
          assert q(ctx, :pop, ["order", 2, 0]) == ["b", "a"]
        end

        test "queues are independent", ctx do
          q(ctx, :push, ["one", "a", 0, 0])
          q(ctx, :push, ["two", "a", 0, 0])
          assert q(ctx, :pop, ["one", 5, 0]) == ["a"]
          q(ctx, :ack, ["one", "a"])
          assert q(ctx, :contains?, ["two", "a"])
          assert q(ctx, :pop, ["two", 5, 0]) == ["a"]
        end

        test "a waiting pop answers when a message is pushed", ctx do
          waiting = Elixir.Task.async(fn -> q(ctx, :pop, ["wait", 3, 5_000]) end)
          Process.sleep(50)
          q(ctx, :push, ["wait", "a", 0, 0])
          assert Elixir.Task.await(waiting, 6_000) == ["a"]
        end

        test "a waiting pop answers when a delayed message becomes visible", ctx do
          q(ctx, :push, ["wait", "a", 0, 100])
          {elapsed, popped} = :timer.tc(fn -> q(ctx, :pop, ["wait", 1, 5_000]) end)
          assert popped == ["a"]
          assert elapsed < 4_000_000
        end

        test "a waiting pop answers [] at its timeout", ctx do
          q(ctx, :push, ["wait", "a", 0, 60_000])
          {elapsed, popped} = :timer.tc(fn -> q(ctx, :pop, ["wait", 1, 100]) end)
          assert popped == []
          assert elapsed >= 100_000
          assert q(ctx, :contains?, ["wait", "a"])
        end
      end
    end
  end
end
