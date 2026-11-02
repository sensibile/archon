# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.DynamicTest do
  @moduledoc """
  `DYNAMIC` and `FORK_JOIN_DYNAMIC` on the runtime (ADR 0026, decision 4, slice 7c), on the
  backend `ARCHON_BACKEND` selects: a retry and the reruns of a dynamic fork (from a branch, and
  from the `FORK`, which makes the branches again), an update of a dynamic branch that always
  decides (`lazy_evaluate?/2`), `forkTaskWorkflow` branches whose definition only the lookup
  finds, and the definition a `DYNAMIC` task changes, stored, also inside a `DO_WHILE`.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{RerunWorkflowRequest, Task, TaskDef, TaskResult, Workflow, WorkflowDef}
  alias Archon.Runtime.Lifecycle
  alias Archon.Runtime.Step.Tasks

  @fork ~S"""
  {"name": "p7c_fork", "version": 1, "tasks": [
    {"name": "p7c_fjd", "taskReferenceName": "fjd", "type": "FORK_JOIN_DYNAMIC",
     "inputParameters": {"forkTaskName": "p7c_worker", "forkTaskInputs": "${workflow.input.inputs}"}},
    {"name": "p7c_join", "taskReferenceName": "join", "type": "JOIN"}]}
  """

  @sub_fork ~S"""
  {"name": "p7c_sub_fork", "version": 1, "tasks": [
    {"name": "p7c_fjd", "taskReferenceName": "fjd", "type": "FORK_JOIN_DYNAMIC",
     "inputParameters": {"forkTaskWorkflow": "p7c_child", "forkTaskInputs": [{"a": 1}]}},
    {"name": "p7c_join", "taskReferenceName": "join", "type": "JOIN"}]}
  """

  @child ~S"""
  {"name": "p7c_child", "version": 3, "tasks": [
    {"name": "p7c_worker", "taskReferenceName": "w", "type": "SIMPLE"}]}
  """

  @dynamic ~S"""
  {"name": "p7c_dynamic", "version": 1, "tasks": [
    {"name": "p7c_dyn", "taskReferenceName": "dyn", "type": "DYNAMIC",
     "dynamicTaskNameParam": "name", "inputParameters": {"name": "${workflow.input.name}"}}]}
  """

  # The DYNAMIC task resolves to another name in each iteration.
  @loop ~S"""
  {"name": "p7c_loop", "version": 1, "tasks": [
    {"name": "p7c_loop", "taskReferenceName": "loop", "type": "DO_WHILE",
     "loopCondition": "if ($.loop['iteration'] < 2) { true; } else { false; }",
     "loopOver": [
       {"name": "p7c_dyn", "taskReferenceName": "dyn", "type": "DYNAMIC",
        "dynamicTaskNameParam": "name",
        "inputParameters": {"name": "p7c_${loop.output.iteration}"}}]}]}
  """

  setup do
    for name <- ["p7c_worker", "p7c_a", "p7c_b"],
        do: :ok = Runtime.metadata().update_task_def(%TaskDef{name: name, retry_count: 0})

    # The DYNAMIC workflow task's own definition, which its tasks take: one retry.
    :ok = Runtime.metadata().update_task_def(%TaskDef{name: "p7c_dyn", retry_count: 1})

    for json <- [@fork, @sub_fork, @child, @dynamic, @loop] do
      {:ok, definition} = json |> Jason.decode!() |> WorkflowDef.from_json()
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

    :ok
  end

  ## Helpers

  defp start(name, input) do
    {:ok, id} = Runtime.start_workflow(%{name: name, input: input})
    id
  end

  defp workflow(id) do
    {:ok, workflow} = Runtime.get_workflow(id)
    workflow
  end

  defp await_status(id, status),
    do: eventually(fn -> match?(%Workflow{status: ^status}, workflow(id)) and workflow(id) end)

  defp scheduled(id, count) do
    eventually(fn ->
      tasks = for %Task{status: :scheduled} = task <- workflow(id).tasks, do: task
      length(tasks) == count and tasks
    end)
  end

  defp update(id, %Task{task_id: task_id}, status) do
    assert %Task{status: ^status} =
             WorkflowServer.update(%TaskResult{
               workflow_instance_id: id,
               task_id: task_id,
               status: status,
               output_data: %{"done" => task_id}
             })
  end

  defp complete_all(id, count) do
    for task <- scheduled(id, count), do: update(id, task, :completed)
    await_status(id, :completed)
  end

  defp summary(%Workflow{tasks: tasks}),
    do: for(t <- tasks, do: {t.reference_task_name, t.task_type, t.status, t.retry_count})

  defp rerun(id, fields), do: Lifecycle.rerun(id, struct(RerunWorkflowRequest, fields))

  describe "a dynamic fork" do
    test "a retry schedules both branches again and the JOIN completes" do
      id = start("p7c_fork", %{"inputs" => [%{"a" => 1}, %{"a" => 2}]})
      [first, _second] = scheduled(id, 2)

      update(id, first, :failed)
      await_status(id, :failed)

      assert WorkflowServer.retry(id, false) == :ok
      complete_all(id, 2)

      assert [
               {"fjd", "FORK", :completed, 0},
               {"_p7c_worker_0", "p7c_worker", :failed, 0},
               {"_p7c_worker_1", "p7c_worker", :canceled, 0},
               {"join", "JOIN", :completed, 0},
               {"_p7c_worker_0", "p7c_worker", :completed, 1},
               {"_p7c_worker_1", "p7c_worker", :completed, 1}
             ] = summary(workflow(id))
    end

    test "a rerun from the FORK makes the fork, its branches and its JOIN again" do
      id = start("p7c_fork", %{"inputs" => [%{"a" => 1}, %{"a" => 2}]})
      complete_all(id, 2)
      fork = task(id, "fjd")

      assert rerun(id, re_run_from_task_id: fork.task_id) == :ok

      wf = eventually(fn -> (wf = workflow(id)) && length(wf.tasks) == 4 && wf end)
      assert wf.status == :running

      assert [
               {"fjd", "FORK", :completed, 0},
               {"_p7c_worker_0", "p7c_worker", :scheduled, 0},
               {"_p7c_worker_1", "p7c_worker", :scheduled, 0},
               {"join", "JOIN", :in_progress, 0}
             ] = summary(wf)

      new_fork = task(id, "fjd")
      assert new_fork.task_id != fork.task_id
      assert new_fork.seq == fork.seq
      assert task(id, "join").input_data["joinOn"] == ["_p7c_worker_0", "_p7c_worker_1"]

      complete_all(id, 2)
    end

    test "a rerun from a branch runs that branch again and deletes the tasks after it" do
      id = start("p7c_fork", %{"inputs" => [%{"a" => 1}, %{"a" => 2}]})
      complete_all(id, 2)
      branch = task(id, "_p7c_worker_1")

      assert rerun(id, re_run_from_task_id: branch.task_id, task_input: %{"a" => 20}) == :ok

      [rerun_branch] = scheduled(id, 1)
      assert rerun_branch.task_id == branch.task_id
      assert rerun_branch.input_data == %{"a" => 20}

      # upstream's seq-based removal takes the JOIN (seq 4) with it; nothing schedules it again,
      # so the workflow stays RUNNING once the branch completes (checkForWorkflowCompletion wants a
      # terminal task for every task of the definition)
      assert task(id, "join") == nil
      update(id, rerun_branch, :completed)
      assert %Task{status: :completed} = task(id, "_p7c_worker_1")
      assert %Workflow{status: :running} = workflow(id)
      assert task(id, "join") == nil
    end

    # finalizeRerun schedules the new branches without setTaskDomains, unlike a decide.
    test "a rerun from the FORK gives the new branches no domain" do
      {:ok, id} =
        Runtime.start_workflow(%{
          name: "p7c_fork",
          input: %{"inputs" => [%{"a" => 1}]},
          task_to_domain: %{"*" => "d"}
        })

      [branch] = scheduled(id, 1)
      assert branch.domain == "d"
      update(id, branch, :completed)
      await_status(id, :completed)

      assert rerun(id, re_run_from_task_id: task(id, "fjd").task_id) == :ok
      [rerun_branch] = scheduled(id, 1)
      assert rerun_branch.task_id != branch.task_id
      assert rerun_branch.domain == nil
    end

    test "a rerun from the FORK whose mapper terminates fails the workflow" do
      id = start("p7c_fork", %{"inputs" => [%{"a" => 1}]})
      complete_all(id, 1)
      fork = task(id, "fjd")

      assert rerun(id, re_run_from_task_id: fork.task_id, workflow_input: %{}) == :ok

      wf = await_status(id, :failed)
      assert wf.reason_for_incompletion =~ ~r/^Dynamic tasks could not be created/
      assert task(id, "fjd") == nil
    end

    test "an update of a dynamic branch is never lazy" do
      id = start("p7c_fork", %{"inputs" => [%{"a" => 1}]})
      [branch] = scheduled(id, 1)

      refute Tasks.lazy_evaluate?(workflow(id).workflow_definition, %{branch | status: :completed})

      update(id, branch, :completed)
      await_status(id, :completed)
    end

    test "forkTaskWorkflow branches take the child's latest version from the lookup" do
      id = start("p7c_sub_fork", %{})

      # without forkTaskName the branches are named after the fork's reference name
      sub = eventually(fn -> (st = task(id, "_fjd_0")) && Task.sub_workflow_id(st) && st end)
      assert sub.task_type == "SUB_WORKFLOW"
      assert sub.input_data["subWorkflowName"] == "p7c_child"
      assert sub.input_data["subWorkflowVersion"] == 3

      child = Task.sub_workflow_id(sub)
      complete_all(child, 1)
      await_status(id, :completed)
    end
  end

  describe "a DYNAMIC task" do
    test "schedules the resolved name and stores the changed definition" do
      id = start("p7c_dynamic", %{"name" => "p7c_a"})
      [dyn] = scheduled(id, 1)

      assert dyn.task_type == "p7c_a"
      assert dyn.task_def_name == "p7c_a"
      assert dyn.workflow_task.name == "p7c_a"
      assert dyn.workflow_task.task_definition.name == "p7c_dyn"

      assert [%{name: "p7c_a", task_definition: %TaskDef{name: "p7c_dyn"}}] =
               workflow(id).workflow_definition.tasks

      # a retry copy keeps the resolved name
      update(id, dyn, :failed)
      [retried] = scheduled(id, 1)
      assert {retried.task_type, retried.retry_count} == {"p7c_a", 1}
      update(id, retried, :completed)
      await_status(id, :completed)
    end

    test "inside a DO_WHILE resolves each iteration and leaves the definition as it is" do
      id = start("p7c_loop", %{})

      [first] = scheduled(id, 1)
      assert {first.reference_task_name, first.task_type} == {"dyn__1", "p7c_1"}
      update(id, first, :completed)

      second = eventually(fn -> (t = task(id, "dyn__2")) && t.status == :scheduled && t end)
      assert second.task_type == "p7c_2"

      # a retry copy of the second iteration does not write its name into the definition
      update(id, second, :failed)

      retried =
        eventually(fn ->
          Enum.find(
            workflow(id).tasks,
            &(&1.reference_task_name == "dyn__2" and &1.retry_count == 1)
          )
        end)

      assert retried.task_type == "p7c_2"
      [%{loop_over: [dyn]}] = workflow(id).workflow_definition.tasks
      assert dyn.name == "p7c_dyn"

      update(id, retried, :completed)
      await_status(id, :completed)
    end
  end
end
