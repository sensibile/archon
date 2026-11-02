# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/tasks/InlineTest.java,
# core/.../execution/mapper/InlineTaskMapperTest.java and LambdaTaskMapperTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests over the Archon.Decider.SystemTask behaviour;
# scripts run on the archon_js pool (ADR 0015). The upstream server answers and the GraalJS
# 25.0.2 oracle results the other cases expect were read for ADR 0026, decision 5.

defmodule Archon.Decider.ScriptTasksTest do
  use ExUnit.Case, async: true

  alias Archon.Decider
  alias Archon.Decider.{Context, SystemTask}
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Script

  @now 1_800_000_000_000

  @blank_evaluator "Empty 'evaluatorType' in INLINE task's input parameters. " <>
                     "A non-empty String value must be provided."
  @blank_expression "Empty 'expression' in Inline task's input parameters. " <>
                      "A non-empty String value must be provided."
  @blank_script "Empty 'scriptExpression' in Lambda task's input parameters. " <>
                  "A non-empty String value must be provided."

  defp context(opts \\ []), do: Context.new([now: @now, new_id: fn -> "task-id" end] ++ opts)

  defp run(type, input, opts) do
    task = %Task{task_id: "t", task_type: type, input_data: input, status: :in_progress}
    SystemTask.execute(%Workflow{workflow_id: "wf"}, task, context(opts))
  end

  defp inline(input, opts \\ []), do: run("INLINE", input, opts)
  defp lambda(input, opts \\ []), do: run("LAMBDA", input, opts)

  defp failing(error), do: [evaluate_script: fn _op, _script, _input -> {:error, error} end]

  defp cast_message(class) do
    "class #{class} cannot be cast to class java.lang.String (#{class} and java.lang.String " <>
      "are in module java.base of loader 'bootstrap')"
  end

  describe "the mappers (upstream InlineTaskMapperTest and LambdaTaskMapperTest)" do
    defp workflow(wt, input) do
      %Workflow{
        workflow_id: "wf",
        workflow_definition: %WorkflowDef{name: "wf", schema_version: 2, tasks: [wt]},
        input: input
      }
    end

    defp script_task(type, extra \\ []) do
      struct!(
        %WorkflowTask{
          name: "#{String.downcase(type)}_task",
          task_reference_name: "ref",
          type: type,
          input_parameters: %{"expression" => "${workflow.input.e}", "a" => "${workflow.input.a}"}
        },
        extra
      )
    end

    defp map(wt, opts \\ []),
      do:
        Decider.tasks_to_be_scheduled(
          workflow(wt, %{"e" => "1", "a" => 2}),
          wt,
          0,
          nil,
          context(opts)
        )

    test "INLINE: one IN_PROGRESS task with the resolved input and the isolation group" do
      wt =
        script_task("INLINE",
          task_definition: %TaskDef{name: "inline_task", isolation_group_id: "iso"}
        )

      assert {:ok, [%Task{} = task]} = map(wt)
      assert task.task_type == "INLINE"
      assert task.task_def_name == "inline_task"
      assert task.status == :in_progress
      assert task.start_time == @now
      assert task.scheduled_time == @now
      assert task.task_id == "task-id"
      assert task.input_data == %{"expression" => "1", "a" => 2}
      assert task.isolation_group_id == "iso"
    end

    test "INLINE without a task definition reads one through task_def_lookup for its input" do
      template = %TaskDef{name: "inline_task", input_template: %{"t" => "template"}}
      lookup = fn "inline_task" -> {:ok, template} end

      assert {:ok, [task]} = map(script_task("INLINE"), task_def_lookup: lookup)
      assert task.input_data == %{"expression" => "1", "a" => 2, "t" => "template"}
      # Upstream takes the isolation group from the context's definition only.
      assert task.isolation_group_id == nil

      assert {:ok, [task]} = map(script_task("INLINE"))
      assert task.input_data == %{"expression" => "1", "a" => 2}

      # The definitions the caller filled come first, as UserDefined reads them.
      not_read = fn _name -> flunk("the store is read") end
      task_defs = %{"inline_task" => template}

      assert {:ok, [task]} =
               map(script_task("INLINE"), task_defs: task_defs, task_def_lookup: not_read)

      assert task.input_data == %{"expression" => "1", "a" => 2, "t" => "template"}
    end

    test "LAMBDA: one IN_PROGRESS task, no isolation group" do
      wt =
        script_task("LAMBDA",
          task_definition: %TaskDef{name: "lambda_task", isolation_group_id: "iso"}
        )

      assert {:ok, [%Task{} = task]} = map(wt)
      assert task.task_type == "LAMBDA"
      assert task.status == :in_progress
      assert task.start_time == @now
      assert task.input_data == %{"expression" => "1", "a" => 2}
      assert task.isolation_group_id == nil
    end

    test "both are synchronous system tasks with a mapper of their own" do
      for type <- ["INLINE", "LAMBDA"] do
        assert Decider.Mapper.mapped?(type)
        assert Decider.SystemTasks.system_task?(Decider.SystemTasks.default(), type)
        refute Decider.SystemTasks.async?(Decider.SystemTasks.default(), type)
      end
    end
  end

  describe "INLINE (upstream InlineTest)" do
    test "validation failures are terminal" do
      assert %{changed?: true, task: task} =
               inline(%{"value" => 1, "expression" => "", "evaluatorType" => "value-param"})

      assert task.status == :failed_with_terminal_error
      assert task.reason_for_incompletion == @blank_expression
      assert task.output_data == %{"error" => @blank_expression}

      assert %{task: task} =
               inline(%{"value" => 1, "expression" => "value", "evaluatorType" => ""})

      assert task.status == :failed_with_terminal_error
      assert task.reason_for_incompletion == @blank_evaluator
    end

    test "value-param expression" do
      assert %{changed?: true, task: task} =
               inline(%{
                 "value" => 101,
                 "expression" => "value",
                 "evaluatorType" => "value-param"
               })

      assert task.status == :completed
      assert task.reason_for_incompletion == nil
      assert task.output_data == %{"result" => 101}

      assert %{task: task} =
               inline(%{
                 "value" => "StringValue",
                 "expression" => "value",
                 "evaluatorType" => "value-param"
               })

      assert task.output_data == %{"result" => "StringValue"}
    end

    test "javascript and graaljs expressions" do
      expression = fn value ->
        "function e() { if ($.value == #{value}){return {\"evalResult\": true}} " <>
          "else { return {\"evalResult\": false}}} e();"
      end

      for {type, value, input} <- [
            {"javascript", "101", 101},
            {"javascript", "'StringValue'", "StringValue"},
            {"graaljs", "42", 42}
          ] do
        assert %{task: task} =
                 inline(%{
                   "value" => input,
                   "expression" => expression.(value),
                   "evaluatorType" => type
                 })

        assert task.status == :completed
        assert task.reason_for_incompletion == nil
        assert task.output_data == %{"result" => %{"evalResult" => true}}
      end
    end

    test "the evaluator defaults to javascript" do
      input = %{
        "value" => 99,
        "expression" => "function e() { return {\"result\": $.value * 2}} e();"
      }

      assert %{task: task} = inline(input)
      assert task.status == :completed
      assert task.output_data == %{"result" => %{"result" => 198}}

      # A null evaluatorType too (upstream: the cast of null, then the default).
      assert %{task: %{status: :completed}} = inline(Map.put(input, "evaluatorType", nil))
    end

    test "host access and load() are not reachable" do
      rce = "var ck = $.getClass(); ck.getClass()"

      for type <- ["javascript", "graaljs"] do
        assert %{task: %{status: :failed_with_terminal_error}} =
                 inline(%{"evaluatorType" => type, "expression" => rce})

        assert %{task: %{status: :completed, output_data: %{"result" => "undefined"}}} =
                 inline(%{"evaluatorType" => type, "expression" => "typeof load"})
      end
    end
  end

  describe "INLINE failures (upstream server, ADR 0026 decision 5)" do
    test "an unknown evaluator is terminal, checked before the expression" do
      for {type, expression} <- [{"archon-unknown", "1"}, {"archon-unknown", ""}, {"python", "1"}] do
        assert %{task: task} = inline(%{"evaluatorType" => type, "expression" => expression})
        assert task.status == :failed_with_terminal_error
        message = "Unknown evaluator '#{type}' in INLINE task."
        assert task.reason_for_incompletion == message
        assert task.output_data == %{"error" => message}
      end
    end

    test "blank values as Java's isBlank sees them" do
      assert %{task: %{reason_for_incompletion: @blank_evaluator}} =
               inline(%{"evaluatorType" => "  ", "expression" => "1"})

      assert %{task: %{reason_for_incompletion: @blank_expression}} =
               inline(%{"evaluatorType" => "javascript", "expression" => " "})

      assert %{task: %{reason_for_incompletion: @blank_expression}} = inline(%{"a" => 1})

      # A no-break space is not blank to Character.isWhitespace.
      assert %{task: %{status: :completed}} =
               inline(%{"evaluatorType" => "value-param", "expression" => " "})
    end

    test "a script that throws or does not parse is terminal" do
      for expression <- ["$.a.b.c", "throw new Error('boom')", "1 +"] do
        assert %{task: task} =
                 inline(%{"evaluatorType" => "javascript", "expression" => expression})

        assert task.status == :failed_with_terminal_error
        assert "Error evaluating the script `" <> _ = task.reason_for_incompletion
        assert task.output_data == %{"error" => task.reason_for_incompletion}
      end
    end

    test "the time limit, an unreadable result and a pool failure are FAILED" do
      for error <- [
            %Script.Error{kind: :timeout, reason: "timeout"},
            %Script.Error{kind: :conversion, reason: "Error: in getter"},
            %Script.Error{kind: :limit, reason: "result is too large"},
            %Script.Error{kind: :limit, reason: "queue is full"},
            %Script.Error{kind: :crashed, reason: "exited"},
            %Script.Error{kind: :request, reason: "bad"}
          ] do
        assert %{task: task} =
                 inline(%{"evaluatorType" => "javascript", "expression" => "1"}, failing(error))

        assert task.status == :failed
        assert task.reason_for_incompletion == Exception.message(error)
        assert task.output_data == %{"error" => Exception.message(error)}
      end

      assert %{
               task: %{
                 reason_for_incompletion: "Script not evaluated within 4 seconds, interrupted."
               }
             } =
               inline(
                 %{"expression" => "1"},
                 failing(%Script.Error{kind: :timeout, reason: "timeout"})
               )
    end

    test "an input that is not a string fails with the message of upstream's cast" do
      for {value, class} <- [
            {5, "java.lang.Integer"},
            {5_000_000_000, "java.lang.Long"},
            {100_000_000_000_000_000_000, "java.math.BigInteger"},
            {1.5, "java.lang.Double"},
            {true, "java.lang.Boolean"},
            {false, "java.lang.Boolean"},
            {%{"x" => 1}, "java.util.LinkedHashMap"},
            {[1], "java.util.ArrayList"}
          ] do
        assert %{task: task} = inline(%{"evaluatorType" => value, "expression" => "1"})
        assert task.status == :failed
        assert task.reason_for_incompletion == cast_message(class)
        assert task.output_data == %{"error" => cast_message(class)}

        assert %{task: %{status: :failed, reason_for_incompletion: message}} =
                 inline(%{"evaluatorType" => "javascript", "expression" => value})

        assert message == cast_message(class)
      end

      # evaluatorType is cast first, before any check.
      assert %{task: %{reason_for_incompletion: message}} =
               inline(%{"evaluatorType" => "archon-unknown", "expression" => 5})

      assert message == cast_message("java.lang.Integer")
    end

    test "the output keeps what was there" do
      task = %Task{
        task_id: "t",
        task_type: "INLINE",
        input_data: %{"expression" => "2"},
        output_data: %{"kept" => true},
        status: :in_progress
      }

      assert %{task: %{output_data: %{"kept" => true, "result" => 2}}} =
               SystemTask.execute(%Workflow{}, task, context())
    end
  end

  describe "LAMBDA (upstream Lambda and server)" do
    test "the script is the body of a function over the task input" do
      assert %{changed?: true, task: task} =
               lambda(%{"scriptExpression" => "return {r: $.a + 1};", "a" => 1})

      assert task.status == :completed
      assert task.output_data == %{"result" => %{"r" => 2}}

      assert %{task: %{output_data: %{"result" => %{"x" => 1, "s" => "function"}}}} =
               lambda(%{"scriptExpression" => "var x = 1; return {x: x, s: typeof scriptFun};"})

      assert %{task: %{output_data: %{"result" => nil}}} = lambda(%{"scriptExpression" => "1"})
    end

    test "a blank or missing script is FAILED without an output error" do
      for input <- [%{"scriptExpression" => ""}, %{"scriptExpression" => "  "}, %{"a" => 1}] do
        assert %{changed?: true, task: task} = lambda(input)
        assert task.status == :failed
        assert task.reason_for_incompletion == @blank_script
        assert task.output_data == %{}
      end
    end

    test "every evaluation error is FAILED" do
      for script <- ["return $.a.b.c;", "}", "throw new TypeError('bad');"] do
        assert %{task: task} = lambda(%{"scriptExpression" => script, "a" => 1})
        assert task.status == :failed
        assert "Error evaluating the script `" <> _ = task.reason_for_incompletion
        assert task.output_data == %{"error" => task.reason_for_incompletion}
      end

      error = %Script.Error{kind: :timeout, reason: "timeout"}
      assert %{task: task} = lambda(%{"scriptExpression" => "while(true){}"}, failing(error))
      assert task.status == :failed
      assert task.reason_for_incompletion == "Script not evaluated within 4 seconds, interrupted."
    end

    test "a script that is not a string is FAILED with the message of upstream's cast" do
      for {value, class} <- [{5, "java.lang.Integer"}, {%{"x" => 1}, "java.util.LinkedHashMap"}] do
        assert %{task: task} = lambda(%{"scriptExpression" => value})
        assert task.status == :failed
        assert task.reason_for_incompletion == cast_message(class)
        assert task.output_data == %{"error" => cast_message(class)}
      end
    end

    test "the wrapper is what upstream builds" do
      test_pid = self()

      evaluate = fn op, script, input ->
        send(test_pid, {:evaluated, op, script, input})
        {:ok, 1}
      end

      input = %{"scriptExpression" => "return 1;", "a" => 1}
      assert %{task: %{status: :completed}} = lambda(input, evaluate_script: evaluate)
      assert_received {:evaluated, :eval, "function scriptFun(){return 1;} scriptFun();", ^input}
    end
  end

  # GraalJS 25.0.2 (ADR 0015, decision 7) with the input below. The oracle's script error texts
  # differ in the engine's own words (ADR 0015's deliberate differences); the status does not.
  describe "results as the GraalJS oracle gives them" do
    @input %{
      "a" => 1,
      "value" => 101,
      "n" => %{"x" => [1, 2.5]},
      "s" => "str",
      "list" => [1, 2, 3]
    }

    @inline_cases [
      {"function f() { return {sum: $.a + 1, list: [$.a]}; } f();", %{"sum" => 2, "list" => [1]}},
      {"$.a * 2", 2},
      {"$.n.x[1] * 2", 5},
      {"$.list.map(function(x) { return x * 10; })", [10, 20, 30]},
      {"$.list.filter(x => x > 1).length", 2},
      {"({ok: $.s.toUpperCase(), len: $.s.length})", %{"ok" => "STR", "len" => 3}},
      {"$.evaluatorType", "javascript"},
      # The oracle ran with the expression "x"; here `$` holds the expression itself.
      {"$.expression.length", 19},
      {"JSON.stringify({k: $.a})", ~s({"k":1})},
      {~S|JSON.parse('{"z": [1, 2.5, null]}')|, %{"z" => [1, 2.5, nil]}},
      {"0/0", "NaN"},
      {"[1/0, -1/0, -0]", ["Infinity", "-Infinity", -0.0]},
      {"undefined", nil},
      {"null", nil},
      {"'text'", "text"},
      {"true", true},
      {"1e21", 1.0e21},
      {"2**53 + 1", 9_007_199_254_740_992},
      {"1.5", 1.5},
      {"var t = 0; for (var i = 0; i < 10; i++) { t += i; } t", 45},
      {"$.missing", nil},
      {"new Date(0).toISOString()", "1970-01-01T00:00:00.000Z"},
      {"[1, [2, [3, {d: 4}]]]", [1, [2, [3, %{"d" => 4}]]]},
      {"({nested: {deep: {deeper: [true, false, null]}}})",
       %{"nested" => %{"deep" => %{"deeper" => [true, false, nil]}}}}
    ]

    @lambda_cases [
      {"return {r: $.a + 1};", %{"r" => 2}},
      {"if ($.a == 1){return {testvalue: true}} else {return {testvalue: false}}",
       %{"testvalue" => true}},
      {"return 1/0;", "Infinity"},
      {"return;", nil},
      {"return arguments.length;", 0},
      {"return this === undefined ? 'strict' : typeof this;", "object"},
      {"return $.list.reduce((a, b) => a + b, 0);", 6},
      {"return [$.s, $.n];", ["str", %{"x" => [1, 2.5]}]}
    ]

    test "INLINE" do
      for {expression, expected} <- @inline_cases do
        input = Map.merge(@input, %{"evaluatorType" => "javascript", "expression" => expression})
        assert %{task: task} = inline(input)

        assert {expression, task.status, task.output_data} ==
                 {expression, :completed, %{"result" => expected}}
      end

      for expression <- [
            "$.missing.deeper",
            "$.a.b.c",
            "throw new Error('boom')",
            "throw 'plain'",
            "1 +"
          ] do
        input = Map.merge(@input, %{"evaluatorType" => "javascript", "expression" => expression})
        assert %{task: %{status: :failed_with_terminal_error}} = inline(input)
      end
    end

    test "LAMBDA" do
      for {script, expected} <- @lambda_cases do
        assert %{task: task} = lambda(Map.put(@input, "scriptExpression", script))

        assert {script, task.status, task.output_data} ==
                 {script, :completed, %{"result" => expected}}
      end

      for script <- ["return $.a.b.c;", "}", "throw new TypeError('bad');"] do
        assert %{task: %{status: :failed}} = lambda(Map.put(@input, "scriptExpression", script))
      end
    end
  end
end
