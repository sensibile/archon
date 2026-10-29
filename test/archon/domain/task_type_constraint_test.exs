# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/validations/
# WorkflowTaskTypeConstraintTest.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests; the HTTP, KAFKA_PUBLISH and JSON_JQ_TRANSFORM
# cases are not ported because those rules are not implemented yet (ADR 0014), and the
# setType executable-validation case has no Elixir counterpart. Script syntax checks run on the
# archon_js pool (ADR 0015).

defmodule Archon.Domain.TaskTypeConstraintTest do
  use ExUnit.Case, async: true

  alias Archon.Domain.{SubWorkflowParams, WorkflowDef, WorkflowTask}

  # createSampleWorkflowTask
  defp sample(attrs) do
    struct!(
      %WorkflowTask{
        name: "encode",
        task_reference_name: "encode",
        type: "FORK_JOIN_DYNAMIC",
        input_parameters: %{"fileLocation" => "${workflow.input.fileLocation}"}
      },
      attrs
    )
  end

  defp messages(task) do
    case WorkflowTask.validate(task) do
      :ok -> []
      {:error, errors} -> errors |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    end
  end

  describe "WorkflowTaskTypeConstraintTest" do
    test "testWorkflowTaskMissingReferenceName" do
      task =
        sample(
          dynamic_fork_tasks_param: "taskList",
          dynamic_fork_tasks_input_param_name: "ForkTaskInputParam",
          task_reference_name: nil
        )

      assert messages(task) == ["WorkflowTask taskReferenceName name cannot be empty or null"]
    end

    test "testWorkflowTaskTypeEvent" do
      assert messages(sample(type: "EVENT")) == [
               "sink field is required for taskType: EVENT taskName: encode"
             ]
    end

    test "testWorkflowTaskTypeDynamic" do
      assert messages(sample(type: "DYNAMIC")) == [
               "dynamicTaskNameParam field is required for taskType: DYNAMIC taskName: encode"
             ]
    end

    test "testWorkflowTaskTypeDecision" do
      assert messages(sample(type: "DECISION")) == [
               "caseValueParam or caseExpression field is required for taskType: DECISION " <>
                 "taskName: encode",
               "decisionCases should have atleast one task for taskType: DECISION taskName: encode"
             ]
    end

    test "testWorkflowTaskTypeDoWhile" do
      assert messages(sample(type: "DO_WHILE")) == [
               "loopCondition field is required for taskType: DO_WHILE taskName: encode",
               "loopOver field is required for taskType: DO_WHILE taskName: encode"
             ]
    end

    test "testWorkflowTaskTypeWait" do
      assert messages(sample(type: "WAIT")) == []

      task =
        sample(type: "WAIT", input_parameters: %{"duration" => "10s", "until" => "2022-04-16"})

      assert messages(task) == [
               "Both 'duration' and 'until' specified. Please provide only one input"
             ]
    end

    test "testWorkflowTaskTypeDecisionWithCaseParam" do
      task = sample(type: "DECISION", case_expression: "$.valueCheck == null ? 'true': 'false'")

      assert messages(task) == [
               "decisionCases should have atleast one task for taskType: DECISION taskName: encode"
             ]
    end

    test "testSwitchJavascriptExpressionWithRuntimeBoundVariableIsAccepted" do
      # Only the syntax is checked: running it would throw, $.items being unresolved.
      task =
        sample(
          type: "SWITCH",
          evaluator_type: "javascript",
          expression: "$.items.filter(i => i > 10).length > 0 ? 'big' : 'small'",
          decision_cases: %{"big" => [sample(type: "SIMPLE")]},
          input_parameters: %{"items" => "${workflow.input.items}"}
        )

      assert messages(task) == []
    end

    test "testSwitchJavascriptExpressionWithSyntaxErrorIsRejected" do
      task =
        sample(
          type: "SWITCH",
          evaluator_type: "javascript",
          expression: "$.inputValue > 10 ? 'big' :",
          decision_cases: %{"big" => [sample(type: "SIMPLE")]}
        )

      assert [message] = messages(task)

      assert message =~
               ~r/^Expression is not well formatted: SyntaxError: .+, taskType: SWITCH taskName encode$/s

      # graaljs expressions are not checked at registration, as upstream.
      assert messages(%{task | evaluator_type: "graaljs"}) == []
    end

    test "a DECISION caseExpression with a syntax error is rejected" do
      task =
        sample(
          type: "DECISION",
          case_expression: "$.valueCheck == null ? 'true' :",
          decision_cases: %{"true" => [sample(type: "SIMPLE")]}
        )

      assert messages(task) == [
               "Expression is not well formatted: SyntaxError: unexpected token in expression: " <>
                 "'', taskType: DECISION taskName encode"
             ]
    end

    test "testWorkflowTaskTypeForJoinDynamic" do
      assert messages(sample([])) == [
               "dynamicForkTasksInputParamName field is required for taskType: " <>
                 "FORK_JOIN_DYNAMIC taskName: encode",
               "dynamicForkTasksParam field is required for taskType: FORK_JOIN_DYNAMIC " <>
                 "taskName: encode"
             ]
    end

    test "testWorkflowTaskTypeForJoinDynamicLegacy" do
      assert messages(sample(dynamic_fork_join_tasks_param: "taskList")) == []
    end

    @exclusive "dynamicForkJoinTasksParam or combination of dynamicForkTasksInputParamName and " <>
                 "dynamicForkTasksParam cam be used for taskType: FORK_JOIN_DYNAMIC taskName: encode"

    test "testWorkflowTaskTypeForJoinDynamicWithForJoinTaskParam" do
      task =
        sample(
          dynamic_fork_join_tasks_param: "taskList",
          dynamic_fork_tasks_input_param_name: "ForkTaskInputParam"
        )

      assert messages(task) == [@exclusive]
    end

    test "testWorkflowTaskTypeForJoinDynamicValid" do
      task =
        sample(
          dynamic_fork_tasks_param: "ForkTasksParam",
          dynamic_fork_tasks_input_param_name: "ForkTaskInputParam"
        )

      assert messages(task) == []
    end

    test "testWorkflowTaskTypeForJoinDynamicWithForkTaskInputs" do
      task = sample(input_parameters: %{"forkTaskInputs" => [%{"key" => "value"}]})
      assert messages(task) == []
    end

    test "testWorkflowTaskTypeForJoinDynamicWithForJoinTaskParamAndInputTaskParam" do
      task =
        sample(
          dynamic_fork_join_tasks_param: "taskList",
          dynamic_fork_tasks_input_param_name: "ForkTaskInputParam",
          dynamic_fork_tasks_param: "ForkTasksParam"
        )

      assert messages(task) == [@exclusive]
    end

    test "testWorkflowTaskTypeFork" do
      assert messages(sample(type: "FORK_JOIN")) == [
               "forkTasks should have atleast one task for taskType: FORK_JOIN taskName: encode"
             ]
    end

    test "testWorkflowTaskTypeSubworkflowMissingSubworkflowParam" do
      assert messages(sample(type: "SUB_WORKFLOW")) == [
               "subWorkflowParam field is required for taskType: SUB_WORKFLOW taskName: encode"
             ]
    end

    @terminate_status "terminate task must have an terminationStatus parameter and must be set " <>
                        "to COMPLETED or FAILED, taskName: terminate_task"

    test "testWorkflowTaskTypeTerminateWithoutTerminationStatus" do
      task =
        sample(
          type: "TERMINATE",
          name: "terminate_task",
          input_parameters: %{"workflowOutput" => "blah"}
        )

      assert messages(task) == [@terminate_status]
    end

    test "testWorkflowTaskTypeTerminateWithInvalidStatus" do
      task =
        sample(
          type: "TERMINATE",
          name: "terminate_task",
          input_parameters: %{"terminationStatus" => "blah"}
        )

      assert messages(task) == [@terminate_status]
    end

    test "testWorkflowTaskTypeTerminateOptional" do
      task =
        sample(
          type: "TERMINATE",
          name: "terminate_task",
          input_parameters: %{"terminationStatus" => "COMPLETED"},
          optional: true
        )

      assert messages(task) == ["terminate task cannot be optional, taskName: terminate_task"]
    end

    test "testWorkflowTaskTypeTerminateValid" do
      task =
        sample(
          type: "TERMINATE",
          name: "terminate_task",
          input_parameters: %{"terminationStatus" => "COMPLETED"}
        )

      assert messages(task) == []
    end
  end

  describe "beyond the upstream tests" do
    test "SWITCH requires an evaluator, then an expression, and decision cases" do
      assert messages(sample(type: "SWITCH", decision_cases: nil)) == [
               "decisionCases field is required for taskType: SWITCH taskName: encode",
               "evaluatorType field is required for taskType: SWITCH taskName: encode"
             ]

      task =
        sample(
          type: "SWITCH",
          evaluator_type: "value-param",
          decision_cases: %{"a" => [sample(type: "SIMPLE", task_reference_name: "a")]}
        )

      assert messages(task) == [
               "expression field is required for taskType: SWITCH taskName: encode"
             ]
    end

    test "TERMINATED is an accepted termination status although the message omits it" do
      task = sample(type: "TERMINATE", input_parameters: %{"terminationStatus" => "TERMINATED"})
      assert messages(task) == []
    end

    test "SUB_WORKFLOW with a param is valid" do
      task = sample(type: "SUB_WORKFLOW", sub_workflow_param: %SubWorkflowParams{name: "child"})
      assert messages(task) == []
    end

    test "WAIT parses the first non-blank input that is not an expression" do
      wait = &sample(type: "WAIT", input_parameters: &1)

      assert messages(wait.(%{"duration" => "1d 2h 3m 4s"})) == []
      assert messages(wait.(%{"duration" => "10 MINUTES"})) == []
      assert messages(wait.(%{"duration" => "${workflow.input.wait}"})) == []
      assert messages(wait.(%{"duration" => "  "})) == []
      assert messages(wait.(%{"until" => "2022-04-16 10:30"})) == []
      assert messages(wait.(%{"until" => "2022-04-16 10:30 GMT"})) == []

      assert messages(wait.(%{"duration" => "soon"})) == [
               "Either date or duration is passed as null "
             ]

      assert messages(wait.(%{"duration" => "10"})) == [
               "Either date or duration is passed as null "
             ]

      # \s* also matches a trailing newline in Java's Pattern
      assert messages(wait.(%{"duration" => "10s\n"})) == []

      assert messages(wait.(%{"duration" => "2147483647s"})) == []
      assert messages(wait.(%{"duration" => "0002147483647s"})) == []

      assert messages(wait.(%{"duration" => String.duplicate("9", 2_000_000) <> "s"})) == [
               "Either date or duration is passed as null "
             ]

      # Integer.parseInt overflow
      assert messages(wait.(%{"duration" => "2147483648s"})) == [
               "Either date or duration is passed as null "
             ]

      assert messages(wait.(%{"until" => "tomorrow"})) == ["Unable to parse date "]
    end

    test "WAIT duration validation does not backtrack on long whitespace runs" do
      task =
        sample(
          type: "WAIT",
          input_parameters: %{"duration" => String.duplicate(" ", 5_000) <> "!"}
        )

      {micros, messages} = :timer.tc(fn -> messages(task) end)
      assert messages == ["Either date or duration is passed as null "]
      assert micros < 100_000
    end

    test "the possessive duration pattern accepts exactly what upstream's pattern accepts" do
      upstream =
        ~r/^\s*(?:(\d+)\s*(?:days?|d))?\s*(?:(\d+)\s*(?:hours?|hrs?|h))?\s*(?:(\d+)\s*(?:minutes?|mins?|m))?\s*(?:(\d+)\s*(?:seconds?|secs?|s))?\s*\z/i

      alphabet = ["1", " ", "d", "h", "m", "s", "y", "x"]

      for length <- 1..5, text <- words(alphabet, length), String.trim(text) != "" do
        expected =
          if Regex.match?(upstream, text),
            do: [],
            else: ["Either date or duration is passed as null "]

        assert messages(sample(type: "WAIT", input_parameters: %{"duration" => text})) == expected,
               inspect(text)
      end
    end

    test "type violations of nested tasks carry the task's path" do
      fork =
        sample(
          type: "FORK_JOIN",
          task_reference_name: "fork",
          fork_tasks: [[sample(type: "SUB_WORKFLOW")]]
        )

      definition = %WorkflowDef{name: "wf", tasks: [fork]}

      assert WorkflowDef.validate(definition) ==
               {:error,
                [
                  {"tasks[0].forkTasks[0][0]",
                   "subWorkflowParam field is required for taskType: SUB_WORKFLOW taskName: encode"}
                ]}
    end
  end

  defp words(_alphabet, 0), do: [""]

  defp words(alphabet, length) do
    for prefix <- words(alphabet, length - 1), char <- alphabet, do: prefix <> char
  end
end
