# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss json-jq-task/src/test/java/com/netflix/conductor/tasks/json/JsonJqTransformTest.java
# and core/src/test/java/com/netflix/conductor/core/execution/mapper/JsonJQTransformTaskMapperTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests over the Decider's mapper and system task,
# with queries run by the archon_jq pool (jqlang) instead of jackson-jq; the messages of the two
# error cases are jq's (ADR 0026, decision 6).

defmodule Archon.Decider.JsonJqTransformTest do
  use ExUnit.Case, async: true

  alias Archon.Decider
  alias Archon.Decider.{Context, Mapper, SystemTask, SystemTasks}
  alias Archon.Decider.SystemTask.JsonJqTransform
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Script

  @now 1_800_000_000_000

  defp context(opts \\ []), do: Context.new([now: @now, new_id: fn -> "task-1" end] ++ opts)

  # JsonJqTransform#start over a task with this input.
  defp start(input, opts \\ []) do
    task = %Task{task_id: "task-1", task_type: "JSON_JQ_TRANSFORM", input_data: input}
    JsonJqTransform.start(%Workflow{workflow_id: "wf"}, task, context(opts))
  end

  describe "JsonJqTransformTest" do
    test "dataShouldBeCorrectlySelected" do
      result =
        start(%{"queryExpression" => ".inputJson.key[0]", "inputJson" => %{"key" => ["VALUE"]}})

      assert %SystemTask.Result{changed?: true, task: task} = result
      assert task.status == :completed
      assert task.output_data == %{"result" => "VALUE", "resultList" => ["VALUE"]}
    end

    # Upstream: jackson-jq's "Encountered \"<EOF>\" at line 1, column 1." The message is jq's.
    test "simpleErrorShouldBeDisplayed" do
      %SystemTask.Result{task: task} = start(%{"queryExpression" => "{"})

      message =
        "syntax error, unexpected end of file at <top-level>, line 1, column 1:\n    {\n    ^"

      assert task.status == :failed
      assert task.reason_for_incompletion == message
      assert task.output_data == %{"error" => message}
    end

    # Upstream: jackson-jq cannot parse `(...)[]` and reports that (the test is about skipping
    # causes that say N/A). jq parses it, so the query runs.
    test "nestedExceptionsWithNACausesShouldBeDisregarded" do
      input = %{
        "queryExpression" =>
          "{officeID: (.inputJson.OIDs | unique)[], requestedIndicatorList: " <>
            ".inputJson.requestedindicatorList}",
        "inputJson" => %{
          "OIDs" => ["VALUE"],
          "requestedindicatorList" => [%{"indicator" => "AFA", "value" => false}]
        }
      }

      %SystemTask.Result{task: task} = start(input)
      indicator = %{"indicator" => "AFA", "value" => false}
      expected = %{"officeID" => "VALUE", "requestedIndicatorList" => [indicator]}
      assert task.status == :completed
      assert task.output_data == %{"result" => expected, "resultList" => [expected]}
    end

    test "mapResultShouldBeCorrectlyExtracted" do
      input = %{
        "input" => %{
          "method" => "POST",
          "successExpression" => nil,
          "requestTransform" => "{name: (.body.name + \" you are a \" + .body.title) }",
          "responseTransform" => "{result: \"reply: \" + .response.body.message}"
        },
        "queryExpression" =>
          ~S|{ requestTransform: .input.requestTransform // ".body"  , responseTransform: | <>
            ~S|.input.responseTransform // ".response.body", method: .input.method // "GET", | <>
            ~S|document: .input.document // "rgt_results", successExpression: | <>
            ~S|.input.successExpression // "true"   }|
      }

      %SystemTask.Result{task: task} = start(input)
      refute Map.has_key?(task.output_data, "error")

      assert %{"result" => %{} = result, "resultList" => [%{}]} = task.output_data
      assert result["method"] == "POST"
      assert result["requestTransform"] == input["input"]["requestTransform"]
      assert result["responseTransform"] == input["input"]["responseTransform"]
      assert result["document"] == "rgt_results"
      assert result["successExpression"] == "true"
    end

    test "stringResultShouldBeCorrectlyExtracted" do
      input = %{
        "data" => [],
        "queryExpression" => "if(.data | length >0) then \"EXISTS\" else \"CREATE\" end"
      }

      %SystemTask.Result{task: task} = start(input)
      assert task.output_data == %{"result" => "CREATE", "resultList" => ["CREATE"]}
    end

    test "listResultShouldBeCorrectlyExtracted" do
      transitions =
        for name <- ["redeliver", "redeliver_from_validation_error", "redelivery"],
            do: %{"name" => name}

      input = %{
        "inputData" => %{"request" => %{"transitions" => transitions}},
        "queryExpression" => ".inputData.request.transitions | map(.name)"
      }

      %SystemTask.Result{task: task} = start(input)
      assert %{"result" => [_, _, _] = names} = task.output_data
      assert names == ["redeliver", "redeliver_from_validation_error", "redelivery"]
    end

    test "nullResultShouldBeCorrectlyExtracted" do
      %SystemTask.Result{task: task} = start(%{"queryExpression" => "null"})
      assert task.status == :completed
      assert task.output_data == %{"result" => nil, "resultList" => [nil]}
    end
  end

  describe "beyond the upstream tests" do
    test "both tables have the type: a mapper and a synchronous system task" do
      assert Mapper.module_for("JSON_JQ_TRANSFORM") == Mapper.JsonJqTransform

      assert %SystemTasks.Spec{module: JsonJqTransform, async?: false} =
               SystemTasks.spec(SystemTasks.default(), "JSON_JQ_TRANSFORM")
    end

    test "no queryExpression, or a null one, fails the task without running anything" do
      for input <- [%{"a" => 1}, %{"queryExpression" => nil}] do
        %SystemTask.Result{changed?: true, task: task} =
          start(input, evaluate_jq: fn _q, _i -> flunk("no query runs") end)

        assert task.status == :failed
        assert task.reason_for_incompletion == "Missing 'queryExpression' in input parameters"
        assert task.output_data == %{}
      end
    end

    test "a queryExpression that is not a string fails the start (upstream's cast throws)" do
      for query <- [5, true, %{"a" => 1}, ["."]] do
        assert {:error, _reason} = start(%{"queryExpression" => query})
      end
    end

    test "no results: result is null and resultList empty" do
      %SystemTask.Result{task: task} = start(%{"queryExpression" => "empty"})
      assert task.status == :completed
      assert task.output_data == %{"result" => nil, "resultList" => []}
    end

    test "the whole input, queryExpression included, is the query's input" do
      %SystemTask.Result{task: task} = start(%{"queryExpression" => "keys", "a" => 1})
      assert task.output_data["result"] == ["a", "queryExpression"]
    end

    test "results join the task's earlier output; an error replaces nothing else" do
      task = %Task{
        task_type: "JSON_JQ_TRANSFORM",
        input_data: %{"queryExpression" => "error(\"boom\")"},
        output_data: %{"kept" => 1}
      }

      %SystemTask.Result{task: failed} =
        JsonJqTransform.start(%Workflow{}, task, context())

      assert failed.status == :failed
      assert failed.reason_for_incompletion == "boom"
      assert failed.output_data == %{"kept" => 1, "error" => "boom"}
    end

    test "the evaluator's other failures become the task's reason" do
      cases = [
        {%Script.Error{kind: :timeout, reason: "interrupted", timeout: 4_000},
         "JQ query not evaluated within 4 seconds, interrupted."},
        {%Script.Error{kind: :limit, reason: "memory limit exceeded"},
         "JQ query memory limit exceeded"},
        {%Script.Error{kind: :crashed, reason: "exited with status 9"},
         "JQ evaluator exited with status 9"},
        {%Script.Error{kind: :request, reason: "import and include are not supported"},
         "JQ query rejected: import and include are not supported"}
      ]

      for {error, message} <- cases do
        %SystemTask.Result{task: task} =
          start(%{"queryExpression" => "."}, evaluate_jq: fn _q, _i -> {:error, error} end)

        assert task.status == :failed
        assert task.reason_for_incompletion == message
        assert task.output_data == %{"error" => message}
      end
    end

    test "execute runs the query again, as upstream's execute calls start; a start error fails" do
      task = %Task{task_type: "JSON_JQ_TRANSFORM", input_data: %{"queryExpression" => "1"}}
      %SystemTask.Result{task: done} = JsonJqTransform.execute(%Workflow{}, task, context())
      assert done.output_data == %{"result" => 1, "resultList" => [1]}

      task = %{task | input_data: %{"queryExpression" => 1}}

      assert %SystemTask.Result{changed?: true, task: %Task{status: :failed} = failed} =
               JsonJqTransform.execute(%Workflow{}, task, context())

      assert failed.reason_for_incompletion == "queryExpression is not a string"
    end
  end

  describe "JsonJQTransformTaskMapperTest" do
    defp jq_task(extra \\ []) do
      struct!(
        %WorkflowTask{
          name: "json_jq_transform_task",
          task_reference_name: "jq",
          type: "JSON_JQ_TRANSFORM",
          input_parameters: %{
            "in1" => ["a", "b"],
            "in2" => ["c", "d"],
            "queryExpression" => "{ out: (.in1 + .in2) }"
          }
        },
        extra
      )
    end

    defp workflow(wt),
      do: %Workflow{
        workflow_id: "wf",
        workflow_definition: %WorkflowDef{name: "wf", schema_version: 2, tasks: [wt]}
      }

    defp map(wt, opts \\ []),
      do: Decider.tasks_to_be_scheduled(workflow(wt), wt, 0, nil, context(opts))

    test "getMappedTasks" do
      wt = jq_task(task_definition: %TaskDef{name: "json_jq_transform_task"})
      assert {:ok, [task]} = map(wt)
      assert task.task_type == "JSON_JQ_TRANSFORM"
      assert task.status == :in_progress
      assert task.start_time == @now
      assert task.input_data == wt.input_parameters
    end

    test "getMappedTasks_WithoutTaskDef" do
      assert {:ok, [task]} = map(jq_task())
      assert task.task_type == "JSON_JQ_TRANSFORM"
      assert task.status == :in_progress
    end

    test "without a task definition in the context the lookup's inputTemplate applies" do
      template = %TaskDef{
        name: "json_jq_transform_task",
        input_template: %{"queryExpression" => ".x", "x" => 1},
        isolation_group_id: "lookup-group"
      }

      wt = jq_task(input_parameters: %{"in1" => 1})
      assert {:ok, [task]} = map(wt, task_def_lookup: fn _name -> {:ok, template} end)
      assert task.input_data == %{"in1" => 1, "queryExpression" => ".x", "x" => 1}
      # The isolation group comes from the context's task definition only, as upstream.
      assert task.isolation_group_id == nil

      embedded = %{template | isolation_group_id: "embedded-group"}
      assert {:ok, [task]} = map(%{wt | task_definition: embedded})
      assert task.isolation_group_id == "embedded-group"
    end
  end
end
