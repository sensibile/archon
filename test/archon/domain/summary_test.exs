# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Domain.SummaryTest do
  @moduledoc """
  `WorkflowSummary` and `TaskSummary` (ADR 0027, decision 3). The expected JSON and values are
  the output of upstream's classes (conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`,
  `conductor-common`) serialized by its `ObjectMapperProvider` (Jackson 2.18.8) on JDK 25, for
  the same workflows and tasks; maps with several keys have their keys in sorted order there so
  that `Map#toString` agrees.
  """

  use ExUnit.Case, async: true

  alias Archon.Domain.{SummaryUtil, Task, TaskSummary, Workflow, WorkflowDef, WorkflowSummary}

  # U+2028 and U+2003, which source strings cannot hold literally.
  @ls <<0x2028::utf8>>
  @em_space <<0x2003::utf8>>

  describe "WorkflowSummary" do
    test "writes upstream's JSON for a finished workflow" do
      workflow = %Workflow{
        workflow_definition: %WorkflowDef{
          name: "p8_wf",
          version: 3,
          metadata: %{"classifier" => " " <> @em_space, "agentDef" => "x"}
        },
        workflow_id: "wf-1",
        correlation_id: "c" <> <<1>> <> ~S|"/| <> @ls <> "é😀\\",
        priority: 5,
        create_time: 1_700_000_000_123,
        update_time: 1_700_000_001_000,
        end_time: 1_700_000_002_500,
        status: :failed,
        input: %{"a" => "v😀", "l" => [1, 2.5, "x", nil, %{"z" => true}], "n" => nil},
        output: %{"o" => 1.0e7},
        reason_for_incompletion: "boom",
        event: "ev",
        failed_reference_task_names: ["r1"],
        failed_task_names: ["t1"],
        external_input_payload_storage_path: "  ",
        external_output_payload_storage_path: "out/path",
        task_to_domain: %{"a" => "b"},
        created_by: "me",
        idempotency_key: "idem",
        parent_workflow_id: "parent-1"
      }

      expected =
        String.replace(
          ~S|{"workflowType":"p8_wf","version":3,"workflowId":"wf-1","correlationId":"c\u0001\"/<LS>é😀\\","startTime":"2023-11-14T22:13:20.123Z","updateTime":"2023-11-14T22:13:21.000Z","endTime":"2023-11-14T22:13:22.500Z","status":"FAILED","input":"{a=v😀, l=[1, 2.5, x, null, {z=true}], n=null}","output":"{o=1.0E7}","reasonForIncompletion":"boom","executionTime":2377,"event":"ev","failedReferenceTaskNames":"r1","externalOutputPayloadStoragePath":"out/path","priority":5,"failedTaskNames":["t1"],"createdBy":"me","taskToDomain":{"a":"b"},"idempotencyKey":"idem","parentWorkflowId":"parent-1","classifier":"agent","inputSize":46,"outputSize":9}|,
          "<LS>",
          @ls
        )

      assert workflow |> WorkflowSummary.new() |> WorkflowSummary.encode() == expected
    end

    test "writes the epoch for an unset update time and no end time while running" do
      workflow = %Workflow{
        workflow_definition: %WorkflowDef{
          name: "p8_x",
          version: 1,
          metadata: %{"classifier" => "custom", "agent_sdk" => "1"}
        },
        workflow_id: "wf-2",
        create_time: 5
      }

      assert workflow |> WorkflowSummary.new() |> WorkflowSummary.encode() ==
               ~S|{"workflowType":"p8_x","version":1,"workflowId":"wf-2","startTime":"1970-01-01T00:00:00.005Z","updateTime":"1970-01-01T00:00:00.000Z","status":"RUNNING","input":"{}","output":"{}","executionTime":0,"failedReferenceTaskNames":"","priority":0,"failedTaskNames":[],"taskToDomain":{},"parentWorkflowId":"","classifier":"custom","inputSize":2,"outputSize":2}|
    end

    test "joins the failed reference names and takes the execution time from the create time" do
      workflow = %Workflow{
        workflow_definition: %WorkflowDef{
          name: "p8_y",
          version: 1,
          metadata: %{"agent_sdk" => "1"}
        },
        workflow_id: "wf-3",
        create_time: 5,
        status: :completed,
        end_time: 9,
        failed_reference_task_names: ["b", "a"]
      }

      assert workflow |> WorkflowSummary.new() |> WorkflowSummary.encode() ==
               ~S|{"workflowType":"p8_y","version":1,"workflowId":"wf-3","startTime":"1970-01-01T00:00:00.005Z","updateTime":"1970-01-01T00:00:00.000Z","endTime":"1970-01-01T00:00:00.009Z","status":"COMPLETED","input":"{}","output":"{}","executionTime":4,"failedReferenceTaskNames":"a,b","priority":0,"failedTaskNames":[],"taskToDomain":{},"parentWorkflowId":"","classifier":"agent","inputSize":2,"outputSize":2}|
    end

    test "leaves the type out and gives version 0 without a definition" do
      summary = WorkflowSummary.new(%Workflow{workflow_id: "wf-4", create_time: 1})
      assert %{workflow_type: nil, version: 0, classifier: "workflow"} = summary
      refute WorkflowSummary.encode(summary) =~ "workflowType"
    end

    test "sorts the failed task names, keeping a null one" do
      summary = WorkflowSummary.new(%Workflow{failed_task_names: ["b", nil, "a"]})
      assert summary.failed_task_names == [nil, "a", "b"]
    end

    test "leaves out null failed task names, as NON_NULL does" do
      json =
        %Workflow{failed_task_names: nil} |> WorkflowSummary.new() |> WorkflowSummary.encode()

      refute json =~ "failedTaskNames"
    end

    test "writes taskToDomain with sorted keys, however many (ADR 0027)" do
      domains = Map.new(1..40, &{"t#{&1}", "d"})

      json =
        %Workflow{task_to_domain: domains} |> WorkflowSummary.new() |> WorkflowSummary.encode()

      keys = Regex.scan(~r/"(t\d+)":"d"/, json, capture: :all_but_first) |> List.flatten()
      assert keys == Enum.sort(Map.keys(domains))
    end

    test "classifier_of/1 follows WorkflowClassifier.classifierOf" do
      for {metadata, classifier} <- [
            {nil, "workflow"},
            {%{}, "workflow"},
            {%{"classifier" => "x"}, "x"},
            {%{"classifier" => ""}, "workflow"},
            {%{"classifier" => " \t"}, "workflow"},
            {%{"classifier" => 5}, "workflow"},
            {%{"classifier" => 5, "agentDef" => %{}}, "agent"},
            {%{"agent_sdk" => nil}, "workflow"},
            {%{"agent_sdk" => false}, "agent"}
          ] do
        assert WorkflowSummary.classifier_of(%WorkflowDef{metadata: metadata}) == classifier,
               inspect(metadata)
      end

      assert WorkflowSummary.classifier_of(nil) == "workflow"
    end
  end

  describe "TaskSummary" do
    test "writes upstream's JSON for a started task" do
      task = %Task{
        task_id: "t-1",
        task_type: "SIMPLE",
        workflow_instance_id: "wf-1",
        workflow_type: "p8_wf",
        status: :in_progress,
        scheduled_time: 1000,
        start_time: 3000,
        input_data: %{"a" => 1},
        domain: "d",
        workflow_priority: 2,
        correlation_id: "c",
        reason_for_incompletion: "r",
        task_def_name: "p8_task",
        external_output_payload_storage_path: "x",
        output_data: %{}
      }

      assert task |> TaskSummary.new(0) |> TaskSummary.encode() ==
               ~S|{"workflowId":"wf-1","workflowType":"p8_wf","correlationId":"c","scheduledTime":"1970-01-01T00:00:01.000Z","startTime":"1970-01-01T00:00:03.000Z","updateTime":"1970-01-01T00:00:00.000Z","endTime":"1970-01-01T00:00:00.000Z","status":"IN_PROGRESS","reasonForIncompletion":"r","executionTime":0,"queueWaitTime":2000,"taskDefName":"p8_task","taskType":"SIMPLE","input":"{a=1}","output":"{}","taskId":"t-1","externalOutputPayloadStoragePath":"x","workflowPriority":2,"domain":"d"}|
    end

    test "falls back to the task type for the definition name" do
      task = %Task{
        task_id: "t-2",
        task_type: "WAIT",
        status: :completed,
        scheduled_time: 1_700_000_000_000,
        start_time: 1_700_000_000_500,
        end_time: 1_700_000_002_000,
        update_time: 1_700_000_002_000
      }

      assert task |> TaskSummary.new(0) |> TaskSummary.encode() ==
               ~S|{"scheduledTime":"2023-11-14T22:13:20.000Z","startTime":"2023-11-14T22:13:20.500Z","updateTime":"2023-11-14T22:13:22.000Z","endTime":"2023-11-14T22:13:22.000Z","status":"COMPLETED","executionTime":1500,"queueWaitTime":500,"taskDefName":"WAIT","taskType":"WAIT","input":"{}","output":"{}","taskId":"t-2","workflowPriority":0}|
    end

    test "takes the queue wait of a callback at the given time" do
      task = %Task{
        scheduled_time: 1000,
        start_time: 2000,
        update_time: 10_000,
        callback_after_seconds: 5
      }

      assert TaskSummary.new(task, 16_000).queue_wait_time == 1000
      assert TaskSummary.new(task, 14_000).queue_wait_time == 0
    end

    test "summarises the task toTask gives" do
      task = %Task{
        sub_workflow_id: "child",
        output_data: %{"subWorkflowId" => "other"},
        reason_for_incompletion: String.duplicate("x", 600)
      }

      summary = TaskSummary.new(task, 0)
      assert summary.output == "{subWorkflowId=child}"
      assert String.length(summary.reason_for_incompletion) == 500
    end
  end

  describe "SummaryUtil" do
    test "format_time/1 matches SimpleDateFormat in GMT" do
      for {ms, text} <- [
            {0, "1970-01-01T00:00:00.000Z"},
            {-1, "1969-12-31T23:59:59.999Z"},
            {1, "1970-01-01T00:00:00.001Z"},
            {951_782_400_000, "2000-02-29T00:00:00.000Z"},
            {253_402_300_799_999, "9999-12-31T23:59:59.999Z"},
            {253_402_300_800_000, "10000-01-01T00:00:00.000Z"},
            {-62_135_596_800_000, "0001-01-03T00:00:00.000Z"},
            {-62_135_596_800_001, "0001-01-02T23:59:59.999Z"},
            {-12_219_292_800_000, "1582-10-15T00:00:00.000Z"},
            {-12_219_292_800_001, "1582-10-04T23:59:59.999Z"},
            {-12_219_379_200_000, "1582-10-04T00:00:00.000Z"},
            {-30_610_224_000_000, "0999-12-27T00:00:00.000Z"},
            {9_223_372_036_854_775_807, "292278994-08-17T07:12:55.807Z"},
            {-9_223_372_036_854_775_808, "292269055-12-02T16:47:04.192Z"},
            {32_503_680_000_000, "3000-01-01T00:00:00.000Z"},
            {-377_705_116_800_000, "10000-03-19T00:00:00.000Z"}
          ] do
        assert SummaryUtil.format_time(ms) == text, inspect(ms)
      end
    end

    test "utf16_length/1 and blank?/1 match String#length and String#isBlank" do
      for {text, length, blank?} <- [
            {"😀a", 3, false},
            {"é", 1, false},
            {@em_space, 1, true},
            {<<0xA0::utf8>>, 1, false},
            {<<0x1C>>, 1, true},
            {" \t", 2, true},
            {"", 0, true}
          ] do
        assert SummaryUtil.utf16_length(text) == length, inspect(text)
        assert SummaryUtil.blank?(text) == blank?, inspect(text)
      end
    end
  end
end
