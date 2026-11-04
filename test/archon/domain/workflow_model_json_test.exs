# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Domain.WorkflowModelJsonTest do
  @moduledoc """
  `Archon.Domain.WorkflowModelJson` beyond the `bulk/search` fixtures (ADR 0027, decision 5,
  slice 8e), which hold a SIMPLE task only: the getters upstream's `TaskModel` derives from its
  input and the tasks no task mapper created.
  """

  use ExUnit.Case, async: true

  alias Archon.Domain.{Task, Workflow, WorkflowDef, WorkflowModelJson, WorkflowTask}

  @now 1_793_751_742_809

  defp definition do
    {:ok, definition} =
      WorkflowDef.from_json(%{
        "name" => "archon_8e_model",
        "version" => 1,
        "tasks" => [
          %{
            "name" => "fjd",
            "taskReferenceName" => "fjd",
            "type" => "FORK_JOIN_DYNAMIC",
            "dynamicForkTasksParam" => "tasks",
            "dynamicForkTasksInputParamName" => "inputs"
          },
          %{"name" => "dyn_join", "taskReferenceName" => "dyn_join", "type" => "JOIN"},
          %{
            "name" => "fork",
            "taskReferenceName" => "fork",
            "type" => "FORK_JOIN",
            "forkTasks" => [
              [%{"name" => "worker", "taskReferenceName" => "worker", "type" => "SIMPLE"}]
            ]
          },
          %{
            "name" => "join",
            "taskReferenceName" => "join",
            "type" => "JOIN",
            "joinOn" => ["worker"]
          }
        ]
      })

    definition
  end

  defp task(definition, ref, fields \\ []) do
    struct!(
      %Task{
        task_type: WorkflowDef.task_by_ref_name(definition, ref).type,
        reference_task_name: ref,
        task_id: "task-#{ref}",
        status: :in_progress,
        workflow_task: WorkflowDef.task_by_ref_name(definition, ref)
      },
      fields
    )
  end

  defp workflow(tasks, definition) do
    %Workflow{
      workflow_id: "archon-8e-model",
      status: :running,
      workflow_definition: definition,
      create_time: 1,
      update_time: 2,
      tasks: tasks
    }
  end

  test "the JOIN a FORK_JOIN_DYNAMIC creates has no onStateChange; mapped tasks have theirs" do
    definition = definition()
    tasks = Enum.map(~w(fjd dyn_join fork worker join), &task(definition, &1))

    json = WorkflowModelJson.workflow(workflow(tasks, definition), @now)
    by_ref = Map.new(json["tasks"], &{&1["referenceTaskName"], &1})

    refute Map.has_key?(by_ref["dyn_join"], "onStateChange")

    for ref <- ~w(fjd fork worker join),
        do: assert(by_ref[ref]["onStateChange"] == %{}, ref)

    # after a skipped dynamic fork (no workflow task) the JOIN mapper made the JOIN
    # (Archon.Runtime.Step.Lifecycle.skip_task/2's stub)
    skipped_fork = %{
      task(definition, "fjd")
      | status: :skipped,
        workflow_task: %WorkflowTask{name: "fjd", task_reference_name: "fjd"}
    }

    json = WorkflowModelJson.workflow(workflow([skipped_fork | tl(tasks)], definition), @now)
    by_ref = Map.new(json["tasks"], &{&1["referenceTaskName"], &1})
    assert by_ref["dyn_join"]["onStateChange"] == %{}

    # a task without its workflow task (a skipped one) has none either
    skipped = %{task(definition, "worker") | workflow_task: nil}
    refute Map.has_key?(WorkflowModelJson.task(skipped, @now), "onStateChange")
  end

  test "asyncComplete is the input's when the key is there, else the workflow task's" do
    definition = definition()

    %WorkflowTask{} = worker = WorkflowDef.task_by_ref_name(definition, "worker")
    async_task = %{worker | async_complete: true}

    for {input, workflow_task, expected} <- [
          {%{"asyncComplete" => true}, nil, true},
          {%{"asyncComplete" => false}, async_task, false},
          {%{"asyncComplete" => nil}, async_task, false},
          {%{}, async_task, true},
          {%{}, nil, false}
        ] do
      task = %{task(definition, "worker") | input_data: input, workflow_task: workflow_task}

      assert %{"asyncComplete" => ^expected, "idempotentExecution" => false} =
               WorkflowModelJson.task(task, @now)
    end
  end

  test "the reason is not cut, the output is the stored one, and the internal fields are kept" do
    definition = definition()
    reason = String.duplicate("r", 600)

    task =
      task(definition, "worker",
        reason_for_incompletion: reason,
        output_data: %{"subWorkflowId" => "stored"},
        sub_workflow_id: "own",
        loop_task_id: "loop-1",
        callback_after_ms: 1500,
        first_scheduled_time: 7,
        wait_timeout: 9
      )

    assert %{
             "reasonForIncompletion" => ^reason,
             "outputData" => %{"subWorkflowId" => "stored"},
             "loopTaskId" => "loop-1",
             "callbackAfterMs" => 1500,
             "firstScheduledTime" => 7,
             "waitTimeout" => 9
           } = WorkflowModelJson.task(task, @now)
  end

  test "previousStatus, failedTaskId and the failed names only when there are some" do
    definition = definition()

    json = WorkflowModelJson.workflow(workflow([], definition), @now)
    refute Map.has_key?(json, "previousStatus")
    refute Map.has_key?(json, "failedReferenceTaskNames")
    assert json["updatedTime"] == 2

    failed = %{
      workflow([], definition)
      | status: :failed,
        previous_status: :running,
        failed_task_id: "task-worker",
        failed_reference_task_names: ["worker"],
        failed_task_names: ["worker"]
    }

    assert %{
             "previousStatus" => "RUNNING",
             "failedTaskId" => "task-worker",
             "failedReferenceTaskNames" => ["worker"],
             "failedTaskNames" => ["worker"]
           } = WorkflowModelJson.workflow(failed, @now)
  end
end
