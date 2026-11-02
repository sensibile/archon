# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Scenarios derived from conductor-oss test-harness/src/test/groovy/com/netflix/conductor/test/integration/StartWorkflowSpec.groovy
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the workflows run as processes, so there is no system task executor to
# call; the started workflow is a SIMPLE one instead of the spec's.

defmodule Archon.Runtime.StartWorkflowTest do
  @moduledoc """
  `START_WORKFLOW` through the running runtime (ADR 0026, decision 7): the effect starts the
  workflow after the starting workflow's commit, a transient failure is tried again, a result
  lost after the start is recovered with the same workflow, and a rerun starts another one.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{RerunWorkflowRequest, Task, Workflow, WorkflowDef}
  alias Archon.Runtime.Lifecycle
  alias Archon.Runtime.Step.StartWorkflow

  @target ~S"""
  {"name": "archon_sw_target", "version": 1, "tasks": [
    {"name": "archon_sw_target_task", "taskReferenceName": "t1", "type": "SIMPLE",
     "inputParameters": {"x": "${workflow.input.x}"}}]}
  """

  @starter ~S"""
  {"name": "archon_sw_starter", "version": 1, "tasks": [
    {"name": "archon_sw_start", "taskReferenceName": "start_ref", "type": "START_WORKFLOW",
     "inputParameters": {"startWorkflow": "${workflow.input.request}"}}],
   "outputParameters": {"started": "${start_ref.output.workflowId}"}}
  """

  setup do
    for json <- [@target, @starter] do
      {:ok, definition} = json |> JSON.decode!() |> WorkflowDef.from_json()
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

    :ok
  end

  defp start(request, fields \\ []) do
    {:ok, id} =
      Runtime.start_workflow(
        Map.merge(%{name: "archon_sw_starter", input: %{"request" => request}}, Map.new(fields))
      )

    id
  end

  defp workflow(id) do
    {:ok, workflow} = Runtime.get_workflow(id)
    workflow
  end

  defp await_status(id, status),
    do: eventually(fn -> match?(%Workflow{status: ^status}, workflow(id)) and workflow(id) end)

  defp request(fields \\ %{}),
    do: Map.merge(%{"name" => "archon_sw_target", "version" => 1, "input" => %{"x" => 1}}, fields)

  describe "StartWorkflowSpec" do
    test "start another workflow: the task completes with its ID, which runs on its own" do
      id = start(request(), correlation_id: "archon-sw-1")

      starter = await_status(id, :completed)

      assert [%Task{task_type: "START_WORKFLOW", status: :completed, poll_count: 1} = task] =
               starter.tasks

      started_id = StartWorkflow.workflow_id(id, task)
      assert task.output_data == %{"workflowId" => started_id}
      assert starter.output == %{"started" => started_id}

      started =
        eventually(fn -> match?([_], workflow(started_id).tasks) and workflow(started_id) end)

      assert %Workflow{
               status: :running,
               correlation_id: "archon-sw-1",
               parent_workflow_id: nil,
               parent_workflow_task_id: nil,
               input: %{"x" => 1}
             } = started

      assert [%Task{reference_task_name: "t1", status: :scheduled, input_data: %{"x" => 1}}] =
               started.tasks
    end

    test "start_workflow does not conform to StartWorkflowRequest" do
      id = start(%{"version" => 1})
      starter = await_status(id, :failed)

      assert [%Task{status: :failed, reason_for_incompletion: reason}] = starter.tasks

      assert reason ==
               "startWorkflow validation failed. 'name' -> Workflow name cannot be null or empty. "
    end

    test "a workflow without a definition fails the task with upstream's message" do
      id = start(request(%{"name" => "archon_sw_missing", "version" => nil}))
      starter = await_status(id, :failed)

      assert [%Task{status: :failed, reason_for_incompletion: reason}] = starter.tasks
      assert reason == "No such workflow defined. name=archon_sw_missing, version=null"
    end
  end

  describe "the effect and its result" do
    test "a commit failure of the started workflow is transient: the next :wake starts it" do
      starter_id = "archon-sw-starter-" <> Runtime.new_id()

      RuntimeHooks.install(
        clock: 1_000_000,
        timer: self(),
        hook: fn
          :commit, id, _commit when id != starter_id -> raise "store down"
          _point, _id, _data -> :ok
        end
      )

      start(request(), workflow_id: starter_id)

      :sys.get_state(WorkflowServer.whereis(starter_id))
      task = task(starter_id, "start_ref")

      assert %Task{status: :scheduled, reason_for_incompletion: nil, callback_after_seconds: 30} =
               task

      started_id = StartWorkflow.workflow_id(starter_id, task)
      assert Runtime.get_workflow(started_id) == {:error, :not_found}

      RuntimeHooks.install(hook: fn _point, _id, _data -> :ok end)
      RuntimeHooks.advance(30_000)
      send(WorkflowServer.whereis(starter_id), :wake)

      starter = await_status(starter_id, :completed)

      assert [
               %Task{
                 status: :completed,
                 poll_count: 2,
                 output_data: %{"workflowId" => ^started_id}
               }
             ] =
               starter.tasks

      assert workflow(started_id).status == :running
    end

    test "a result lost after the start: the recovery starts again and gets the same workflow" do
      starter_id = "archon-sw-starter-" <> Runtime.new_id()
      lost = :atomics.new(1, [])

      RuntimeHooks.install(
        timer: self(),
        hook: fn
          :step, ^starter_id, {:workflow_started, _task_id, {:ok, _started}} ->
            if :atomics.add_get(lost, 1, 1) == 1, do: raise("lost result")

          _point, _id, _data ->
            :ok
        end
      )

      start(request(), workflow_id: starter_id, correlation_id: starter_id)

      # the deferred start ran and its result's step failed (isolated)
      pid = WorkflowServer.whereis(starter_id)
      :sys.get_state(pid)
      assert :atomics.get(lost, 1) == 1
      task = task(starter_id, "start_ref")
      assert %Task{status: :scheduled, poll_count: 1} = task

      started_id = StartWorkflow.workflow_id(starter_id, task)

      %Workflow{create_time: created} =
        eventually(fn ->
          match?({:ok, _}, Runtime.get_workflow(started_id)) and workflow(started_id)
        end)

      send(pid, :recover)
      starter = await_status(starter_id, :completed)

      assert [
               %Task{
                 status: :completed,
                 poll_count: 2,
                 output_data: %{"workflowId" => ^started_id}
               }
             ] =
               starter.tasks

      assert %Workflow{create_time: ^created} = workflow(started_id)

      assert %{^starter_id => [%Workflow{workflow_id: ^started_id}]} =
               Runtime.correlated_workflows("archon_sw_target", [starter_id], true, false)
    end

    test "a rerun of the task starts another workflow" do
      id = start(request(), correlation_id: "archon-sw-rerun")
      starter = await_status(id, :completed)
      [%Task{task_id: task_id} = task] = starter.tasks
      first = StartWorkflow.workflow_id(id, task)

      assert :ok = Lifecycle.rerun(id, %RerunWorkflowRequest{re_run_from_task_id: task_id})

      starter =
        eventually(fn ->
          w = workflow(id)
          w.status == :completed and hd(w.tasks).output_data["workflowId"] != first and w
        end)

      [rerun_task] = starter.tasks
      second = rerun_task.output_data["workflowId"]
      assert second == StartWorkflow.workflow_id(id, rerun_task)
      assert workflow(first).status == :running
      assert workflow(second).status == :running
    end
  end
end
