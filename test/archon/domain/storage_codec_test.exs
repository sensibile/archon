defmodule Archon.Domain.StorageCodecTest do
  @moduledoc """
  The storage encoding (`to_storage/1`, `from_storage/1`, ADR 0021 decision 2) gives back the
  same struct through JSON text, including internal fields and values that the REST encoding
  changes or drops.
  """

  use ExUnit.Case, async: true

  alias Archon.Contract

  alias Archon.Domain.{
    ExecutionMetadata,
    SubWorkflowParams,
    Task,
    TaskDef,
    Workflow,
    WorkflowDef,
    WorkflowTask
  }

  @fixtures [
    {"metadata_get_taskdef", TaskDef},
    {"metadata_get_workflow", WorkflowDef},
    {"metadata_get_workflow_fork", WorkflowDef},
    {"metadata_get_workflow_switch", WorkflowDef},
    {"task_get", Task},
    {"task_poll_fork_b", Task},
    {"workflow_get_completed_fork", Workflow},
    {"workflow_get_completed_simple", Workflow},
    {"workflow_get_completed_switch", Workflow},
    {"workflow_get_running", Workflow},
    {"workflow_get_terminated", Workflow},
    {"workflow_get_without_tasks", Workflow}
  ]

  for {name, module} <- @fixtures do
    test "#{name} round-trips through the storage encoding" do
      body = Contract.fixture(unquote(name))["response"]["body"]
      assert {:ok, struct} = unquote(module).from_json(body)
      assert round_trip(unquote(module), struct) == struct
    end
  end

  test "a workflow keeps its internal fields and the values REST would change" do
    workflow = workflow()

    assert round_trip(Workflow, workflow) == workflow

    stored = Workflow.to_storage(workflow)
    assert stored["endCount"] == 2
    assert stored["revivedParentEndCount"] == 1
    assert stored["previousStatus"] == "RUNNING"
    assert stored["failedTaskId"] == "t-1"
    # Only the storage encoding has them; the REST shape is unchanged.
    refute Map.has_key?(Workflow.to_json(workflow), "endCount")
    refute Map.has_key?(Workflow.to_json(workflow), "revivedParentEndCount")
  end

  test "a task keeps its internal fields and its stored names and reason" do
    task = hd(workflow().tasks)

    assert round_trip(Task, task) == task
    # REST resolves these from other fields and cuts the reason to 500 characters.
    assert {:ok, rest} = task |> Task.to_json(0) |> json_text() |> Task.from_json()
    refute rest == task
  end

  test "definitions keep explicit nils and inline sub workflow definitions" do
    definition = workflow().workflow_definition

    assert round_trip(WorkflowDef, definition) == definition
    task_def = %TaskDef{name: "t", input_keys: nil, input_template: nil}
    assert round_trip(TaskDef, task_def) == task_def

    # A workflowDefinition string that REST would refuse is still given back as stored.
    params = %SubWorkflowParams{workflow_definition: "manual"}

    stored = %WorkflowDef{
      name: "p",
      tasks: [%WorkflowTask{name: "s", sub_workflow_param: params}]
    }

    assert round_trip(WorkflowDef, stored) == stored
    assert {:error, _errors} = stored |> WorkflowDef.to_json() |> WorkflowDef.from_json()
  end

  test "strings with NUL survive the JSON text" do
    workflow = %Workflow{
      workflow_id: "w\u0000id",
      input: %{"k\u0000" => "v\u0000", "list" => ["\u0000", nil, 1.5]},
      reason_for_incompletion: "a\u0000b"
    }

    assert round_trip(Workflow, workflow) == workflow
  end

  test "keys missing from older rows decode to the field defaults" do
    assert {:ok, workflow} = Workflow.from_storage(%{"workflowId" => "w", "status" => "PAUSED"})
    assert workflow.status == :paused
    assert workflow.end_count == 0
    assert workflow.revived_parent_end_count == 0
    assert workflow.tasks == []
    assert workflow.input == %{}
  end

  test "an invalid stored value is a decode error" do
    assert {:error, [{"endCount", "must be integer"}]} =
             Workflow.from_storage(%{"endCount" => "many"})

    assert {:error, [{"tasks[0].status", _message}]} =
             Workflow.from_storage(%{"tasks" => [%{"status" => "NOPE"}]})
  end

  defp workflow do
    sub_definition = %WorkflowDef{
      name: "child",
      version: 3,
      tasks: [%WorkflowTask{name: "c", task_reference_name: "c", input_parameters: nil}]
    }

    definition = %WorkflowDef{
      name: "parent",
      version: 1,
      input_parameters: nil,
      tasks: [
        %WorkflowTask{
          name: "sub",
          task_reference_name: "sub",
          type: "SUB_WORKFLOW",
          decision_cases: nil,
          sub_workflow_param: %SubWorkflowParams{workflow_definition: sub_definition}
        },
        %WorkflowTask{
          name: "dsl",
          task_reference_name: "dsl",
          type: "SUB_WORKFLOW",
          sub_workflow_param: %SubWorkflowParams{
            name: "x",
            workflow_definition: "${wf.input.def}"
          }
        }
      ]
    }

    task = %Task{
      task_id: "t-1",
      task_type: "SIMPLE",
      task_def_name: nil,
      status: :failed,
      seq: 1,
      reason_for_incompletion: String.duplicate("r", 600),
      output_data: %{"subWorkflowId" => "from-output"},
      sub_workflow_id: nil,
      runtime_metadata: %{},
      execution_metadata: %ExecutionMetadata{execution_start_time: 5, additional_context: %{}},
      workflow_task: hd(definition.tasks),
      first_scheduled_time: 10,
      wait_timeout: 20,
      loop_task_id: "loop",
      callback_after_ms: 30
    }

    %Workflow{
      workflow_id: "w-1",
      status: :failed,
      create_time: 100,
      end_time: 200,
      tasks: [task, nil],
      task_to_domain: nil,
      variables: nil,
      failed_task_names: ["a", "a"],
      workflow_definition: definition,
      history: [%Workflow{workflow_id: "w-1", status: :completed, end_count: 1}],
      previous_status: :running,
      failed_task_id: "t-1",
      end_count: 2,
      revived_parent_end_count: 1
    }
  end

  # Encodes through the real JSON text, as a `json_data` column holds it.
  defp round_trip(module, struct) do
    assert {:ok, decoded} = struct |> module.to_storage() |> json_text() |> module.from_storage()
    decoded
  end

  defp json_text(json), do: json |> JSON.encode!() |> JSON.decode!()
end
