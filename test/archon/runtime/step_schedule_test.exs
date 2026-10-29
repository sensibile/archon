# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/TestWorkflowExecutor.java
# (testScheduleTask, testQueueFailuresDuringScheduleTask,
# testScheduleTaskQueuesAsyncSubWorkflowWithoutInlineStart, testDecisionSwitchIsNeverQueued,
# testGetActiveDomain, testInactiveDomains, testDefaultDomain, testTaskToDomain,
# testTaskToDomainsPerTask, testTaskToDomainOverrides, testDedupAndAddTasks,
# testScheduleNextIteration) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the cases run against Archon.Runtime.Step.Schedule and the step, with poll
# data in the env and queue pushes as effects instead of mocks.

defmodule Archon.Runtime.StepScheduleTest do
  @moduledoc """
  `Archon.Runtime.Step.Schedule`: domains, deduplication and `scheduleTask` (ADR 0018,
  decision 4). The expected values were also checked against upstream's compiled
  `WorkflowExecutorOps` (`getActiveDomain`, `setTaskDomains`, `dedupAndAddTasks`) on JDK 25.
  """

  use ExUnit.Case, async: true

  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.{Env, Schedule, State}

  @now 1_000_000

  defp env(opts \\ []), do: Env.new(Keyword.merge([now: @now], opts))

  defp workflow(fields \\ []),
    do:
      struct!(
        %Workflow{
          workflow_id: "wf",
          status: :running,
          workflow_definition: %WorkflowDef{name: "wf", version: 1}
        },
        fields
      )

  defp task(fields), do: struct!(%Task{status: :scheduled, workflow_instance_id: "wf"}, fields)

  describe "getActiveDomain" do
    # testGetActiveDomain (activeWorkerLastPollTimeout of 100 s, as the upstream test sets).
    test "the first domain polled within the timeout, else the last domain" do
      polled = fn polls -> env(active_worker_last_poll_ms: 100_000, poll_data: polls) end
      domains = ["domain1", "domain2"]

      assert Schedule.active_domain(
               "test-task",
               domains,
               polled.(%{{"test-task", "domain1"} => @now - 99_000})
             ) == "domain1"

      assert Schedule.active_domain(
               "test-task",
               domains,
               polled.(%{
                 {"test-task", "domain1"} => @now - 101_000,
                 {"test-task", "domain2"} => @now - 99_000
               })
             ) == "domain2"

      assert Schedule.active_domain("test-task", [""], polled.(%{{"test-task", ""} => 0})) == ""
      assert Schedule.active_domain("test-task", [], polled.(%{})) == nil
      assert Schedule.active_domain("test-task", nil, polled.(%{})) == nil
      assert Schedule.active_domain("test-task", ["test-domain"], polled.(%{})) == "test-domain"
    end

    # testInactiveDomains
    test "without an active domain the last one is used" do
      env = env(poll_data: %{{"test-task", "domain1"} => @now - 990_000})
      assert Schedule.active_domain("test-task", ["domain1", "domain2"], env) == "domain2"
    end

    # testDefaultDomain
    test "a last NO_DOMAIN means no domain, in any case" do
      env = env(poll_data: %{{"test-task", "domain1"} => @now - 990_000})
      assert Schedule.active_domain("test-task", ["domain1", "domain2", "NO_DOMAIN"], env) == nil
      assert Schedule.active_domain("test-task", ["x", " no_domain"], env) == nil
    end

    test "domains are trimmed" do
      env = env(poll_data: %{{"test-task", "b"} => @now - 1_000})
      assert Schedule.active_domain("test-task", ["a ", " b "], env) == "b"
    end
  end

  describe "setTaskDomains" do
    defp tasks(count),
      do: for(i <- 1..count, do: task(task_id: "t#{i}", task_type: "task#{i}", retry_count: 1))

    # testTaskToDomain
    test "the * mapping applies to every task" do
      env = env(poll_data: Map.new(1..3, &{{"task#{&1}", "mydomain"}, @now - 9_900}))
      wf = workflow(task_to_domain: %{"*" => "mydomain"})

      assert Enum.map(Schedule.set_task_domains(tasks(3), wf, env), & &1.domain) ==
               ["mydomain", "mydomain", "mydomain"]
    end

    # testTaskToDomainsPerTask
    test "a task with no active domain before NO_DOMAIN gets none" do
      env = env(poll_data: %{{"task1", "mydomain"} => @now - 9_900})
      wf = workflow(task_to_domain: %{"*" => "mydomain, NO_DOMAIN"})

      assert Enum.map(Schedule.set_task_domains(tasks(2), wf, env), & &1.domain) ==
               ["mydomain", nil]
    end

    # testTaskToDomainOverrides; a system task (JOIN) never takes a domain.
    test "task type entries override the * mapping" do
      polls =
        for(
          type <- ~w(task1 task2 task3 task4 JOIN),
          into: %{},
          do: {{type, "mydomain"}, @now - 9_900}
        )

      env = env(poll_data: Map.put(polls, {"task3", "someActiveDomain"}, @now - 9_900))

      wf =
        workflow(
          task_to_domain: %{
            "*" => "mydomain",
            "task2" => "someInactiveDomain, NO_DOMAIN",
            "task3" => "someActiveDomain, NO_DOMAIN",
            "task4" => "someInactiveDomain, someInactiveDomain2"
          }
        )

      tasks = tasks(4) ++ [task(task_id: "j", task_type: "JOIN")]

      assert Enum.map(Schedule.set_task_domains(tasks, wf, env), & &1.domain) ==
               ["mydomain", nil, "someActiveDomain", "someInactiveDomain2", nil]
    end

    test "without a mapping domains stay as they are" do
      assert Schedule.set_task_domains(tasks(1), workflow(task_to_domain: %{}), env()) == tasks(1)
    end
  end

  # testDedupAndAddTasks
  test "dedupAndAddTasks adds the tasks whose reference name and retry count are new" do
    state = State.new(workflow(tasks: []), env())
    task1 = task(task_id: "a", reference_task_name: "task1", retry_count: 1)
    task2 = task(task_id: "b", reference_task_name: "task2", retry_count: 2)

    {state, new} = Schedule.dedup_and_add(state, [task1, task2])
    assert new == [task1, task2]
    assert state.wf.tasks == [task1, task2]

    {state, new} = Schedule.dedup_and_add(state, [task1, task2])
    assert new == []

    retried = task(task_id: "c", reference_task_name: "task1", retry_count: 2)
    {state, new} = Schedule.dedup_and_add(state, [retried])
    assert new == [retried]
    assert length(state.wf.tasks) == 3
  end

  describe "scheduleTask" do
    # testScheduleTask: the synchronous system task starts and is saved, the worker task is
    # queued. Upstream also queues the asynchronous WAIT; here its process evaluates it on :wake.
    test "starts synchronous system tasks and queues worker tasks" do
      state =
        State.new(workflow(tasks: [task(task_id: "old", seq: 4, status: :completed)]), env())

      tasks = [
        task(task_id: "http", task_type: "SIMPLE", callback_after_seconds: 5),
        task(task_id: "wait", task_type: "WAIT", status: :in_progress),
        task(task_id: "switch", task_type: "SWITCH", status: :in_progress)
      ]

      {state, started?} = Schedule.schedule(state, tasks)

      assert started?

      assert Enum.map(state.stored.tasks, &{&1.task_id, &1.seq}) ==
               [{"old", 4}, {"http", 5}, {"wait", 6}, {"switch", 7}]

      assert Enum.all?(tl(state.stored.tasks), &(&1.first_scheduled_time == @now))
      assert [{:queue_push, "SIMPLE", "http", 0, 5_000}] = state.post

      assert %Task{start_time: @now, update_time: @now} =
               Enum.find(state.stored.tasks, &(&1.task_id == "switch"))

      assert %Task{start_time: @now, update_time: 0} =
               Enum.find(state.stored.tasks, &(&1.task_id == "wait"))
    end

    # testQueueFailuresDuringScheduleTask: queueing worker tasks does not count as a start.
    test "worker tasks alone change no state" do
      state = State.new(workflow(), env())
      task = task(task_id: "tid_01", task_type: "SIMPLE", domain: "d1", callback_after_ms: 1500)
      {state, started?} = Schedule.schedule(state, [task])

      refute started?
      assert state.post == [{:queue_push, "d1:SIMPLE", "tid_01", 0, 1500}]
    end

    # testScheduleTaskQueuesAsyncSubWorkflowWithoutInlineStart: a SUB_WORKFLOW is not started by
    # scheduleTask; it is due for the process's evaluation.
    test "asynchronous system tasks are not started in place" do
      state = State.new(workflow(), env())
      task = task(task_id: "sub-workflow-task", task_type: "SUB_WORKFLOW")
      {state, started?} = Schedule.schedule(state, [task])

      refute started?
      assert state.post == []
      assert MapSet.to_list(state.due) == ["sub-workflow-task"]
      assert [%Task{update_time: 0}] = state.stored.tasks
    end

    # testDecisionSwitchIsNeverQueued
    test "a SWITCH is never queued and stays IN_PROGRESS" do
      state = State.new(workflow(), env())
      task = task(task_id: "r1", task_type: "SWITCH", status: :in_progress)
      {state, true} = Schedule.schedule(state, [task])

      assert state.post == []
      assert [%Task{status: :in_progress}] = state.stored.tasks
    end
  end

  # testScheduleNextIteration: the next DO_WHILE iteration takes its task type's domain.
  test "the next DO_WHILE iteration gets its domain" do
    body = %WorkflowTask{
      name: "TEST",
      task_reference_name: "test",
      type: "SIMPLE",
      task_definition: %TaskDef{name: "TEST", retry_count: 0}
    }

    loop = %WorkflowTask{
      name: "loop",
      task_reference_name: "loop",
      type: "DO_WHILE",
      loop_over: [body],
      loop_condition: "false",
      task_definition: %TaskDef{name: "loop", retry_count: 0, response_timeout_seconds: 0}
    }

    wf = %Workflow{
      workflow_id: "wf",
      task_to_domain: %{"TEST" => "domain1"},
      workflow_definition: %WorkflowDef{name: "wf", version: 1, tasks: [loop]}
    }

    {{:ok, "wf"}, stored, [], _commit, post} = Step.run(nil, {:start, wf}, env())

    assert [
             %Task{task_type: "DO_WHILE"},
             %Task{reference_task_name: "test__1", domain: "domain1"}
           ] =
             stored.tasks

    assert {:queue_push, "domain1:TEST", _id, 0, 0} = hd(post)
  end
end
