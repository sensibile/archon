# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/test/java/org/conductoross/conductor/core/execution/ExecutorUtilsTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the cases run against Archon.Runtime.Step.Postpone, in milliseconds with
# a fixed clock.

defmodule Archon.Runtime.StepPostponeTest do
  @moduledoc """
  `Archon.Runtime.Step.Postpone` (upstream `ExecutorUtils#computePostpone`, ADR 0018,
  decision 6). Upstream works in whole seconds from `System.currentTimeMillis()`; these cases
  use elapsed times that are whole seconds, where both give the same value. Each expected value
  was also checked against upstream's compiled `ExecutorUtils` on JDK 25.
  """

  use ExUnit.Case, async: true

  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step.{Env, Postpone}

  @now 1_000_000

  defp env(opts \\ []), do: Env.new(Keyword.merge([now: @now], opts))

  defp task(type, status, fields \\ []),
    do:
      struct!(
        %Task{
          task_type: type,
          status: status,
          task_id: "#{type}-#{status}",
          scheduled_time: @now
        },
        fields
      )

  defp with_def(task, task_def),
    do: %{task | workflow_task: %WorkflowTask{task_definition: struct!(TaskDef, task_def)}}

  defp workflow(tasks, timeout_seconds \\ 0),
    do: %Workflow{
      workflow_id: "workflowId",
      workflow_definition: %WorkflowDef{timeout_seconds: timeout_seconds},
      tasks: tasks
    }

  defp compute(workflow, opts \\ []), do: Postpone.compute(workflow, env(opts))

  # computePostponeUsesMinimumAcrossTasks
  test "the minimum across tasks" do
    long = with_def(task("SIMPLE", :scheduled), poll_timeout_seconds: 50)
    short = with_def(task("SIMPLE", :scheduled), poll_timeout_seconds: 5)
    assert compute(workflow([long, short])) == 6_000
  end

  # computePostponeCapsByMaxPostpone
  test "capped by the maximum postpone" do
    task = task("SIMPLE", :in_progress, response_timeout_seconds: 500, start_time: @now)
    assert compute(workflow([task]), max_postpone_ms: 60_000) == 60_000
  end

  # computePostponeUsesScheduledPollTimeout
  test "a scheduled task's poll timeout" do
    task = with_def(task("SIMPLE", :scheduled), poll_timeout_seconds: 10)
    assert compute(workflow([task])) == 11_000
  end

  test "a scheduled task without a poll timeout uses the workflow timeout" do
    assert compute(workflow([task("SIMPLE", :scheduled)], 100)) == 101_000
  end

  # computePostponeUsesWorkflowOffsetForScheduledSubWorkflow and
  # computePostponePrefersScheduledSubWorkflowOffsetOverWorkflowTimeout
  test "an active SUB_WORKFLOW uses the workflow offset" do
    sub_workflow = task("SUB_WORKFLOW", :scheduled)
    assert compute(workflow([sub_workflow], 432_000), max_postpone_ms: 900_000) == 30_000

    simple = task("SIMPLE", :scheduled)

    assert compute(workflow([simple, sub_workflow], 432_000), max_postpone_ms: 900_000) ==
             30_000
  end

  # computePostponeUsesWorkflowOffsetForInProgressSubWorkflow
  test "an in-progress SUB_WORKFLOW ignores its response timeout" do
    task = task("SUB_WORKFLOW", :in_progress, response_timeout_seconds: 500, start_time: @now)
    assert compute(workflow([task], 432_000), max_postpone_ms: 900_000) == 30_000
  end

  # computePostponeDefaultsToWorkflowOffsetWhenNoEligibleTasks
  test "no eligible task uses the workflow offset" do
    assert compute(workflow([task("SIMPLE", :completed)])) == 30_000
  end

  # computePostponeUsesOffsetForWaitWithoutTimeout
  test "a WAIT without a timeout uses the offset, with one the time left" do
    assert compute(workflow([task("WAIT", :in_progress, wait_timeout: 0)])) == 30_000
    assert compute(workflow([task("WAIT", :in_progress, wait_timeout: @now + 12_000)])) == 12_000
  end

  test "an in-progress HUMAN uses the offset" do
    assert compute(workflow([task("HUMAN", :in_progress)])) == 30_000
  end

  # computePostponeScheduledElapsedExceedsTimeout
  test "a poll window already over gives 0" do
    task =
      with_def(task("SIMPLE", :scheduled, scheduled_time: @now - 60_000), poll_timeout_seconds: 1)

    assert compute(workflow([task])) == 0
  end

  # computePostponeInProgressElapsedExceedsResponseTimeout
  test "a response window already over gives 0" do
    task = task("SIMPLE", :in_progress, response_timeout_seconds: 1, start_time: @now - 60_000)
    assert compute(workflow([task])) == 0
  end

  # computePostponeUsesTaskModelResponseTimeoutWhenTaskDefIsZero
  test "the task's response timeout when its definition has none" do
    task =
      with_def(task("SIMPLE", :in_progress, response_timeout_seconds: 120, start_time: @now),
        response_timeout_seconds: 0
      )

    assert compute(workflow([task])) == 121_000
  end

  test "the definition's response timeout comes first" do
    task =
      with_def(
        task("SIMPLE", :in_progress, response_timeout_seconds: 120, start_time: @now - 10_000),
        response_timeout_seconds: 40
      )

    assert compute(workflow([task])) == 31_000
  end

  describe "wake_at" do
    test "is at least a second after now" do
      task = task("SIMPLE", :in_progress, response_timeout_seconds: 1, start_time: @now - 60_000)
      assert Postpone.wake_at(workflow([task]), env()) == @now + 1_000
    end

    test "a delayed asynchronous system task wakes the workflow when its delay ends" do
      task = task("SUB_WORKFLOW", :scheduled, callback_after_seconds: 10)
      assert Postpone.wake_at(workflow([task]), env()) == @now + 10_000
    end
  end
end
