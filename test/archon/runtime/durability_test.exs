# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.DurabilityTest do
  @moduledoc """
  The Postgres backend outlives the runtime (ADR 0021, decision 9, slice 4h): stopping
  `Archon.Runtime.Supervisor` and starting it again stands for a VM restart. Running and waiting
  workflows go on from the database, the due ones are activated when it starts, outbox entries
  left behind run, and the new node lock's epoch fences the writes of the previous one.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log
  @moduletag :postgres
  @moduletag backend: :postgres

  alias Archon.Domain.{Task, TaskResult, Workflow, WorkflowDef}
  alias Archon.Runtime.{Commit, Lifecycle, Postgres, Waker}
  alias Archon.Runtime.Postgres.NodeLock

  @t0 1_700_000_000_000

  @child ~S"""
  {"name": "durability_child", "version": 1, "tasks": [
    {"name": "archon_task_a", "taskReferenceName": "t1", "type": "SIMPLE", "inputParameters": {}}]}
  """

  @parent ~S"""
  {"name": "durability_parent", "version": 1, "tasks": [
    {"name": "durability_sub", "taskReferenceName": "st", "type": "SUB_WORKFLOW",
     "inputParameters": {}, "subWorkflowParam": {"name": "durability_child", "version": 1},
     "retryCount": 0}]}
  """

  setup do
    for json <- [@child, @parent] do
      {:ok, definition} = json |> JSON.decode!() |> WorkflowDef.from_json()
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

    :ok
  end

  # Stops the runtime tree, Repo and node lock included, and starts it again.
  defp restart_runtime do
    :ok = Supervisor.terminate_child(Archon.Supervisor, Archon.Runtime.Supervisor)
    refute Process.whereis(Archon.Repo)
    {:ok, _pid} = Supervisor.restart_child(Archon.Supervisor, Archon.Runtime.Supervisor)
    :ok
  end

  defp workflow(id) do
    {:ok, workflow} = Runtime.get_workflow(id)
    workflow
  end

  defp await_status(id, status),
    do: eventually(fn -> match?(%Workflow{status: ^status}, workflow(id)) and workflow(id) end)

  defp complete(id, task_id) do
    WorkflowServer.update(%TaskResult{
      workflow_instance_id: id,
      task_id: task_id,
      status: :completed
    })
  end

  test "a running workflow goes on after a restart: its queued task is polled and completed" do
    id = start_simple(%{"x" => 1})
    a = task(id, "task_a_ref")

    restart_runtime()

    # Other tests' tasks of the type may be queued too, so this workflow's task is polled by ID.
    assert Runtime.queue().contains?("archon_task_a", a.task_id)
    assert WorkflowServer.whereis(id) == nil
    assert %Task{status: :in_progress} = WorkflowServer.poll(id, a.task_id, "w")
    assert %Task{status: :completed} = complete(id, a.task_id)
    assert %Task{status: :scheduled} = task(id, "task_b_ref")
    assert Runtime.queue().contains?("archon_task_b", task(id, "task_b_ref").task_id)
  end

  test "the start activates the due workflows only, and a request the others" do
    RuntimeHooks.install(clock: @t0)
    due = start_simple(%{"x" => 1})
    RuntimeHooks.advance(60_000)
    waiting = start_simple(%{"x" => 2})
    paused = start_simple(%{"x" => 3})
    :ok = Lifecycle.pause(paused)

    restart_runtime()
    :ok = :sys.suspend(Waker)
    on_exit(fn -> with(pid when is_pid(pid) <- Process.whereis(Waker), do: :sys.resume(pid)) end)

    assert eventually(fn -> WorkflowServer.whereis(due) end)
    assert WorkflowServer.whereis(waiting) == nil
    assert WorkflowServer.whereis(paused) == nil

    # A request activates the waiting workflow; resuming the paused one activates it too.
    assert %Task{status: :in_progress} =
             WorkflowServer.poll(waiting, task(waiting, "task_a_ref").task_id, "w")

    assert :ok = Lifecycle.resume(paused)
    assert %Workflow{status: :running} = workflow(paused)
  end

  test "an outbox entry left by a runner that never acked it runs after the restart" do
    {:ok, parent} = Runtime.start_workflow(%{name: "durability_parent", input: %{}})
    child = eventually(fn -> Task.sub_workflow_id(task(parent, "st")) end)
    t1 = eventually(fn -> task(child, "t1") end)

    # The child's notice to its parent fails every time until the restart.
    RuntimeHooks.install(
      hook: fn
        :outbox, ^child, _entry -> raise "parent unreachable"
        _point, _id, _data -> :ok
      end
    )

    assert %Task{status: :in_progress} = WorkflowServer.poll(child, t1.task_id, "w")
    assert %Task{status: :completed} = complete(child, t1.task_id)
    assert await_status(child, :completed)

    assert [{_id, {:notify_parent, ^parent, _task, _owner}}] =
             eventually(fn -> match?([_], pending(child)) and pending(child) end)

    assert %Workflow{status: :running} = workflow(parent)

    RuntimeHooks.install(hook: fn _point, _id, _data -> :ok end)
    restart_runtime()

    assert await_status(parent, :completed)
    assert eventually(fn -> pending(child) == [] end)
    await_down(child)
  end

  test "the restarted node raises the epoch, and a write of the previous one is fenced" do
    id = start_simple(%{"x" => 1})
    previous = NodeLock.epoch()

    restart_runtime()

    assert NodeLock.epoch() > previous
    assert Postgres.epoch() == NodeLock.epoch()

    current = Postgres.epoch()
    on_exit(fn -> Postgres.put_epoch(current) end)
    Postgres.put_epoch(previous)

    assert Runtime.store().commit(id, %Commit{wake: {:at, @t0}}) == {:error, :fenced}
    assert_raise Postgres.FencedError, fn -> Runtime.queue().push("durability", "m", 0, 0) end

    Postgres.put_epoch(current)
    assert Runtime.queue().push("durability", "m", 0, 0) == :ok
    assert Runtime.queue().remove("durability", "m") == :ok
  end

  defp pending(id), do: Runtime.store().pending_outbox(id)
end
