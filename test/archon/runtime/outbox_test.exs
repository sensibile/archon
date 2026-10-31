# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.OutboxTest do
  @moduledoc """
  The outbox runner (ADR 0021, decision 4, slice 4e) and the limits it closes: entries saved by
  a commit survive a crash before they run or before they are acked, run in order with a growing
  delay after a failure, never by two runners at once, and keep a terminal workflow's process
  alive; a parent's notice is a call that is sent again until the parent saved it (L1); a child
  that ran again after its parent ended is neither terminated by a termination run again nor by
  its own recovery check (L2); an ancestor is cancelled under the task supervisor (L6).
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{Task, TaskResult, Workflow, WorkflowDef}
  alias Archon.Runtime.{Commit, Outbox}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.{Env, Lifecycle, State}

  @child ~S"""
  {"name": "outbox_child", "version": 1, "tasks": [
    {"name": "outbox_task", "taskReferenceName": "t1", "type": "SIMPLE", "inputParameters": {}}]}
  """

  @parent ~S"""
  {"name": "outbox_parent", "version": 1, "tasks": [
    {"name": "outbox_sub", "taskReferenceName": "st", "type": "SUB_WORKFLOW",
     "inputParameters": {}, "subWorkflowParam": {"name": "outbox_child", "version": 1},
     "retryCount": 0}]}
  """

  @grandparent ~S"""
  {"name": "outbox_grandparent", "version": 1, "tasks": [
    {"name": "outbox_sub", "taskReferenceName": "st", "type": "SUB_WORKFLOW",
     "inputParameters": {}, "subWorkflowParam": {"name": "outbox_parent", "version": 1},
     "retryCount": 0}]}
  """

  @with_failure ~S"""
  {"name": "outbox_with_failure", "version": 1, "tasks": [
    {"name": "outbox_task", "taskReferenceName": "t1", "type": "SIMPLE", "inputParameters": {}}],
   "failureWorkflow": "outbox_child"}
  """

  setup do
    :ok =
      Runtime.metadata().update_task_def(%Archon.Domain.TaskDef{
        name: "outbox_task",
        retry_count: 0
      })

    for json <- [@child, @parent, @grandparent, @with_failure] do
      {:ok, definition} = json |> Jason.decode!() |> WorkflowDef.from_json()
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

    saved = Application.get_env(:archon, Archon.Runtime)
    Application.put_env(:archon, Archon.Runtime, Keyword.put(saved, :outbox_retry_ms, 50))
    on_exit(fn -> Application.put_env(:archon, Archon.Runtime, saved) end)
    :ok
  end

  ## Helpers

  defp start(name) do
    {:ok, id} = Runtime.start_workflow(%{name: name, input: %{}})
    id
  end

  defp workflow(id) do
    {:ok, workflow} = Runtime.get_workflow(id)
    workflow
  end

  defp await_status(id, status),
    do: eventually(fn -> match?(%Workflow{status: ^status}, workflow(id)) and workflow(id) end)

  defp child_of(id),
    do: eventually(fn -> Task.sub_workflow_id(task(id, "st")) end)

  # The last instance of t1, once it is scheduled.
  defp finish(id, status) do
    task = eventually(fn -> match?(%Task{status: :scheduled}, last_t1(id)) and last_t1(id) end)

    assert %Task{status: :in_progress} = WorkflowServer.poll(id, task.task_id, "w")

    WorkflowServer.update(%TaskResult{
      workflow_instance_id: id,
      task_id: task.task_id,
      status: status
    })
  end

  defp last_t1(id),
    do: workflow(id).tasks |> Enum.filter(&(&1.reference_task_name == "t1")) |> List.last()

  defp pending(id), do: Runtime.store().pending_outbox(id)

  # A parent and its running child.
  defp parent_and_child do
    parent = start("outbox_parent")
    {parent, child_of(parent)}
  end

  # Entries committed while the workflow has no process, then run by its activation.
  defp activate_with(id, entries) do
    :ok =
      DynamicSupervisor.terminate_child(
        Archon.Runtime.WorkflowSupervisor,
        WorkflowServer.whereis(id)
      )

    :ok = Runtime.store().commit(id, %Commit{outbox: entries})
    {:ok, pid} = WorkflowServer.activate(id)
    pid
  end

  defp missing, do: "archon-outbox-missing-" <> Runtime.new_id()

  defp once do
    counter = :counters.new(1, [])
    fn -> :counters.add(counter, 1, 1) == :ok and :counters.get(counter, 1) == 1 end
  end

  describe "an entry outlives a crash" do
    test "a notice saved before the child's process crashed reaches the parent after the restart" do
      {parent, child} = parent_and_child()
      first? = once()

      RuntimeHooks.install(
        hook: fn
          :committed, ^child, %Workflow{status: :completed} ->
            if first?.(), do: raise("crash after the commit")

          _point, _id, _data ->
            :ok
        end
      )

      assert {:error, _reason} = finish(child, :completed)

      # the next process of the child (restarted, or activated here when other tests used up
      # the supervisor's restarts) finds the entry and its runner tells the parent
      eventually(fn -> match?({:ok, _pid}, WorkflowServer.activate(child)) end)
      assert await_status(parent, :completed)
      assert eventually(fn -> pending(child) == [] end)
    end

    test "an entry run but not acked runs again, with the same result" do
      {parent, child} = parent_and_child()
      test = self()
      first? = once()

      RuntimeHooks.install(
        hook: fn
          :outbox, ^child, {_id, effect} ->
            send(test, {:ran, effect})

          :outbox_ack, ^child, _id ->
            if first?.(), do: raise("crash before the ack")

          _point, _id, _data ->
            :ok
        end
      )

      assert %Task{status: :completed} = finish(child, :completed)
      assert_receive {:ran, {:notify_parent, ^parent, _task, nil}}
      assert_receive {:ran, {:notify_parent, ^parent, _task, nil}}, 1_000
      assert eventually(fn -> pending(child) == [] end)
      assert await_status(parent, :completed)
      refute_receive {:ran, _effect}, 100
    end
  end

  describe "the runner" do
    test "runs the entries in order and waits a growing delay after a failure" do
      id = start("outbox_child")
      [a, b] = [missing(), missing()]
      test = self()
      failures = :counters.new(1, [])

      RuntimeHooks.install(
        hook: fn
          :outbox, ^id, {_id, {:retry_sub_workflow, child}} ->
            send(test, {:ran, child, System.monotonic_time(:millisecond)})

            if child == a and :counters.get(failures, 1) < 2 do
              :counters.add(failures, 1, 1)
              raise "not yet"
            end

          _point, _id, _data ->
            :ok
        end
      )

      activate_with(id, [{:retry_sub_workflow, a}, {:retry_sub_workflow, b}])

      assert_receive {:ran, ^a, t1}
      assert_receive {:ran, ^a, t2}, 1_000
      assert_receive {:ran, ^a, t3}, 1_000
      assert_receive {:ran, ^b, _t4}, 1_000
      # 50 ms, then 100 ms; b waits for a
      assert t2 - t1 >= 50
      assert t3 - t2 >= 100
      assert eventually(fn -> pending(id) == [] end)
    end

    test "is one at a time: a new process waits for the runner of the one that was killed" do
      id = start("outbox_child")
      [a, b] = [missing(), missing()]
      test = self()

      RuntimeHooks.install(
        hook: fn
          :outbox, ^id, {_id, {:retry_sub_workflow, child}} ->
            send(test, {:ran, child, self()})

            if child == a do
              receive do
                :release -> :ok
              after
                5_000 -> :ok
              end
            end

          _point, _id, _data ->
            :ok
        end
      )

      first = activate_with(id, [{:retry_sub_workflow, a}, {:retry_sub_workflow, b}])
      assert_receive {:ran, ^a, runner}

      Process.exit(first, :kill)

      # restarted by the supervisor or activated here, whichever comes first
      second =
        eventually(fn ->
          match?({:ok, pid} when pid != first, WorkflowServer.activate(id)) and
            WorkflowServer.whereis(id)
        end)

      assert is_pid(second)

      # the new process's runner found the key taken and runs nothing
      refute_receive {:ran, _child, _runner}, 200

      send(runner, :release)
      assert_receive {:ran, ^b, other}, 2_000
      assert other != runner
      refute_receive {:ran, ^a, _runner}, 100
      assert eventually(fn -> pending(id) == [] end)
    end

    test "keeps a terminal workflow's process alive until the outbox is empty" do
      {parent, child} = parent_and_child()
      test = self()

      RuntimeHooks.install(
        hook: fn
          :outbox, ^child, {_id, {:notify_parent, _parent, _task, _child}} ->
            send(test, {:running, self()})

            receive do
              :release -> :ok
            after
              5_000 -> :ok
            end

          _point, _id, _data ->
            :ok
        end
      )

      assert %Task{status: :completed} = finish(child, :completed)
      assert_receive {:running, runner}

      # longer than the idle timeout (200 ms in tests)
      Process.sleep(300)
      assert WorkflowServer.whereis(child) != nil

      send(runner, :release)
      assert await_status(parent, :completed)
      await_down(child)
    end
  end

  describe "the failure workflow" do
    test "a refused start is written to the output and its entry deleted with it" do
      {:ok, definition} = Runtime.metadata().get_workflow_def("outbox_with_failure", 1)

      :ok =
        Runtime.metadata().update_workflow_def(%{
          definition
          | name: "outbox_refused_failure",
            failure_workflow: "archon_outbox_no_such_wf"
        })

      id = start("outbox_refused_failure")
      assert %Task{status: :failed} = finish(id, :failed)

      assert eventually(fn ->
               workflow(id).output["conductor.failure_workflow"] =~
                 "Error workflow archon_outbox_no_such_wf failed to start."
             end)

      assert eventually(fn -> pending(id) == [] end)
      assert workflow(id).end_count == 1
    end

    test "a feedback commit that fails keeps the entry, which runs again" do
      {:ok, definition} = Runtime.metadata().get_workflow_def("outbox_with_failure", 1)

      :ok =
        Runtime.metadata().update_workflow_def(%{
          definition
          | name: "outbox_refused_again",
            failure_workflow: "archon_outbox_no_such_wf"
        })

      first? = once()

      RuntimeHooks.install(
        hook: fn
          :commit, _id, %Commit{outbox_ack: [_ | _]} ->
            if first?.(), do: raise("store down")

          _point, _id, _data ->
            :ok
        end
      )

      id = start("outbox_refused_again")
      assert %Task{status: :failed} = finish(id, :failed)

      assert eventually(fn ->
               workflow(id).output["conductor.failure_workflow"] =~ "failed to start"
             end)

      assert eventually(fn -> pending(id) == [] end)
    end

    test "a refusal that arrives after a retry leaves the new run's output alone" do
      wf = %Workflow{workflow_id: "w", status: :running, output: %{"a" => 1}, tasks: []}
      env = Env.new(now: 1)

      assert {:ok, ^wf, [], %Commit{workflow: nil}, []} =
               Step.run(wf, {:failure_workflow_started, {:error, "gone"}}, env)
    end

    test "a start that failed in the store is tried again" do
      first? = once()

      RuntimeHooks.install(
        hook: fn
          :commit,
          _id,
          %Commit{create: %Workflow{workflow_definition: %{name: "outbox_child"}}} ->
            if first?.(), do: raise("store down")

          _point, _id, _data ->
            :ok
        end
      )

      id = start("outbox_with_failure")
      assert %Task{status: :failed} = finish(id, :failed)

      failure_id = workflow(id).output["conductor.failure_workflow"]

      assert {:ok, %Workflow{status: :running}} =
               eventually(fn ->
                 match?({:ok, _}, Runtime.get_workflow(failure_id)) and
                   Runtime.get_workflow(failure_id)
               end)

      assert eventually(fn -> pending(id) == [] end)
    end
  end

  describe "notices to the parent are calls (L1)" do
    test "a revival the parent failed to save is sent again" do
      {parent, child} = parent_and_child()
      assert %Task{status: :failed} = finish(child, :failed)
      assert await_status(parent, :failed)
      first? = once()

      RuntimeHooks.install(
        hook: fn
          :env, ^parent, {:child_revived, _task_id} ->
            if first?.(), do: raise("store down")

          _point, _id, _data ->
            :ok
        end
      )

      assert :ok = Runtime.Lifecycle.retry(child)
      assert await_status(parent, :running)
      assert eventually(fn -> pending(child) == [] end)
    end
  end

  describe "an entry run twice (decision 4, idempotence)" do
    test "a revival request for a parent that already revived changes nothing" do
      {parent, child} = parent_and_child()
      assert %Task{status: :failed} = finish(child, :failed)
      assert await_status(parent, :failed)

      assert :ok = Runtime.Lifecycle.retry(child)
      assert await_status(parent, :running)
      assert eventually(fn -> pending(child) == [] end)
      before = workflow(parent)

      task_id = task(parent, "st").task_id
      assert Outbox.run_effect(child, {:revive_parent, parent, task_id}) == :ok
      after_again = workflow(parent)
      assert {after_again.status, after_again.end_count} == {:running, before.end_count}
      assert [%Task{status: :in_progress}] = after_again.tasks

      assert %Task{status: :completed} = finish(child, :completed)
      assert await_status(parent, :completed)
    end

    test "a retry of a child that already runs is acked and leaves it running" do
      {parent, child} = parent_and_child()
      before = workflow(child)

      assert {:error, {:not_found, _message}} =
               Outbox.run_effect(parent, {:retry_sub_workflow, child})

      activate_with(parent, [{:retry_sub_workflow, child}])
      assert eventually(fn -> pending(parent) == [] end)
      assert workflow(child) == before
    end
  end

  describe "a child that ran again after its parent ended (L2)" do
    test "a revived parent records its own parent's endCount" do
      grandparent = start("outbox_grandparent")
      parent = child_of(grandparent)
      child = child_of(parent)
      assert %Task{status: :failed} = finish(child, :failed)
      assert %Workflow{end_count: 1} = await_status(grandparent, :failed)

      assert :ok = Runtime.Lifecycle.retry(child)
      assert await_status(grandparent, :running)
      assert workflow(child).revived_parent_end_count == 1
      assert workflow(parent).revived_parent_end_count == 1
      assert workflow(grandparent).revived_parent_end_count == 0
    end

    # The parent terminated by request, its child with it before the commit.
    defp terminated_parent do
      {parent, child} = parent_and_child()
      eventually(fn -> task(child, "t1") end)
      assert :ok = Runtime.terminate_workflow(parent, "stop")
      assert await_status(child, :terminated)
      assert workflow(parent).end_count == 1
      {parent, child}
    end

    test "a termination from the outbox run again leaves the retried child running" do
      {parent, child} = terminated_parent()

      assert :ok = WorkflowServer.retry(child, false)
      assert %Workflow{status: :running, revived_parent_end_count: 1} = workflow(child)

      # the parent's entry for this end, run again after the retry
      reason = "Parent workflow has been terminated with reason: stop"
      assert Outbox.run_effect(parent, {:terminate_sub_workflow, child, reason, 1}) == :ok
      assert workflow(child).status == :running

      # a later end of the parent terminates it
      assert Outbox.run_effect(parent, {:terminate_sub_workflow, child, reason, 2}) == :ok
      assert workflow(child).status == :terminated
    end

    test "pausing and resuming the retried child does not make its recovery check end it" do
      {parent, child} = terminated_parent()
      assert [%Task{status: :canceled}] = workflow(parent).tasks

      assert :ok = WorkflowServer.retry(child, false)
      assert :ok = WorkflowServer.pause(child)
      assert :ok = WorkflowServer.resume(child)
      assert workflow(child).previous_status == :paused

      send(WorkflowServer.whereis(child), :recover)
      assert :ok = WorkflowServer.pause(child)
      assert workflow(child).status == :paused
    end

    test "endCount counts the ends from a running status, in the same millisecond too" do
      running = %Workflow{status: :running, end_count: 0}
      failed = State.set_status(running, :failed)
      assert failed.end_count == 1
      # a terminal workflow terminated again by request
      assert State.set_status(failed, :terminated).end_count == 1
      # revived and ended again
      assert failed
             |> State.set_status(:running)
             |> State.set_status(:completed)
             |> Map.get(:end_count) == 2

      # a child retried in the same millisecond as its parent's end, but before it
      parent = %Workflow{status: :terminated, end_time: 5, end_count: 1}

      before = %Workflow{
        previous_status: :failed,
        last_retried_time: 5,
        revived_parent_end_count: 0
      }

      after_end = %{before | revived_parent_end_count: 1}

      refute Lifecycle.revived_after?(before, parent)
      assert Lifecycle.revived_after?(after_end, parent)
      refute Lifecycle.revived_after?(after_end, %{parent | end_count: 2})
    end
  end

  describe "an ancestor named as a child (L6)" do
    test "is cancelled from a task under the task supervisor" do
      grandparent = start("outbox_grandparent")
      parent = child_of(grandparent)
      sub_task = eventually(fn -> task(parent, "st").sub_workflow_id && task(parent, "st") end)
      test = self()

      assert %Task{} =
               WorkflowServer.update(%TaskResult{
                 workflow_instance_id: parent,
                 task_id: sub_task.task_id,
                 status: :in_progress,
                 sub_workflow_id: grandparent
               })

      RuntimeHooks.install(
        hook: fn
          :env, ^grandparent, {:cancel_by_parent, _reason, nil} ->
            send(test, {:cancelling, self()})

            receive do
              :release -> :ok
            after
              5_000 -> :ok
            end

          _point, _id, _data ->
            :ok
        end
      )

      assert :ok = Runtime.terminate_workflow(parent, "stop")
      assert_receive {:cancelling, grandparent_pid}, 2_000

      # the outbox runners are registered as {:outbox, id}; the cancel is not
      cancels =
        for pid <- Elixir.Task.Supervisor.children(Archon.Runtime.TaskSupervisor),
            Registry.keys(Archon.Runtime.Registry, pid) == [],
            do: pid

      assert cancels != []

      send(grandparent_pid, :release)
      assert await_status(grandparent, :terminated)
    end
  end
end
