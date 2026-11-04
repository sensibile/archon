# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.RerunTest do
  @moduledoc """
  `Archon.Runtime.Lifecycle.rerun/2` (ADR 0025, decision 2, slice 6f) beyond the contract
  replay: the read-only checks on the way down (a child that has not ended, one the store does not
  have or that belongs to another task), a rerun inside a child that revives its parent twice
  (its own revival and the parent's case 3) and runs to the end once, and a whole rerun that
  revives the parent.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{RerunWorkflowRequest, Task, TaskDef, TaskResult, Workflow, WorkflowDef}
  alias Archon.Runtime.{Commit, Lifecycle}

  @child ~S"""
  {"name": "rerun_child", "version": 1, "tasks": [
    {"name": "rerun_task", "taskReferenceName": "t1", "type": "SIMPLE", "inputParameters": {}}]}
  """

  @parent ~S"""
  {"name": "rerun_parent", "version": 1, "tasks": [
    {"name": "rerun_sub", "taskReferenceName": "st", "type": "SUB_WORKFLOW",
     "inputParameters": {}, "subWorkflowParam": {"name": "rerun_child", "version": 1},
     "retryCount": 0}]}
  """

  setup do
    :ok = Runtime.metadata().update_task_def(%TaskDef{name: "rerun_task", retry_count: 0})

    for json <- [@child, @parent] do
      {:ok, definition} = json |> Jason.decode!() |> WorkflowDef.from_json()
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

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
    do: eventually(fn -> (st = task(id, "st")) && Task.sub_workflow_id(st) end)

  defp finish(id, status) do
    t1 =
      eventually(fn -> match?(%Task{status: :scheduled}, task(id, "t1")) and task(id, "t1") end)

    assert %Task{status: :in_progress} = WorkflowServer.poll(id, t1.task_id, "w")

    assert %Task{status: ^status} =
             WorkflowServer.update(%TaskResult{
               workflow_instance_id: id,
               task_id: t1.task_id,
               status: status
             })

    t1
  end

  # A parent FAILED because its child's task failed.
  defp failed_pair do
    parent = start("rerun_parent")
    child = child_of(parent)
    t1 = finish(child, :failed)
    await_status(child, :failed)
    await_status(parent, :failed)
    {parent, child, t1}
  end

  defp rerun(id, fields), do: Lifecycle.rerun(id, struct(RerunWorkflowRequest, fields))

  describe "the checks on the way down" do
    test "a running workflow, a task found nowhere" do
      id = start("rerun_child")

      assert rerun(id, []) ==
               {:error,
                {:conflict,
                 "Workflow: rerun_child.1/#{id}.RUNNING is not in terminal state, unable to rerun."}}

      assert Runtime.terminate_workflow(id, "stop") == :ok

      assert rerun(id, re_run_from_task_id: "missing") ==
               {:error, {:invalid, "Task missing not found"}}
    end

    test "a child that has not ended is a conflict, one that is gone is not found" do
      {parent, child, _t1} = failed_pair()

      # the child runs again on its own (a retry that does not revive the parent)
      assert WorkflowServer.retry(child, false) == :ok
      assert workflow(parent).status == :failed

      assert rerun(parent, re_run_from_task_id: "missing") ==
               {:error,
                {:conflict,
                 "Workflow: rerun_child.1/#{child}.RUNNING is not in terminal state, unable to rerun."}}

      assert Runtime.terminate_workflow(child, "stop") == :ok
      assert Lifecycle.remove(child, false) == :ok

      assert rerun(parent, re_run_from_task_id: "missing") ==
               {:error, {:not_found, "No such workflow found by id: #{child}"}}
    end

    test "a child that belongs to another task is not looked into" do
      {parent, child, t1} = failed_pair()
      st = task(parent, "st")

      # the child now names another parent task (ADR 0024, decision 2)
      :ok =
        Runtime.store().commit(child, %Commit{
          workflow: %{workflow(child) | parent_workflow_task_id: "another-task"}
        })

      assert rerun(parent, re_run_from_task_id: t1.task_id) ==
               {:error, {:not_found, "No such workflow found by id: #{child}"}}

      assert %Task{status: :failed} = task(parent, st.reference_task_name)
    end
  end

  describe "a rerun inside a child" do
    test "revives the parent twice and runs to the end once" do
      {parent, child, t1} = failed_pair()

      assert rerun(parent, re_run_from_task_id: t1.task_id, task_input: %{"c" => 1}) == :ok

      # at the answer every workflow on the way runs again
      assert %Workflow{status: :running, tasks: [%Task{status: :in_progress} = st]} =
               workflow(parent)

      assert Task.sub_workflow_id(st) == child
      # only case 3 writes this: the revival from below stamped it, case 3 keeps the value read
      assert workflow(parent).last_retried_time == 0
      assert %Workflow{status: :running, tasks: [%Task{status: :scheduled} = t]} = workflow(child)
      assert t.task_id == t1.task_id and t.input_data == %{"c" => 1}

      finish(child, :completed)
      await_status(child, :completed)
      parent_wf = await_status(parent, :completed)

      # the revival and the case 3 message left one task, attached to the same child
      assert [%Task{status: :completed} = st] = parent_wf.tasks
      assert Task.sub_workflow_id(st) == child
      assert eventually(fn -> Runtime.store().pending_outbox(child) == [] end)
      assert eventually(fn -> Runtime.store().pending_outbox(parent) == [] end)
    end

    test "a child that ends while the rerun waits for its outbox keeps its parent's end" do
      {parent, child, t1} = failed_pair()
      test = self()
      held = :counters.new(1, [:atomics])

      RuntimeHooks.install(
        hook: fn
          :outbox, ^child, {_entry, effect} ->
            if :counters.get(held, 1) == 0 do
              :counters.add(held, 1, 1)
              send(test, {:held, self(), effect})

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

      rerun =
        Elixir.Task.async(fn ->
          rerun(parent,
            re_run_from_task_id: t1.task_id,
            workflow_input: %{"late" => true},
            correlation_id: "rerun-late"
          )
        end)

      assert_receive {:held, runner, {:revive_parent, ^parent, _task, "reran", _chain}}, 2_000

      # the worker finishes the task while the rerun waits on the child's outbox
      finish(child, :completed)
      send(runner, :release)

      assert Elixir.Task.await(rerun, 5_000) == :ok
      parent_wf = await_status(parent, :completed)
      assert [%Task{status: :completed}] = parent_wf.tasks
      Process.sleep(200)
      assert workflow(parent).status == :completed
      assert workflow(parent).end_count == parent_wf.end_count
      # case 3 still gave the top workflow what the request asked of it
      assert %Workflow{input: %{"late" => true}, correlation_id: "rerun-late"} = workflow(parent)
    end

    test "the input and correlation ID go to the top workflow only" do
      {parent, child, t1} = failed_pair()
      child_input = workflow(child).input

      assert rerun(parent,
               re_run_from_task_id: t1.task_id,
               workflow_input: %{"p" => 1},
               correlation_id: "rerun-top"
             ) == :ok

      assert %Workflow{input: %{"p" => 1}, correlation_id: "rerun-top"} = workflow(parent)
      assert %Workflow{input: ^child_input, correlation_id: nil} = workflow(child)
    end
  end

  # WorkflowExecutorOps#finalizeRerun: after a direct rerun, every task of another reference that
  # ended unsuccessfully runs again; a JOIN is set IN_PROGRESS in place, other tasks SCHEDULED.
  describe "finalizeRerun" do
    @fork ~S"""
    {"name": "rerun_fork", "version": 1, "tasks": [
      {"name": "fork", "taskReferenceName": "fork", "type": "FORK_JOIN", "inputParameters": {},
       "forkTasks": [
        [{"name": "rerun_task", "taskReferenceName": "a", "type": "SIMPLE", "inputParameters": {}}],
        [{"name": "rerun_task", "taskReferenceName": "b", "type": "SIMPLE", "inputParameters": {}},
         {"name": "rerun_task", "taskReferenceName": "c", "type": "SIMPLE",
          "inputParameters": {}}]]},
      {"name": "join", "taskReferenceName": "join", "type": "JOIN", "inputParameters": {},
       "joinOn": ["a", "c"]}]}
    """

    defp run_task(id, ref, status) do
      t = eventually(fn -> match?(%Task{status: :scheduled}, task(id, ref)) and task(id, ref) end)
      assert %Task{status: :in_progress} = WorkflowServer.poll(id, t.task_id, "w")

      assert %Task{status: ^status} =
               WorkflowServer.update(%TaskResult{
                 workflow_instance_id: id,
                 task_id: t.task_id,
                 status: status
               })

      t
    end

    test "a JOIN canceled with the workflow runs again in place beside the rerun task" do
      {:ok, definition} = @fork |> Jason.decode!() |> WorkflowDef.from_json()
      :ok = Runtime.metadata().update_workflow_def(definition)

      id = start("rerun_fork")
      run_task(id, "b", :completed)
      # c is scheduled after the JOIN, so the rerun from c keeps the JOIN
      c = run_task(id, "c", :failed)
      await_status(id, :failed)
      assert %Task{status: :canceled} = task(id, "a")
      assert %Task{status: :canceled} = join = task(id, "join")
      assert join.seq < c.seq

      assert rerun(id, re_run_from_task_id: c.task_id) == :ok

      assert %Workflow{status: :running} = workflow(id)
      assert %Task{status: :in_progress} = new_join = task(id, "join")
      assert new_join.task_id == join.task_id
      assert %Task{status: :scheduled} = task(id, "a")

      run_task(id, "a", :completed)
      run_task(id, "c", :completed)
      assert await_status(id, :completed)
    end
  end

  describe "a child's notice to a canceled task" do
    test "a parent that ended and canceled the task keeps it without the child's reason" do
      parent = start("rerun_parent")
      child = child_of(parent)

      assert Runtime.terminate_workflow(parent, "stop") == :ok
      assert await_status(child, :terminated)
      assert eventually(fn -> Runtime.store().pending_outbox(child) == [] end)
      assert %Task{status: :canceled, reason_for_incompletion: nil} = task(parent, "st")
    end

    test "a task a client canceled still takes its child's later reason" do
      parent = start("rerun_parent")
      child = child_of(parent)
      st = task(parent, "st")

      WorkflowServer.update(%TaskResult{
        workflow_instance_id: parent,
        task_id: st.task_id,
        status: :canceled
      })

      assert %Task{status: :canceled} = task(parent, "st")
      assert Runtime.terminate_workflow(child, "client-stop") == :ok
      assert eventually(fn -> Runtime.store().pending_outbox(child) == [] end)

      assert eventually(fn ->
               (task(parent, "st").reason_for_incompletion || "") =~ "failure reason: client-stop"
             end)
    end

    test "a child terminated on its own still cancels its task with the reason" do
      parent = start("rerun_parent")
      child = child_of(parent)

      assert Runtime.terminate_workflow(child, "stop") == :ok
      assert await_status(parent, :terminated)
      assert %Task{status: :canceled, reason_for_incompletion: reason} = task(parent, "st")
      assert reason =~ "Sub workflow rerun_child.1/#{child} failure reason: stop"
    end
  end

  test "a whole rerun of a child revives its parent" do
    {parent, child, _t1} = failed_pair()

    assert rerun(child, workflow_input: %{"again" => true}) == :ok
    assert %Workflow{status: :running, input: %{"again" => true}} = workflow(child)

    assert eventually(fn ->
             match?(
               %Workflow{status: :running, tasks: [%Task{status: :in_progress}]},
               workflow(parent)
             )
           end)

    finish(child, :completed)
    assert await_status(parent, :completed)
  end
end
