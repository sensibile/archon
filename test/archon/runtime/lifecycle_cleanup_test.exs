# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.LifecycleCleanupTest do
  @moduledoc """
  The lifecycle operations of slice 6d (ADR 0025, decisions 2 and 3) beyond what the contract
  replay shows: a removal waits for the workflow's outbox (a terminated parent's child
  termination, a terminated child's notice to its parent) and gives up with nothing removed, a
  retry that revives the workflow while the removal waits meets the archive check again, a child
  that tells a removed parent finds none, and resetcallbacks changes only the tasks whose queue
  message was there.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{Task, TaskDef, TaskResult, Workflow, WorkflowDef}
  alias Archon.Runtime.Lifecycle
  alias Archon.Runtime.Step.Lifecycle, as: Rules

  @child ~S"""
  {"name": "cleanup_child", "version": 1, "tasks": [
    {"name": "cleanup_task", "taskReferenceName": "t1", "type": "SIMPLE", "inputParameters": {}}]}
  """

  @parent ~S"""
  {"name": "cleanup_parent", "version": 1, "tasks": [
    {"name": "cleanup_sub", "taskReferenceName": "st", "type": "SUB_WORKFLOW",
     "inputParameters": {}, "subWorkflowParam": {"name": "cleanup_child", "version": 1},
     "retryCount": 0}]}
  """

  setup do
    :ok = Runtime.metadata().update_task_def(%TaskDef{name: "cleanup_task", retry_count: 0})

    for json <- [@child, @parent] do
      {:ok, definition} = json |> Jason.decode!() |> WorkflowDef.from_json()
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

    saved = Application.get_env(:archon, Archon.Runtime)
    on_exit(fn -> Application.put_env(:archon, Archon.Runtime, saved) end)
    :ok
  end

  ## Helpers

  defp set(key, value) do
    saved = Application.get_env(:archon, Archon.Runtime)
    Application.put_env(:archon, Archon.Runtime, Keyword.put(saved, key, value))
  end

  defp start(name) do
    {:ok, id} = Runtime.start_workflow(%{name: name, input: %{}})
    id
  end

  defp workflow(id) do
    {:ok, workflow} = Runtime.get_workflow(id)
    workflow
  end

  defp gone?(id), do: Runtime.get_workflow(id) == {:error, :not_found}

  defp await_status(id, status),
    do: eventually(fn -> match?(%Workflow{status: ^status}, workflow(id)) and workflow(id) end)

  defp child_of(id),
    do: eventually(fn -> (st = task(id, "st")) && Task.sub_workflow_id(st) end)

  defp parent_and_child do
    parent = start("cleanup_parent")
    {parent, child_of(parent)}
  end

  defp scheduled_t1(id),
    do: eventually(fn -> match?(%Task{status: :scheduled}, task(id, "t1")) and task(id, "t1") end)

  defp finish(id, status) do
    task = scheduled_t1(id)
    assert %Task{status: :in_progress} = WorkflowServer.poll(id, task.task_id, "w")

    WorkflowServer.update(%TaskResult{
      workflow_instance_id: id,
      task_id: task.task_id,
      status: status
    })
  end

  # Holds the outbox runner of `id` at its first entry until the test sends `:release` to it.
  defp hold_outbox(id) do
    test = self()

    RuntimeHooks.install(
      hook: fn
        :outbox, ^id, {_entry, effect} ->
          send(test, {:held, self(), effect})

          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end

        _point, _id, _data ->
          :ok
      end
    )
  end

  defp removing(fun) do
    test = self()
    Elixir.Task.async(fn -> send(test, {:removed, fun.()}) end)
  end

  describe "remove" do
    test "deletes the workflow, its tasks and their queue messages, and ends its process" do
      id = start("cleanup_child")
      t1 = scheduled_t1(id)
      assert Runtime.queue().contains?("cleanup_task", t1.task_id)

      assert Lifecycle.remove(id, true) ==
               {:error, {:invalid, "Cannot archive workflow: #{id} with status: RUNNING"}}

      assert workflow(id).status == :running

      assert Lifecycle.remove(id, false) == :ok
      assert gone?(id)
      refute Runtime.queue().contains?("cleanup_task", t1.task_id)
      assert Runtime.store().pending_outbox(id) == []
      await_down(id)
      assert Lifecycle.remove(id, false) == {:error, :not_found}
    end

    test "with archiveWorkflow only a terminal workflow without a running task" do
      wf = %Workflow{workflow_id: "w", status: :failed, tasks: []}
      running = %Task{task_id: "t", status: :in_progress}
      scheduled = %Task{task_id: "s", status: :scheduled}

      assert Rules.removable(wf, true) == :ok
      assert Rules.removable(%{wf | tasks: [scheduled]}, true) == :ok

      assert Rules.removable(%{wf | tasks: [scheduled, running]}, true) ==
               {:error,
                {:invalid,
                 "Cannot archive task: t of workflow: w with non-terminal status: IN_PROGRESS"}}

      assert Rules.removable(%{wf | status: :paused, tasks: [running]}, false) == :ok
    end

    # A termination request ends the children before its commit (upstream
    # cancelNonTerminalTasks), so nothing is left in the parent's outbox.
    test "the terminate-remove of a parent with a running child terminates the child" do
      {parent, child} = parent_and_child()

      assert Lifecycle.terminate_remove(parent, "cleanup", true) == :ok
      assert gone?(parent)
      assert workflow(child).status == :terminated
    end

    test "the terminate-remove of a child its parent waits on reaches the parent first" do
      {parent, child} = parent_and_child()
      hold_outbox(child)

      removing(fn -> Lifecycle.terminate_remove(child, "cleanup", true) end)
      assert_receive {:held, runner, {:notify_parent, ^parent, _task, _child}}, 2_000
      refute_receive {:removed, _result}, 300
      assert workflow(child).status == :terminated
      assert task(parent, "st").status == :in_progress

      send(runner, :release)
      assert_receive {:removed, :ok}, 2_000
      assert gone?(child)

      parent_wf = await_status(parent, :terminated)
      assert [%Task{task_type: "SUB_WORKFLOW", status: :canceled}] = parent_wf.tasks
    end

    test "gives up with nothing removed when the outbox does not empty in time" do
      set(:remove_timeout, 300)
      {parent, child} = parent_and_child()
      hold_outbox(child)

      assert :ok = Runtime.terminate_workflow(child, "cleanup")
      assert_receive {:held, runner, {:notify_parent, ^parent, _task, _child}}, 2_000

      assert Lifecycle.remove(child, true) == {:error, :outbox_pending}
      assert workflow(child).status == :terminated
      assert [_entry] = Runtime.store().pending_outbox(child)

      send(runner, :release)
      assert await_status(parent, :terminated)
      assert eventually(fn -> Lifecycle.remove(child, true) == :ok end)
      assert gone?(child)
    end

    test "a retry while the removal waits revives the workflow, which the archive check refuses" do
      {parent, child} = parent_and_child()
      hold_outbox(child)
      assert :ok = Runtime.terminate_workflow(child, "cleanup")
      assert_receive {:held, runner, {:notify_parent, ^parent, _task, _child}}, 2_000

      removing(fn -> Lifecycle.remove(child, true) end)
      refute_receive {:removed, _result}, 200

      assert Lifecycle.retry(child) == :ok
      assert workflow(child).status == :running
      send(runner, :release)

      message = "Cannot archive workflow: #{child} with status: RUNNING"
      assert_receive {:removed, {:error, {:invalid, ^message}}}, 2_000
      assert workflow(child).status == :running
      assert await_status(parent, :running)
    end

    test "a child that tells its removed parent finds none and goes on" do
      {parent, child} = parent_and_child()
      assert Lifecycle.remove(parent, false) == :ok
      assert gone?(parent)

      assert %Task{status: :completed} = finish(child, :completed)
      assert await_status(child, :completed)
      assert eventually(fn -> Runtime.store().pending_outbox(child) == [] end)
      assert gone?(parent)
    end
  end

  describe "resetcallbacks" do
    defp postponed(id) do
      t1 = scheduled_t1(id)
      assert %Task{status: :in_progress} = WorkflowServer.poll(id, t1.task_id, "w")

      assert %Task{status: :scheduled, callback_after_seconds: 3600} =
               WorkflowServer.update(%TaskResult{
                 workflow_instance_id: id,
                 task_id: t1.task_id,
                 status: :in_progress,
                 callback_after_seconds: 3600
               })

      t1
    end

    test "a task whose queue message is there loses its callback delay" do
      id = start("cleanup_child")
      t1 = postponed(id)

      assert Lifecycle.reset_callbacks(id) == :ok
      assert %Task{callback_after_seconds: 0, status: :scheduled} = task(id, "t1")
      assert Runtime.queue().contains?("cleanup_task", t1.task_id)
      # Read again, the message is there and already due: still true, nothing else changes.
      assert Lifecycle.reset_callbacks(id) == :ok
      assert %Task{callback_after_seconds: 0} = task(id, "t1")
    end

    test "a task whose queue message is gone keeps it" do
      id = start("cleanup_child")
      t1 = postponed(id)
      :ok = Runtime.queue().remove("cleanup_task", t1.task_id)

      assert Lifecycle.reset_callbacks(id) == :ok
      assert %Task{callback_after_seconds: 3600} = task(id, "t1")
      refute Runtime.queue().contains?("cleanup_task", t1.task_id)
    end
  end
end
