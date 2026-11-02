# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.TasksSignalTest do
  @moduledoc """
  `Archon.Runtime.Tasks` updates by reference and signals (ADR 0025 decision 5, slice 6e): the
  pending task's choice (reference name, `DO_WHILE` suffix, terminal tasks), the worker kept or
  cleared, the merged output, and the signal's search into children with the ownership check
  (ADR 0024, decision 2). Runs on the backend the suite runs on.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Contract
  alias Archon.Domain.{Codec, Task, TaskDef, Workflow, WorkflowDef}
  alias Archon.Runtime.Tasks

  setup do
    {:ok, task_defs} =
      Codec.cast(
        {:list, {:struct, TaskDef}},
        Contract.fixture("metadata_register_ops_taskdefs")["request"]["body"],
        []
      )

    for task_def <- task_defs, do: :ok = Runtime.metadata().update_task_def(task_def)

    for name <- ~w(waits signal_parent loop idle) do
      body = Contract.fixture("metadata_register_workflow_ops_#{name}")["request"]["body"]
      {:ok, definition} = WorkflowDef.from_json(body)
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

    isolate_queues(["archon_ops_a", "archon_ops_b", "archon_ops_idle"])
  end

  defp start(name, input \\ %{}) do
    {:ok, id} = Runtime.start_workflow(%{name: name, input: input})
    id
  end

  defp workflow(id) do
    {:ok, workflow} = Runtime.get_workflow(id, true)
    workflow
  end

  # The child of the parent's SUB_WORKFLOW task, once started.
  defp child(parent_id) do
    eventually(fn ->
      case workflow(parent_id).tasks do
        [%Task{} = task | _rest] -> Task.sub_workflow_id(task)
        [] -> nil
      end
    end)
  end

  describe "pending_task/2" do
    test "the first non-terminal task with the reference name, none for a terminal one" do
      id = start("archon_ops_waits")

      assert %Task{reference_task_name: "wait1_ref", status: :in_progress} =
               Tasks.pending_task(id, "wait1_ref")

      assert Tasks.pending_task(id, "wait2_ref") == nil

      assert {:ok, _task_id} = Tasks.update_by_ref(id, "wait1_ref", :completed, nil, %{})
      assert Tasks.pending_task(id, "wait1_ref") == nil

      assert %Task{reference_task_name: "wait2_ref"} =
               eventually(fn -> Tasks.pending_task(id, "wait2_ref") end)
    end

    test "a DO_WHILE iteration's task by its reference name without the suffix" do
      id = start("archon_ops_loop")
      task = eventually(fn -> Tasks.pending_task(id, "loop_b_ref") end)
      assert task.reference_task_name == "loop_b_ref__1"

      assert {:ok, _task_id} = Tasks.update_by_ref(id, "loop_b_ref", :completed, nil, %{"i" => 1})
      second = eventually(fn -> Tasks.pending_task(id, "loop_b_ref") end)
      assert second.reference_task_name == "loop_b_ref__2"
      assert Tasks.pending_task(id, "loop_b_ref__2").task_id == second.task_id
    end

    test "nil for an unknown workflow" do
      assert Tasks.pending_task("00000000-0000-0000-0000-000000000000", "wait1_ref") == nil

      assert Tasks.update_by_ref(
               "00000000-0000-0000-0000-000000000000",
               "x",
               :completed,
               nil,
               %{}
             ) == {:ok, nil}
    end
  end

  describe "update_by_ref/6" do
    test "merges the output and keeps the worker for a blank worker ID" do
      id = start("archon_ops_waits")
      task = Tasks.pending_task(id, "wait1_ref")

      assert Tasks.update_by_ref(id, "wait1_ref", :in_progress, "w-1", %{"a" => 1}) ==
               {:ok, task.task_id}

      assert %Task{worker_id: "w-1", output_data: %{"a" => 1}} = task(id, "wait1_ref")

      assert Tasks.update_by_ref(id, "wait1_ref", :in_progress, "  ", %{"b" => 2}) ==
               {:ok, task.task_id}

      assert %Task{worker_id: "w-1", output_data: %{"a" => 1, "b" => 2}} = task(id, "wait1_ref")

      assert {:ok, _task_id} =
               Tasks.update_by_ref(id, "wait1_ref", :completed, nil, %{"a" => 3},
                 keep_worker: false
               )

      assert %Task{worker_id: nil, status: :completed, output_data: %{"a" => 3, "b" => 2}} =
               task(id, "wait1_ref")
    end
  end

  describe "signal/3" do
    test "the workflow's first WAIT task that is not terminal" do
      id = start("archon_ops_waits")
      first = task(id, "wait1_ref")

      assert Tasks.signal(id, :completed, %{"s" => 1}) == {:ok, first.task_id}
      assert %Task{status: :completed, output_data: %{"s" => 1}} = task(id, "wait1_ref")
      eventually(fn -> task(id, "wait2_ref") end)
    end

    test "without a WAIT task, nothing is signalled" do
      id = start("archon_ops_idle")
      assert Tasks.signal(id, :completed, %{}) == {:ok, nil}
    end

    test "an unknown workflow is not found" do
      assert Tasks.signal("00000000-0000-0000-0000-000000000000", :completed, %{}) ==
               {:error,
                {:not_found, "No such workflow found by id: 00000000-0000-0000-0000-000000000000"}}
    end

    test "descends into the child of a running SUB_WORKFLOW task" do
      parent = start("archon_ops_signal_parent")
      child = child(parent)
      wait = eventually(fn -> task(child, "wait1_ref") end)

      assert Tasks.signal(parent, :completed, %{"s" => 9}) == {:ok, wait.task_id}
      assert %Task{status: :completed, output_data: %{"s" => 9}} = task(child, "wait1_ref")
    end

    # TaskServiceImpl#findPendingBlockingTask: a child without a blocked task leaves the search
    # to the next running SUB_WORKFLOW task.
    test "passes over a child without a WAIT task to the next running SUB_WORKFLOW task" do
      {:ok, definition} =
        WorkflowDef.from_json(%{
          "name" => "archon_test_gap_signal_fork",
          "version" => 1,
          "schemaVersion" => 2,
          "timeoutPolicy" => "ALERT_ONLY",
          "timeoutSeconds" => 0,
          "tasks" => [
            %{
              "name" => "fork",
              "taskReferenceName" => "fork_ref",
              "type" => "FORK_JOIN",
              "forkTasks" => [
                [
                  %{
                    "name" => "archon_ops_sub_once",
                    "taskReferenceName" => "idle_sub_ref",
                    "type" => "SUB_WORKFLOW",
                    "subWorkflowParam" => %{"name" => "archon_ops_idle", "version" => 1}
                  }
                ],
                [
                  %{
                    "name" => "archon_ops_sub_once",
                    "taskReferenceName" => "waits_sub_ref",
                    "type" => "SUB_WORKFLOW",
                    "subWorkflowParam" => %{"name" => "archon_ops_waits", "version" => 1}
                  }
                ]
              ]
            },
            %{
              "name" => "join",
              "taskReferenceName" => "join_ref",
              "type" => "JOIN",
              "joinOn" => ["idle_sub_ref", "waits_sub_ref"]
            }
          ]
        })

      :ok = Runtime.metadata().update_workflow_def(definition)
      parent = start("archon_test_gap_signal_fork")

      [idle, waits] =
        for ref <- ["idle_sub_ref", "waits_sub_ref"] do
          eventually(fn ->
            with %Task{} = sub <- task(parent, ref),
                 id when is_binary(id) <- Task.sub_workflow_id(sub),
                 do: id
          end)
        end

      eventually(fn -> task(idle, "idle_ref") end)
      wait = eventually(fn -> task(waits, "wait1_ref") end)

      assert [
               %Task{reference_task_name: "idle_sub_ref"},
               %Task{reference_task_name: "waits_sub_ref"}
             ] =
               Enum.filter(workflow(parent).tasks, &(&1.task_type == "SUB_WORKFLOW"))

      assert Tasks.signal(parent, :completed, %{"s" => 3}) == {:ok, wait.task_id}
      assert %Task{status: :completed, output_data: %{"s" => 3}} = task(waits, "wait1_ref")
      assert %Task{status: :scheduled} = task(idle, "idle_ref")
    end
  end

  describe "signal/3 and children it cannot use" do
    # ADR 0025 decision 5 with the ownership check of ADR 0024 decision 2: a SUB_WORKFLOW task
    # whose stored child ID names a workflow of another parent and task does not reach that
    # workflow's WAIT task.
    test "a child of another parent and task is passed over, and its WAIT task is left alone" do
      owner = start("archon_ops_signal_parent")
      child = child(owner)
      wait = eventually(fn -> task(child, "wait1_ref") end)
      stored = workflow(owner)
      id = "archon-test-gap-" <> Runtime.new_id()

      tasks =
        for %Task{} = task <- stored.tasks,
            do: %{task | task_id: Runtime.new_id(), workflow_instance_id: id}

      assert [%Task{task_type: "SUB_WORKFLOW", status: :in_progress} = sub] = tasks
      assert Task.sub_workflow_id(sub) == child

      :ok =
        Runtime.store().commit(id, %Archon.Runtime.Commit{
          create: %{stored | workflow_id: id, tasks: tasks}
        })

      on_exit(fn -> Runtime.store().remove_workflow(id) end)

      assert Tasks.signal(id, :completed, %{"s" => 1}) == {:ok, nil}

      assert %Task{task_id: task_id, status: :in_progress, output_data: output} =
               task(child, "wait1_ref")

      assert task_id == wait.task_id
      refute Map.has_key?(output, "s")
    end

    test "a child removed from the store is not found, as upstream's read" do
      parent = start("archon_ops_signal_parent")
      child = child(parent)
      eventually(fn -> task(child, "wait1_ref") end)
      :ok = Runtime.store().remove_workflow(child)

      assert Tasks.signal(parent, :completed, %{}) ==
               {:error, {:not_found, "No such workflow found by id: #{child}"}}
    end
  end

  describe "owned_child/3" do
    setup do
      parent = start("archon_ops_signal_parent")
      child = child(parent)
      %{parent: workflow(parent), child: child}
    end

    test "the child its SUB_WORKFLOW task started", %{parent: parent, child: child} do
      [task] = parent.tasks
      assert {:ok, %Workflow{workflow_id: ^child}} = Tasks.owned_child(parent, task, [])
    end

    test "nil for a workflow of another parent or task, and for a seen ID", %{
      parent: parent,
      child: child
    } do
      [task] = parent.tasks
      other = start("archon_ops_waits")

      assert Tasks.owned_child(parent, %{task | sub_workflow_id: other}, []) == {:ok, nil}
      assert Tasks.owned_child(parent, %{task | task_id: "another-task"}, []) == {:ok, nil}
      assert Tasks.owned_child(%{parent | workflow_id: "another-parent"}, task, []) == {:ok, nil}
      assert Tasks.owned_child(parent, task, [child]) == {:ok, nil}
    end

    test "an unknown child is not found", %{parent: parent} do
      [task] = parent.tasks

      assert Tasks.owned_child(parent, %{task | sub_workflow_id: "missing-child"}, []) ==
               {:error, {:not_found, "No such workflow found by id: missing-child"}}
    end
  end
end
