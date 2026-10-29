# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/tasks/TestJoin.java,
# JoinTest.java and SwitchTest.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests against the pure execute; the evaluation
# offset cases move with the queue to Phase 3 (ADR 0014).

defmodule Archon.Decider.SystemTaskTest do
  use ExUnit.Case, async: true

  alias Archon.Decider.SystemTask
  alias Archon.Domain.{Task, Workflow, WorkflowDef, WorkflowTask}

  # TestJoin#createTask
  defp forked(ref, status, opts \\ []) do
    %Task{
      reference_task_name: ref,
      status: status,
      task_def_name: Keyword.get(opts, :def_name),
      task_id: Keyword.get(opts, :id),
      reason_for_incompletion: Keyword.get(opts, :reason),
      output_data: Keyword.get(opts, :output, %{}),
      input_data: Keyword.get(opts, :input, %{}),
      workflow_task: %WorkflowTask{
        optional: Keyword.get(opts, :optional, false),
        permissive: Keyword.get(opts, :permissive, false)
      }
    }
  end

  # TestJoin#createJoinWorkflow
  defp join(tasks, extra_refs \\ [], definition \\ %WorkflowDef{}) do
    join = %Task{
      reference_task_name: "join",
      task_type: "JOIN",
      status: :in_progress,
      input_data: %{"joinOn" => Enum.map(tasks, & &1.reference_task_name) ++ extra_refs}
    }

    SystemTask.execute(%Workflow{workflow_definition: definition, tasks: tasks ++ [join]}, join)
  end

  test "SWITCH and DECISION complete; FORK does nothing" do
    for type <- ["SWITCH", "DECISION"] do
      task = %Task{task_type: type, status: :in_progress}
      assert {true, %Task{status: :completed}} = SystemTask.execute(%Workflow{}, task)
    end

    fork = %Task{task_type: "FORK", status: :completed}
    assert {false, ^fork} = SystemTask.execute(%Workflow{}, fork)
  end

  describe "JOIN" do
    # TestJoin#testShouldNotMarkJoinAsCompletedWithErrorsWhenNotDone
    test "waits while a joined task is not scheduled yet" do
      task1 = forked("task1", :completed_with_errors, optional: true)
      assert {false, %Task{status: :in_progress}} = join([task1], ["task2"])
    end

    # TestJoin#testJoinCompletesSuccessfullyWhenAllTasksSucceed
    test "completes with the branch outputs when every joined task succeeded" do
      task1 = forked("task1", :completed, output: %{"a" => 1})
      task2 = forked("task2", :completed)

      assert {true, %Task{status: :completed, output_data: output}} = join([task1, task2])
      assert output == %{"task1" => %{"a" => 1}}
    end

    # TestJoin#testJoinWaitsWhenAnyTaskIsNotTerminal
    test "waits while a joined task is not terminal" do
      assert {false, _join} = join([forked("task1", :in_progress), forked("task2", :completed)])
    end

    # TestJoin#testJoinIsCanceledWhenForkedTaskIsCanceled
    test "is canceled when the only failure is a cancellation" do
      assert {true, %Task{status: :canceled}} =
               join([forked("task1", :completed), forked("task2", :canceled)])
    end

    # TestJoin#testJoinFailsWhenAnotherForkedTaskFailsBesidesCancellation
    test "fails when a genuine failure exists alongside a cancellation" do
      assert {true, %Task{status: :failed}} =
               join([forked("task1", :canceled), forked("task2", :failed)])
    end

    # TestJoin#testJoinFailsWhenMandatoryTaskFails
    test "fails when a mandatory task fails" do
      task2 = forked("task2", :completed_with_errors, optional: true)
      assert {true, %Task{status: :failed}} = join([forked("task1", :failed), task2])
    end

    # TestJoin#testJoinCompletesWithErrorsWhenOnlyOptionalTasksFail
    test "completes with errors when only optional tasks completed with errors" do
      task2 = forked("task2", :completed_with_errors, optional: true, def_name: "t2", id: "id-2")

      assert {true, %Task{status: :completed_with_errors, reason_for_incompletion: reason}} =
               join([forked("task1", :completed), task2])

      assert reason == "t2/id-2 completed with errors"
    end

    # TestJoin#testJoinAggregatesFailureReasonsCorrectly
    test "joins the failure reasons" do
      task1 = forked("task1", :failed, reason: "Task1 failed")
      task2 = forked("task2", :failed, reason: "Task2 failed")

      assert {true, %Task{status: :failed, reason_for_incompletion: "Task1 failed Task2 failed"}} =
               join([task1, task2])
    end

    # TestJoin#testJoinWaitsForAllTasksBeforeFailingDueToPermissiveTaskFailure
    test "a permissive failure fails the join only once every joined task is terminal" do
      task1 = forked("task1", :failed, permissive: true)
      assert {false, _join} = join([task1, forked("task2", :in_progress)])
      assert {true, %Task{status: :failed}} = join([task1, forked("task2", :completed)])
    end

    test "inside a loop it joins on the tasks of its iteration" do
      task = forked("task1__2", :completed, output: %{"i" => 2})

      join = %Task{
        reference_task_name: "join__2",
        task_type: "JOIN",
        status: :in_progress,
        iteration: 2,
        input_data: %{"joinOn" => ["task1"]}
      }

      workflow = %Workflow{workflow_definition: %WorkflowDef{}, tasks: [task, join]}

      assert {true, %Task{status: :completed, output_data: %{"task1__2" => %{"i" => 2}}}} =
               SystemTask.execute(workflow, join)
    end

    test "reads the latest task of a reference name" do
      retried = %{forked("task1", :failed) | retried: true}

      assert {true, %Task{status: :completed}} = join([retried, forked("task1", :completed)])
    end
  end

  describe "JOIN in agent workflows" do
    @agent %WorkflowDef{metadata: %{"agent_sdk" => "python"}}

    # JoinTest#testAgentWorkflowDefCompactsForkOutput
    test "state-bearing outputs are compacted to the merge keys" do
      output = %{"state" => "s", "_state_updates" => %{"u" => 1}, "toolResult" => "raw"}

      assert {true, %Task{output_data: %{"t1" => compact}}} =
               join([forked("t1", :completed, output: output)], [], @agent)

      assert compact == %{"state" => "s", "_state_updates" => %{"u" => 1}}
    end

    # JoinTest#testAgentWorkflowDefKeepsToolOutputWithoutStateKeys
    test "outputs without state keys pass through" do
      output = %{"verdict" => "RECURRING", "matchedCount" => 100}

      assert {true, %Task{output_data: %{"tool_1" => ^output}}} =
               join([forked("tool_1", :completed, output: output)], [], @agent)
    end

    # JoinTest#testMarkedAgentToolKeepsNameAndFullOutputWhenItAlsoUpdatesState
    test "a marked tool keeps its name and full output" do
      output = %{"customerName" => "Alice", "_state_updates" => %{"customerName" => "Alice"}}

      tool =
        forked("lookup", :completed, output: output, input: %{"_agent_tool_name" => "handoff"})

      assert {true, %Task{output_data: %{"lookup" => shaped}}} = join([tool], [], @agent)
      assert shaped == %{"_agent_tool_name" => "handoff", "_agent_tool_output" => output}
    end

    # JoinTest#testNonAgentWorkflowDefCopiesFullForkOutput and #testNoWorkflowDefinitionDoesNotThrow
    test "other workflows copy the full output" do
      output = %{"state" => "s", "toolResult" => "raw"}

      assert {true, %Task{output_data: %{"t1" => ^output}}} =
               join([forked("t1", :completed, output: output)])

      task = forked("t1", :completed, output: output)
      join = %Task{task_type: "JOIN", status: :in_progress, input_data: %{"joinOn" => ["t1"]}}

      assert {true, %Task{status: :completed}} =
               SystemTask.execute(%Workflow{tasks: [task, join]}, join)
    end
  end
end
