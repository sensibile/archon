# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/TestWorkflowExecutorDecideLoop.java
# (testDecideLoopManyIterationsNoStackOverflow, testDecideLoopRequeuesWhenApproachingLockLeaseTime)
# and core/.../execution/TestWorkflowExecutor.java (testCancelNonTerminalTasks,
# testTerminateCompletedWorkflow, testTerminateAlreadyTerminatedWorkflow,
# testTerminateWorkflowWithFailureWorkflow, testStartWorkflowIdempotentReturnsExistingWorkflowModel,
# testStartWorkflowIdempotentRejectsExistingWorkflowOwnedByDifferentParentTask)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the cases run through Archon.Runtime.Step.run/3; a DO_WHILE of SWITCH
# tasks stands in for the mocked Decider, and effects replace the mocked DAOs.

defmodule Archon.Runtime.StepTest do
  @moduledoc """
  `Archon.Runtime.Step.run/3` (ADR 0018, decisions 2, 4, 5, 6 and 8): the decide loop and its
  iteration limit, what is stored and when, the two termination paths, the effects of a
  `SUB_WORKFLOW`, `WAIT` and `JOIN` evaluation and the recovery check.
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay, only: [apply_commit: 2]

  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.{Env, SubWorkflow}

  @now 1_000_000

  defp env(opts \\ []) do
    counter = :counters.new(1, [])

    Env.new(
      Keyword.merge(
        [
          now: @now,
          new_id: fn ->
            :counters.add(counter, 1, 1)
            "id-#{:counters.get(counter, 1)}"
          end
        ],
        opts
      )
    )
  end

  defp run(workflow, event, env \\ env()) do
    {reply, stored, pre, commit, post} = Step.run(workflow, event, env)
    assert apply_commit(workflow, commit) == stored
    {reply, stored, pre, post}
  end

  defp system_def(name), do: %TaskDef{name: name, retry_count: 0, response_timeout_seconds: 0}

  defp simple(ref, fields \\ []),
    do:
      struct!(
        %WorkflowTask{
          name: ref,
          task_reference_name: ref,
          type: "SIMPLE",
          task_definition: %TaskDef{name: ref, retry_count: 0}
        },
        fields
      )

  defp system(type, ref, fields),
    do:
      struct!(
        %WorkflowTask{
          name: ref,
          task_reference_name: ref,
          type: type,
          task_definition: system_def(ref)
        },
        fields
      )

  defp new_workflow(tasks, fields \\ []) do
    struct!(
      %Workflow{
        workflow_id: "wf",
        workflow_definition: %WorkflowDef{name: "wf", version: 1, schema_version: 2, tasks: tasks}
      },
      fields
    )
  end

  defp start(tasks, fields \\ [], env \\ env()) do
    {{:ok, "wf"}, stored, [], post} = run(nil, {:start, new_workflow(tasks, fields)}, env)
    {stored, post}
  end

  defp task(workflow, ref), do: Enum.find(workflow.tasks, &(&1.reference_task_name == ref))

  describe "start" do
    test "creates the workflow with its first tasks in one commit and sets the timer" do
      {_reply, stored, [], commit, post} =
        Step.run(nil, {:start, new_workflow([simple("a")])}, env())

      assert commit.create == stored
      assert %Workflow{status: :running, create_time: @now, update_time: @now} = stored
      assert [%Task{reference_task_name: "a", seq: 1, first_scheduled_time: @now}] = stored.tasks
      assert [{:queue_push, "a", _id, 0, 0}, {:wake_at, wake}] = post
      assert wake == @now + 30_000
    end

    test "an existing workflow is a conflict" do
      {stored, _post} = start([simple("a")])

      assert {{:error, :conflict}, ^stored, [], []} =
               run(stored, {:start, new_workflow([simple("a")])})
    end

    # testStartWorkflowIdempotentReturnsExistingWorkflowModel and
    # testStartWorkflowIdempotentRejectsExistingWorkflowOwnedByDifferentParentTask
    test "an idempotent start creates without deciding, or answers with the owned workflow" do
      child = new_workflow([simple("a")], parent_workflow_id: "p", parent_workflow_task_id: "t")

      {{:ok, created}, stored, [], []} = run(nil, {:start_idempotent, child})
      assert created == stored
      assert stored.tasks == []

      assert {{:ok, ^stored}, ^stored, [], []} = run(stored, {:start_idempotent, child})

      other = %{child | parent_workflow_task_id: "t2"}

      assert {{:error,
               "Workflow id wf already belongs to parent workflow p task t, cannot attach to " <>
                 "parent workflow p task t2"}, ^stored, [], []} =
               run(stored, {:start_idempotent, other})
    end
  end

  describe "decide loop" do
    # A DO_WHILE whose body is one SWITCH: every iteration starts and executes a synchronous
    # system task, so the loop goes on in the same step, as upstream's mocked Decider does.
    defp switch_loop(iterations) do
      switch =
        system("SWITCH", "sw",
          evaluator_type: "value-param",
          expression: "x",
          input_parameters: %{"x" => "a"}
        )

      loop = system("DO_WHILE", "loop", loop_over: [switch], loop_condition: "condition")

      evaluate = fn :eval, "condition", input ->
        {:ok, input["loop"]["iteration"] < iterations}
      end

      {[loop], evaluate}
    end

    # testDecideLoopManyIterationsNoStackOverflow
    test "hundreds of iterations finish in one step" do
      {tasks, evaluate} = switch_loop(500)
      env = env(evaluate_script: evaluate, max_decide_iterations: 2_000)
      {stored, post} = start(tasks, [], env)

      assert stored.status == :completed
      assert %Task{iteration: 500, status: :completed} = hd(stored.tasks)
      assert length(stored.tasks) == 501
      assert post == []
    end

    # testDecideLoopRequeuesWhenApproachingLockLeaseTime: the iteration limit saves the workflow
    # and asks for a :wake at once instead.
    test "the iteration limit saves the progress and wakes the workflow at once" do
      {tasks, evaluate} = switch_loop(500)
      env = env(evaluate_script: evaluate, max_decide_iterations: 10)
      {stored, post} = start(tasks, [], env)

      assert %Workflow{status: :running, update_time: @now} = stored
      assert %Task{status: :in_progress, iteration: 5} = hd(stored.tasks)
      assert List.last(post) == {:wake_at, @now}

      {:ok, stored, [], post} = run(stored, :wake, env)
      assert %Task{iteration: 10} = hd(stored.tasks)
      assert List.last(post) == {:wake_at, @now}
    end

    test "completion stores the status and output but not the Decider's executed markings" do
      {stored, _post} = start([simple("a")])
      a = task(stored, "a")
      stored = %{stored | tasks: [%{a | status: :completed, output_data: %{"x" => 1}}]}

      {:ok, stored, [], post} = run(stored, :wake)

      assert %Workflow{
               status: :completed,
               previous_status: :running,
               end_time: @now,
               output: %{"x" => 1}
             } = stored

      assert [%Task{executed: false}] = stored.tasks
      assert post == []
    end
  end

  describe "termination by request" do
    # testTerminateCompletedWorkflow and testTerminateAlreadyTerminatedWorkflow
    test "a COMPLETED workflow is a conflict and a TERMINATED one stays" do
      completed = new_workflow([], status: :completed)
      assert {{:error, :conflict}, ^completed, [], []} = run(completed, {:terminate, "r"})

      terminated = new_workflow([], status: :terminated)
      assert {:ok, ^terminated, [], []} = run(terminated, {:terminate, "r"})
    end

    # testCancelNonTerminalTasks: the running SUB_WORKFLOW and the scheduled task are canceled,
    # the child is terminated before the commit and the queues are cleaned up after it.
    test "cancels the remaining tasks and terminates children before the commit" do
      wf =
        new_workflow([],
          status: :failed,
          parent_workflow_id: "parent",
          parent_workflow_task_id: "ptask",
          tasks: [
            %Task{
              task_id: "sub",
              task_type: "SUB_WORKFLOW",
              status: :in_progress,
              sub_workflow_id: "child"
            },
            %Task{task_id: "lambda", task_type: "LAMBDA", status: :scheduled},
            %Task{
              task_id: "simple",
              task_type: "SIMPLE",
              status: :failed,
              reference_task_name: "s"
            }
          ]
        )

      assert {:ok, stored, pre, post} = run(wf, {:terminate, "stop"})

      assert %Workflow{
               status: :terminated,
               previous_status: :failed,
               reason_for_incompletion: "stop",
               failed_reference_task_names: ["s"],
               failed_task_names: ["SIMPLE"],
               failed_task_id: nil,
               end_time: @now
             } = stored

      assert Enum.map(stored.tasks, & &1.status) == [:canceled, :canceled, :failed]

      assert pre == [
               {:terminate_sub_workflow, "child",
                "Parent workflow has been terminated with reason: stop"}
             ]

      assert [
               {:queue_remove, "LAMBDA", "lambda"},
               {:queue_remove, "SIMPLE", "simple"},
               {:notify_parent, "parent", "ptask", ^stored}
             ] = post
    end
  end

  describe "termination by the Decider" do
    defp failing_workflow(fields) do
      {stored, _post} = start([simple("a")], fields)
      a = task(stored, "a")
      %{stored | tasks: [%{a | status: :failed, reason_for_incompletion: "boom"}]}
    end

    # testTerminateWorkflowWithFailureWorkflow: failedTaskId, the failure workflow ID in the output
    # and its start after the commit.
    test "records the failed task and starts the failure workflow" do
      wf =
        failing_workflow(input: %{"x" => 1})
        |> put_in(
          [Access.key!(:workflow_definition), Access.key!(:failure_workflow)],
          "on_failure"
        )

      {:ok, stored, [], post} = run(wf, :wake)
      a = task(stored, "a")

      assert %Workflow{status: :failed, failed_task_id: failed_id, failed_task_names: ["a"]} =
               stored

      assert failed_id == a.task_id
      assert stored.output["conductor.failure_workflow"] == "id-1"
      assert stored.reason_for_incompletion =~ "boom"

      assert [{:queue_remove, "a", _id}, {:start_failure_workflow, start}] = post
      assert %{workflow_id: "id-1", name: "on_failure", triggering_workflow_id: "wf"} = start

      assert %{
               "x" => 1,
               "workflowId" => "wf",
               "failureStatus" => "FAILED",
               "failureTaskId" => ^failed_id,
               "failedWorkflow" => %{"workflowId" => "wf"}
             } = start.input

      # A start lost before it ran is started again by the recovery with the same input.
      {:ok, ^stored, [], [{:start_failure_workflow, ^start}]} =
        run(stored, :recover, env(workflows: %{"id-1" => nil}))

      {:ok, stored, [], []} =
        run(stored, {:failure_workflow_started, {:error, "no such workflow"}})

      assert stored.output["conductor.failure_workflow"] ==
               "Error workflow on_failure failed to start.  reason: no such workflow"

      # A terminal workflow the Decider did not end keeps the output its tasks gave: a worker's
      # `conductor.failure_workflow` there is not a start to recover.
      for {status, fields} <- [
            completed: [],
            terminated: [failed_task_id: nil],
            terminated: [previous_status: :failed]
          ] do
        forged =
          struct!(
            %{stored | status: status, output: %{"conductor.failure_workflow" => "x"}},
            fields
          )

        assert {:ok, ^forged, [], []} = run(forged, :recover, env(workflows: %{"x" => nil}))
      end

      # The error message is not an ID to start again.
      message = stored.output["conductor.failure_workflow"]
      assert {:ok, ^stored, [], []} = run(stored, :recover, env(workflows: %{message => nil}))
    end

    # terminate(): the name after the second `.` is the input key, so the braces of
    # `${workflow.input.handler}` stay in it, as upstream reads it.
    test "a $ failure workflow name is read from the input" do
      failure = fn name ->
        wf =
          failing_workflow(input: %{"handler" => "from_input"})
          |> put_in([Access.key!(:workflow_definition), Access.key!(:failure_workflow)], name)

        {:ok, _stored, [], post} = run(wf, :wake)
        for {:start_failure_workflow, start} <- post, do: start.name
      end

      assert failure.("$workflow.input.handler") == ["from_input"]
      assert failure.("${workflow.input.handler}") == []
    end

    test "a TERMINATE task with terminationStatus FAILED terminates with its reason" do
      terminate =
        system("TERMINATE", "end", input_parameters: %{"terminationStatus" => "FAILED"})

      {stored, _post} = start([terminate])
      [%Task{task_id: id}] = stored.tasks

      {:ok, stored, [], _post} =
        run(%{stored | tasks: [%{hd(stored.tasks) | status: :completed}]}, :wake)

      assert {stored.status, stored.reason_for_incompletion, stored.failed_task_id} ==
               {:failed, "Workflow is FAILED by TERMINATE task: #{id}", id}
    end
  end

  test "a parent's cancel terminates even a COMPLETED child, once" do
    child = new_workflow([], status: :completed, tasks: [])

    {:ok, stored, [], []} =
      run(child, {:cancel_by_parent, "Parent workflow has been terminated with status FAILED"})

    assert {stored.status, stored.previous_status} == {:terminated, :completed}
    assert {:ok, ^stored, [], []} = run(stored, {:cancel_by_parent, "again"})
  end

  describe "retry" do
    # DeciderService#retry gives the new attempt scheduledTime 0 and the retry delay as
    # callbackAfterMs; createTasks stamps scheduledTime and addTaskToQueue queues with the delay.
    test "a retried worker task is queued with its delay and keeps its poll window" do
      a =
        simple("a",
          task_definition: %TaskDef{
            name: "a",
            retry_count: 1,
            retry_delay_seconds: 5,
            poll_timeout_seconds: 60
          }
        )

      {stored, _post} = start([a])
      failed = %{task(stored, "a") | status: :failed}
      later = env(now: @now + 1_000, jitter: fn _max -> 0 end, new_id: fn -> "retried" end)
      {:ok, stored, [], post} = run(%{stored | tasks: [failed]}, :wake, later)

      assert [_failed, %Task{status: :scheduled, retry_count: 1} = retried] = stored.tasks
      assert retried.scheduled_time == @now + 1_000
      assert {:queue_push, "a", retried.task_id, 0, 5_000} in post
      assert List.last(post) == {:wake_at, @now + 1_000 + 61_000}

      {:ok, stored, [], _post} = run(stored, :wake, env(now: @now + 2_000))
      assert %Workflow{status: :running} = stored
    end

    # Wait#start: a retried WAIT is SCHEDULED and starts IN_PROGRESS once its retry delay is
    # over; from then on its evaluation offset decides when it is looked at again.
    test "a retried WAIT starts again after its retry delay and completes" do
      wait =
        system("WAIT", "wait",
          input_parameters: %{"duration" => "10 seconds"},
          task_definition: %TaskDef{name: "wait", retry_count: 1, retry_delay_seconds: 60}
        )

      {stored, _post} = start([wait])
      failed = %{hd(stored.tasks) | status: :failed}
      retry_env = env(now: @now + 1_000, jitter: fn _max -> 0 end, new_id: fn -> "retried" end)
      {:ok, stored, [], _post} = run(%{stored | tasks: [failed]}, :wake, retry_env)
      assert [_failed, %Task{status: :scheduled, callback_after_ms: 60_000}] = stored.tasks

      {:ok, stored, [], _post} = run(stored, :wake, env(now: @now + 61_000))

      # The copy keeps the original waitTimeout, already past: a negative offset, due at once.
      assert [_failed, %Task{status: :in_progress, poll_count: 1, callback_after_ms: 0} = retried] =
               stored.tasks

      assert retried.callback_after_seconds < 0
      {:ok, stored, [], []} = run(stored, :wake, env(now: @now + 62_000))

      assert [_failed, %Task{status: :completed}] = stored.tasks
      assert stored.status == :completed
    end
  end

  describe "JOIN and WAIT" do
    test "a WAIT is evaluated on :wake and its timeout sets the next one" do
      wait = system("WAIT", "wait", input_parameters: %{"duration" => "10 seconds"})
      {stored, post} = start([wait])

      assert [%Task{task_type: "WAIT", status: :in_progress, wait_timeout: deadline}] =
               stored.tasks

      assert List.last(post) == {:wake_at, deadline}

      # Upstream queues the WAIT with its duration as the delay, so an earlier :wake leaves it.
      {:ok, ^stored, [], [{:wake_at, ^deadline}]} =
        run(stored, :wake, env(now: deadline - 4_500))

      # Wait#getEvaluationOffset: no time left rounds up to 1 s.
      {:ok, stored, [], post} = run(stored, :wake, env(now: deadline))

      assert [%Task{status: :in_progress, poll_count: 1, callback_after_seconds: 1}] =
               stored.tasks

      assert List.last(post) == {:wake_at, deadline + 1_000}

      {:ok, stored, [], []} = run(stored, :wake, env(now: deadline + 1_000))
      assert [%Task{status: :completed, poll_count: 2, end_time: end_time}] = stored.tasks
      assert end_time == deadline + 1_000
      assert stored.status == :completed
    end

    test "a SCHEDULED JOIN with a delay is not evaluated before the delay is over" do
      join = system("JOIN", "join", join_on: ["a"])
      fork = system("FORK_JOIN", "fork", fork_tasks: [[simple("a")]])
      {stored, _post} = start([fork, join])

      delayed = %{
        task(stored, "join")
        | status: :scheduled,
          callback_after_seconds: 10,
          poll_count: 0,
          update_time: 0
      }

      a = %{task(stored, "a") | status: :in_progress}

      stored = %{
        stored
        | tasks:
            Enum.map(
              stored.tasks,
              &(%{"join" => delayed, "a" => a}[&1.reference_task_name] || &1)
            )
      }

      result = %Archon.Domain.TaskResult{
        workflow_instance_id: "wf",
        task_id: a.task_id,
        status: :completed
      }

      {%Task{status: :completed}, stored, [], _post} = run(stored, {:update, result})
      assert %Task{status: :scheduled, poll_count: 0} = task(stored, "join")
    end

    test "a JOIN in a terminated workflow is canceled" do
      join = system("JOIN", "join", join_on: ["a"])
      fork = system("FORK_JOIN", "fork", fork_tasks: [[simple("a")]])
      {stored, _post} = start([fork, join])
      assert %Task{status: :in_progress, poll_count: 1} = task(stored, "join")

      {:ok, stored, _pre, _post} = run(stored, {:terminate, nil})
      assert %Task{status: :canceled} = task(stored, "join")
    end
  end

  describe "SUB_WORKFLOW" do
    defp sub_workflow(fields \\ []) do
      system("SUB_WORKFLOW", "sub",
        sub_workflow_param:
          struct!(%Archon.Domain.SubWorkflowParams{name: "child", version: 2}, fields)
      )
    end

    test "starts the child with the deterministic ID and attaches to it" do
      {stored, post} =
        start([sub_workflow()], correlation_id: "c1", task_to_domain: %{"*" => "d"})

      sub = task(stored, "sub")
      child_id = SubWorkflow.child_id("wf", sub)

      assert %Task{status: :scheduled, poll_count: 1, start_time: @now, update_time: @now} = sub

      assert [{:start_sub_workflow, task_id, start}, {:wake_at, _}] = post
      assert task_id == sub.task_id

      assert %{
               workflow_id: ^child_id,
               name: "child",
               version: 2,
               correlation_id: "c1",
               task_to_domain: %{"*" => "d"},
               parent_workflow_id: "wf",
               parent_workflow_task_id: ^task_id
             } = start

      child = %Workflow{workflow_id: child_id, status: :running}
      {:ok, stored, [], _post} = run(stored, {:sub_workflow_started, task_id, {:ok, child}})

      assert %Task{status: :in_progress, sub_workflow_id: ^child_id, output_data: output} =
               task(stored, "sub")

      assert output["subWorkflowId"] == child_id

      # A child the task is no longer attached to (a replaced one) changes nothing.
      stale = %Workflow{workflow_id: "stale", status: :failed}
      {:ok, ^stored, [], _post} = run(stored, {:child_changed, task_id, stale})

      done = %{child | status: :completed, output: %{"r" => 1}}
      {:ok, stored, [], []} = run(stored, {:child_changed, task_id, done})
      assert %Task{status: :completed, output_data: %{"r" => 1}} = task(stored, "sub")
      assert stored.status == :completed
    end

    test "matches upstream's deterministic child ID" do
      # IDGenerator#generateSubWorkflowId("parent-1", "task-1", 0 and 2), run on JDK 25.
      assert SubWorkflow.child_id("parent-1", %Task{task_id: "task-1", retry_count: 0}) ==
               "0a8c7eb9-1302-375f-bc46-b83e16feb205"

      assert SubWorkflow.child_id("parent-1", %Task{task_id: "task-1", retry_count: 2}) ==
               "cd45a945-3011-3849-99d1-91b47793554e"
    end

    test "a child that already failed is replaced by a new ID saved before its start" do
      {stored, [{:start_sub_workflow, task_id, start}, _wake]} = start([sub_workflow()])
      dead = %Workflow{workflow_id: start.workflow_id, status: :failed}

      {:ok, stored, [], post} = run(stored, {:sub_workflow_started, task_id, {:ok, dead}})
      assert %Task{status: :scheduled, sub_workflow_id: "id-1"} = task(stored, "sub")
      assert [{:start_sub_workflow, ^task_id, %{workflow_id: "id-1"}} | _] = post
    end

    test "a transient error keeps the task SCHEDULED to try again after 30 s" do
      {stored, [{:start_sub_workflow, task_id, _start}, _wake]} = start([sub_workflow()])

      {:ok, stored, [], post} =
        run(stored, {:sub_workflow_started, task_id, {:error, :transient, "busy"}})

      assert %Task{
               status: :scheduled,
               callback_after_seconds: 30,
               reason_for_incompletion: "Transient error starting sub workflow child: busy",
               output_data: %{"subWorkflowLaunchError" => "busy"}
             } = task(stored, "sub")

      assert post == []

      {:ok, _stored, [], post} = run(stored, :wake, env(now: @now + 30_000))
      assert [{:start_sub_workflow, ^task_id, _start} | _] = post
    end

    test "any other start error fails the task" do
      {stored, [{:start_sub_workflow, task_id, _start}, _wake]} = start([sub_workflow()])
      {:ok, stored, [], _post} = run(stored, {:sub_workflow_started, task_id, {:error, "bad"}})

      assert %Task{status: :failed, reason_for_incompletion: "bad", end_time: @now} =
               task(stored, "sub")

      assert stored.status == :failed
    end

    test "a start delay holds the start until it is over" do
      {stored, post} = start([sub_workflow() |> Map.put(:start_delay, 5)])
      assert %Task{status: :scheduled, poll_count: 0} = task(stored, "sub")
      assert post == [{:wake_at, @now + 5_000}]

      {:ok, _stored, [], post} = run(stored, :wake, env(now: @now + 5_000))
      assert [{:start_sub_workflow, _id, _start} | _] = post
    end
  end

  describe "recovery" do
    test "pushes SCHEDULED worker tasks without a message with what is left of their delay" do
      {stored, _post} = start([simple("a")])
      a = %{task(stored, "a") | update_time: @now - 2_000, callback_after_seconds: 5}
      stored = %{stored | tasks: [a]}

      {:ok, _stored, [], post} = run(stored, :recover)
      assert [{:queue_push, "a", id, 0, 3_000}, {:wake_at, _}] = post
      assert id == a.task_id

      {:ok, _stored, [], post} = run(stored, :recover, env(queued: MapSet.new([a.task_id])))
      assert [{:wake_at, _}] = post
    end

    # The sweeper repairs after deciding: a task the decide times out is not queued again, and the
    # retry it schedules is queued once.
    test "repairs the queues after the decide" do
      a =
        simple("a",
          task_definition: %TaskDef{
            name: "a",
            retry_count: 1,
            retry_delay_seconds: 0,
            poll_timeout_seconds: 1,
            timeout_policy: :retry
          }
        )

      {stored, _post} = start([a])
      old = task(stored, "a")
      later = env(now: @now + 10_000, new_id: fn -> "retried" end)
      {:ok, stored, [], post} = run(stored, :recover, later)

      assert [%Task{status: :timed_out}, %Task{task_id: "retried", status: :scheduled}] =
               stored.tasks

      pushed = for {:queue_push, _queue, id, _priority, _delay} <- post, do: id
      assert pushed == ["retried"]
      refute old.task_id in pushed
    end

    test "a child whose parent ended and canceled its task terminates itself" do
      {stored, _post} =
        start([simple("a")], parent_workflow_id: "p", parent_workflow_task_id: "pt")

      parent = %Workflow{
        workflow_id: "p",
        status: :terminated,
        reason_for_incompletion: "manual",
        tasks: [%Task{task_id: "pt", status: :canceled}]
      }

      {:ok, stored, [], _post} = run(stored, :recover, env(workflows: %{"p" => parent}))

      assert {stored.status, stored.reason_for_incompletion} ==
               {:terminated, "Parent workflow has been terminated with reason: manual"}

      {stored, _post} = start([simple("a")], parent_workflow_id: "gone")
      {:ok, stored, [], _post} = run(stored, :recover, env(workflows: %{"gone" => nil}))
      assert stored.status == :terminated
    end

    test "a terminal workflow terminates children left running and restarts a lost failure workflow" do
      wf =
        new_workflow([],
          status: :failed,
          output: %{"conductor.failure_workflow" => "fw"},
          tasks: [
            %Task{
              task_id: "s",
              task_type: "SUB_WORKFLOW",
              status: :canceled,
              sub_workflow_id: "c"
            }
          ]
        )
        |> put_in(
          [Access.key!(:workflow_definition), Access.key!(:failure_workflow)],
          "on_failure"
        )

      workflows = %{"c" => %Workflow{workflow_id: "c", status: :running}, "fw" => nil}
      {:ok, ^wf, [], post} = run(wf, :recover, env(workflows: workflows))

      assert [
               {:terminate_sub_workflow, "c",
                "Parent workflow has been terminated with status FAILED"},
               {:start_failure_workflow, %{workflow_id: "fw", name: "on_failure"}}
             ] = post
    end
  end
end
