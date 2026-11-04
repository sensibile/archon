# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.TaskLogTest do
  @moduledoc """
  The task execution logs of the runtime (ADR 0027, decision 6, slice 8d) beyond the contract
  replay: a task update's `logs` (the first 10, `null` entries, `createdTime`), the updates that
  write none, and the logs `updateAndPushParents` writes on each parent above a child that is
  retried, restarted or rerun, with the chain of workflows below, and none for a revival an
  outbox entry stored before.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{RerunWorkflowRequest, Task, TaskDef, TaskExecLog, TaskResult, Workflow}
  alias Archon.Domain.WorkflowDef
  alias Archon.Runtime.{Lifecycle, Outbox, Tasks}

  @child ~S"""
  {"name": "log_child", "version": 1, "tasks": [
    {"name": "log_task", "taskReferenceName": "t1", "type": "SIMPLE", "inputParameters": {}}]}
  """

  @parent ~S"""
  {"name": "log_parent", "version": 2, "tasks": [
    {"name": "log_sub", "taskReferenceName": "st", "type": "SUB_WORKFLOW",
     "inputParameters": {}, "subWorkflowParam": {"name": "log_child", "version": 1}}]}
  """

  @grand ~S"""
  {"name": "log_grand", "version": 1, "tasks": [
    {"name": "log_sub", "taskReferenceName": "st", "type": "SUB_WORKFLOW",
     "inputParameters": {}, "subWorkflowParam": {"name": "log_parent", "version": 2}}]}
  """

  setup do
    :ok = Runtime.metadata().update_task_def(%TaskDef{name: "log_task", retry_count: 0})
    :ok = Runtime.metadata().update_task_def(%TaskDef{name: "log_sub", retry_count: 0})

    for json <- [@child, @parent, @grand] do
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

  defp sub_task(id),
    do: eventually(fn -> (st = task(id, "st")) && Task.sub_workflow_id(st) && st end)

  # The latest t1 (a retry adds one), once it waits for a worker.
  defp scheduled_t1(id) do
    eventually(fn ->
      {:ok, wf} = Runtime.get_workflow(id)
      t1 = wf.tasks |> Enum.filter(&(&1.reference_task_name == "t1")) |> List.last()
      match?(%Task{status: :scheduled}, t1) and t1
    end)
  end

  defp update(id, task_id, status, logs \\ [], fields \\ []) do
    WorkflowServer.update(
      struct!(
        %TaskResult{workflow_instance_id: id, task_id: task_id, status: status, logs: logs},
        fields
      )
    )
  end

  # The child's task, polled and ended with `status`.
  defp finish(id, status) do
    t1 = scheduled_t1(id)
    assert %Task{status: :in_progress} = WorkflowServer.poll(id, t1.task_id, "w")
    assert %Task{status: ^status} = update(id, t1.task_id, status)
    t1
  end

  # grand -> parent -> child, all FAILED because the child's task failed.
  defp failed_family do
    grand = start("log_grand")
    gst = sub_task(grand)
    parent = Task.sub_workflow_id(gst)
    pst = sub_task(parent)
    child = Task.sub_workflow_id(pst)
    t1 = finish(child, :failed)
    for id <- [child, parent, grand], do: await_status(id, :failed)
    %{grand: grand, gst: gst.task_id, parent: parent, pst: pst.task_id, child: child, t1: t1}
  end

  defp texts(task_id), do: Enum.map(Tasks.logs(task_id), & &1.log)

  defp await_logs(task_id, count),
    do: eventually(fn -> length(texts(task_id)) >= count and texts(task_id) end)

  describe "a task update's logs" do
    test "the first 10 are kept, null entries dropped and a missing createdTime stamped" do
      id = start("log_child")
      t1 = scheduled_t1(id)
      WorkflowServer.poll(id, t1.task_id, "w")

      logs =
        [nil, %TaskExecLog{log: nil, created_time: 5}] ++
          for(n <- 1..11, do: %TaskExecLog{log: "l#{n}", created_time: 100 + n}) ++ [nil]

      before = Runtime.now()
      # a worker's IN_PROGRESS is saved SCHEDULED, with its logs
      assert %Task{status: :scheduled} = update(id, t1.task_id, :in_progress, logs)
      assert texts(t1.task_id) == for(n <- 1..10, do: "l#{n}")

      assert Enum.all?(Tasks.logs(t1.task_id), &(&1.task_id == t1.task_id)),
             "each log takes the updated task's ID"

      # A log without createdTime takes the time of the update; another task ID is ignored.
      update(id, t1.task_id, :in_progress, [%TaskExecLog{log: "now", task_id: "other"}])
      assert %TaskExecLog{created_time: time} = List.last(Tasks.logs(t1.task_id))
      assert time >= before and time <= Runtime.now()
      assert Tasks.logs("other") == []
    end

    test "an update of an ended task or workflow, or an extendLease, writes none" do
      id = start("log_child")
      t1 = scheduled_t1(id)
      WorkflowServer.poll(id, t1.task_id, "w")
      log = [%TaskExecLog{log: "x", created_time: 1}]

      update(id, t1.task_id, :in_progress, log, extend_lease: true)
      assert Tasks.logs(t1.task_id) == []

      update(id, t1.task_id, :completed, log)
      await_status(id, :completed)
      update(id, t1.task_id, :completed, [%TaskExecLog{log: "late", created_time: 2}])
      assert texts(t1.task_id) == ["x"]
    end
  end

  describe "the logs of a child that runs again (updateAndPushParents)" do
    test "a retry and a restart log on every parent above, with the chain below" do
      %{grand: grand, gst: gst, parent: parent, pst: pst, child: child} = failed_family()
      chain = "log_parent.2/#{parent} -> log_child.1/#{child}"

      assert Lifecycle.retry(child) == :ok
      assert await_logs(pst, 1) == ["Sub workflow log_child.1/#{child} retried."]
      assert await_logs(gst, 1) == ["Sub workflow #{chain} retried."]
      await_status(grand, :running)

      finish(child, :failed)
      for id <- [child, parent, grand], do: await_status(id, :failed)

      assert Lifecycle.restart(child) == :ok
      assert List.last(await_logs(pst, 2)) == "Sub workflow log_child.1/#{child} restarted."
      assert List.last(await_logs(gst, 2)) == "Sub workflow #{chain} restarted."
    end

    test "a rerun logs twice at each level, as every path of upstream's rerunWF walks twice" do
      %{grand: grand, gst: gst, parent: parent, pst: pst, child: child, t1: t1} = failed_family()

      assert Lifecycle.rerun(grand, %RerunWorkflowRequest{re_run_from_task_id: t1.task_id}) ==
               :ok

      child_line = "Sub workflow log_child.1/#{child} reran."
      assert await_logs(pst, 2) == [child_line, child_line]

      # The child's two walks reach the grandparent through the parent; then the parent's own
      # rerun (case 3) walks twice from the parent.
      chain_line = "Sub workflow log_parent.2/#{parent} -> log_child.1/#{child} reran."
      parent_line = "Sub workflow log_parent.2/#{parent} reran."
      assert await_logs(gst, 4) == [chain_line, chain_line, parent_line, parent_line]

      finish(child, :completed)
      await_status(grand, :completed)
      assert texts(pst) == [child_line, child_line]
    end

    # Self-review r1: two state-changing revivals reached a parent whose child ended again in its
    # first decide, so the parent ended twice and started its failure workflow twice.
    test "a rerun of a child that ends in its first decide ends the parent once" do
      for json <- [
            ~S({"name": "log_term_child", "version": 1, "tasks": [
              {"name": "term", "taskReferenceName": "term", "type": "TERMINATE",
               "inputParameters": {"terminationStatus": "FAILED"}}]}),
            ~S({"name": "log_handler", "version": 1, "tasks": [
              {"name": "log_task", "taskReferenceName": "t1", "type": "SIMPLE",
               "inputParameters": {}}]}),
            ~S({"name": "log_term_parent", "version": 1, "failureWorkflow": "log_handler",
              "tasks": [{"name": "log_sub", "taskReferenceName": "st", "type": "SUB_WORKFLOW",
                "inputParameters": {},
                "subWorkflowParam": {"name": "log_term_child", "version": 1}}]})
          ] do
        {:ok, definition} = json |> Jason.decode!() |> WorkflowDef.from_json()
        :ok = Runtime.metadata().update_workflow_def(definition)
      end

      handlers = fn -> length(Runtime.store().pending_workflow_ids("log_handler")) end
      parent = start("log_term_parent")
      st = sub_task(parent)
      ended = await_status(parent, :failed)
      assert eventually(fn -> handlers.() == 1 end)

      assert Lifecycle.rerun(Task.sub_workflow_id(st), %RerunWorkflowRequest{}) == :ok
      line = "Sub workflow log_term_child.1/#{Task.sub_workflow_id(st)} reran."
      assert await_logs(st.task_id, 2) == [line, line]
      assert eventually(fn -> handlers.() == 2 end)
      Process.sleep(300)

      assert %Workflow{status: :failed, end_count: end_count} = workflow(parent)
      assert end_count == ended.end_count + 1
      assert handlers.() == 2
      assert texts(st.task_id) == [line, line]
    end

    test "a revival an outbox entry stored before ADR 0027 revives without a log" do
      %{grand: grand, gst: gst, parent: parent, pst: pst, child: child} = failed_family()

      # The child runs again without asking its parent, which the entry of before then does: no
      # operation and no chain.
      assert WorkflowServer.retry(child, false) == :ok
      assert Outbox.run_effect(child, {:revive_parent, parent, pst}) == :ok
      await_status(parent, :running)
      await_status(grand, :running)
      assert task(parent, "st").status == :in_progress
      Process.sleep(200)
      assert Tasks.logs(pst) == []
      assert Tasks.logs(gst) == []
    end

    test "a walk that stops (an optional task) writes no log" do
      optional = ~S"""
      {"name": "log_optional", "version": 1, "tasks": [
        {"name": "log_sub", "taskReferenceName": "st", "type": "SUB_WORKFLOW", "optional": true,
         "inputParameters": {}, "subWorkflowParam": {"name": "log_child", "version": 1}}]}
      """

      {:ok, definition} = optional |> Jason.decode!() |> WorkflowDef.from_json()
      :ok = Runtime.metadata().update_workflow_def(definition)

      root = start("log_optional")
      st = sub_task(root)
      child = Task.sub_workflow_id(st)
      finish(child, :failed)
      await_status(root, :completed)

      assert Lifecycle.retry(child) == :ok
      assert eventually(fn -> Runtime.store().pending_outbox(child) == [] end)
      assert Tasks.logs(st.task_id) == []
    end
  end
end
