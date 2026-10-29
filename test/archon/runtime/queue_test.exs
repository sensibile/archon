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
    start_supervised!(Memory, id: :named)

    assert Memory.push("named", "a", 0, 0) == :ok
    assert Memory.contains?("named", "a")
    assert Memory.size("named") == 1
    assert Memory.pop("named", 1, 0) == ["a"]
    assert Memory.postpone("named", "a", 0, 0) == :ok
    assert Memory.ack("named", "a")
    assert Memory.remove("named", "a") == :ok
  end

  test "a waiting pop whose caller exits is dropped and takes nothing", %{server: server} do
    caller = spawn(fn -> Memory.pop(server, "gone", 1, 5_000) end)
    Process.sleep(50)
    Process.exit(caller, :kill)
    Process.sleep(50)

    Memory.push(server, "gone", "a", 0, 0)
    assert Memory.pop(server, "gone", 1, 0) == ["a"]
  end

  test "the unack timeout is an option", %{advance: advance} do
    offset = :atomics.new(1, [])
    clock = fn -> System.system_time(:millisecond) + :atomics.get(offset, 1) end

    server =
      start_supervised!({Memory, name: nil, clock: clock, unack_timeout: 1_000}, id: :short)

    _ = advance

    Memory.push(server, "q", "a", 0, 0)
    assert Memory.pop(server, "q", 1, 0) == ["a"]
    :atomics.add(offset, 1, 1_000)
    assert Memory.pop(server, "q", 1, 0) == ["a"]
  end
end
