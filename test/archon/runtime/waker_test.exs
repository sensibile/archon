# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.WakerTest do
  @moduledoc """
  Lazy activation (ADR 0021, decision 6, slice 4g) on the memory backend: a commit saves the
  step's next evaluation time, `Archon.Runtime.Waker` activates the workflows without a process
  once that time is near and those with outbox entries, and with `evict_after` an idle running
  workflow's process ends until then. The clock is installed; the waker of the tree is suspended,
  so each test runs its rounds itself.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{TaskResult, Workflow}
  alias Archon.Runtime.{Commit, Waker}

  import ExUnit.CaptureLog

  @t0 1_700_000_000_000

  setup do
    RuntimeHooks.install(clock: @t0)
    :ok = :sys.suspend(Waker)

    on_exit(fn ->
      with pid when is_pid(pid) <- Process.whereis(Waker), do: :sys.resume(pid)
    end)

    :ok
  end

  ## Helpers

  defp put_settings(settings) do
    saved = Application.get_env(:archon, Archon.Runtime)
    Application.put_env(:archon, Archon.Runtime, Keyword.merge(saved, settings))
    on_exit(fn -> Application.put_env(:archon, Archon.Runtime, saved) end)
  end

  # The stored re-evaluation time, `nil` when the workflow is not due even far ahead.
  defp stored_wake(id) do
    Runtime.store().due_workflow_ids(@t0 * 2, nil, 10_000)
    |> Enum.find_value(fn {key, due_id} -> if due_id == id, do: key end)
  end

  defp stop_process(id) do
    case WorkflowServer.whereis(id) do
      nil -> :ok
      pid -> :ok = DynamicSupervisor.terminate_child(Archon.Runtime.WorkflowSupervisor, pid)
    end
  end

  # Hibernating shows as erlang:hibernate/3, or gen_server's own hibernation loop in OTP 28.
  defp hibernating?(pid),
    do:
      Process.info(pid, :current_function) in [
        {:current_function, {:erlang, :hibernate, 3}},
        {:current_function, {:gen_server, :loop_hibernate, 4}}
      ]

  defp timer(id), do: :sys.get_state(WorkflowServer.whereis(id)).timer

  defp capture_commits(id) do
    test = self()

    RuntimeHooks.install(
      hook: fn
        :commit, ^id, %Commit{} = commit -> send(test, {:commit, commit})
        _point, _id, _data -> :ok
      end
    )
  end

  describe "the commit saves the next evaluation (Commit.wake)" do
    test "a decide saves the time of its timer, a poll pulls it and a pause clears it" do
      id = start_simple(%{"x" => 1})
      %{at: at, message: :wake} = timer(id)
      assert stored_wake(id) == at

      capture_commits(id)
      task = task(id, "task_a_ref")
      assert %{status: :in_progress} = WorkflowServer.poll(id, task.task_id, "w")
      assert_receive {:commit, %Commit{wake: {:before, pulled}}}
      assert stored_wake(id) == min(at, pulled)

      assert Runtime.Lifecycle.pause(id) == :ok
      assert_receive {:commit, %Commit{wake: :none, workflow: %Workflow{status: :paused}}}
      assert stored_wake(id) == nil

      assert Runtime.Lifecycle.resume(id) == :ok

      assert_receive {:commit,
                      %Commit{wake: {:at, resumed}, workflow: %Workflow{status: :running}}}

      assert stored_wake(id) == resumed
    end

    test "an isolated exception saves its recovery deadline, and a failure to save is logged" do
      id = start_simple(%{"x" => 1})
      far = @t0 + 10_000_000
      :ok = Runtime.store().commit(id, %Commit{wake: {:at, far}})
      task_id = task(id, "task_a_ref").task_id
      result = %TaskResult{workflow_instance_id: id, task_id: task_id, status: :in_progress}

      RuntimeHooks.install(
        hook: fn
          :step, ^id, {:update, _result} -> raise "step down"
          _point, _id, _data -> :ok
        end
      )

      assert {:error, %RuntimeError{}} = WorkflowServer.update(result)
      assert %{message: :recover, at: deadline} = timer(id)
      assert deadline == @t0 + 30_000
      assert stored_wake(id) == deadline

      :ok = Runtime.store().commit(id, %Commit{wake: {:at, far}})

      RuntimeHooks.install(
        hook: fn
          :step, ^id, {:update, _result} -> raise "step down"
          :commit, ^id, %Commit{wake: {:before, _at}, workflow: nil} -> raise "store down"
          _point, _id, _data -> :ok
        end
      )

      assert {:error, %RuntimeError{}} = WorkflowServer.update(result)
      assert %{message: :recover} = timer(id)
      assert stored_wake(id) == far
    end
  end

  describe "the waker" do
    test "activates a running workflow without a process once its time is within the margin" do
      early = start_simple(%{"x" => 1})
      RuntimeHooks.advance(20_000)
      late = start_simple(%{"x" => 2})
      early_at = stored_wake(early)
      late_at = stored_wake(late)
      assert early_at < late_at
      stop_process(early)
      stop_process(late)

      RuntimeHooks.advance(early_at - 5_000 - 1 - Runtime.now())
      Waker.run()
      assert WorkflowServer.whereis(early) == nil

      RuntimeHooks.advance(1)
      Waker.run()
      assert WorkflowServer.whereis(early)
      assert WorkflowServer.whereis(late) == nil

      RuntimeHooks.advance(late_at - 5_000 - Runtime.now())
      assert Waker.run() >= 1
      assert WorkflowServer.whereis(late)
    end

    test "reads every keyset page and leaves paused and running processes alone" do
      put_settings(activation_page_size: 2)
      ids = for x <- 1..5, do: start_simple(%{"x" => x})
      paused = start_simple(%{"x" => 6})
      assert Runtime.Lifecycle.pause(paused) == :ok
      kept = Enum.at(ids, 0)
      kept_pid = WorkflowServer.whereis(kept)
      for id <- tl(ids), do: stop_process(id)
      stop_process(paused)

      RuntimeHooks.advance(10_000_000)
      assert Waker.run() >= 4
      for id <- ids, do: assert(WorkflowServer.whereis(id))
      assert WorkflowServer.whereis(kept) == kept_pid
      assert WorkflowServer.whereis(paused) == nil
    end

    test "activates a terminal workflow with outbox entries, which runs them" do
      id = start_simple(%{"x" => 1})
      assert Runtime.terminate_workflow(id, "r") == :ok
      await_down(id)
      missing = "archon-waker-missing-" <> Runtime.new_id()
      :ok = Runtime.store().commit(id, %Commit{outbox: [{:retry_sub_workflow, missing}]})

      assert Waker.run() >= 1
      assert eventually(fn -> Runtime.store().pending_outbox(id) == [] end)
      await_down(id)
    end

    test "a round that fails is logged and the next one is scheduled" do
      put_settings(activation_page_size: -1)
      pid = Process.whereis(Waker)
      ref = :sys.get_state(pid)

      log =
        capture_log(fn ->
          send(pid, {:tick, ref})
          :sys.resume(pid)
          assert :sys.get_state(pid) != ref
          :sys.suspend(pid)
        end)

      assert log =~ "the waker failed"
      assert Process.whereis(Waker) == pid
    end
  end

  describe "idle eviction (evict_after)" do
    test "a running workflow's idle process ends and the waker activates it before its time" do
      put_settings(evict_after: 1_000, hibernate_after: 20)
      id = start_simple(%{"x" => 1})
      at = stored_wake(id)
      assert at - Runtime.now() > 1_000

      await_down(id)
      Waker.run()
      assert WorkflowServer.whereis(id) == nil

      RuntimeHooks.advance(at - 5_000 - Runtime.now())
      Waker.run()
      pid = WorkflowServer.whereis(id)
      assert %{message: :wake} = :sys.get_state(pid).timer
    end

    test "a request activates an evicted workflow" do
      put_settings(evict_after: 1_000, hibernate_after: 20)
      id = start_simple(%{"x" => 1})
      await_down(id)

      task = task(id, "task_a_ref")
      assert %{status: :in_progress} = WorkflowServer.poll(id, task.task_id, "w")
    end

    test "a process whose next evaluation is within evict_after hibernates instead" do
      put_settings(evict_after: 10_000_000, hibernate_after: 20)
      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)

      assert eventually(fn -> hibernating?(pid) end)

      assert WorkflowServer.whereis(id) == pid
    end

    test "a process whose outbox runner works is not evicted until the outbox is empty" do
      id = start_simple(%{"x" => 1})
      stop_process(id)
      put_settings(evict_after: 1_000, hibernate_after: 20)
      test = self()

      RuntimeHooks.install(
        clock: @t0,
        hook: fn
          :outbox, ^id, _entry ->
            send(test, {:running, self()})
            receive do: (:go -> :ok)

          _point, _id, _data ->
            :ok
        end
      )

      missing = "archon-waker-missing-" <> Runtime.new_id()
      :ok = Runtime.store().commit(id, %Commit{outbox: [{:retry_sub_workflow, missing}]})
      {:ok, pid} = WorkflowServer.activate(id)
      assert_receive {:running, runner}

      Process.sleep(100)
      assert Process.alive?(pid)

      send(runner, :go)
      await_down(id)
      assert Runtime.store().pending_outbox(id) == []
    end

    @tag backend: :memory
    test "is off with the memory store by default, and on when set" do
      saved = Application.get_env(:archon, Archon.Runtime)

      put_settings(
        hibernate_after: 20,
        settings: [workflow_offset_timeout_ms: 600_000]
      )

      Application.put_env(
        :archon,
        Archon.Runtime,
        Keyword.delete(Application.get_env(:archon, Archon.Runtime), :evict_after)
      )

      on_exit(fn -> Application.put_env(:archon, Archon.Runtime, saved) end)
      kept = start_simple(%{"x" => 1})
      assert stored_wake(kept) - Runtime.now() > 60_000
      pid = WorkflowServer.whereis(kept)
      assert eventually(fn -> hibernating?(pid) end)
      assert WorkflowServer.whereis(kept) == pid

      put_settings(evict_after: 60_000)
      evicted = start_simple(%{"x" => 2})
      await_down(evicted)
    end

    @tag backend: :postgres
    test "is 60 s with the Postgres store by default" do
      put_settings(hibernate_after: 20, settings: [workflow_offset_timeout_ms: 600_000])

      Application.put_env(
        :archon,
        Archon.Runtime,
        Keyword.delete(Application.get_env(:archon, Archon.Runtime), :evict_after)
      )

      evicted = start_simple(%{"x" => 1})
      assert stored_wake(evicted) - Runtime.now() > 60_000
      await_down(evicted)
    end

    test "a process with a :recover timer is not evicted" do
      put_settings(evict_after: 1_000, hibernate_after: 20)
      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)
      task_id = task(id, "task_a_ref").task_id

      RuntimeHooks.install(
        hook: fn
          :step, ^id, {:update, _result} -> raise "step down"
          _point, _id, _data -> :ok
        end
      )

      assert {:error, %RuntimeError{}} =
               WorkflowServer.update(%TaskResult{
                 workflow_instance_id: id,
                 task_id: task_id,
                 status: :in_progress
               })

      assert %{message: :recover, at: at} = :sys.get_state(pid).timer
      assert at - Runtime.now() > 5_000
      assert eventually(fn -> hibernating?(pid) end)
      assert WorkflowServer.whereis(id) == pid
    end

    test "a process whose next evaluation is within the activation margin stays" do
      # Else the waker would activate it at once and it would end again (evict_after < margin).
      put_settings(
        evict_after: 1_000,
        hibernate_after: 20,
        settings: [workflow_offset_timeout_ms: 3_000]
      )

      id = start_simple(%{"x" => 1})
      pid = WorkflowServer.whereis(id)
      assert (stored_wake(id) - Runtime.now()) in 1_001..5_000
      assert eventually(fn -> hibernating?(pid) end)
      assert WorkflowServer.whereis(id) == pid
    end
  end

  describe "folding the timer effects of one step (WorkflowServer.fold_wake/2)" do
    test "gives what the store has after applying them one by one" do
      cases = [
        {:keep, [], :keep},
        {:keep, [{:wake_at, 5}], {:at, 5}},
        {:keep, [{:wake_before, 5}], {:before, 5}},
        {:keep, [:cancel_wake], :none},
        {:keep, [{:wake_at, 9}, {:wake_before, 5}], {:at, 5}},
        {:keep, [{:wake_at, 3}, {:wake_before, 5}], {:at, 3}},
        {:keep, [{:wake_before, 9}, {:wake_before, 5}], {:before, 5}},
        {:keep, [:cancel_wake, {:wake_before, 5}], {:at, 5}},
        {:keep, [{:wake_before, 5}, {:wake_at, 9}], {:at, 9}},
        {:keep, [{:wake_at, 5}, :cancel_wake], :none},
        {:keep, [{:queue_remove, "q", "t"}, {:wake_at, 5}], {:at, 5}}
      ]

      for {wake, effects, expected} <- cases,
          do: assert(WorkflowServer.fold_wake(wake, effects) == expected, inspect(effects))
    end
  end
end
