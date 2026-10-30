# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Scenarios derived from conductor-oss test-harness/src/test/groovy/com/netflix/conductor/test/integration/
# RetryPolicySpec.groovy, SubWorkflowRetrySpec.groovy, SubWorkflowRestartSpec.groovy,
# HierarchicalForkJoinSubworkflowRetrySpec.groovy and HierarchicalForkJoinSubworkflowRestartSpec.groovy
# with their resource definitions, and from
# core/src/test/java/com/netflix/conductor/core/execution/TestWorkflowExecutor.java (the retry,
# restart, pause and resume cases) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the workflows run as processes, so there is no system task executor or
# sweep to call, and the parents revive by a message shortly after the retry or restart
# answered. The TestWorkflowExecutor cases reach their states through workers instead of mocks.

defmodule Archon.Runtime.LifecycleTest do
  @moduledoc """
  `Archon.Runtime.Lifecycle` and `Archon.Runtime.Step.Lifecycle` (ADR 0018, decision 9, slice
  3f): pause, resume, retry and restart, the parents that revive with a child
  (`updateAndPushParents`) and `adjustStateIfSubWorkflowChanged`.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{Task, TaskDef, TaskResult, Workflow, WorkflowDef}
  alias Archon.Runtime.Lifecycle
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.Env

  # simple_workflow_1_integration_test.json
  @simple_workflow ~S"""
  {"name": "integration_test_wf", "version": 1, "tasks": [
    {"name": "integration_task_1", "taskReferenceName": "t1", "type": "SIMPLE",
     "inputParameters": {"p1": "${workflow.input.param1}", "p2": "${workflow.input.param2}",
                         "p3": "${CPEWF_TASK_ID}", "someNullKey": null}},
    {"name": "integration_task_2", "taskReferenceName": "t2", "type": "SIMPLE",
     "inputParameters": {"tp1": "${workflow.input.param1}", "tp2": "${t1.output.op}",
                         "tp3": "${CPEWF_TASK_ID}"}}],
   "inputParameters": ["param1", "param2"],
   "outputParameters": {"o1": "${workflow.input.param1}", "o2": "${t2.output.uuid}",
                        "o3": "${t1.output.op}"},
   "failureWorkflow": "$workflow.input.failureWfName"}
  """

  # workflow_with_sub_workflow_1_integration_test.json
  @workflow_with_sub_workflow ~S"""
  {"name": "integration_test_wf_with_sub_wf", "version": 1, "tasks": [
    {"name": "integration_task_1", "taskReferenceName": "t1", "type": "SIMPLE",
     "inputParameters": {"p1": "${workflow.input.param1}", "p2": "${workflow.input.param2}",
                         "someNullKey": null}},
    {"name": "sub_workflow_task", "taskReferenceName": "t2", "type": "SUB_WORKFLOW",
     "inputParameters": {"param1": "${workflow.input.param1}",
                         "param2": "${workflow.input.param2}",
                         "subwf": "${workflow.input.nextSubwf}"},
     "subWorkflowParam": {"name": "${workflow.input.subwf}", "version": 1},
     "retryCount": 0}],
   "inputParameters": ["param1", "param2"],
   "failureWorkflow": "$workflow.input.failureWfName"}
  """

  # hierarchical_fork_join_swf.json
  @hierarchical ~S"""
  {"name": "hierarchical_fork_join_swf", "version": 1, "tasks": [
    {"name": "fork", "taskReferenceName": "fanouttask", "type": "FORK_JOIN",
     "inputParameters": {"param1": "${workflow.input.param1}",
                         "param2": "${workflow.input.param2}",
                         "subwf": "${workflow.input.nextSubwf}"},
     "forkTasks": [
      [{"name": "sub_workflow_task", "taskReferenceName": "st1", "type": "SUB_WORKFLOW",
        "inputParameters": {"param1": "${workflow.input.param1}",
                            "param2": "${workflow.input.param2}",
                            "subwf": "${workflow.input.nextSubwf}"},
        "subWorkflowParam": {"name": "${workflow.input.subwf}", "version": 1},
        "retryCount": 0}],
      [{"name": "integration_task_2", "taskReferenceName": "t2", "type": "SIMPLE",
        "inputParameters": {"p1": "${workflow.input.param1}", "p2": "${workflow.input.param2}"},
        "retryCount": 0}]]},
    {"name": "join", "taskReferenceName": "fanouttask_join", "type": "JOIN",
     "inputParameters": {}, "joinOn": ["st1", "t2"]}],
   "inputParameters": ["param1", "param2", "subwf"],
   "restartable": true, "timeoutPolicy": "ALERT_ONLY", "timeoutSeconds": 0}
  """

  # RetryPolicySpec: one SIMPLE task.
  @retry_policy ~S"""
  {"name": "retry_policy_wf", "version": 1, "tasks": [
    {"name": "retry_policy_task", "taskReferenceName": "retry_task_ref", "type": "SIMPLE"}],
   "timeoutSeconds": 3600, "timeoutPolicy": "ALERT_ONLY"}
  """

  # Two children side by side (the siblings of updateAndPushParents).
  @two_children ~S"""
  {"name": "lifecycle_two_children", "version": 1, "tasks": [
    {"name": "fork", "taskReferenceName": "fork", "type": "FORK_JOIN", "inputParameters": {},
     "forkTasks": [
      [{"name": "sub_workflow_task", "taskReferenceName": "st1", "type": "SUB_WORKFLOW",
        "inputParameters": {}, "subWorkflowParam": {"name": "integration_test_wf", "version": 1}}],
      [{"name": "sub_workflow_task", "taskReferenceName": "st2", "type": "SUB_WORKFLOW",
        "inputParameters": {}, "subWorkflowParam": {"name": "integration_test_wf", "version": 1}}]]},
    {"name": "join", "taskReferenceName": "join", "type": "JOIN", "inputParameters": {},
     "joinOn": ["st1", "st2"]}]}
  """

  # TestWorkflowExecutor#testRestartOptionalSubWorkflow: an optional child.
  @optional_child ~S"""
  {"name": "lifecycle_optional_child", "version": 1, "tasks": [
    {"name": "sub_workflow_task", "taskReferenceName": "st", "type": "SUB_WORKFLOW",
     "inputParameters": {}, "optional": true,
     "subWorkflowParam": {"name": "integration_test_wf", "version": 1}}]}
  """

  setup do
    # The specs set integration_task_2 to 0 retries.
    for name <- ["integration_task_1", "integration_task_2"],
        do: :ok = Runtime.metadata().update_task_def(%TaskDef{name: name, retry_count: 0})

    for json <- [
          @simple_workflow,
          @workflow_with_sub_workflow,
          @hierarchical,
          @retry_policy,
          @two_children,
          @optional_child
        ],
        do: define(json)

    :ok
  end

  ## Helpers

  defp define(json, change \\ & &1) do
    {:ok, definition} = json |> Jason.decode!() |> WorkflowDef.from_json()
    :ok = Runtime.metadata().update_workflow_def(change.(definition))
    definition
  end

  defp start(name, input, fields \\ []) do
    {:ok, id} = Runtime.start_workflow(Map.merge(%{name: name, input: input}, Map.new(fields)))
    id
  end

  defp workflow(id) do
    {:ok, workflow} = Runtime.get_workflow(id)
    workflow
  end

  defp statuses(%Workflow{tasks: tasks}), do: Enum.map(tasks, &{&1.task_type, &1.status})

  # The last instance of the task with the reference name.
  defp last(id, ref) do
    id
    |> workflow()
    |> Map.fetch!(:tasks)
    |> Enum.filter(&(&1.reference_task_name == ref))
    |> List.last()
  end

  defp poll(id, ref) do
    task =
      eventually(fn ->
        match?({:ok, _}, Runtime.get_workflow(id)) and
          match?(%Task{status: :scheduled}, last(id, ref)) and last(id, ref)
      end)

    assert %Task{status: :in_progress} = WorkflowServer.poll(id, task.task_id, "worker")
    task
  end

  defp complete(id, ref, output \\ %{"op" => "task1.done"}) do
    task = poll(id, ref)

    assert %Task{status: :completed} =
             WorkflowServer.update(%TaskResult{
               workflow_instance_id: id,
               task_id: task.task_id,
               status: :completed,
               output_data: output
             })
  end

  defp fail(id, ref, reason \\ "failed") do
    task = poll(id, ref)

    assert %Task{status: :failed} =
             WorkflowServer.update(%TaskResult{
               workflow_instance_id: id,
               task_id: task.task_id,
               status: :failed,
               reason_for_incompletion: reason
             })
  end

  defp await_statuses(id, expected),
    do: eventually(fn -> statuses(workflow(id)) == expected and workflow(id) end)

  defp await_status(id, status),
    do: eventually(fn -> match?(%Workflow{status: ^status}, workflow(id)) and workflow(id) end)

  defp child_of(id, ref), do: eventually(fn -> last(id, ref).sub_workflow_id end)

  @input %{"param1" => "p1 value", "param2" => "p2 value"}

  # The setup of SubWorkflowRetrySpec and SubWorkflowRestartSpec: three workflows FAILED because
  # integration_task_2 FAILED in the leaf.
  defp three_levels do
    input =
      Map.merge(@input, %{
        "subwf" => "integration_test_wf_with_sub_wf",
        "nextSubwf" => "integration_test_wf"
      })

    root =
      start("integration_test_wf_with_sub_wf", input,
        correlation_id: "retry_on_root_in_3level_wf"
      )

    assert [{"integration_task_1", :scheduled}] = statuses(workflow(root))

    complete(root, "t1")

    assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :in_progress}] =
             statuses(workflow(root))

    mid = child_of(root, "t2")

    await_statuses(mid, [{"integration_task_1", :scheduled}])
    complete(mid, "t1")
    leaf = child_of(mid, "t2")

    await_statuses(leaf, [{"integration_task_1", :scheduled}])
    complete(leaf, "t1")
    fail(leaf, "t2")

    leaf_wf = await_status(leaf, :failed)

    assert [{"integration_task_1", :completed}, {"integration_task_2", :failed}] =
             statuses(leaf_wf)

    for id <- [mid, root] do
      wf = await_status(id, :failed)
      assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :failed}] = statuses(wf)
    end

    {root, mid, leaf}
  end

  # The setup of the HierarchicalForkJoinSubworkflow specs.
  defp hierarchical_three_levels do
    input =
      Map.merge(@input, %{
        "subwf" => "hierarchical_fork_join_swf",
        "nextSubwf" => "integration_test_wf"
      })

    root =
      start("hierarchical_fork_join_swf", input, correlation_id: "retry_on_root_in_3level_wf")

    await_statuses(root, [
      {"FORK", :completed},
      {"SUB_WORKFLOW", :in_progress},
      {"integration_task_2", :scheduled},
      {"JOIN", :in_progress}
    ])

    complete(root, "t2", %{"op" => "task2.done"})
    mid = child_of(root, "st1")

    await_statuses(mid, [
      {"FORK", :completed},
      {"SUB_WORKFLOW", :in_progress},
      {"integration_task_2", :scheduled},
      {"JOIN", :in_progress}
    ])

    complete(mid, "t2", %{"op" => "task2.done"})
    leaf = child_of(mid, "st1")

    await_statuses(leaf, [{"integration_task_1", :scheduled}])
    complete(leaf, "t1")
    fail(leaf, "t2")

    await_status(leaf, :failed)

    for id <- [mid, root] do
      wf = await_status(id, :failed)

      assert [
               {"FORK", :completed},
               {"SUB_WORKFLOW", :failed},
               {"integration_task_2", :completed},
               {"JOIN", :canceled}
             ] = statuses(wf)
    end

    {root, mid, leaf}
  end

  @fork_running [
    {"FORK", :completed},
    {"SUB_WORKFLOW", :in_progress},
    {"integration_task_2", :completed},
    {"JOIN", :in_progress}
  ]

  @fork_completed [
    {"FORK", :completed},
    {"SUB_WORKFLOW", :completed},
    {"integration_task_2", :completed},
    {"JOIN", :completed}
  ]

  # The leaf retried in place: its failed task and the new instance.
  defp assert_leaf_retried(leaf, status_of_new) do
    wf = workflow(leaf)
    assert wf.status == :running or status_of_new == :completed

    assert [
             {"integration_task_1", :completed},
             {"integration_task_2", :failed},
             {"integration_task_2", ^status_of_new}
           ] = statuses(wf)

    [_t1, failed, new] = wf.tasks
    assert failed.retried
    assert new.retried_task_id == failed.task_id
  end

  # A SUB_WORKFLOW task retried with a new instance: the failed one and the new one.
  defp assert_retried_pair(%Workflow{tasks: tasks}, ref) do
    [failed, new] = Enum.filter(tasks, &(&1.reference_task_name == ref))
    assert failed.status == :failed and failed.retried
    assert new.retried_task_id == failed.task_id
    new
  end

  # Completes a fresh leaf (integration_test_wf).
  defp complete_leaf(leaf) do
    await_statuses(leaf, [{"integration_task_1", :scheduled}])
    complete(leaf, "t1")
    complete(leaf, "t2", %{"op" => "task2.done"})
    await_status(leaf, :completed)
  end

  ## Pause and resume

  describe "pause and resume (TestWorkflowExecutor#testPauseWorkflow, #testResumeWorkflow)" do
    test "a terminal workflow cannot be paused; a paused one stays paused" do
      id = start("integration_test_wf", @input)
      complete(id, "t1")
      complete(id, "t2", %{"uuid" => "u"})
      await_status(id, :completed)

      assert {:error, {:conflict, message}} = Lifecycle.pause(id)

      assert message ==
               "Workflow integration_test_wf.1/#{id} has ended, status cannot be updated."

      assert workflow(id).status == :completed

      running = start("integration_test_wf", @input)
      assert :ok = Lifecycle.pause(running)
      paused = workflow(running)
      assert paused.status == :paused
      assert paused.previous_status == :running

      # pausing again changes nothing
      assert :ok = Lifecycle.pause(running)
      assert workflow(running).update_time == paused.update_time
    end

    test "a paused workflow has no :wake timer and does not move on until it is resumed" do
      id = start("integration_test_wf", @input)
      pid = WorkflowServer.whereis(id)
      assert %{message: :wake} = :sys.get_state(pid).timer

      assert :ok = Lifecycle.pause(id)
      assert :sys.get_state(pid).timer == nil

      # a worker still polls and completes the task (upstream poll does not look at the
      # workflow), but the decide of a paused workflow schedules nothing
      complete(id, "t1")
      paused = workflow(id)
      assert paused.status == :paused
      assert [{"integration_task_1", :completed}] = statuses(paused)
      assert :sys.get_state(pid).timer == nil

      assert :ok = Lifecycle.resume(id)
      resumed = workflow(id)
      assert resumed.status == :running
      assert resumed.previous_status == :paused
      assert resumed.last_retried_time > 0

      assert [{"integration_task_1", :completed}, {"integration_task_2", :scheduled}] =
               statuses(resumed)

      assert %{message: :wake} = :sys.get_state(pid).timer
    end

    test "resuming a running workflow does nothing; one that is not paused is an invalid state" do
      id = start("integration_test_wf", @input)
      before = workflow(id)
      assert :ok = Lifecycle.resume(id)
      assert workflow(id).update_time == before.update_time

      assert :ok = Runtime.terminate_workflow(id, "done")

      assert Lifecycle.resume(id) ==
               {:error,
                {:invalid_state,
                 "The workflow #{id} is not PAUSED so cannot resume. Current status is TERMINATED"}}
    end

    test "a workflow the store does not have is not found" do
      for operation <- [
            &Lifecycle.pause/1,
            &Lifecycle.resume/1,
            &Lifecycle.retry/1,
            &Lifecycle.restart/1
          ],
          do: assert(operation.("lifecycle-missing") == {:error, :not_found})

      assert Lifecycle.retry("lifecycle-missing", true) == {:error, :not_found}
      assert Lifecycle.restart("lifecycle-missing", true) == {:error, :not_found}
    end
  end

  ## Retry

  describe "retry (TestWorkflowExecutor)" do
    test "testRetryNonTerminalWorkflow: a running workflow is refused" do
      id = start("integration_test_wf", @input)

      assert Lifecycle.retry(id) ==
               {:error, {:not_found, "Workflow is still running.  status=RUNNING"}}

      assert Lifecycle.retry(id, true) ==
               {:error, {:not_found, "Workflow is still running.  status=RUNNING"}}
    end

    test "testRetryWorkflowNoTasks: a terminal workflow without tasks has not started" do
      wf = %Workflow{
        workflow_id: "no-tasks",
        status: :failed,
        tasks: [],
        workflow_definition: %WorkflowDef{name: "x", version: 1}
      }

      assert {{:error, {:conflict, "Workflow has not started yet"}}, ^wf, [], commit, []} =
               Step.run(wf, {:retry, true}, Env.new(now: 1000))

      assert commit == %Archon.Runtime.Commit{}
    end

    test "testRetryWorkflowNoFailedTasks: a task whose last instance completed is not retried" do
      failed = %Task{
        task_id: "a",
        seq: 1,
        retry_count: 0,
        task_type: "SIMPLE",
        status: :failed,
        task_def_name: "task1",
        reference_task_name: "task1_ref1"
      }

      completed = %{failed | task_id: "b", seq: 2, retry_count: 1, status: :completed}

      wf = %Workflow{
        workflow_id: "no-failed",
        status: :failed,
        tasks: [failed, completed],
        workflow_definition: %WorkflowDef{name: "x", version: 1}
      }

      assert {{:error, {:conflict, message}}, ^wf, [], _commit, []} =
               Step.run(wf, {:retry, true}, Env.new(now: 1000))

      assert message ==
               "There are no retryable tasks! Use restart if you want to attempt entire " <>
                 "workflow execution again."
    end

    test "testRetryWorkflowMultipleRetries: each retry adds one instance of the failed task" do
      id = start("integration_test_wf", @input)
      complete(id, "t1")

      for count <- 1..3 do
        fail(id, "t2")
        failed = await_status(id, :failed)
        assert length(failed.tasks) == count + 1

        assert :ok = Lifecycle.retry(id)
        retried = workflow(id)
        assert retried.status == :running
        assert retried.previous_status == :failed
        assert retried.reason_for_incompletion == nil
        assert retried.last_retried_time > 0
        assert length(retried.tasks) == count + 2

        new = last(id, "t2")
        assert new.status == :scheduled
        assert new.retry_count == count
        assert new.poll_count == 0
        assert new.seq == count + 2
        # the input is resolved again for the new task ID
        assert new.input_data["tp3"] == new.task_id
      end

      complete(id, "t2", %{"uuid" => "u-1"})
      assert %Workflow{output: %{"o2" => "u-1"}} = await_status(id, :completed)
    end

    test "testRetryWorkflowWithJoinTask: a canceled JOIN runs again in place" do
      root =
        start(
          "hierarchical_fork_join_swf",
          Map.merge(@input, %{"subwf" => "integration_test_wf"})
        )

      child = child_of(root, "st1")
      fail(root, "t2")

      failed = await_status(root, :failed)

      assert [
               {"FORK", :completed},
               {"SUB_WORKFLOW", :canceled},
               {"integration_task_2", :failed},
               {"JOIN", :canceled}
             ] = statuses(failed)

      join = last(root, "fanouttask_join")
      await_status(child, :terminated)

      assert :ok = Lifecycle.retry(root)
      retried = workflow(root)
      assert length(retried.tasks) == 6
      assert retried.previous_status == :failed
      assert retried.status == :running

      # upstream retry sets a canceled JOIN IN_PROGRESS without taskToBeRescheduled
      assert %Task{status: :in_progress, retry_count: 0} =
               new_join = last(root, "fanouttask_join")

      assert new_join.task_id == join.task_id

      # the canceled SUB_WORKFLOW task is retried with a new child
      new_sub = assert_retried_pair_status(retried, "st1", :canceled)
      assert new_sub.sub_workflow_id not in [nil, child]

      complete_leaf(new_sub.sub_workflow_id)
      complete(root, "t2", %{"op" => "task2.done"})
      assert await_status(root, :completed)
    end

    test "testRetryTimedOutWorkflowWithoutFailedTasks: a timed out workflow runs again" do
      t1 = %Task{
        task_id: "t1-id",
        seq: 1,
        task_type: "SIMPLE",
        status: :completed,
        executed: true,
        task_def_name: "task1",
        reference_task_name: "task1_ref1",
        workflow_instance_id: "timed-out"
      }

      definition =
        ~S"""
        {"name": "retry_timed_out", "version": 1, "tasks": [
          {"name": "task1", "taskReferenceName": "task1_ref1", "type": "SIMPLE"},
          {"name": "task2", "taskReferenceName": "task2_ref1", "type": "SIMPLE"},
          {"name": "task3", "taskReferenceName": "task3_ref1", "type": "SIMPLE"}]}
        """
        |> Jason.decode!()
        |> WorkflowDef.from_json()
        |> elem(1)

      t2 = %{
        t1
        | task_id: "t2-id",
          seq: 2,
          task_def_name: "task2",
          reference_task_name: "task2_ref1"
      }

      wf = %Workflow{
        workflow_id: "timed-out",
        status: :timed_out,
        end_time: 100,
        tasks: [t1, t2],
        workflow_definition: definition
      }

      {:ok, stored, [], commit, _post} = Step.run(wf, {:retry, true}, Env.new(now: 5000))
      assert stored.status == :running
      assert stored.previous_status == :timed_out
      assert stored.last_retried_time == 5000
      assert commit.workflow.status == :running
      assert length(commit.upsert_tasks) == 2
    end

    test "testRetryWorkflowClearsLegacySubWorkflowIdFromRetriedTask" do
      parent =
        start("integration_test_wf_with_sub_wf", Map.put(@input, "subwf", "integration_test_wf"))

      complete(parent, "t1")
      child = child_of(parent, "t2")
      complete(child, "t1")
      fail(child, "t2")
      await_status(parent, :failed)

      old = last(parent, "t2")
      assert old.sub_workflow_id == child
      assert old.output_data["subWorkflowId"] == child

      # the step alone: the new task is scheduled and its child not started yet
      {:ok, stored, _pre, _commit, post} =
        Step.run(
          workflow(parent),
          {:retry, true},
          WorkflowServer.env(workflow(parent), {:retry, true})
        )

      new = List.last(stored.tasks)
      assert new.reference_task_name == "t2"
      assert new.sub_workflow_id == nil
      refute Map.has_key?(new.input_data, "subWorkflowId")
      assert new.output_data == %{}
      assert new.external_output_payload_storage_path == nil

      assert Enum.any?(
               post,
               &match?({:start_sub_workflow, _task_id, %{workflow_id: id}} when id != child, &1)
             )
    end
  end

  defp assert_retried_pair_status(%Workflow{tasks: tasks}, ref, old_status) do
    [old, new] = Enum.filter(tasks, &(&1.reference_task_name == ref))
    assert old.status == old_status and old.retried
    assert new.retried_task_id == old.task_id
    new
  end

  ## Restart

  describe "restart (TestWorkflowExecutor)" do
    test "testRestartWorkflow: the tasks are deleted and the workflow starts over" do
      define(@simple_workflow, &%{&1 | name: "lifecycle_restart_wf"})
      id = start("lifecycle_restart_wf", @input)
      first = last(id, "t1")
      fail(id, "t1")
      failed = await_status(id, :failed)
      assert failed.end_time > 0

      assert :ok = Lifecycle.restart(id)
      restarted = workflow(id)
      assert restarted.status == :running
      assert restarted.previous_status == :failed
      assert restarted.end_time == 0
      assert restarted.last_retried_time == 0
      assert restarted.reason_for_incompletion == nil
      assert restarted.failed_task_id == nil
      assert restarted.output == %{}
      assert restarted.workflow_definition == failed.workflow_definition
      assert [%Task{reference_task_name: "t1", status: :scheduled} = t1] = restarted.tasks
      assert t1.task_id != first.task_id
      assert Runtime.store().get_task(first.task_id) == {:error, :not_found}

      complete(id, "t1")
      complete(id, "t2", %{"uuid" => "u"})
      await_status(id, :completed)

      # a new version of the definition, used with use_latest_definitions
      define(@simple_workflow, fn definition ->
        %{definition | name: "lifecycle_restart_wf", version: 2, restartable: true}
      end)

      assert :ok = Lifecycle.restart(id, true)
      latest = workflow(id)
      assert latest.status == :running
      assert latest.previous_status == :completed
      assert latest.workflow_definition.version == 2
      # the task definitions are embedded
      assert %Task{workflow_task: %{task_definition: %TaskDef{name: "integration_task_1"}}} =
               last(id, "t1")
    end

    test "a running workflow and a completed one that is not restartable are refused" do
      id = start("integration_test_wf", @input)

      assert {:error, {:conflict, message}} = Lifecycle.restart(id)

      assert message ==
               "Workflow: integration_test_wf.1/#{id}.RUNNING is not in terminal state, unable to restart."

      assert {:error, {:conflict, ^message}} = Lifecycle.restart(id, true)

      define(@simple_workflow, &%{&1 | name: "lifecycle_not_restartable", restartable: false})
      other = start("lifecycle_not_restartable", @input)
      complete(other, "t1")
      complete(other, "t2", %{"uuid" => "u"})
      await_status(other, :completed)

      assert Lifecycle.restart(other) ==
               {:error,
                {:not_found,
                 "Workflow: lifecycle_not_restartable.1/#{other}.COMPLETED is non-restartable"}}

      # a failed one may restart
      third = start("lifecycle_not_restartable", @input)
      fail(third, "t1")
      await_status(third, :failed)
      assert :ok = Lifecycle.restart(third)
    end

    test "restarting with the latest definition when there is none is not found" do
      # started with its definition inline, so the metadata has none of that name
      {:ok, definition} = @simple_workflow |> Jason.decode!() |> WorkflowDef.from_json()
      definition = %{definition | name: "lifecycle_latest_gone"}
      {:ok, id} = Runtime.start_workflow(%{definition: definition, input: @input})
      assert :ok = Runtime.terminate_workflow(id, "stop")

      assert Lifecycle.restart(id, true) ==
               {:error, {:not_found, "Unable to find latest definition for #{id}"}}
    end
  end

  ## SubWorkflowRetrySpec

  describe "SubWorkflowRetrySpec" do
    test "Test retry on the root in a 3-level subworkflow" do
      {root, mid, leaf} = three_levels()

      assert :ok = Lifecycle.retry(root)
      root_wf = workflow(root)
      assert root_wf.status == :running

      assert [
               {"integration_task_1", :completed},
               {"SUB_WORKFLOW", :failed},
               {"SUB_WORKFLOW", :in_progress}
             ] = statuses(root_wf)

      new_sub = assert_retried_pair(root_wf, "t2")

      new_mid = new_sub.sub_workflow_id
      assert new_mid != mid
      await_statuses(new_mid, [{"integration_task_1", :scheduled}])
      complete(new_mid, "t1")
      new_leaf = child_of(new_mid, "t2")
      assert new_leaf != leaf

      complete_leaf(new_leaf)

      mid_wf = await_status(new_mid, :completed)
      assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :completed}] = statuses(mid_wf)

      root_wf = await_status(root, :completed)

      assert [
               {"integration_task_1", :completed},
               {"SUB_WORKFLOW", :failed},
               {"SUB_WORKFLOW", :completed}
             ] = statuses(root_wf)

      assert_retried_pair(root_wf, "t2")

      # the old children are left as they were
      assert workflow(mid).status == :failed
      assert workflow(leaf).status == :failed
    end

    test "Test retry on the root with resume flag in a 3-level subworkflow" do
      {root, mid, leaf} = three_levels()

      assert :ok = Lifecycle.retry(root, true)
      assert_leaf_retried(leaf, :scheduled)

      for id <- [mid, root] do
        wf =
          await_statuses(id, [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :in_progress}])

        assert wf.status == :running
        # the flag is reset by the decide that follows
        refute last(id, "t2").subworkflow_changed
      end

      complete(leaf, "t2", %{"op" => "task1.done"})
      assert_leaf_retried(leaf, :completed)
      assert await_status(leaf, :completed)

      for id <- [mid, root] do
        wf = await_status(id, :completed)
        assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :completed}] = statuses(wf)
      end
    end

    test "Test retry on the mid-level in a 3-level subworkflow" do
      {root, mid, leaf} = three_levels()

      assert :ok = Lifecycle.retry(mid)
      mid_wf = workflow(mid)
      assert mid_wf.status == :running

      assert [
               {"integration_task_1", :completed},
               {"SUB_WORKFLOW", :failed},
               {"SUB_WORKFLOW", :in_progress}
             ] = statuses(mid_wf)

      new_sub = assert_retried_pair(mid_wf, "t2")

      root_wf =
        await_statuses(root, [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :in_progress}])

      assert root_wf.status == :running

      new_leaf = new_sub.sub_workflow_id
      assert new_leaf != leaf
      complete_leaf(new_leaf)

      mid_wf = await_status(mid, :completed)

      assert [
               {"integration_task_1", :completed},
               {"SUB_WORKFLOW", :failed},
               {"SUB_WORKFLOW", :completed}
             ] = statuses(mid_wf)

      root_wf = await_status(root, :completed)

      assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :completed}] =
               statuses(root_wf)
    end

    test "Test retry on the mid-level with resume flag in a 3-level subworkflow" do
      {root, mid, leaf} = three_levels()

      assert :ok = Lifecycle.retry(mid, true)
      assert_leaf_retried(leaf, :scheduled)

      for id <- [mid, root],
          do:
            await_statuses(id, [
              {"integration_task_1", :completed},
              {"SUB_WORKFLOW", :in_progress}
            ])

      complete(leaf, "t2")
      assert await_status(leaf, :completed)

      for id <- [mid, root] do
        wf = await_status(id, :completed)
        assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :completed}] = statuses(wf)
      end
    end

    test "Test retry on the leaf in a 3-level subworkflow" do
      {root, mid, leaf} = three_levels()

      assert :ok = Lifecycle.retry(leaf)
      assert_leaf_retried(leaf, :scheduled)
      assert workflow(leaf).status == :running

      for id <- [mid, root] do
        wf =
          await_statuses(id, [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :in_progress}])

        assert wf.status == :running
        assert wf.previous_status == :failed
        assert wf.failed_reference_task_names == []
        assert wf.last_retried_time > 0
      end

      complete(leaf, "t2")
      assert_leaf_retried(leaf, :completed)

      for id <- [mid, root] do
        wf = await_status(id, :completed)
        assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :completed}] = statuses(wf)
      end
    end

    test "Test retry on the leaf with resume flag in a 3-level subworkflow" do
      {root, mid, leaf} = three_levels()

      assert :ok = Lifecycle.retry(leaf, true)
      assert_leaf_retried(leaf, :scheduled)

      for id <- [mid, root],
          do:
            await_statuses(id, [
              {"integration_task_1", :completed},
              {"SUB_WORKFLOW", :in_progress}
            ])

      complete(leaf, "t2")

      for id <- [mid, root] do
        wf = await_status(id, :completed)
        assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :completed}] = statuses(wf)
      end
    end
  end

  ## SubWorkflowRestartSpec

  describe "SubWorkflowRestartSpec" do
    test "Test restart on the root in a 3-level subworkflow" do
      {root, mid, leaf} = three_levels()

      assert :ok = Lifecycle.restart(root)
      assert [{"integration_task_1", :scheduled}] = statuses(workflow(root))
      complete(root, "t1")

      root_wf = workflow(root)
      assert root_wf.status == :running

      assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :in_progress}] =
               statuses(root_wf)

      new_mid = child_of(root, "t2")
      assert new_mid != mid
      await_statuses(new_mid, [{"integration_task_1", :scheduled}])
      complete(new_mid, "t1")
      new_leaf = child_of(new_mid, "t2")
      assert new_leaf != leaf

      complete_leaf(new_leaf)

      for id <- [new_mid, root] do
        wf = await_status(id, :completed)
        assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :completed}] = statuses(wf)
      end
    end

    test "Test restart on the mid-level in a 3-level subworkflow" do
      {root, mid, leaf} = three_levels()

      assert :ok = Lifecycle.restart(mid)
      mid_wf = workflow(mid)
      assert mid_wf.status == :running
      assert [{"integration_task_1", :scheduled}] = statuses(mid_wf)

      root_wf =
        await_statuses(root, [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :in_progress}])

      assert root_wf.status == :running

      complete(mid, "t1")
      new_leaf = child_of(mid, "t2")
      assert new_leaf != leaf
      complete_leaf(new_leaf)

      for id <- [mid, root] do
        wf = await_status(id, :completed)
        assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :completed}] = statuses(wf)
      end

      refute last(root, "t2").subworkflow_changed
    end

    test "Test restart on the leaf in a 3-level subworkflow" do
      {root, mid, leaf} = three_levels()

      assert :ok = Lifecycle.restart(leaf)
      leaf_wf = workflow(leaf)
      assert leaf_wf.status == :running
      assert [{"integration_task_1", :scheduled}] = statuses(leaf_wf)

      for id <- [mid, root] do
        wf =
          await_statuses(id, [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :in_progress}])

        assert wf.status == :running
      end

      complete_leaf(leaf)

      for id <- [mid, root] do
        wf = await_status(id, :completed)
        assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :completed}] = statuses(wf)
        refute last(id, "t2").subworkflow_changed
      end
    end
  end

  ## HierarchicalForkJoinSubworkflowRetrySpec

  describe "HierarchicalForkJoinSubworkflowRetrySpec" do
    test "Test retry on the root in a 3-level subworkflow" do
      {root, mid, leaf} = hierarchical_three_levels()

      assert :ok = Lifecycle.retry(root)
      root_wf = workflow(root)
      assert root_wf.status == :running

      assert [
               {"FORK", :completed},
               {"SUB_WORKFLOW", :failed},
               {"integration_task_2", :completed},
               {"JOIN", :in_progress},
               {"SUB_WORKFLOW", :in_progress}
             ] = statuses(root_wf)

      new_mid = assert_retried_pair(root_wf, "st1").sub_workflow_id
      assert new_mid != mid

      await_statuses(new_mid, [
        {"FORK", :completed},
        {"SUB_WORKFLOW", :in_progress},
        {"integration_task_2", :scheduled},
        {"JOIN", :in_progress}
      ])

      complete(new_mid, "t2", %{"op" => "task2.done"})
      new_leaf = child_of(new_mid, "st1")
      assert new_leaf != leaf
      complete_leaf(new_leaf)

      assert await_statuses(new_mid, @fork_completed).status == :completed

      root_wf = await_status(root, :completed)

      assert [
               {"FORK", :completed},
               {"SUB_WORKFLOW", :failed},
               {"integration_task_2", :completed},
               {"JOIN", :completed},
               {"SUB_WORKFLOW", :completed}
             ] = statuses(root_wf)
    end

    test "Test retry on the mid-level in a 3-level subworkflow" do
      {root, mid, leaf} = hierarchical_three_levels()

      assert :ok = Lifecycle.retry(mid)
      mid_wf = workflow(mid)

      assert [
               {"FORK", :completed},
               {"SUB_WORKFLOW", :failed},
               {"integration_task_2", :completed},
               {"JOIN", :in_progress},
               {"SUB_WORKFLOW", :in_progress}
             ] = statuses(mid_wf)

      new_leaf = assert_retried_pair(mid_wf, "st1").sub_workflow_id
      assert new_leaf != leaf

      assert await_statuses(root, @fork_running).status == :running

      complete_leaf(new_leaf)

      assert await_status(mid, :completed)
      assert await_statuses(root, @fork_completed).status == :completed
    end

    test "Test retry on the leaf in a 3-level subworkflow" do
      {root, mid, leaf} = hierarchical_three_levels()

      assert :ok = Lifecycle.retry(leaf)
      assert_leaf_retried(leaf, :scheduled)

      for id <- [mid, root] do
        assert await_statuses(id, @fork_running).status == :running
        refute last(id, "st1").subworkflow_changed
      end

      complete(leaf, "t2")
      assert_leaf_retried(leaf, :completed)

      for id <- [mid, root], do: assert(await_statuses(id, @fork_completed).status == :completed)
    end

    test "Test retry on the root with resume flag in a 3-level subworkflow" do
      {root, mid, leaf} = hierarchical_three_levels()

      assert :ok = Lifecycle.retry(root, true)
      assert_leaf_retried(leaf, :scheduled)

      for id <- [mid, root], do: assert(await_statuses(id, @fork_running).status == :running)

      complete(leaf, "t2")
      for id <- [mid, root], do: assert(await_statuses(id, @fork_completed).status == :completed)
    end

    test "Test retry on the mid-level with resume flag in a 3-level subworkflow" do
      {root, mid, leaf} = hierarchical_three_levels()

      assert :ok = Lifecycle.retry(mid, true)
      assert_leaf_retried(leaf, :scheduled)

      for id <- [mid, root], do: assert(await_statuses(id, @fork_running).status == :running)

      complete(leaf, "t2")
      for id <- [mid, root], do: assert(await_statuses(id, @fork_completed).status == :completed)
    end

    test "Test retry on the leaf with resume flag in a 3-level subworkflow" do
      {root, mid, leaf} = hierarchical_three_levels()

      assert :ok = Lifecycle.retry(leaf, true)
      assert_leaf_retried(leaf, :scheduled)

      for id <- [mid, root], do: assert(await_statuses(id, @fork_running).status == :running)

      complete(leaf, "t2")
      for id <- [mid, root], do: assert(await_statuses(id, @fork_completed).status == :completed)
    end
  end

  ## HierarchicalForkJoinSubworkflowRestartSpec

  describe "HierarchicalForkJoinSubworkflowRestartSpec" do
    test "Test restart on the root in a 3-level subworkflow" do
      {root, mid, leaf} = hierarchical_three_levels()

      assert :ok = Lifecycle.restart(root)

      await_statuses(root, [
        {"FORK", :completed},
        {"SUB_WORKFLOW", :in_progress},
        {"integration_task_2", :scheduled},
        {"JOIN", :in_progress}
      ])

      new_mid = child_of(root, "st1")
      assert new_mid != mid
      complete(root, "t2", %{"op" => "task2.done"})

      await_statuses(new_mid, [
        {"FORK", :completed},
        {"SUB_WORKFLOW", :in_progress},
        {"integration_task_2", :scheduled},
        {"JOIN", :in_progress}
      ])

      complete(new_mid, "t2", %{"op" => "task2.done"})
      new_leaf = child_of(new_mid, "st1")
      assert new_leaf != leaf
      complete_leaf(new_leaf)

      for id <- [new_mid, root],
          do: assert(await_statuses(id, @fork_completed).status == :completed)
    end

    test "Test restart on the mid-level in a 3-level subworkflow" do
      {root, mid, leaf} = hierarchical_three_levels()

      assert :ok = Lifecycle.restart(mid)

      await_statuses(mid, [
        {"FORK", :completed},
        {"SUB_WORKFLOW", :in_progress},
        {"integration_task_2", :scheduled},
        {"JOIN", :in_progress}
      ])

      assert await_statuses(root, @fork_running).status == :running

      new_leaf = child_of(mid, "st1")
      assert new_leaf != leaf
      complete(mid, "t2", %{"op" => "task2.done"})
      complete_leaf(new_leaf)

      for id <- [mid, root], do: assert(await_statuses(id, @fork_completed).status == :completed)
    end

    test "Test restart on the leaf in a 3-level subworkflow" do
      {root, mid, leaf} = hierarchical_three_levels()

      assert :ok = Lifecycle.restart(leaf)
      assert [{"integration_task_1", :scheduled}] = statuses(workflow(leaf))

      for id <- [mid, root], do: assert(await_statuses(id, @fork_running).status == :running)

      complete_leaf(leaf)
      for id <- [mid, root], do: assert(await_statuses(id, @fork_completed).status == :completed)
    end
  end

  ## updateAndPushParents

  describe "parents that revive (updateAndPushParents)" do
    test "a sibling child terminated with its parent is retried, a canceled JOIN runs again" do
      root = start("lifecycle_two_children", %{})
      first = child_of(root, "st1")
      second = child_of(root, "st2")

      await_statuses(second, [{"integration_task_1", :scheduled}])
      complete(second, "t1")
      fail(second, "t2")

      # the root fails and terminates the first child with it
      await_status(second, :failed)

      assert [
               {"FORK", :completed},
               {"SUB_WORKFLOW", :canceled},
               {"SUB_WORKFLOW", :failed},
               {"JOIN", :canceled}
             ] = statuses(await_status(root, :failed))

      assert [{"integration_task_1", :canceled}] = statuses(await_status(first, :terminated))

      # retrying the second child revives the root, which retries the first
      assert :ok = Lifecycle.retry(second)

      root_wf =
        await_statuses(root, [
          {"FORK", :completed},
          {"SUB_WORKFLOW", :in_progress},
          {"SUB_WORKFLOW", :in_progress},
          {"JOIN", :in_progress}
        ])

      assert root_wf.status == :running

      first_wf =
        await_statuses(first, [
          {"integration_task_1", :canceled},
          {"integration_task_1", :scheduled}
        ])

      assert first_wf.status == :running
      assert first_wf.previous_status == :terminated

      complete(first, "t1")
      complete(first, "t2", %{"uuid" => "a"})
      complete(second, "t2", %{"uuid" => "b"})

      assert await_status(root, :completed)
    end

    test "a child retried after its parent was terminated is not terminated again" do
      root =
        start("integration_test_wf_with_sub_wf", Map.put(@input, "subwf", "integration_test_wf"))

      complete(root, "t1")
      child = child_of(root, "t2")
      await_statuses(child, [{"integration_task_1", :scheduled}])

      assert :ok = Runtime.terminate_workflow(root, "stop")
      assert await_status(child, :terminated)
      assert [_t1, {"SUB_WORKFLOW", :canceled}] = statuses(workflow(root))
      await_down(root)

      # the root's process starts again for the message, and its recovery check leaves the
      # child alone
      assert :ok = Lifecycle.retry(child)
      await_statuses(root, [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :in_progress}])
      assert workflow(child).status == :running

      complete(child, "t1")
      complete(child, "t2", %{"uuid" => "u"})
      assert await_status(root, :completed)
    end

    test "testRestartOptionalSubWorkflow, testRetryOptionalSubWorkflow: the parent stays as it is" do
      root = start("lifecycle_optional_child", %{})
      child = child_of(root, "st")
      complete(child, "t1")
      fail(child, "t2")
      await_status(child, :failed)

      parent = await_status(root, :completed)

      # the Decider's COMPLETED_WITH_ERRORS is not saved with the completion (ADR 0018, decision 2)
      assert [{"SUB_WORKFLOW", status}] = statuses(parent)
      assert status in [:failed, :completed_with_errors]

      me = self()

      RuntimeHooks.install(
        hook: fn
          :step, id, {:child_revived, _task_id} -> send(me, {:revive_handled, id})
          _point, _id, _data -> :ok
        end
      )

      assert :ok = Lifecycle.restart(child)
      assert workflow(child).status == :running
      assert workflow(child).previous_status == :failed

      complete(child, "t1")
      fail(child, "t2")
      await_status(child, :failed)

      assert :ok = Lifecycle.retry(child, true)
      assert workflow(child).status == :running

      # the walk stops at the optional task: the parent handled both requests and is not revived
      assert_receive {:revive_handled, ^root}, 1000
      assert_receive {:revive_handled, ^root}, 1000
      await_down(root)
      after_retry = workflow(root)
      assert after_retry.status == :completed
      assert after_retry.last_retried_time == parent.last_retried_time
      assert [{"SUB_WORKFLOW", ^status}] = statuses(after_retry)
      refute last(root, "st").subworkflow_changed
    end
  end

  describe "a child that ends in its first decide after a restart" do
    test "the parent revives before the child's notice and completes with it" do
      define(~S"""
      {"name": "lifecycle_instant_child", "version": 1, "tasks": [
        {"name": "integration_task_1", "taskReferenceName": "t1", "type": "SIMPLE"}]}
      """)

      define(~S"""
      {"name": "lifecycle_parent_of_instant", "version": 1, "tasks": [
        {"name": "sub_workflow_task", "taskReferenceName": "st", "type": "SUB_WORKFLOW",
         "inputParameters": {},
         "subWorkflowParam": {"name": "lifecycle_instant_child", "version": 1}}]}
      """)

      root = start("lifecycle_parent_of_instant", %{})
      child = child_of(root, "st")
      fail(child, "t1")
      await_status(child, :failed)
      await_status(root, :failed)

      # the latest version ends in its first decide
      define(~S"""
      {"name": "lifecycle_instant_child", "version": 2, "tasks": [
        {"name": "switch", "taskReferenceName": "sw", "type": "SWITCH",
         "evaluatorType": "value-param", "expression": "x", "inputParameters": {"x": "a"},
         "decisionCases": {}, "defaultCase": []}]}
      """)

      assert :ok = Lifecycle.restart(child, true)
      assert workflow(child).status == :completed

      parent = await_status(root, :completed)
      assert [{"SUB_WORKFLOW", :completed}] = statuses(parent)
    end
  end

  describe "child_revived (the step alone)" do
    test "a task that is gone or a SUB_WORKFLOW task already retried stops the walk" do
      sub = %Task{
        task_id: "sub",
        task_type: "SUB_WORKFLOW",
        status: :failed,
        reference_task_name: "st",
        retried: true,
        sub_workflow_id: "child",
        workflow_task: %Archon.Domain.WorkflowTask{name: "st", task_reference_name: "st"}
      }

      wf = %Workflow{
        workflow_id: "parent",
        parent_workflow_id: "grandparent",
        parent_workflow_task_id: "gp-task",
        status: :failed,
        end_time: 100,
        tasks: [sub],
        workflow_definition: %WorkflowDef{name: "p", version: 1}
      }

      for task_id <- ["gone", "sub"] do
        assert {:ok, ^wf, [], %Archon.Runtime.Commit{} = commit, []} =
                 Step.run(wf, {:child_revived, task_id}, Env.new(now: 1000))

        assert commit == %Archon.Runtime.Commit{}
      end
    end

    test "a child that already ended again is reflected at once" do
      sub = %Task{
        task_id: "sub",
        task_type: "SUB_WORKFLOW",
        status: :failed,
        reference_task_name: "st",
        sub_workflow_id: "child",
        workflow_task: %Archon.Domain.WorkflowTask{name: "st", task_reference_name: "st"}
      }

      wf = %Workflow{
        workflow_id: "parent",
        status: :failed,
        end_time: 100,
        tasks: [sub],
        workflow_definition: %WorkflowDef{name: "p", version: 1, tasks: []}
      }

      child = %Workflow{workflow_id: "child", status: :completed, output: %{"o" => 1}}

      {:ok, stored, [], _commit, _post} =
        Step.run(
          wf,
          {:child_revived, "sub"},
          Env.new(now: 1000, workflows: %{"child" => child})
        )

      assert [%Task{status: :completed, output_data: %{"o" => 1}}] = stored.tasks
    end

    test "a revived workflow asks its own parent after its commit" do
      sub = %Task{
        task_id: "sub",
        task_type: "SUB_WORKFLOW",
        status: :failed,
        reference_task_name: "st",
        sub_workflow_id: "child",
        workflow_task: %Archon.Domain.WorkflowTask{name: "st", task_reference_name: "st"}
      }

      wf = %Workflow{
        workflow_id: "parent",
        parent_workflow_id: "grandparent",
        parent_workflow_task_id: "gp-task",
        status: :failed,
        failed_task_id: "sub",
        failed_reference_task_names: ["st"],
        end_time: 100,
        tasks: [sub],
        workflow_definition: %WorkflowDef{name: "p", version: 1, tasks: []}
      }

      {:ok, stored, [], commit, post} =
        Step.run(wf, {:child_revived, "sub"}, Env.new(now: 1000, workflows: %{}))

      assert stored.status == :running
      assert stored.previous_status == :failed
      assert stored.failed_task_id == nil
      assert stored.failed_reference_task_names == []
      assert stored.last_retried_time == 1000
      assert [%Task{status: :in_progress, reason_for_incompletion: nil}] = commit.upsert_tasks
      assert {:revive_parent, "grandparent", "gp-task"} in post
    end
  end

  ## RetryPolicySpec

  defp retry_policy(fields) do
    task_def =
      struct!(
        %TaskDef{
          name: "retry_policy_task",
          timeout_seconds: 3600,
          response_timeout_seconds: 3600
        },
        fields
      )

    :ok = Runtime.metadata().update_task_def(task_def)
    start("retry_policy_wf", %{})
  end

  defp scheduled(id),
    do:
      id
      |> workflow()
      |> Map.fetch!(:tasks)
      |> Enum.filter(&(&1.status == :scheduled))
      |> List.last()

  describe "RetryPolicySpec" do
    test "Exponential backoff delay is capped by maxRetryDelaySeconds" do
      id =
        retry_policy(
          retry_count: 5,
          retry_delay_seconds: 2,
          retry_logic: :exponential_backoff,
          max_retry_delay_seconds: 3
        )

      fail(id, "retry_task_ref")
      assert scheduled(id).callback_after_seconds == 2

      fail(id, "retry_task_ref")
      assert scheduled(id).callback_after_seconds == 3
    end

    test "Linear backoff delay is capped by maxRetryDelaySeconds" do
      id =
        retry_policy(
          retry_count: 5,
          retry_delay_seconds: 2,
          retry_logic: :linear_backoff,
          backoff_scale_factor: 2,
          max_retry_delay_seconds: 5
        )

      fail(id, "retry_task_ref")
      assert scheduled(id).callback_after_seconds == 4

      fail(id, "retry_task_ref")
      assert scheduled(id).callback_after_seconds == 5
    end

    test "backoffJitterMs adds a random offset in [0, maxJitterMs] to the retry delay" do
      id =
        retry_policy(
          retry_count: 3,
          retry_delay_seconds: 60,
          retry_logic: :fixed,
          backoff_jitter_ms: 5000
        )

      fail(id, "retry_task_ref")
      task = scheduled(id)
      assert task.callback_after_seconds == 60
      assert task.callback_after_ms in 60_000..65_000
    end

    test "backoffJitterMs of zero produces no jitter" do
      id =
        retry_policy(
          retry_count: 3,
          retry_delay_seconds: 30,
          retry_logic: :fixed,
          backoff_jitter_ms: 0
        )

      fail(id, "retry_task_ref")
      assert scheduled(id).callback_after_ms == 30_000
    end

    test "Cap is applied before jitter" do
      id =
        retry_policy(
          retry_count: 5,
          retry_delay_seconds: 2,
          retry_logic: :exponential_backoff,
          max_retry_delay_seconds: 3,
          backoff_jitter_ms: 2000
        )

      fail(id, "retry_task_ref")
      fail(id, "retry_task_ref")
      task = scheduled(id)
      assert task.callback_after_seconds == 3
      assert task.callback_after_ms in 3_000..5_000
    end

    test "totalTimeoutSeconds=0 is disabled" do
      id =
        retry_policy(
          retry_count: 5,
          retry_delay_seconds: 0,
          retry_logic: :fixed,
          total_timeout_seconds: 0
        )

      fail(id, "retry_task_ref")
      wf = workflow(id)
      assert length(wf.tasks) >= 2
      assert List.last(wf.tasks).status == :scheduled
    end

    test "totalTimeoutSeconds exceeded on retry" do
      RuntimeHooks.install(clock: 1_000_000, timer: self())

      id =
        retry_policy(
          retry_count: 10,
          retry_delay_seconds: 0,
          retry_logic: :fixed,
          total_timeout_seconds: 5,
          timeout_seconds: 0,
          response_timeout_seconds: 1,
          timeout_policy: :time_out_wf
        )

      RuntimeHooks.advance(60_000)
      fail(id, "retry_task_ref")

      assert workflow(id).status in [:timed_out, :failed]
    end

    test "totalTimeoutSeconds exceeded in checkTotalTimeout" do
      RuntimeHooks.install(clock: 1_000_000, timer: self())

      id =
        retry_policy(
          retry_count: 10,
          retry_delay_seconds: 0,
          retry_logic: :fixed,
          total_timeout_seconds: 5,
          timeout_seconds: 0,
          response_timeout_seconds: 1,
          timeout_policy: :retry
        )

      polled = poll(id, "retry_task_ref")
      RuntimeHooks.advance(60_000)
      send(WorkflowServer.whereis(id), :wake)

      timed_out =
        eventually(fn ->
          task = Enum.find(workflow(id).tasks, &(&1.task_id == polled.task_id))
          task.status == :timed_out and task
        end)

      # the total timeout fired, not the response timeout that is also exceeded
      assert timed_out.reason_for_incompletion =~ "exceeded total timeout of 5 seconds"
    end
  end
end
