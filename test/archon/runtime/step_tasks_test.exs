# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/TestWorkflowExecutor.java
# (testUpdateTaskWithCallbackAfterSeconds, testUpdateTaskWithOutCallbackAfterSeconds,
# testTaskExtendLease, testIsLazyEvaluateWorkflow) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the cases run through Archon.Runtime.Step.run/3, with queue changes as
# effects instead of mocks.

defmodule Archon.Runtime.StepTasksTest do
  @moduledoc """
  Worker poll and task update in `Archon.Runtime.Step` (ADR 0018, decision 7): upstream
  `ExecutionService#poll` for one task and `WorkflowExecutorOps#updateTask`.
  """

  use ExUnit.Case, async: true

  alias Archon.Domain.{Task, TaskDef, TaskResult, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.{Env, Tasks}

  @now 1_000_000

  defp env(opts \\ []), do: Env.new(Keyword.merge([now: @now], opts))

  defp simple_def(name, fields \\ []), do: struct!(%TaskDef{name: name, retry_count: 0}, fields)

  defp wt(name, fields \\ []),
    do:
      struct!(
        %WorkflowTask{
          name: name,
          task_reference_name: name,
          type: "SIMPLE",
          task_definition: simple_def(name)
        },
        fields
      )

  defp workflow(tasks, status \\ :running) do
    %Workflow{
      workflow_id: "test-workflow-id",
      status: status,
      workflow_definition: %WorkflowDef{name: "wf", version: 1, tasks: [wt("simpleTask")]},
      tasks: tasks
    }
  end

  defp simple(fields) do
    struct!(
      %Task{
        task_id: "simple-task-id",
        task_type: "simpleTask",
        reference_task_name: "simpleTask",
        workflow_instance_id: "test-workflow-id",
        scheduled_time: @now - 1_000,
        status: :in_progress,
        workflow_task: wt("simpleTask")
      },
      fields
    )
  end

  defp result(fields),
    do:
      struct!(
        %TaskResult{
          workflow_instance_id: "test-workflow-id",
          task_id: "simple-task-id",
          worker_id: "test-worker-id"
        },
        fields
      )

  describe "poll" do
    test "the scheduled task goes to the worker IN_PROGRESS" do
      task =
        simple(
          status: :scheduled,
          callback_after_seconds: 7,
          callback_after_ms: 7_250,
          start_time: 0
        )

      {polled, stored, [], commit, post} =
        Step.run(workflow([task]), {:poll, task.task_id, "w1"}, env())

      assert %Task{
               status: :in_progress,
               worker_id: "w1",
               poll_count: 1,
               callback_after_seconds: 0,
               callback_after_ms: 0,
               start_time: @now,
               update_time: @now
             } = polled

      assert stored.tasks == [polled]
      assert commit.upsert_tasks == [polled]
      # adjustDeciderQueuePostpone: the default response timeout of 3600 s pulls the timer.
      assert post == [{:wake_before, @now + 3_600_000}]
    end

    test "a start time already set is kept" do
      task = simple(status: :scheduled, start_time: 5)

      {%Task{start_time: 5}, _stored, [], _commit, _post} =
        Step.run(workflow([task]), {:poll, task.task_id, "w1"}, env())
    end

    test "a terminal task is removed from its queue" do
      task = simple(status: :canceled, domain: "d")

      assert {nil, _stored, [], %{upsert_tasks: []},
              [{:queue_remove, "d:simpleTask", "simple-task-id"}]} =
               Step.run(workflow([task]), {:poll, task.task_id, "w1"}, env())
    end

    test "a task the workflow does not have" do
      assert {{:error, :not_found}, _stored, [], _commit, []} =
               Step.run(workflow([]), {:poll, "other", "w1"}, env())
    end

    test "over the concurrent execution limit the task is put back for 60 s" do
      task =
        simple(
          status: :scheduled,
          workflow_priority: 3,
          workflow_task:
            wt("simpleTask", task_definition: simple_def("simpleTask", concurrent_exec_limit: 2))
        )

      assert {nil, _stored, [], %{upsert_tasks: []}, post} =
               Step.run(
                 workflow([task]),
                 {:poll, task.task_id, "w1"},
                 env(in_progress: %{"simpleTask" => 2})
               )

      assert post == [{:queue_postpone, "simpleTask", "simple-task-id", 3, 60_000}]

      assert {%Task{status: :in_progress}, _stored, [], _commit, _post} =
               Step.run(
                 workflow([task]),
                 {:poll, task.task_id, "w1"},
                 env(in_progress: %{"simpleTask" => 1})
               )
    end
  end

  describe "update" do
    # testUpdateTaskWithCallbackAfterSeconds
    test "IN_PROGRESS from a worker puts the task back SCHEDULED for its callback" do
      result = result(status: :in_progress, callback_after_seconds: 300)

      {task, stored, [], commit, post} =
        Step.run(workflow([simple([])]), {:update, result}, env())

      assert %Task{
               status: :scheduled,
               callback_after_seconds: 300,
               callback_after_ms: 0,
               worker_id: "test-worker-id"
             } = task

      assert [%Task{status: :scheduled}] = commit.upsert_tasks
      assert stored.status == :running
      assert {:queue_postpone, "simpleTask", "simple-task-id", 0, 300_000} in post
    end

    # testUpdateTaskWithOutCallbackAfterSeconds
    test "IN_PROGRESS without a callback postpones by 0" do
      {task, _stored, [], _commit, post} =
        Step.run(workflow([simple([])]), {:update, result(status: :in_progress)}, env())

      assert %Task{status: :scheduled, callback_after_seconds: 0} = task
      assert {:queue_postpone, "simpleTask", "simple-task-id", 0, 0} in post
    end

    # testTaskExtendLease
    test "extendLease only refreshes updateTime" do
      task = simple(update_time: 5)

      assert {nil, stored, [], commit, []} =
               Step.run(
                 workflow([task]),
                 {:update, result(extend_lease: true, status: :completed)},
                 env()
               )

      assert [%Task{update_time: @now, status: :in_progress}] = commit.upsert_tasks
      assert commit.workflow == nil
      assert stored.tasks == commit.upsert_tasks
    end

    test "a completed update replaces the output, ends the task and decides" do
      result = result(status: :completed, output_data: %{"y" => 2})

      {task, stored, [], commit, post} =
        Step.run(workflow([simple(output_data: %{"x" => 1})]), {:update, result}, env())

      assert %Task{status: :completed, output_data: %{"y" => 2}, end_time: @now} = task
      assert {:queue_remove, "simpleTask", "simple-task-id"} in post
      assert stored.status == :completed
      assert commit.workflow.status == :completed
    end

    test "the subWorkflowId output key follows the result's" do
      result =
        result(status: :failed, output_data: %{"subWorkflowId" => "old"}, sub_workflow_id: "new")

      {task, _stored, [], _commit, _post} =
        Step.run(workflow([simple([])]), {:update, result}, env())

      assert {task.sub_workflow_id, task.output_data} == {"new", %{"subWorkflowId" => "new"}}
    end

    test "a terminal task or workflow ignores the update and removes the message" do
      done = simple(status: :completed)

      assert {^done, _stored, [], %{upsert_tasks: []}, [{:queue_remove, "simpleTask", _id}]} =
               Step.run(workflow([done]), {:update, result(status: :failed)}, env())

      running = simple([])

      assert {^running, _stored, [], %{upsert_tasks: []}, [{:queue_remove, "simpleTask", _id}]} =
               Step.run(
                 workflow([running], :terminated),
                 {:update, result(status: :failed)},
                 env()
               )
    end

    test "an unknown task" do
      assert {{:error, :not_found}, _stored, [], _commit, []} =
               Step.run(workflow([]), {:update, result(status: :completed)}, env())
    end
  end

  # testIsLazyEvaluateWorkflow
  test "isLazyEvaluateWorkflow skips the decide only for a successful forked task a JOIN waits on" do
    fork = %WorkflowTask{
      name: "fork",
      task_reference_name: "fork",
      type: "FORK_JOIN",
      fork_tasks: [[wt("branchTask1"), wt("branchTask2")]]
    }

    join = %WorkflowTask{
      name: "join",
      task_reference_name: "join",
      type: "JOIN",
      join_on: ["branchTask2"]
    }

    do_while = %WorkflowTask{
      name: "doWhile",
      task_reference_name: "doWhile",
      type: "DO_WHILE",
      loop_over: [wt("loopTask")]
    }

    definition = %WorkflowDef{
      name: "lazyEvaluate",
      version: 1,
      tasks: [wt("simple"), fork, join, do_while]
    }

    lazy? = fn fields ->
      Tasks.lazy_evaluate?(definition, struct!(%Task{status: :completed}, fields))
    end

    refute lazy?.(reference_task_name: "dynamic")
    refute lazy?.(reference_task_name: "branchTask1")
    assert lazy?.(reference_task_name: "branchTask2")
    refute lazy?.(reference_task_name: "simple")
    refute lazy?.(reference_task_name: "loopTask__1", iteration: 1)
    refute lazy?.(reference_task_name: "branchTask2", status: :failed)
  end
end
