# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.QueueTest do
  use ExUnit.Case, async: true
  use Archon.Runtime.QueueContract

  alias Archon.Runtime.Queue.Memory

  setup do
    offset = :atomics.new(1, [])
    clock = fn -> System.system_time(:millisecond) + :atomics.get(offset, 1) end
    server = start_supervised!({Memory, name: nil, clock: clock})
    %{impl: Memory, server: server, advance: &:atomics.add(offset, 1, &1)}
  end

  test "the behaviour arities use the server named after the module" do
    # 3c starts the named instance under Archon.Runtime.Supervisor; use it when it is there.
    unless Process.whereis(Memory), do: start_supervised!(Memory, id: :named)

    assert Memory.push("queue-test-named", "a", 0, 0) == :ok
    assert Memory.contains?("queue-test-named", "a")
    assert Memory.size("queue-test-named") == 1
    assert Memory.pop("queue-test-named", 1, 0) == ["a"]
    assert Memory.postpone("queue-test-named", "a", 0, 0) == :ok
    assert Memory.ack("queue-test-named", "a")
    assert Memory.remove("queue-test-named", "a") == :ok
  end

  test "a waiting pop whose caller exits is dropped and takes nothing", %{server: server} do
    caller = spawn(fn -> Memory.pop(server, "gone", 1, 5_000) end)
    Process.sleep(50)
    Process.exit(caller, :kill)
    Process.sleep(50)

    Memory.push(server, "gone", "a", 0, 0)
    assert Memory.pop(server, "gone", 1, 0) == ["a"]
  end

  test "the unack timeout is an option" do
    offset = :atomics.new(1, [])
    clock = fn -> System.system_time(:millisecond) + :atomics.get(offset, 1) end

    server =
      start_supervised!({Memory, name: nil, clock: clock, unack_timeout: 1_000}, id: :short)

    Memory.push(server, "q", "a", 0, 0)
    assert Memory.pop(server, "q", 1, 0) == ["a"]
    :atomics.add(offset, 1, 1_000)
    assert Memory.pop(server, "q", 1, 0) == ["a"]
  end

  test "waiting pops are served in arrival order", ctx do
    first = Elixir.Task.async(fn -> Memory.pop(ctx.server, "wait", 1, 5_000) end)
    Process.sleep(50)
    second = Elixir.Task.async(fn -> Memory.pop(ctx.server, "wait", 1, 5_000) end)
    Process.sleep(50)
    Memory.push(ctx.server, "wait", "a", 0, 0)
    assert Elixir.Task.await(first, 6_000) == ["a"]
    Memory.push(ctx.server, "wait", "b", 0, 0)
    assert Elixir.Task.await(second, 6_000) == ["b"]
  end

  test "a waiting pop gets a message that became visible before a newer pop", ctx do
    Memory.push(ctx.server, "wait", "a", 0, 60_000)
    first = Elixir.Task.async(fn -> Memory.pop(ctx.server, "wait", 1, 5_000) end)
    Process.sleep(50)
    ctx.advance.(60_000)
    assert Memory.pop(ctx.server, "wait", 1, 0) == []
    assert Elixir.Task.await(first, 6_000) == ["a"]
  end
end
