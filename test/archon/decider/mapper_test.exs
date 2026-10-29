# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/mapper/SwitchTaskMapperTest.java,
# DecisionTaskMapperTest.java, ForkJoinTaskMapperTest.java, JoinTaskMapperTest.java,
# SubWorkflowTaskMapperTest.java and WaitTaskMapperTest.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests that schedule through
# Archon.Decider.tasks_to_be_scheduled/5 instead of a mocked DeciderService; JavaScript cases run
# on the archon_js pool (ADR 0015), cases that need a custom evaluator use value-param inputs that
# reach the same branch, and mocked ParametersUtils results are replaced by inputs that resolve
# to them (ADR 0014).

defmodule Archon.Decider.MapperTest do
  use ExUnit.Case, async: true

  alias Archon.Decider
  alias Archon.Decider.{Context, Termination}
  alias Archon.Domain.{SubWorkflowParams, Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}

  @now 1_800_000_000_000

  defp context(opts) do
    counter = :counters.new(1, [])

    Context.new(
      [
        now: @now,
        new_id: fn ->
          :counters.add(counter, 1, 1)
          "id-#{:counters.get(counter, 1)}"
        end
      ] ++ opts
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

  defp schedule(workflow, wt, opts \\ []),
    do: Decider.tasks_to_be_scheduled(workflow, wt, 0, nil, context(opts))

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
      for type <- ["python", nil] do
        wt = switch(type, "$.route == 'even' ? 'even' : 'odd'")

        assert {:terminate, %Termination{reason: reason, status: :failed}} =
                 schedule(workflow([wt], %{"route" => "even"}), wt)

        assert reason == "No evaluator registered for type: #{type || "null"}"
      end
    end

    # SwitchTaskMapperTest#getMappedTasks
    test "a javascript or graaljs expression picks the case" do
      expression =
        "if ($.Id == null) 'bad input'; else if ( ($.Id != null && $.Id % 2 == 0)) 'even'; " <>
          "else 'odd'; "

      for type <- ["javascript", "graaljs"] do
        wt = switch(type, expression, input_parameters: %{"Id" => "${workflow.input.Id}"})
        workflow = workflow([wt], %{"Id" => "22"})

        assert {:ok, [sw, %Task{reference_task_name: "t2"}]} = schedule(workflow, wt)
        assert sw.status == :in_progress
        assert sw.input_data == %{"Id" => "22", "case" => "even", "hasChildren" => "true"}
        assert sw.output_data == %{"evaluationResult" => ["even"], "selectedCase" => "even"}
      end
    end

    # SwitchTaskMapperTest#getMappedTasksWithEmptyMatchedCase, with the upstream script
    test "a script naming a case with no tasks schedules nothing" do
      wt = switch("javascript", "'true'", decision_cases: %{"true" => []})
      assert {:ok, [%Task{status: :in_progress}]} = schedule(workflow([wt], %{}), wt)
    end

    # SwitchTaskMapperTest#getMappedTasksWhenEvaluatorThrowsException
    test "a script that fails leaves the SWITCH task FAILED and schedules nothing" do
      wt = switch("javascript", "undefinedVariable")

      assert {:ok, [sw]} = schedule(workflow([wt], %{"route" => "even"}), wt)
      assert %Task{reference_task_name: "switchTask", task_type: "SWITCH", status: :failed} = sw
      assert sw.start_time == @now
      assert sw.input_data == %{"route" => "even"}
      assert sw.output_data == %{}

      assert sw.reason_for_incompletion ==
               "Error evaluating the script `ReferenceError: undefinedVariable is not defined` " <>
                 "at line 1"
    end

    test "the script result is routed by its Java string, non-finite numbers included" do
      # GraalJS 25.0.2 oracle: String.valueOf of 1/0, 0/0, -0 and 1e21 after getObject.
      for {expression, case_name} <- [
            {"1/0", "Infinity"},
            {"0/0", "NaN"},
            {"-1/0", "-Infinity"},
            {"-0", "-0.0"},
            {"1e21", "1.0E21"},
            {"$.n * 2", "4"},
            {"[1, 'a', null]", "[1, a, null]"}
          ] do
        wt =
          switch("javascript", expression,
            input_parameters: %{"n" => "${workflow.input.n}"},
            decision_cases: %{case_name => [simple("T", "t")]}
          )

        assert {:ok, [sw, %Task{reference_task_name: "t"}]} =
                 schedule(workflow([wt], %{"n" => 2}), wt)

        assert sw.output_data["selectedCase"] == case_name
      end
    end

    test "a script result map is stored as upstream stores it" do
      # GraalJS 25.0.2 + Jackson 2.18.8 oracle: the non-finite doubles serialize as strings, and
      # a user object shaped like a protocol tag stays a plain list.
      wt =
        switch(
          "graaljs",
          "({selectedCase: 'even', x: 0/0, y: [1/0, -0], tag: ['nonfinite', 'NaN']})"
        )

      assert {:ok, [sw, _t2]} = schedule(workflow([wt], %{}), wt)

      assert sw.output_data == %{
               "selectedCase" => "even",
               "evaluationResult" => ["even"],
               "x" => "NaN",
               "y" => ["Infinity", -0.0],
               "tag" => ["nonfinite", "NaN"]
             }
    end

    test "the script sees a copy of the input" do
      wt =
        switch("javascript", "$.data.newKey = 'new value'; $.data.newKey",
          input_parameters: %{"data" => "${workflow.input.data}"}
        )

      assert {:ok, [sw, _default]} =
               schedule(workflow([wt], %{"data" => %{"original" => "value"}}), wt)

      assert sw.input_data["data"] == %{"original" => "value"}
      assert sw.output_data["selectedCase"] == "new value"
    end

    test "the script runs through the context's evaluate_script" do
      parent = self()

      evaluate = fn op, script, input ->
        send(parent, {:evaluated, op, script, input})
        {:ok, "even"}
      end

      wt = switch("javascript", "anything")

      assert refs(schedule(workflow([wt], %{"route" => "x"}), wt, evaluate_script: evaluate)) ==
               ["switchTask", "t2"]

      assert_received {:evaluated, :eval, "anything", %{"route" => "x"}}
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

    # DecisionTaskMapperTest#getEvaluatedCaseValueUsingExpression
    test "a caseExpression is a script whose Java string picks the case" do
      expression =
        "if ($.Id == null) 'bad input'; else if ( ($.Id != null && $.Id % 2 == 0)) 'even'; " <>
          "else 'odd'; "

      wt =
        decision(
          case_expression: expression,
          input_parameters: %{"Id" => "${workflow.input.Id}"},
          decision_cases: %{"even" => [simple("Test2", "t2")], "odd" => [simple("Test3", "t3")]}
        )

      assert {:ok, [task, %Task{reference_task_name: "t2"}]} =
               schedule(workflow([wt], %{"Id" => "22"}), wt)

      assert task.input_data == %{"case" => "even", "hasChildren" => "true"}
      assert task.output_data == %{"caseOutput" => ["even"]}

      wt = decision(case_expression: "$.case == null ? null : 1/0")
      assert {:ok, [task, _t1]} = schedule(workflow([wt], %{}), wt)
      assert task.input_data["case"] == "null"
      assert {:ok, [task, _t1]} = schedule(workflow([wt], %{"case" => 1}), wt)
      assert task.input_data["case"] == "Infinity"
    end

    # DecisionTaskMapperTest#getEvaluatedCaseValueException
    test "a caseExpression that fails terminates the workflow" do
      expression =
        "if ($Id == null) 'bad input'; else if ( ($Id != null && $Id % 2 == 0)) 'even'; " <>
          "else 'odd'; "

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

  describe "SUB_WORKFLOW" do
    defp sub_workflow(params, extra \\ []) do
      struct!(
        %WorkflowTask{
          name: "sub",
          task_reference_name: "sub_ref",
          type: "SUB_WORKFLOW",
          sub_workflow_param: params
        },
        extra
      )
    end

    # SubWorkflowTaskMapperTest#getMappedTasks
    test "schedules a SUB_WORKFLOW task with the resolved parameters" do
      params = %SubWorkflowParams{
        name: "${workflow.input.name}",
        version: 2,
        task_to_domain: %{"*" => "${workflow.input.domain}"}
      }

      wt =
        sub_workflow(params, start_delay: 30, input_parameters: %{"a" => "${workflow.input.a}"})

      workflow = workflow([wt], %{"name" => "FooWorkFlow", "domain" => "unittest", "a" => 1})

      assert {:ok, [%Task{} = task]} = schedule(workflow, wt)

      assert {task.status, task.task_type, task.callback_after_seconds} ==
               {:scheduled, "SUB_WORKFLOW", 30}

      assert task.input_data == %{
               "subWorkflowName" => "FooWorkFlow",
               "priority" => nil,
               "subWorkflowVersion" => 2,
               "subWorkflowTaskToDomain" => %{"*" => "unittest"},
               "subWorkflowDefinition" => nil,
               "idempotencyKey" => nil,
               "idempotencyStrategy" => nil,
               "workflowInput" => %{"a" => 1}
             }
    end

    # SubWorkflowTaskMapperTest#testTaskToDomain
    test "without taskToDomain the input holds null" do
      wt = sub_workflow(%SubWorkflowParams{name: "Foo", version: 2})

      assert {:ok, [%Task{status: :scheduled, task_type: "SUB_WORKFLOW"} = task]} =
               schedule(workflow([wt], %{}), wt)

      assert task.input_data["subWorkflowTaskToDomain"] == nil
    end

    # SubWorkflowTaskMapperTest#getExceptionWhenNoSubWorkflowParamsPassed
    test "a task without subWorkflowParams terminates the workflow" do
      wt = %{sub_workflow(nil) | name: "FooWorkFLow"}

      assert {:terminate, %Termination{reason: reason}} = schedule(workflow([wt], %{}), wt)

      assert reason ==
               "Task FooWorkFLow is defined as sub-workflow and is missing subWorkflowParams. " <>
                 "Please check the workflow definition"
    end

    # SubWorkflowTaskMapperTest#workflowDefinitionStringExpressionIsResolvedToRuntimeValue
    test "a workflowDefinition expression resolves to the referenced value" do
      inline = %{"name" => "dynamic_plan_wf", "version" => 1, "tasks" => []}

      plan = %Task{
        reference_task_name: "planTask",
        task_type: "SIMPLE",
        status: :completed,
        output_data: %{"result" => inline}
      }

      params = %SubWorkflowParams{
        name: "dynamic_plan_wf",
        version: 1,
        workflow_definition: "${planTask.output.result}"
      }

      wt = sub_workflow(params)
      workflow = workflow([wt], %{}, tasks: [plan])

      assert {:ok, [%Task{task_type: "SUB_WORKFLOW"} = task]} = schedule(workflow, wt)
      assert task.input_data["subWorkflowDefinition"] == inline
      # SubWorkflowTaskMapper skips the version with a definition.
      assert task.input_data["subWorkflowVersion"] == nil
    end

    test "an inline definition is copied as JSON without resolving its expressions" do
      definition = %WorkflowDef{
        name: "inline_wf",
        version: 3,
        tasks: [simple("t", "t")],
        input_parameters: ["${workflow.input.x}"]
      }

      wt = sub_workflow(%SubWorkflowParams{name: "ignored", workflow_definition: definition})

      assert {:ok, [task]} = schedule(workflow([wt], %{"x" => 1}), wt)
      assert task.input_data["subWorkflowName"] == "inline_wf"
      assert task.input_data["subWorkflowDefinition"] == WorkflowDef.to_json(definition)
      assert task.input_data["subWorkflowVersion"] == nil
    end

    test "without a version the latest one in the context is used" do
      wt = sub_workflow(%SubWorkflowParams{name: "Foo"})
      workflow = workflow([wt], %{})

      assert {:ok, [task]} = schedule(workflow, wt, latest_workflow_versions: %{"Foo" => 7})
      assert task.input_data["subWorkflowVersion"] == 7

      assert {:terminate, %Termination{reason: reason}} = schedule(workflow, wt)

      assert reason ==
               "The Task Foo defined as a sub-workflow has no workflow definition available "
    end

    test "a numeric priority overrides the workflow priority; an expression only the input" do
      wt = sub_workflow(%SubWorkflowParams{name: "Foo", version: 1, priority: 5})
      assert {:ok, [task]} = schedule(workflow([wt], %{}, priority: 1), wt)
      assert {task.workflow_priority, task.input_data["priority"]} == {5, 5}

      wt =
        sub_workflow(%SubWorkflowParams{name: "Foo", version: 1, priority: "${workflow.input.p}"})

      assert {:ok, [task]} = schedule(workflow([wt], %{"p" => 9}, priority: 1), wt)
      assert {task.workflow_priority, task.input_data["priority"]} == {1, 9}
    end

    test "the idempotency key resolves and the strategy keeps its upstream name" do
      params = %SubWorkflowParams{
        name: "Foo",
        version: 1,
        idempotency_key: "${workflow.input.key}",
        idempotency_strategy: :return_existing
      }

      wt = sub_workflow(params)
      assert {:ok, [task]} = schedule(workflow([wt], %{"key" => "k1"}), wt)

      assert {task.input_data["idempotencyKey"], task.input_data["idempotencyStrategy"]} ==
               {"k1", "RETURN_EXISTING"}
    end

    test "a name that resolves to null terminates the workflow" do
      wt = sub_workflow(%SubWorkflowParams{name: "${workflow.input.missing}", version: 1})

      assert {:terminate, %Termination{reason: reason}} = schedule(workflow([wt], %{}), wt)

      assert reason ==
               "Task sub is defined as sub-workflow and its subWorkflowParams name resolved to null"
    end
  end

  describe "WAIT" do
    defp wait(input, extra \\ []) do
      struct!(
        %WorkflowTask{
          name: "Wait_task",
          task_reference_name: "wait_ref",
          type: "WAIT",
          input_parameters: input
        },
        extra
      )
    end

    defp schedule_wait(wt, input \\ %{}) do
      assert {:ok, [%Task{task_type: "WAIT"} = task]} = schedule(workflow([wt], input), wt)
      task
    end

    # WaitTaskMapperTest#getMappedTasks and #testWaitForever
    test "without duration or until the task waits forever" do
      task = schedule_wait(wait(%{}))

      assert {task.status, task.start_time, task.output_data} == {:in_progress, @now, %{}}
      assert {task.callback_after_seconds, task.wait_timeout} == {2_147_483_647, 0}
    end

    # WaitTaskMapperTest#testWaitUntil: an until in the past waits 0 seconds.
    test "until sets the wait timeout to that time" do
      task = schedule_wait(wait(%{"until" => "2022-12-12 10:00"}))
      assert {task.status, task.callback_after_seconds} == {:in_progress, 0}
      assert task.wait_timeout == 1_670_839_200_000

      # @now is 2027-01-15 08:00 UTC.
      task =
        schedule_wait(wait(%{"until" => "${workflow.input.until}"}), %{
          "until" => "2027-01-15 08:30"
        })

      assert {task.wait_timeout, task.callback_after_seconds} == {@now + 1_800_000, 1800}
    end

    # WaitTaskMapperTest#testWaitDuration
    test "duration sets the wait timeout from now" do
      task = schedule_wait(wait(%{"duration" => "1s"}))

      assert {task.status, task.callback_after_seconds, task.wait_timeout} ==
               {:in_progress, 1, @now + 1000}
    end

    # WaitTaskMapperTest#testInvalidWaitConfig
    test "both duration and until fail the task" do
      task = schedule_wait(wait(%{"duration" => "1s", "until" => "2022-12-12"}))
      assert task.status == :failed_with_terminal_error

      assert task.reason_for_incompletion ==
               "Both 'duration' and 'until' specified. Please provide only one input"
    end

    test "an until that does not parse fails the task with upstream's reason" do
      task = schedule_wait(wait(%{"until" => "2022-12-12 10:00 KST"}))
      assert task.status == :failed_with_terminal_error

      assert task.reason_for_incompletion ==
               "Invalid/Unsupported Wait Until format.  Provided: 2022-12-12 10:00 KST"
    end

    test "a no-break space is not blank, so it fails as an until (StringUtils.isNotBlank)" do
      task = schedule_wait(wait(%{"until" => "\u00a0"}))
      assert task.status == :failed_with_terminal_error

      assert task.reason_for_incompletion ==
               "Invalid/Unsupported Wait Until format.  Provided: \u00a0"

      task = schedule_wait(wait(%{"until" => " \t"}))
      assert {task.status, task.callback_after_seconds} == {:in_progress, 2_147_483_647}
    end

    test "a duration that does not parse fails the task where upstream throws" do
      task = schedule_wait(wait(%{"duration" => "${workflow.input.d}"}), %{"d" => "5.0s"})
      assert task.status == :failed_with_terminal_error
      assert task.reason_for_incompletion == "Not valid duration: 5.0s"
    end

    test "the input is resolved with the task ID and the isolation group comes from the definition" do
      wt = wait(%{"id" => "${CPEWF_TASK_ID}"}, task_definition: %TaskDef{isolation_group_id: "g"})
      task = schedule_wait(wt)
      assert task.input_data == %{"id" => task.task_id}
      assert task.isolation_group_id == "g"
    end
  end
end
