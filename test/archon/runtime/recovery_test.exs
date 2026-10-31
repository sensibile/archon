# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.RecoveryTest do
  @moduledoc """
  `Archon.Runtime.Recovery` and the `rest_for_one` tree (ADR 0018, decisions 1 and 7): running
  workflows are activated again and repair their queue messages. With `:due` (the Postgres
  backend, ADR 0021, decision 6) only the due running workflows and those with outbox entries
  are activated.
  """

  use Archon.RuntimeCase

  alias Archon.Runtime.Queue.Memory, as: QueueMemory

  @moduletag :capture_log

  alias Archon.Runtime.Commit
  alias Archon.Runtime.{Recovery, Waker}

  defp stop_process(id),
    do:
      :ok =
        DynamicSupervisor.terminate_child(
          Archon.Runtime.WorkflowSupervisor,
          WorkflowServer.whereis(id)
        )

  test "activates the running workflows of the store and not the terminal ones" do
    running = start_simple(%{"x" => 1})
    terminated = start_simple(%{"x" => 2})
    assert Runtime.terminate_workflow(terminated, "r") == :ok
    await_down(terminated)

    :ok =
      DynamicSupervisor.terminate_child(
        Archon.Runtime.WorkflowSupervisor,
        WorkflowServer.whereis(running)
      )

    task_id = task(running, "task_a_ref").task_id
    Runtime.queue().remove("archon_task_a", task_id)

    assert Recovery.run(:all) >= 1
    assert WorkflowServer.whereis(running)
    assert WorkflowServer.whereis(terminated) == nil
    eventually(fn -> Runtime.queue().contains?("archon_task_a", task_id) end)
  end

  # The memory queue is a process of its own; the Postgres one is a table of the store.
  @tag backend: :memory
  test "a restart of the queue restarts the workflow processes, which refill it" do
    id = start_simple(%{"x" => 1})
    pid = WorkflowServer.whereis(id)
    queue = Process.whereis(QueueMemory)
    task_id = task(id, "task_a_ref").task_id
    assert Runtime.queue().contains?("archon_task_a", task_id)

    Process.exit(queue, :kill)

    restarted =
      eventually(fn ->
        Process.whereis(QueueMemory) not in [nil, queue] and WorkflowServer.whereis(id)
      end)

    assert restarted != pid
    refute Process.alive?(pid)
    eventually(fn -> Runtime.queue().contains?("archon_task_a", task_id) end)
  end

  test "with :due, activates the due running workflows and those with outbox entries only" do
    RuntimeHooks.install(clock: 1_700_000_000_000)
    :ok = :sys.suspend(Waker)
    on_exit(fn -> with(pid when is_pid(pid) <- Process.whereis(Waker), do: :sys.resume(pid)) end)

    due = start_simple(%{"x" => 1})
    RuntimeHooks.advance(60_000)
    later = start_simple(%{"x" => 2})
    paused = start_simple(%{"x" => 3})
    assert Runtime.Lifecycle.pause(paused) == :ok
    ended = start_simple(%{"x" => 4})
    assert Runtime.terminate_workflow(ended, "r") == :ok
    await_down(ended)
    missing = "archon-recovery-missing-" <> Runtime.new_id()
    :ok = Runtime.store().commit(ended, %Commit{outbox: [{:retry_sub_workflow, missing}]})
    for id <- [due, later, paused], do: stop_process(id)

    assert Recovery.run(:due) >= 2
    assert WorkflowServer.whereis(due)
    assert WorkflowServer.whereis(later) == nil
    assert WorkflowServer.whereis(paused) == nil
    assert eventually(fn -> Runtime.store().pending_outbox(ended) == [] end)
  end
end
