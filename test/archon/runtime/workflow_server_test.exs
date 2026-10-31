# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.WorkflowServerTest do
  @moduledoc """
  `Archon.Runtime.WorkflowServer` (ADR 0018, decisions 1, 6 and 7): activation, the poll and
  update client functions, the `:wake` timer, the lifetime of a process, crashes and exception
  isolation.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{Task, TaskResult}
  alias Archon.Runtime.Commit
  alias Archon.Runtime.Queue.Memory, as: Queue

  defp complete(id, ref) do
    task = task(id, ref)
    assert %Task{status: :in_progress} = WorkflowServer.poll(id, task.task_id, "w")

    result = %TaskResult{
      workflow_instance_id: id,
      task_id: task.task_id,
      status: :completed,
      output_data: %{"y" => ref}
    }

    assert %Task{status: :completed} = WorkflowServer.update(result)
  end

  describe "activation" do
    test "an unknown ID starts no process" do
      assert WorkflowServer.activate("ws-unknown") == {:error, :not_found}
      assert WorkflowServer.poll("ws-unknown", "t", "w") == {:error, :not_found}
      assert WorkflowServer.whereis("ws-unknown") == nil
    end

    test "concurrent activations share one process" do
      id = start_simple(%{"x" => 1})

      :ok =
        DynamicSupervisor.terminate_child(
          Archon.Runtime.WorkflowSupervisor,
          WorkflowServer.whereis(id)
        )

      pids =
        1..10
        |> Enum.map(fn _ -> Elixir.Task.async(fn -> WorkflowServer.activate(id) end) end)
        |> Enum.map(&Elixir.Task.await/1)
        |> Enum.uniq()

      assert [{:ok, pid}] = pids
      assert WorkflowServer.whereis(id) == pid
    end

    test "a stopped process is activated again by the next request" do
      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)
      :ok = DynamicSupervisor.terminate_child(Archon.Runtime.WorkflowSupervisor, pid)
      task_id = task(id, "task_a_ref").task_id

      assert %Task{status: :in_progress} = WorkflowServer.poll(id, task_id, "w")
      assert WorkflowServer.whereis(id) not in [nil, pid]
    end
  end

  describe "poll and update" do
    test "run a workflow to completion, after which the process ends" do
      id = start_simple(%{"x" => 1})
      complete(id, "task_a_ref")
      assert task(id, "task_b_ref").status == :scheduled
      assert Queue.contains?("archon_task_b", task(id, "task_b_ref").task_id)
      complete(id, "task_b_ref")

      assert {:ok, %{status: :completed, output: %{"y" => "task_b_ref"}}} =
               Runtime.get_workflow(id)

      await_down(id)
      assert Runtime.terminate_workflow(id, "late") == {:error, :conflict}
      await_down(id)
    end

    test "a task the workflow does not have" do
      id = start_simple(%{"x" => 1})
      assert WorkflowServer.poll(id, "no-such-task", "w") == {:error, :not_found}

      assert WorkflowServer.update(%TaskResult{
               workflow_instance_id: id,
               task_id: "no-such-task",
               status: :completed
             }) == {:error, :not_found}
    end
  end

  describe "timer" do
    setup do
      RuntimeHooks.install(clock: 1_000_000, timer: self())
      :ok
    end

    test "a start sets the next :wake and a :wake that changes nothing repairs the queue" do
      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)
      assert_receive {:timer_set, ^pid, wake, 30_000}

      task_id = task(id, "task_a_ref").task_id
      Queue.remove("archon_task_a", task_id)

      RuntimeHooks.advance(30_000)
      send(pid, wake)
      assert_receive {:timer_set, ^pid, _wake, 30_000}
      assert Queue.contains?("archon_task_a", task_id)
    end

    test "a stale timer message is ignored and a poll only pulls the timer" do
      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)
      assert_receive {:timer_set, ^pid, first, 30_000}

      task_id = task(id, "task_a_ref").task_id
      assert %Task{} = WorkflowServer.poll(id, task_id, "w")
      refute_receive {:timer_set, ^pid, _wake, _delay}

      send(pid, :wake)
      assert_receive {:timer_set, ^pid, second, _delay}
      assert first != second

      # the first timer was replaced: its message changes nothing and sets no timer
      send(pid, first)
      refute_receive {:timer_set, ^pid, _wake, _delay}
      assert task(id, "task_a_ref").status == :in_progress
    end

    test "the response timeout fires on :wake" do
      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)
      assert_receive {:timer_set, ^pid, _wake, 30_000}
      task_id = task(id, "task_a_ref").task_id
      assert %Task{} = WorkflowServer.poll(id, task_id, "w")

      RuntimeHooks.advance(61_000)
      send(pid, :wake)
      eventually(fn -> task(id, "task_a_ref").status == :timed_out end)
    end
  end

  describe "crashes" do
    test "a killed process restarts from the store and repairs what it lost" do
      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)
      task_id = task(id, "task_a_ref").task_id
      Queue.remove("archon_task_a", task_id)

      Process.exit(pid, :kill)
      restarted = eventually(fn -> (p = WorkflowServer.whereis(id)) != pid and p end)
      assert is_pid(restarted)

      eventually(fn -> Queue.contains?("archon_task_a", task_id) end)
      assert %Task{status: :in_progress} = WorkflowServer.poll(id, task_id, "w")
    end

    test "a crash after the commit and before the effects is made good on restart" do
      id = "ws-crash-after-commit"

      RuntimeHooks.install(
        hook: fn
          :committed, ^id, _stored -> Process.exit(self(), :kill)
          _point, _id, _data -> :ok
        end
      )

      assert {:error, :killed} =
               Runtime.start_workflow(%{name: "archon_simple", workflow_id: id, input: %{}})

      RuntimeHooks.reset()

      task_id = eventually(fn -> task(id, "task_a_ref") end).task_id
      eventually(fn -> Queue.contains?("archon_task_a", task_id) end)
    end
  end

  describe "exception isolation" do
    setup do
      RuntimeHooks.install(clock: 2_000_000, timer: self())
      :ok
    end

    test "a failing step keeps the stored workflow, answers an error and recovers later" do
      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)
      assert_receive {:timer_set, ^pid, _wake, 30_000}
      task_id = task(id, "task_a_ref").task_id

      RuntimeHooks.install(
        hook: fn
          :step, ^id, {:poll, _task_id, _worker} -> raise "boom"
          _point, _id, _data -> :ok
        end
      )

      # more failures than the supervisor's restart intensity
      for _ <- 1..5 do
        assert {:error, %RuntimeError{message: "boom"}} = WorkflowServer.poll(id, task_id, "w")

        assert_receive {:timer_set, ^pid, _recover, 30_000}
      end

      assert WorkflowServer.whereis(id) == pid
      assert task(id, "task_a_ref").status == :scheduled

      RuntimeHooks.install(hook: fn _point, _id, _data -> :ok end)
      assert %Task{status: :in_progress} = WorkflowServer.poll(id, task_id, "w")
    end

    test "a failing post effect leaves the commit and the recovery check runs later" do
      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)
      assert_receive {:timer_set, ^pid, _wake, 30_000}
      a = task(id, "task_a_ref")
      assert %Task{} = WorkflowServer.poll(id, a.task_id, "w")

      RuntimeHooks.install(
        hook: fn
          :effect, ^id, {:wake_at, _at} -> raise "timer failed"
          _point, _id, _data -> :ok
        end
      )

      result = %TaskResult{workflow_instance_id: id, task_id: a.task_id, status: :completed}
      assert {:error, {:post_effect, %RuntimeError{}}} = WorkflowServer.update(result)
      assert task(id, "task_a_ref").status == :completed
      # the queue push was written with the commit (ADR 0021, decision 3)
      b = task(id, "task_b_ref")
      assert Queue.contains?("archon_task_b", b.task_id)
      assert_receive {:timer_set, ^pid, recover, 30_000}

      RuntimeHooks.install(hook: fn _point, _id, _data -> :ok end)
      send(pid, recover)
      assert_receive {:timer_set, ^pid, _wake, 30_000}
    end

    test "a start that fails after its commit leaves nothing behind" do
      id = "ws-start-fails"
      test = self()

      RuntimeHooks.install(
        hook: fn
          :commit, ^id, %Commit{queue: [{:push, queue, task_id, _priority, _at}]} ->
            send(test, {:pushed, queue, task_id})

          :effect, ^id, {:wake_at, _at} ->
            raise "late failure"

          _point, _id, _data ->
            :ok
        end
      )

      assert {:error, {:post_effect, %RuntimeError{message: "late failure"}}} =
               Runtime.start_workflow(%{name: "archon_simple", workflow_id: id, input: %{}})

      assert_receive {:pushed, "archon_task_a", task_id}
      assert Runtime.get_workflow(id) == {:error, :not_found}
      refute Queue.contains?("archon_task_a", task_id)
      await_down(id)
    end

    # ADR 0021, decision 3: the push is part of the commit, so a queue that is down fails it.
    test "a queue push that fails fails the start and leaves nothing behind" do
      id = "ws-push-fails-" <> Runtime.new_id()
      test = self()
      queue = Process.whereis(Queue)
      on_exit(fn -> Process.whereis(Queue) || Process.register(queue, Queue) end)

      RuntimeHooks.install(
        hook: fn
          :commit, ^id, %Commit{queue: [{:push, _queue, task_id, _priority, _at}]} ->
            send(test, {:pushing, task_id})
            Process.unregister(Queue)

          _point, _id, _data ->
            :ok
        end
      )

      assert {:error, {:commit, {:exit, {:noproc, _call}}}} =
               Runtime.start_workflow(%{name: "archon_simple", workflow_id: id, input: %{}})

      Process.register(queue, Queue)
      assert_receive {:pushing, task_id}
      assert Runtime.get_workflow(id) == {:error, :not_found}
      refute Queue.contains?("archon_task_a", task_id)
      await_down(id)
    end

    test "a queue operation that fails fails the commit; the update sent again applies it" do
      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)
      assert_receive {:timer_set, ^pid, _wake, 30_000}
      a = task(id, "task_a_ref")
      assert %Task{} = WorkflowServer.poll(id, a.task_id, "w")
      queue = Process.whereis(Queue)
      on_exit(fn -> Process.whereis(Queue) || Process.register(queue, Queue) end)

      RuntimeHooks.install(
        hook: fn
          :commit, ^id, %Commit{queue: [_ | _]} -> Process.unregister(Queue)
          _point, _id, _data -> :ok
        end
      )

      result = %TaskResult{workflow_instance_id: id, task_id: a.task_id, status: :completed}
      assert {:error, {:commit, {:exit, _reason}}} = WorkflowServer.update(result)
      Process.register(queue, Queue)
      assert task(id, "task_a_ref").status == :in_progress
      assert task(id, "task_b_ref") == nil
      assert_receive {:timer_set, ^pid, _recover, 30_000}

      RuntimeHooks.install(hook: fn _point, _id, _data -> :ok end)
      assert %Task{status: :completed} = WorkflowServer.update(result)
      b = task(id, "task_b_ref")
      assert Queue.contains?("archon_task_b", b.task_id)
    end
  end

  describe "the commit's queue operations (ADR 0021, decision 3)" do
    test "carry the delivery time from the event's clock" do
      RuntimeHooks.install(clock: 4_000_000, timer: self())
      id = "ws-queue-" <> Runtime.new_id()
      test = self()

      RuntimeHooks.install(
        hook: fn
          :commit, ^id, %Commit{} = commit -> send(test, {:commit, commit})
          _point, _id, _data -> :ok
        end
      )

      assert {:ok, ^id} =
               Runtime.start_workflow(%{name: "archon_simple", workflow_id: id, input: %{}})

      assert_receive {:commit, %Commit{create: %{}, queue: [push]}}
      task_id = task(id, "task_a_ref").task_id
      assert push == {:push, "archon_task_a", task_id, 0, 4_000_000}
      assert Queue.contains?("archon_task_a", task_id)

      # a poll of a terminal task commits only the queue removal
      assert Runtime.terminate_workflow(id, "done") == :ok
      assert_receive {:commit, %Commit{workflow: %{status: :terminated}}}
      assert WorkflowServer.poll(id, task_id, "w") == nil
      assert_receive {:commit, %Commit{workflow: nil, upsert_tasks: [], queue: queue}}
      assert queue == [{:remove, "archon_task_a", task_id}]
    end
  end

  describe "lifetime" do
    test "a process activated for a terminal workflow ends after the request" do
      id = start_simple(%{"x" => 1})
      assert Runtime.terminate_workflow(id, "done") == :ok
      await_down(id)

      assert WorkflowServer.poll(id, task(id, "task_a_ref").task_id, "w") == nil
      await_down(id)
    end

    test "a process activated without a request for a terminal workflow ends when idle" do
      id = start_simple(%{"x" => 1})
      assert Runtime.terminate_workflow(id, "done") == :ok
      await_down(id)

      assert {:ok, pid} = WorkflowServer.activate(id)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end
end
