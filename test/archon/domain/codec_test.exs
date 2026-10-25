defmodule Archon.Domain.CodecTest do
  use ExUnit.Case, async: true

  alias Archon.Domain.{Codec, TaskDef, WorkflowDef, WorkflowTask}

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
end
