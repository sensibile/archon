# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.StoreTest do
  use ExUnit.Case, async: true
  use Archon.Runtime.StoreContract

  alias Archon.Runtime.Queue.Memory, as: QueueMemory
  alias Archon.Runtime.Store.Memory

  setup do
    offset = :atomics.new(1, [])
    now = fn -> 1_000_000 + :atomics.get(offset, 1) end
    queue = start_supervised!({QueueMemory, name: nil, clock: now})

    %{
      impl: Memory,
      server: start_supervised!({Memory, name: nil, queue: queue}),
      queue_impl: QueueMemory,
      queue: queue,
      now: now,
      advance: &:atomics.add(offset, 1, &1)
    }
  end

  test "the behaviour arities use the server named after the module" do
    # 3c starts the named instance under Archon.Runtime.Supervisor; use it when it is there.
    unless Process.whereis(Memory), do: start_supervised!(Memory, id: :named)
    wf = %Workflow{workflow_id: "store-test-named", status: :running}

    assert Memory.commit("store-test-named", %Commit{create: wf}) == :ok
    assert Memory.get_workflow("store-test-named", false) == {:ok, wf}
    assert Memory.get_task("none") == {:error, :not_found}
    assert "store-test-named" in Memory.running_workflow_ids()
    assert Memory.in_progress_count("store-test-task") == 0
    assert Memory.put_poll_data("store-test-task", nil, "w", 1) == :ok
    assert {:ok, %{worker_id: "w"}} = Memory.get_poll_data("store-test-task", nil)
    assert Memory.pending_outbox("store-test-named") == []
    assert Memory.ack_outbox("store-test-named", [1]) == :ok
    assert is_list(Memory.outbox_workflow_ids(nil, 10))
    # The shared store may hold many running workflows; start the page just before this one.
    assert Memory.due_workflow_ids(0, {0, "store-test-name"}, 1) == [{0, "store-test-named"}]
    assert Memory.remove_workflow("store-test-named") == :ok
  end

  test "a commit whose queue call exits is not applied and the caller exits" do
    queue = start_supervised!({QueueMemory, name: nil}, id: :doomed)
    store = start_supervised!({Memory, name: nil, queue: queue}, id: :store_of_doomed)
    stop_supervised!(:doomed)

    commit = %Commit{create: %Workflow{workflow_id: "wf1", status: :running}}
    assert Memory.commit(store, "wf1", commit) == :ok

    failing = %Commit{
      workflow: %Workflow{workflow_id: "wf1", status: :completed},
      outbox: [{:retry_sub_workflow, "c"}],
      queue: [{:push, "q", "a", 0, 0}]
    }

    assert {:noproc, _} = catch_exit(Memory.commit(store, "wf1", failing))
    assert {:ok, %Workflow{status: :running}} = Memory.get_workflow(store, "wf1", false)
    assert Memory.pending_outbox(store, "wf1") == []
    assert Process.alive?(store)
  end

  test "malformed new commit fields are refused in the caller", %{server: store} do
    Memory.commit(store, "wf1", %Commit{create: %Workflow{workflow_id: "wf1", status: :running}})

    for bad <- [
          %Commit{queue: [{:push, "q", "a", 0}]},
          %Commit{queue: :nope},
          %Commit{wake: {:at, nil}},
          %Commit{limits: %{"a" => 0}},
          %Commit{outbox_ack: [0]}
        ] do
      assert_raise ArgumentError, fn -> Memory.commit(store, "wf1", bad) end
    end

    assert Process.alive?(store)
  end
end
