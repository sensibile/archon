# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Domain.StartWorkflowRequestTest do
  use ExUnit.Case, async: true

  alias Archon.Domain.{StartWorkflowRequest, WorkflowDef}

  describe "from_json/1" do
    test "a missing key is upstream's field initializer, an explicit null is null" do
      assert {:ok, request} = StartWorkflowRequest.from_json(%{"name" => "w"})
      assert %{input: %{}, task_to_domain: %{}, priority: 0, version: nil} = request

      assert {:ok, request} =
               StartWorkflowRequest.from_json(%{
                 "input" => nil,
                 "taskToDomain" => nil,
                 "priority" => nil
               })

      assert %{input: nil, task_to_domain: nil, priority: nil} = request
    end

    test "reads every field, the inline definition as a WorkflowDef" do
      json = %{
        "name" => "w",
        "version" => "2",
        "correlationId" => "c",
        "input" => %{"a" => nil},
        "taskToDomain" => %{"t" => 1},
        "workflowDef" => %{"name" => "d", "tasks" => []},
        "externalInputPayloadStoragePath" => "p",
        "priority" => 1.7,
        "createdBy" => "me",
        "idempotencyKey" => "k",
        "idempotencyStrategy" => "RETURN_EXISTING"
      }

      assert {:ok, request} = StartWorkflowRequest.from_json(json)

      assert %StartWorkflowRequest{
               version: 2,
               task_to_domain: %{"t" => "1"},
               workflow_def: %WorkflowDef{name: "d", tasks: []},
               priority: 1,
               idempotency_strategy: :return_existing
             } = request

      assert StartWorkflowRequest.to_json(request)["idempotencyStrategy"] == "RETURN_EXISTING"
    end

    test "a value of the wrong type is a codec error with its path" do
      assert {:error, [{"input", "must be object"}]} =
               StartWorkflowRequest.from_json(%{"input" => []})

      assert {:error, [{"idempotencyStrategy", _message}]} =
               StartWorkflowRequest.from_json(%{"idempotencyStrategy" => "BAD"})

      assert {:error, [{"", "must be object"}]} = StartWorkflowRequest.from_json([])
    end
  end

  describe "validate/1" do
    test "name is @NotNull only: an empty name passes" do
      assert StartWorkflowRequest.validate(%StartWorkflowRequest{name: ""}) == :ok

      assert StartWorkflowRequest.validate(%StartWorkflowRequest{}) ==
               {:error, [{"name", "Workflow name cannot be null or empty"}]}
    end

    test "priority is 0 to 99, a null priority passes" do
      assert StartWorkflowRequest.validate(%StartWorkflowRequest{name: "w", priority: nil}) == :ok

      assert StartWorkflowRequest.validate(%StartWorkflowRequest{name: "w", priority: 100}) ==
               {:error, [{"priority", "priority: 100 should be maximum 99"}]}

      assert StartWorkflowRequest.validate(%StartWorkflowRequest{name: "w", priority: -1}) ==
               {:error, [{"priority", "priority: -1 should be minimum 0"}]}
    end

    test "the inline definition is validated under workflowDef" do
      request = %StartWorkflowRequest{name: "w", workflow_def: %WorkflowDef{name: "", tasks: []}}

      assert {:error, errors} = StartWorkflowRequest.validate(request)

      assert Enum.sort(errors) == [
               {"workflowDef.name", "WorkflowDef name cannot be null or empty"},
               {"workflowDef.tasks", "WorkflowTask list cannot be empty"}
             ]
    end
  end

  describe "to_start_input/1" do
    test "copies the request fields only: no workflow ID and no parent fields" do
      {:ok, request} =
        StartWorkflowRequest.from_json(%{
          "name" => "w",
          "version" => 3,
          "correlationId" => "c",
          "input" => %{"x" => 1},
          "taskToDomain" => %{"t" => "d"},
          "priority" => 5,
          "workflowId" => "chosen",
          "parentWorkflowId" => "parent",
          "parentWorkflowTaskId" => "parent-task",
          "triggeringWorkflowId" => "trigger"
        })

      assert StartWorkflowRequest.to_start_input(request) == %{
               name: "w",
               version: 3,
               definition: nil,
               input: %{"x" => 1},
               correlation_id: "c",
               priority: 5,
               task_to_domain: %{"t" => "d"}
             }
    end
  end
end
