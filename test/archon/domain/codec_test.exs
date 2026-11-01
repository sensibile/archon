defmodule Archon.Domain.CodecTest do
  use ExUnit.Case, async: true

  alias Archon.Domain.{Codec, Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}

  describe "missing keys and explicit null (Jackson defaults)" do
    test "a missing key keeps the field initializer" do
      assert {:ok, task_def} = TaskDef.from_json(%{"name" => "t"})
      assert task_def.retry_count == 3
      assert task_def.response_timeout_seconds == 3600
      assert task_def.timeout_policy == :time_out_wf
      assert task_def.input_keys == []
    end

    test "null on a primitive becomes its zero value (FAIL_ON_NULL_FOR_PRIMITIVES = false)" do
      assert {:ok, task_def} = TaskDef.from_json(%{"retryCount" => nil, "enforceSchema" => nil})
      assert task_def.retry_count == 0
      assert task_def.enforce_schema == false
    end

    test "null on a boxed field or collection is kept and then omitted (NON_NULL)" do
      json = %{
        "name" => "t",
        "inputKeys" => nil,
        "timeoutPolicy" => nil,
        "pollTimeoutSeconds" => nil
      }

      assert {:ok, task_def} = TaskDef.from_json(json)
      assert task_def.input_keys == nil

      encoded = TaskDef.to_json(task_def)
      refute Map.has_key?(encoded, "inputKeys")
      refute Map.has_key?(encoded, "timeoutPolicy")
      refute Map.has_key?(encoded, "pollTimeoutSeconds")
    end

    test "getter fallbacks for null are applied" do
      assert {:ok, task_def} =
               TaskDef.from_json(%{
                 "rateLimitPerFrequency" => nil,
                 "rateLimitFrequencyInSeconds" => nil
               })

      assert %{"rateLimitPerFrequency" => 0, "rateLimitFrequencyInSeconds" => 1} =
               TaskDef.to_json(task_def)
    end

    test "null values inside free-form maps are kept" do
      assert {:ok, task} = WorkflowTask.from_json(%{"inputParameters" => %{"a" => nil}})
      assert WorkflowTask.to_json(task)["inputParameters"] == %{"a" => nil}
    end
  end

  test "unknown keys are ignored (FAIL_ON_UNKNOWN_PROPERTIES = false)" do
    assert {:ok, task_def} = TaskDef.from_json(%{"name" => "t", "somethingNew" => 1})
    refute Map.has_key?(TaskDef.to_json(task_def), "somethingNew")
  end

  describe "scalar coercion" do
    test "integers accept integral strings and truncate floats" do
      assert {:ok, %TaskDef{retry_count: 5, timeout_seconds: 2}} =
               TaskDef.from_json(%{"retryCount" => "5", "timeoutSeconds" => 2.9})
    end

    test "booleans accept true/false strings" do
      assert {:ok, %TaskDef{enforce_schema: true}} =
               TaskDef.from_json(%{"enforceSchema" => "true"})
    end

    test "strings accept numbers and booleans" do
      assert {:ok, %TaskDef{name: "12", description: "true"}} =
               TaskDef.from_json(%{"name" => 12, "description" => true})
    end
  end

  describe "errors" do
    # A body within the 8 MB limit holds this many bad elements; appending each error to the
    # ones before it would take minutes (ADR 0023, slice 5c review).
    test "many errors are gathered in order without quadratic copying" do
      items = List.duplicate(false, 200_000)

      assert {:error, errors} = Codec.cast({:list, {:struct, TaskDef}}, items, [], [])
      assert length(errors) == 200_000
      assert Enum.take(errors, 2) == [{"[0]", "must be object"}, {"[1]", "must be object"}]
      assert List.last(errors) == {"[199999]", "must be object"}
    end

    test "a non-object body is rejected" do
      assert {:error, [{"", "must be object"}]} = TaskDef.from_json([1])
    end

    test "unknown enum constants are rejected" do
      assert {:error, [{"timeoutPolicy", message}]} =
               TaskDef.from_json(%{"timeoutPolicy" => "retry"})

      assert message == "must be one of RETRY, TIME_OUT_WF, ALERT_ONLY"
    end

    test "all type errors are reported with nested paths" do
      json = %{
        "name" => "wf",
        "version" => "one",
        "tasks" => [
          %{"name" => "a", "taskReferenceName" => "a"},
          %{
            "name" => "s",
            "taskReferenceName" => "s",
            "type" => "SWITCH",
            "decisionCases" => %{"b" => [%{"name" => "x", "startDelay" => []}]},
            "forkTasks" => [[%{"optional" => "maybe"}]]
          }
        ]
      }

      assert {:error, errors} = WorkflowDef.from_json(json)

      assert errors == [
               {"version", "must be integer"},
               {"tasks[1].decisionCases[b][0].startDelay", "must be integer"},
               {"tasks[1].forkTasks[0][0].optional", "must be boolean"}
             ]
    end
  end

  test "enum atoms map to upstream constant names" do
    assert Codec.enum_name(:time_out_wf) == "TIME_OUT_WF"
    assert Codec.enum_name(:failed_with_terminal_error) == "FAILED_WITH_TERMINAL_ERROR"
  end

  test "deeply nested definitions round trip" do
    leaf = %{"name" => "leaf", "taskReferenceName" => "leaf"}

    nested =
      Enum.reduce(1..20, leaf, fn depth, inner ->
        %{
          "name" => "loop#{depth}",
          "taskReferenceName" => "loop#{depth}",
          "type" => "DO_WHILE",
          "loopOver" => [inner]
        }
      end)

    assert {:ok, task} = WorkflowTask.from_json(nested)
    assert length(WorkflowTask.collect_tasks(task)) == 21
    assert {:ok, ^task} = task |> WorkflowTask.to_json() |> WorkflowTask.from_json()
  end

  describe "internal fields (wire: false)" do
    test "are never encoded" do
      task = %Task{
        task_id: "t1",
        first_scheduled_time: 10,
        wait_timeout: 20,
        loop_task_id: "loop",
        callback_after_ms: 30
      }

      json = Task.to_json(task)
      assert json["taskId"] == "t1"

      for key <- ["firstScheduledTime", "waitTimeout", "loopTaskId", "callbackAfterMs"] do
        refute Map.has_key?(json, key)
      end

      workflow = %Workflow{workflow_id: "w1", previous_status: :paused, failed_task_id: "t1"}
      json = Workflow.to_json(workflow)
      refute Map.has_key?(json, "previousStatus")
      refute Map.has_key?(json, "failedTaskId")
    end

    test "decode to their defaults even when the key is present" do
      json = %{"firstScheduledTime" => 10, "loopTaskId" => "loop", "callbackAfterMs" => "x"}

      assert {:ok, task} = Task.from_json(json)
      assert task.first_scheduled_time == 0
      assert task.loop_task_id == nil
      assert task.callback_after_ms == 0

      assert {:ok, workflow} = Workflow.from_json(%{"previousStatus" => "PAUSED"})
      assert workflow.previous_status == nil
    end
  end
end
