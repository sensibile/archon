# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.RecoveryTest do
  @moduledoc """
  `Archon.Runtime.Recovery` and the `rest_for_one` tree (ADR 0018, decisions 1 and 7): running
  workflows are activated again and repair their queue messages.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Runtime.Queue.Memory, as: Queue
  alias Archon.Runtime.Recovery

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
    Queue.remove("archon_task_a", task_id)

    assert Recovery.run() >= 1
    assert WorkflowServer.whereis(running)
    assert WorkflowServer.whereis(terminated) == nil
    eventually(fn -> Queue.contains?("archon_task_a", task_id) end)
  end

  test "a restart of the queue restarts the workflow processes, which refill it" do
    id = start_simple(%{"x" => 1})
    pid = WorkflowServer.whereis(id)
    queue = Process.whereis(Queue)
    task_id = task(id, "task_a_ref").task_id
    assert Queue.contains?("archon_task_a", task_id)

    Process.exit(queue, :kill)

    restarted =
      eventually(fn ->
        Process.whereis(Queue) not in [nil, queue] and WorkflowServer.whereis(id)
      end)

    assert restarted != pid
    refute Process.alive?(pid)
    eventually(fn -> Queue.contains?("archon_task_a", task_id) end)
  end
end
