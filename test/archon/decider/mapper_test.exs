# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/mapper/SwitchTaskMapperTest.java,
# DecisionTaskMapperTest.java, ForkJoinTaskMapperTest.java and JoinTaskMapperTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests that schedule through
# Archon.Decider.tasks_to_be_scheduled/5 instead of a mocked DeciderService; cases that need a
# script or custom evaluator use value-param inputs that reach the same branch (ADR 0014).

defmodule Archon.Decider.MapperTest do
  use ExUnit.Case, async: true

  alias Archon.Decider
  alias Archon.Decider.{Context, Termination}
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}

  @now 1_800_000_000_000

  defp context do
    counter = :counters.new(1, [])

    Context.new(
      now: @now,
      new_id: fn ->
        :counters.add(counter, 1, 1)
        "id-#{:counters.get(counter, 1)}"
      end
    )
  end

  defp simple(name, ref) do
    %WorkflowTask{
      name: name,
      task_reference_name: ref,
      input_parameters: %{"p1" => "${workflow.input.param1}", "case" => "${workflow.input.case}"},
      task_definition: %TaskDef{name: name}
    }
  end

  defp workflow(tasks, input, extra \\ []) do
    struct!(
      %Workflow{
        workflow_id: "wf",
        workflow_definition: %WorkflowDef{name: "wf", schema_version: 2, tasks: tasks},
        input: input
      },
      extra
    )
  end

  defp schedule(workflow, wt), do: Decider.tasks_to_be_scheduled(workflow, wt, 0, nil, context())

  defp refs({:ok, tasks}), do: Enum.map(tasks, & &1.reference_task_name)

  describe "SWITCH" do
    defp switch(evaluator, expression, extra \\ []) do
      struct!(
        %WorkflowTask{
          name: "Switch",
          task_reference_name: "switchTask",
          type: "SWITCH",
          input_parameters: %{"route" => "${workflow.input.route}"},
          evaluator_type: evaluator,
          expression: expression,
          decision_cases: %{"even" => [simple("Test2", "t2")], "odd" => [simple("Test3", "t3")]},
          default_case: [simple("Test1", "t1")]
        },
        extra
      )
    end

    # SwitchTaskMapperTest#valueParamSwitchIsEvaluatedInTheMapperAndBranchScheduledInTheSameCall
    test "value-param picks the case and schedules its first task in the same call" do
      wt = switch("value-param", "route")

      assert {:ok, [sw, branch]} = schedule(workflow([wt], %{"route" => "even"}), wt)
      assert %Task{task_type: "SWITCH", task_def_name: "SWITCH", status: :in_progress} = sw
      assert sw.start_time == @now
      assert sw.input_data == %{"route" => "even", "case" => "even", "hasChildren" => "true"}
      assert sw.output_data == %{"evaluationResult" => ["even"], "selectedCase" => "even"}
      assert %Task{reference_task_name: "t2", status: :scheduled} = branch
    end

    # SwitchTaskMapperTest#getMappedTasksWithValueParamEvaluator, with no matching case
    test "an unknown case schedules the default case" do
      wt = switch("value-param", "route")
      assert refs(schedule(workflow([wt], %{"route" => "none"}), wt)) == ["switchTask", "t1"]

      assert {:ok, [sw | _]} = schedule(workflow([wt], %{}), wt)
      assert sw.input_data["case"] == "null"
    end

    test "the case name is the Java string of the value" do
      wt = switch("value-param", "route", decision_cases: %{"1" => [simple("Test2", "t2")]})
      assert refs(schedule(workflow([wt], %{"route" => 1}), wt)) == ["switchTask", "t2"]
    end

    # SwitchTaskMapperTest#getMappedTasksWithEmptyMatchedCase
    test "a matched case with no tasks schedules nothing, not the default case" do
      wt = switch("value-param", "route", decision_cases: %{"even" => []})

      assert {:ok, [sw]} = schedule(workflow([wt], %{"route" => "even"}), wt)
      refute Map.has_key?(sw.input_data, "hasChildren")
    end

    # SwitchTaskMapperTest#structuredResultIsEvaluatedInMapperAndSchedulesSelectedBranch and
    # #structuredResultWithUnmatchedCaseSchedulesDefault
    test "a result map with selectedCase routes by it and is copied into the output" do
      wt = switch("value-param", "route")
      route = %{"selectedCase" => "even", "model" => "m-1", "usage" => %{"inputTokens" => 10}}

      assert {:ok, [sw, %Task{reference_task_name: "t2"}]} =
               schedule(workflow([wt], %{"route" => route}), wt)

      assert sw.output_data == Map.put(route, "evaluationResult", ["even"])
      assert sw.input_data["case"] == "even"

      unknown = %{"route" => %{"selectedCase" => "unknown"}}
      assert refs(schedule(workflow([wt], unknown), wt)) == ["switchTask", "t1"]
    end

    test "an evaluator that is not registered terminates the workflow" do
      for type <- ["javascript", "graaljs", nil] do
        wt = switch(type, "$.route == 'even' ? 'even' : 'odd'")

        assert {:terminate, %Termination{reason: reason, status: :failed}} =
                 schedule(workflow([wt], %{"route" => "even"}), wt)

        assert reason == "No evaluator registered for type: #{type || "null"}"
      end
    end

    test "a case task already in progress is not scheduled again" do
      wt = switch("value-param", "route")
      running = %Task{reference_task_name: "t2", status: :in_progress}
      workflow = workflow([wt], %{"route" => "even"}, tasks: [running])

      assert refs(schedule(workflow, wt)) == ["switchTask"]
    end
  end

  describe "DECISION" do
    defp decision(extra) do
      struct!(
        %WorkflowTask{
          name: "Decision",
          task_reference_name: "decisionTask",
          type: "DECISION",
          input_parameters: %{"case" => "${workflow.input.case}"},
          case_value_param: "case",
          decision_cases: %{"0" => [simple("Test2", "t2")], "1" => [simple("Test3", "t3")]},
          default_case: [simple("Test1", "t1")]
        },
        extra
      )
    end

    # DecisionTaskMapperTest#getEvaluatedCaseValue
    test "caseValueParam picks the case; the input holds only case and hasChildren" do
      wt = decision([])

      assert {:ok, [task, %Task{reference_task_name: "t2"}]} =
               schedule(workflow([wt], %{"case" => "0"}), wt)

      assert %Task{task_type: "DECISION", task_def_name: "DECISION", status: :in_progress} = task
      assert task.input_data == %{"case" => "0", "hasChildren" => "true"}
      assert task.output_data == %{"caseOutput" => ["0"]}
    end

    test "an empty matched case falls back to the default case" do
      wt = decision(decision_cases: %{"0" => []})
      assert refs(schedule(workflow([wt], %{"case" => "0"}), wt)) == ["decisionTask", "t1"]
    end

    # DecisionTaskMapperTest#getEvaluatedCaseValueException
    test "a caseExpression terminates the workflow without a script evaluator" do
      expression = "if ($.Id == null) 'bad input'; else 'odd';"
      wt = decision(case_expression: expression)

      assert {:terminate, %Termination{reason: reason}} = schedule(workflow([wt], %{}), wt)
      assert reason == "Error while evaluating script: #{expression}"

      wt = decision(case_expression: "  ")
      assert refs(schedule(workflow([wt], %{"case" => "1"}), wt)) == ["decisionTask", "t3"]
    end
  end

  describe "FORK_JOIN and JOIN" do
    defp fork do
      %WorkflowTask{
        name: "fork",
        task_reference_name: "forktask",
        type: "FORK_JOIN",
        fork_tasks: [
          [simple("junit_task_1", "t1"), simple("junit_task_3", "t3")],
          [simple("junit_task_2", "t2")]
        ],
        task_definition: %TaskDef{name: "fork", isolation_group_id: "group"}
      }
    end

    defp join do
      %WorkflowTask{
        name: "join",
        task_reference_name: "forktask_join",
        type: "JOIN",
        join_on: ["t3", "t2"]
      }
    end

    # ForkJoinTaskMapperTest#getMappedTasks
    test "FORK_JOIN schedules a completed FORK, each branch's first task and the JOIN" do
      workflow = workflow([fork(), join(), simple("junit_task_4", "t4")], %{})

      assert {:ok, [fork_task, t1, t2, join_task]} = schedule(workflow, fork())

      assert %Task{task_type: "FORK", task_def_name: "FORK", status: :completed} = fork_task
      assert {fork_task.start_time, fork_task.end_time} == {@now, @now}
      assert fork_task.input_data == %{}
      assert fork_task.isolation_group_id == "group"
      assert {t1.reference_task_name, t2.reference_task_name} == {"t1", "t2"}

      assert %Task{task_type: "JOIN", task_def_name: "JOIN", status: :in_progress} = join_task
      assert join_task.input_data == %{"joinOn" => ["t3", "t2"]}
      assert join_task.start_time == @now
    end

    # ForkJoinTaskMapperTest#getMappedTasksException
    test "FORK_JOIN not followed by a JOIN terminates the workflow" do
      workflow = workflow([fork(), simple("junit_task_4", "t4")], %{})

      assert {:terminate, %Termination{reason: reason}} = schedule(workflow, fork())
      assert reason == "Fork task definition is not followed by a join task.  Check the blueprint"
    end

    test "an empty branch schedules nothing" do
      wt = %{fork() | fork_tasks: [[], [simple("junit_task_2", "t2")]]}

      assert refs(schedule(workflow([wt, join()], %{}), wt)) == [
               "forktask",
               "t2",
               "forktask_join"
             ]
    end

    # JoinTaskMapperTest#getMappedTasksWithJoinMode
    test "JOIN keeps joinMode on the workflow task, not in the input" do
      wt = %{join() | join_mode: :sync}

      assert {:ok, [%Task{task_type: "JOIN"} = task]} = schedule(workflow([wt], %{}), wt)
      assert task.input_data == %{"joinOn" => ["t3", "t2"]}
      assert task.workflow_task.join_mode == :sync
    end
  end
end
