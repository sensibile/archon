# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/TestWorkflowDef.java
# and TestDeciderService.java (testGetNextTask, createNestedWorkflow)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests against the Elixir structs; DO_WHILE cases
# added.

defmodule Archon.Domain.WorkflowNavigationTest do
  use ExUnit.Case, async: true

  alias Archon.Domain.{SubWorkflowParams, WorkflowDef, WorkflowTask}

  defp task(ref), do: %WorkflowTask{name: ref, task_reference_name: ref}

  defp decider(ref, cases, default) do
    %WorkflowTask{
      task("#{ref}")
      | type: "DECISION",
        decision_cases: Map.new(cases, fn {key, refs} -> {key, Enum.map(refs, &task/1)} end),
        default_case: Enum.map(default, &task/1)
    }
  end

  defp next_ref(definition, ref) do
    case WorkflowDef.next_task(definition, ref) do
      nil -> nil
      next -> next.task_reference_name
    end
  end

  defp decision_workflow do
    decision = %WorkflowTask{
      task("decision_task_1")
      | type: "DECISION",
        decision_cases: %{
          "Case1" => [task("case_1_task_1"), task("case_1_task_2")],
          "Case2" => [task("case_2_task_1"), task("case_2_task_2")],
          "Case3" => [
            decider("decision_task_2", [{"Case31", ["case31_task_1", "case_31_task_2"]}], [
              "case3_def_task"
            ])
          ]
        }
    }

    %WorkflowDef{
      name: "test_workflow",
      version: 1,
      tasks: [task("simple_task_1"), task("simple_task_2"), decision, task("simple_task_3")]
    }
  end

  # TestDeciderService#createNestedWorkflow
  defp nested_workflow do
    t = Map.new(0..9, &{&1, task("t#{&1}")})

    decision = %WorkflowTask{
      task("d1")
      | type: "DECISION",
        case_value_param: "case",
        default_case: [t[8]],
        decision_cases: %{"a" => [t[6], t[9]], "b" => [t[7]]}
    }

    sub_workflow = %WorkflowTask{
      task("sw1")
      | type: "SUB_WORKFLOW",
        sub_workflow_param: %SubWorkflowParams{name: "linear"}
    }

    fork2 = %WorkflowTask{
      task("fork2")
      | type: "FORK_JOIN",
        fork_tasks: [[t[2], t[4]], [t[3], decision]]
    }

    join2 = %WorkflowTask{task("join2") | type: "JOIN", join_on: ["t4", "d1"]}

    fork1 = %WorkflowTask{
      task("fork1")
      | type: "FORK_JOIN",
        fork_tasks: [[t[1]], [fork2, join2], [sub_workflow]]
    }

    join1 = %WorkflowTask{task("join1") | type: "JOIN", join_on: ["t1", "fork2"]}

    %WorkflowDef{name: "Nested Workflow", version: 1, tasks: [fork1, join1, t[5]]}
  end

  describe "TestWorkflowDef" do
    test "testContainsType" do
      definition = decision_workflow()

      assert WorkflowDef.contains_type?(definition, "SIMPLE")
      assert WorkflowDef.contains_type?(definition, "DECISION")
      refute WorkflowDef.contains_type?(definition, "DO_WHILE")
    end

    test "testGetNextTask_Decision" do
      definition = decision_workflow()

      assert next_ref(definition, "simple_task_1") == "simple_task_2"
      assert next_ref(definition, "simple_task_2") == "decision_task_1"
      assert next_ref(definition, "decision_task_1") == "simple_task_3"
      assert next_ref(definition, "case_1_task_1") == "case_1_task_2"
      assert next_ref(definition, "case_1_task_2") == "simple_task_3"
      assert next_ref(definition, "case3_def_task") == "simple_task_3"
      assert next_ref(definition, "case31_task_1") == "case_31_task_2"
    end

    test "testGetNextTask_Conditional" do
      t = Map.new(0..9, &{&1, task("junit_task_#{&1}")})

      sub_case = %WorkflowTask{
        task("case2")
        | type: "DECISION",
          case_value_param: "case2",
          decision_cases: %{"sc1" => [t[4]], "sc2" => [t[5], t[6]]}
      }

      case_task = %WorkflowTask{
        task("case")
        | type: "DECISION",
          case_value_param: "case",
          decision_cases: %{"c1" => [t[0], sub_case, t[1]], "c2" => [t[3]]}
      }

      definition = %WorkflowDef{name: "COND_TASK_WF", tasks: [case_task, t[8]]}

      assert next_ref(definition, "case") == "junit_task_8"
      assert next_ref(definition, "junit_task_8") == nil
      assert next_ref(definition, "junit_task_0") == "case2"
      assert next_ref(definition, "case2") == "junit_task_1"
    end
  end

  describe "TestDeciderService" do
    test "testGetNextTask" do
      definition = nested_workflow()

      assert hd(definition.tasks).task_reference_name == "fork1"
      assert next_ref(definition, "fork1") == "join1"
      assert WorkflowDef.task_by_ref_name(definition, "fork2").task_reference_name == "fork2"
      assert next_ref(definition, "fork2") == "join2"
      assert next_ref(definition, "t2") == "t4"

      assert %WorkflowTask{type: "DECISION", task_reference_name: "d1"} =
               WorkflowDef.next_task(definition, "t3")

      assert next_ref(definition, "t4") == "join2"
      assert next_ref(definition, "t6") == "t9"
      assert next_ref(definition, "join2") == "join1"
      assert next_ref(definition, "join1") == "t5"
      assert next_ref(definition, "sw1") == "join1"
      assert next_ref(definition, "t9") == "join2"
    end
  end

  describe "beyond the upstream tests" do
    setup do
      loop = %WorkflowTask{
        task("loop")
        | type: "DO_WHILE",
          loop_condition: "false",
          loop_over: [task("body_1"), task("body_2")]
      }

      terminate = %WorkflowTask{task("stop") | type: "TERMINATE"}

      %{definition: %WorkflowDef{name: "loop_wf", tasks: [loop, task("after"), terminate]}}
    end

    test "the last task of a DO_WHILE body leads back to the loop", %{definition: definition} do
      assert next_ref(definition, "body_1") == "body_2"
      assert next_ref(definition, "body_2") == "loop"
      assert next_ref(definition, "loop") == "after"
    end

    test "a TERMINATE task has no next task", %{definition: definition} do
      assert next_ref(definition, "after") == "stop"
      assert next_ref(definition, "stop") == nil
    end

    test "an unknown reference has no next task", %{definition: definition} do
      assert next_ref(definition, "missing") == nil
    end

    test "has?/2 and get/2 look into nested branches" do
      definition = nested_workflow()
      [fork1 | _rest] = definition.tasks

      assert WorkflowTask.has?(fork1, "t9")
      refute WorkflowTask.has?(fork1, "t5")
      assert WorkflowTask.get(fork1, "d1").type == "DECISION"
      assert WorkflowTask.get(fork1, "t5") == nil
    end
  end
end
