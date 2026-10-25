# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss common/src/test/java/com/netflix/conductor/common/
# tasks/TaskTest.java, tasks/TaskResultTest.java and workflow/SubWorkflowParamsTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests against the Elixir structs; tests of Java
# copy/equals/toString behaviour that have no Elixir counterpart were dropped.

defmodule Archon.Domain.ExecutionModelTest do
  use ExUnit.Case, async: true

  alias Archon.Domain.{
    ExecutionMetadata,
    SubWorkflowParams,
    Task,
    TaskDef,
    TaskExecLog,
    TaskResult,
    Workflow,
    WorkflowDef,
    WorkflowTask
  }

  describe "TaskTest" do
    test "test (every TaskResult status is a Task status)" do
      for status <- [:in_progress, :failed, :failed_with_terminal_error, :completed, :canceled] do
        assert status in Task.statuses()
      end
    end

    test "testTaskDefinitionIfAvailable" do
      task = %Task{status: :failed}
      assert Task.task_definition(task) == nil
      assert Task.to_json(task)["taskDefinition"] == nil

      definition = %TaskDef{}
      task = %{task | workflow_task: %WorkflowTask{task_definition: definition}}
      assert Task.task_definition(task) == definition
      assert Task.to_json(task)["taskDefinition"] == TaskDef.to_json(definition)
    end

    test "testTaskQueueWaitTime" do
      now = System.system_time(:millisecond)
      task = %Task{scheduled_time: now - 30_000, start_time: now - 25_000}
      assert Task.queue_wait_time(task, now) == 5000

      task = %{task | update_time: now - 20_000, callback_after_seconds: 10}
      assert Task.queue_wait_time(task, now) == 10_000
      assert Task.queue_wait_time(task, now - 60_000) == 0
    end

    test "testRuntimeMetadataSerializedOnlyWhenNonEmpty" do
      task = %Task{task_id: "task-1", runtime_metadata: %{"OPENAI_API_KEY" => "sk-secret-value"}}
      assert Task.to_json(task)["runtimeMetadata"] == %{"OPENAI_API_KEY" => "sk-secret-value"}
      refute Map.has_key?(Task.to_json(%Task{task_id: "task-2"}), "runtimeMetadata")
    end

    test "testSetRuntimeMetadataNullGuard" do
      assert {:ok, %Task{runtime_metadata: %{}}} = Task.from_json(%{"runtimeMetadata" => nil})
    end

    test "testExecutionMetadataHelperGettersNotSerialized" do
      metadata = %ExecutionMetadata{server_send_time: 1000, client_receive_time: 2000}
      json = Task.to_json(%Task{task_id: "task-1", execution_metadata: metadata})

      refute Map.has_key?(json, "orCreateExecutionMetadata")
      refute Map.has_key?(json, "executionMetadataIfHasData")
      assert json["executionMetadata"]["serverSendTime"] == 1000

      assert {:ok, %Task{execution_metadata: ^metadata}} =
               json |> JSON.encode!() |> JSON.decode!() |> Task.from_json()
    end
  end

  describe "Task beyond the upstream tests" do
    test "status flags match upstream Task.Status" do
      assert Enum.filter(Task.statuses(), &Task.terminal?/1) ==
               ~w(canceled failed failed_with_terminal_error completed completed_with_errors timed_out skipped)a

      assert Enum.filter(Task.statuses(), &Task.successful?/1) ==
               ~w(in_progress completed completed_with_errors scheduled skipped)a

      assert Enum.reject(Task.statuses(), &Task.retriable?/1) ==
               ~w(canceled failed_with_terminal_error skipped)a
    end

    test "taskDefName and subWorkflowId fall back like upstream getters" do
      task = %Task{task_type: "HTTP", output_data: %{"subWorkflowId" => "sub-1"}}
      assert %{"taskDefName" => "HTTP", "subWorkflowId" => "sub-1"} = Task.to_json(task)

      task = %Task{
        task_type: "HTTP",
        task_def_name: "",
        input_data: %{"subWorkflowId" => "sub-2"}
      }

      assert %{"taskDefName" => "HTTP", "subWorkflowId" => "sub-2"} = Task.to_json(task)
    end

    test "an empty executionMetadata is always written" do
      assert Task.to_json(%Task{})["executionMetadata"] == %{
               "additionalContext" => %{},
               "additionalContextMap" => %{},
               "empty" => true
             }
    end

    test "reasonForIncompletion is cut to 500 characters" do
      long = String.duplicate("x", 600)

      assert {:ok, %Task{reason_for_incompletion: reason}} =
               Task.from_json(%{"reasonForIncompletion" => long})

      assert String.length(reason) == 500
    end

    test "derived keys are ignored when decoding" do
      assert {:ok, task} =
               Task.from_json(%{"queueWaitTime" => 5, "loopOverTask" => true, "iteration" => 0})

      refute Task.loop_over_task?(task)
    end
  end

  describe "TaskResultTest" do
    setup do
      task = %Task{
        workflow_instance_id: "workflow-id",
        task_id: "task-id",
        reason_for_incompletion: "reason",
        callback_after_seconds: 10,
        worker_id: "worker-id",
        output_data: %{},
        external_output_payload_storage_path: "externalOutput"
      }

      %{task: task}
    end

    for {task_status, result_status} <- [
          canceled: :canceled,
          completed_with_errors: :failed,
          scheduled: :in_progress,
          completed: :completed
        ] do
      test "#{task_status} task maps to #{result_status}", %{task: task} do
        result = TaskResult.from_task(%{task | status: unquote(task_status)})

        assert result.status == unquote(result_status)
        assert result.workflow_instance_id == task.workflow_instance_id
        assert result.task_id == task.task_id
        assert result.reason_for_incompletion == task.reason_for_incompletion
        assert result.callback_after_seconds == task.callback_after_seconds
        assert result.worker_id == task.worker_id
        assert result.output_data == task.output_data

        assert result.external_output_payload_storage_path ==
                 task.external_output_payload_storage_path
      end
    end
  end

  describe "TaskResult beyond the upstream tests" do
    test "ids are @NotEmpty" do
      assert TaskResult.validate(%TaskResult{}) ==
               {:error,
                [
                  {"workflowInstanceId", "Workflow Id cannot be null or empty"},
                  {"taskId", "Task ID cannot be null or empty"}
                ]}

      assert TaskResult.validate(%TaskResult{workflow_instance_id: "w", task_id: "t"}) == :ok
    end

    test "executionMetadata is written only with data" do
      refute Map.has_key?(
               TaskResult.to_json(%TaskResult{execution_metadata: %ExecutionMetadata{}}),
               "executionMetadata"
             )

      metadata = %ExecutionMetadata{execution_start_time: 10, execution_end_time: 25}

      assert %{"executionMetadata" => %{"executionDuration" => 15, "empty" => false}} =
               TaskResult.to_json(%TaskResult{execution_metadata: metadata})
    end

    test "logs decode as TaskExecLog" do
      json = %{"logs" => [%{"log" => "hello", "createdTime" => 5}]}

      assert {:ok, %TaskResult{logs: [%TaskExecLog{log: "hello", created_time: 5}]}} =
               TaskResult.from_json(json)
    end

    test "worker-only statuses are rejected" do
      assert {:error, [{"status", _}]} = TaskResult.from_json(%{"status" => "SCHEDULED"})
    end
  end

  describe "SubWorkflowParamsTest" do
    test "testWorkflowSetTaskToDomain" do
      assert {:ok, %SubWorkflowParams{task_to_domain: %{"unit" => "test"}}} =
               SubWorkflowParams.from_json(%{"taskToDomain" => %{"unit" => "test"}})
    end

    test "testSetWorkflowDefinition (invalid values are rejected)" do
      assert {:error, [{"workflowDefinition", message}]} =
               SubWorkflowParams.from_json(%{"name" => "dummy-name", "workflowDefinition" => 1})

      assert message ==
               "workflowDefinition must be either null, or WorkflowDef, or a valid DSL string"

      assert {:error,
              [
                {"workflowDefinition",
                 "workflowDefinition is a string, but not a valid DSL string"}
              ]} =
               SubWorkflowParams.from_json(%{"workflowDefinition" => "not-dsl"})
    end

    test "testGetWorkflowDef / testWorkflowDefJson" do
      definition = %WorkflowDef{
        name: "test_workflow",
        version: 1,
        tasks: [%WorkflowTask{name: "test_task", task_reference_name: "t1"}]
      }

      params = %SubWorkflowParams{name: "dummy-name", workflow_definition: definition}
      json = params |> SubWorkflowParams.to_json() |> JSON.encode!() |> JSON.decode!()

      # The inline definition's name wins over the field, as in upstream's getName().
      assert json["name"] == "test_workflow"

      assert {:ok, %SubWorkflowParams{workflow_definition: ^definition}} =
               SubWorkflowParams.from_json(json)
    end

    test "a ${...} expression is kept as a string" do
      assert {:ok, %SubWorkflowParams{workflow_definition: "${workflow.input.def}"}} =
               SubWorkflowParams.from_json(%{"workflowDefinition" => "${workflow.input.def}"})
    end
  end

  describe "Workflow" do
    test "startTime is an alias of createTime" do
      assert {:ok, %Workflow{create_time: 42}} = Workflow.from_json(%{"startTime" => 42})

      assert {:ok, %Workflow{create_time: 7}} =
               Workflow.from_json(%{"startTime" => 42, "createTime" => 7})

      assert Workflow.to_json(%Workflow{create_time: 7})["startTime"] == 7
    end

    test "workflowName and workflowVersion come from the definition" do
      workflow = %Workflow{workflow_definition: %WorkflowDef{name: "wf", version: 3}}
      assert %{"workflowName" => "wf", "workflowVersion" => 3} = Workflow.to_json(workflow)
      assert {Workflow.workflow_name(workflow), Workflow.workflow_version(workflow)} == {"wf", 3}

      json = Workflow.to_json(%Workflow{})
      refute Map.has_key?(json, "workflowName")
      refute Map.has_key?(json, "workflowVersion")
    end

    test "failed task name sets drop duplicates" do
      assert {:ok, %Workflow{failed_task_names: ["a", "b"]}} =
               Workflow.from_json(%{"failedTaskNames" => ["a", "b", "a"]})
    end

    test "history is recursive" do
      json = %{"workflowId" => "w2", "history" => [%{"workflowId" => "w1", "status" => "FAILED"}]}

      assert {:ok, %Workflow{history: [%Workflow{workflow_id: "w1", status: :failed}]}} =
               Workflow.from_json(json)
    end

    test "status flags match upstream WorkflowStatus" do
      assert Enum.filter(Workflow.statuses(), &Workflow.terminal?/1) ==
               ~w(completed failed timed_out terminated)a

      assert Enum.filter(Workflow.statuses(), &Workflow.successful?/1) == ~w(completed paused)a
    end

    test "priority is limited to 0..99" do
      assert Workflow.validate(%Workflow{priority: 99}) == :ok

      assert Workflow.validate(%Workflow{priority: 100}) ==
               {:error, [{"priority", "workflow priority: 100 should be maximum 99"}]}

      assert Workflow.validate(%Workflow{priority: -1}) ==
               {:error, [{"priority", "workflow priority: -1 should be minimum 0"}]}
    end
  end
end
