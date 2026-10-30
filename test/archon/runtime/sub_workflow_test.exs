# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Scenarios derived from conductor-oss test-harness/src/test/groovy/com/netflix/conductor/test/integration/
# SubWorkflowSpec.groovy, FailureWorkflowSpec.groovy and NestedForkJoinSubWorkflowSpec.groovy (the
# parts before any retry or restart) and their resource definitions at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the workflows run as processes, so there is no system task executor or
# sweep to call. LAMBDA and TERMINATE are not MVP types (ADR 0003): a LAMBDA is a SIMPLE task a
# worker completes with the same output, and a FAILED TERMINATE a SIMPLE task the worker fails.

defmodule Archon.Runtime.SubWorkflowTest do
  @moduledoc """
  `Archon.Runtime.SubWorkflows` (ADR 0018, decisions 5 and 8 (a), slice 3e): starting a child,
  the parent following it, cancelling it with its parent, and the failure workflow. The child's
  SIMPLE tasks run through the `Archon.Runtime.WorkflowServer` poll and update client functions.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Domain.{Task, TaskDef, TaskResult, Workflow, WorkflowDef}
  alias Archon.Runtime.Step.SubWorkflow
  alias Archon.Runtime.SubWorkflows

  # simple_one_task_sub_workflow_integration_test.json
  @sub_workflow ~S"""
  {"name": "sub_workflow", "version": 1, "tasks": [
    {"name": "simple_task_in_sub_wf", "taskReferenceName": "t1", "inputParameters": {},
     "type": "SIMPLE"}],
   "inputParameters": [], "outputParameters": {}}
  """

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

  # nested_fork_join_swf.json
  @nested_fork_join ~S"""
  {"name": "nested_fork_join_swf", "version": 1, "tasks": [
    {"name": "outer_fork", "taskReferenceName": "outer_fork", "type": "FORK_JOIN",
     "inputParameters": {}, "forkTasks": [
      [{"name": "inner_fork", "taskReferenceName": "inner_fork", "type": "FORK_JOIN",
        "inputParameters": {}, "forkTasks": [
         [{"name": "sub_workflow_task", "taskReferenceName": "st1", "type": "SUB_WORKFLOW",
           "inputParameters": {"param1": "${workflow.input.param1}",
                               "param2": "${workflow.input.param2}",
                               "subwf": "${workflow.input.nextSubwf}"},
           "subWorkflowParam": {"name": "${workflow.input.subwf}", "version": 1}}],
         [{"name": "integration_task_2", "taskReferenceName": "t2", "type": "SIMPLE",
           "inputParameters": {"p1": "${workflow.input.param1}",
                               "p2": "${workflow.input.param2}"}}]]},
       {"name": "inner_join", "taskReferenceName": "inner_join", "type": "JOIN",
        "joinOn": ["st1", "t2"]}],
      [{"name": "integration_task_2", "taskReferenceName": "t3", "type": "SIMPLE",
        "inputParameters": {"p1": "${workflow.input.param1}",
                            "p2": "${workflow.input.param2}"}}]]},
    {"name": "join", "taskReferenceName": "outer_join", "type": "JOIN", "inputParameters": {},
     "joinOn": ["inner_join", "t3"]}],
   "inputParameters": ["param1", "param2", "subwf"]}
  """

  # failure_workflow_for_terminate_task_workflow.json (LAMBDA → SIMPLE)
  @failure_workflow ~S"""
  {"name": "failure_workflow", "version": 1, "tasks": [
    {"name": "lambda", "taskReferenceName": "lambda0", "type": "SIMPLE",
     "inputParameters": {"input": "${workflow.input}"}}],
   "inputParameters": [], "outputParameters": {}}
  """

  # terminate_task_failed_workflow_integration.json (LAMBDA → SIMPLE, TERMINATE → a SIMPLE task
  # the worker fails)
  @terminate_task_failed ~S"""
  {"name": "test_terminate_task_failed_wf", "version": 1, "tasks": [
    {"name": "lambda", "taskReferenceName": "lambda0", "type": "SIMPLE",
     "inputParameters": {"input": "${workflow.input}"}},
    {"name": "terminate", "taskReferenceName": "terminate0", "type": "SIMPLE",
     "inputParameters": {"workflowOutput": "${lambda0.output}"}},
    {"name": "integration_task_2", "taskReferenceName": "t2", "type": "SIMPLE",
     "inputParameters": {}}],
   "inputParameters": [], "outputParameters": {}, "failureWorkflow": "failure_workflow"}
  """

  # test_task_failed_parent_workflow.json (LAMBDA → SIMPLE)
  @task_failed_parent ~S"""
  {"name": "test_task_failed_parent_wf", "version": 1, "tasks": [
    {"name": "test_lambda_task1", "taskReferenceName": "lambdaTask1", "type": "SIMPLE",
     "inputParameters": {"lambdaValue": "${workflow.input.lambdaValue}"}},
    {"name": "test_task_failed_sub_wf", "taskReferenceName": "test_task_failed_sub_wf",
     "type": "SUB_WORKFLOW", "inputParameters": {},
     "subWorkflowParam": {"name": "test_task_failed_sub_wf"}},
    {"name": "test_lambda_task2", "taskReferenceName": "lambdaTask2", "type": "SIMPLE",
     "inputParameters": {"lambdaValue": "${workflow.input.lambdaValue}"}}],
   "failureWorkflow": "failure_workflow"}
  """

  # test_task_failed_sub_workflow.json (LAMBDA → SIMPLE, TERMINATE → a SIMPLE task the worker
  # fails)
  @task_failed_sub ~S"""
  {"name": "test_task_failed_sub_wf", "version": 1, "tasks": [
    {"name": "lambda", "taskReferenceName": "lambda0", "type": "SIMPLE",
     "inputParameters": {"input": "${workflow.input}"}},
    {"name": "terminate", "taskReferenceName": "terminate0", "type": "SIMPLE",
     "inputParameters": {"workflowOutput": "${lambda0.output}"}},
    {"name": "integration_task_2", "taskReferenceName": "t2", "type": "SIMPLE",
     "inputParameters": {}}],
   "inputParameters": [], "outputParameters": {}}
  """

  setup do
    # NestedForkJoinSubWorkflowSpec and SubWorkflowSpec set integration_task_2 to 0 retries.
    for {name, retries} <- [
          {"integration_task_1", 0},
          {"integration_task_2", 0},
          {"simple_task_in_sub_wf", 0},
          {"lambda", 0},
          {"terminate", 0},
          {"test_lambda_task1", 0}
        ] do
      :ok = Runtime.metadata().update_task_def(%TaskDef{name: name, retry_count: retries})
    end

    for json <- [
          @sub_workflow,
          @simple_workflow,
          @workflow_with_sub_workflow,
          @nested_fork_join,
          @failure_workflow,
          @terminate_task_failed,
          @task_failed_parent,
          @task_failed_sub
        ],
        do: define(json)

    :ok
  end

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

  # A child decides first after its start answered, and a failure workflow starts after its
  # parent's commit, so their tasks appear a little later.
  defp poll(id, ref) do
    task = eventually(fn -> match?({:ok, _}, Runtime.get_workflow(id)) and task(id, ref) end)
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

  defp fail(id, ref, reason) do
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
    do: eventually(fn -> statuses(workflow(id)) == expected end)

  defp child_of(id, ref), do: eventually(fn -> task(id, ref).sub_workflow_id end)

  defp await_status(id, status),
    do: eventually(fn -> match?(%Workflow{status: ^status}, workflow(id)) and workflow(id) end)

  # The parent of integration_test_wf_with_sub_wf with its child started.
  defp start_with_child(subwf, fields \\ []) do
    input = %{"param1" => "p1 value", "param2" => "p2 value", "subwf" => subwf}

    id =
      start(
        "integration_test_wf_with_sub_wf",
        input,
        [correlation_id: "wf_with_subwf_test_1"] ++ fields
      )

    assert [{"integration_task_1", :scheduled}] = statuses(workflow(id))
    complete(id, "t1")

    # the start of the child is fed back within the update
    parent = workflow(id)
    assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :in_progress}] = statuses(parent)
    {id, Enum.at(parent.tasks, 1).sub_workflow_id}
  end

  describe "SubWorkflowSpec" do
    test "the child starts with the parent's references and the parent completes with it" do
      {id, child_id} = start_with_child("integration_test_wf")
      sub_task = task(id, "t2")

      assert child_id == SubWorkflow.child_id(id, sub_task)
      assert sub_task.output_data["subWorkflowId"] == child_id

      await_statuses(child_id, [{"integration_task_1", :scheduled}])
      child = workflow(child_id)
      assert child.status == :running
      assert child.parent_workflow_id == id
      assert child.parent_workflow_task_id == sub_task.task_id
      assert child.correlation_id == "wf_with_subwf_test_1"
      assert %{"param1" => "p1 value", "param2" => "p2 value"} = child.input

      complete(child_id, "t1")
      complete(child_id, "t2", %{"uuid" => "u-1"})

      child = await_status(child_id, :completed)
      assert child.output == %{"o1" => "p1 value", "o2" => "u-1", "o3" => "task1.done"}

      parent = await_status(id, :completed)
      assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :completed}] = statuses(parent)
      assert %{"o1" => "p1 value", "subWorkflowId" => ^child_id} = task(id, "t2").output_data
    end

    test "Test retrying a subworkflow where parent workflow timed out due to workflowTimeout (until the retry)" do
      RuntimeHooks.install(clock: 1_000_000, timer: self())

      define(@workflow_with_sub_workflow, fn definition ->
        %{definition | timeout_policy: :time_out_wf, timeout_seconds: 10}
      end)

      {id, child_id} = start_with_child("sub_workflow")
      await_statuses(child_id, [{"simple_task_in_sub_wf", :scheduled}])

      RuntimeHooks.advance(10_000)
      send(WorkflowServer.whereis(id), :wake)

      parent = await_status(id, :timed_out)
      assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :canceled}] = statuses(parent)

      # the child is terminated before the parent's commit (a pre effect)
      child = workflow(child_id)
      assert child.status == :terminated
      assert [{"simple_task_in_sub_wf", :canceled}] = statuses(child)
    end

    test "Test terminating a subworkflow terminates parent workflow" do
      {id, child_id} = start_with_child("sub_workflow")

      await_statuses(child_id, [{"simple_task_in_sub_wf", :scheduled}])
      assert workflow(child_id).status == :running

      terminate_reason = "terminating from a test case"
      assert Runtime.terminate_workflow(child_id, terminate_reason) == :ok

      child = workflow(child_id)
      assert child.status == :terminated
      assert [{"simple_task_in_sub_wf", :canceled}] = statuses(child)
      assert child.reason_for_incompletion == terminate_reason

      parent = await_status(id, :terminated)
      assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :canceled}] = statuses(parent)
      assert parent.reason_for_incompletion =~ terminate_reason
    end

    test "Test retrying a workflow with subworkflow resume (until the retry)" do
      {id, child_id} = start_with_child("integration_test_wf")

      complete(child_id, "t1")
      fail(child_id, "t2", "failed")

      child = await_status(child_id, :failed)

      assert [{"integration_task_1", :completed}, {"integration_task_2", :failed}] =
               statuses(child)

      parent = await_status(id, :failed)
      assert [{"integration_task_1", :completed}, {"SUB_WORKFLOW", :failed}] = statuses(parent)
    end
  end

  describe "FailureWorkflowSpec" do
    test "Test workflow with a task that failed" do
      id = start("test_terminate_task_failed_wf", %{"a" => 1}, correlation_id: "testId")
      complete(id, "lambda0", %{"testvalue" => true})
      fail(id, "terminate0", "Early exit in terminate")

      parent = workflow(id)
      assert parent.status == :failed
      assert parent.reason_for_incompletion =~ "Early exit in terminate"
      assert [{"lambda", :completed}, {"terminate", :failed}] = names(parent)
      assert Enum.map(parent.tasks, & &1.seq) == [1, 2]
      failure_id = parent.output["conductor.failure_workflow"]
      terminate_id = Enum.at(parent.tasks, 1).task_id

      complete(failure_id, "lambda0", %{"testvalue" => true})
      failure = await_status(failure_id, :completed)
      assert failure.correlation_id == "testId"
      assert failure.input["workflowId"] == id
      assert failure.input["failureTaskId"] == terminate_id
      assert failure.input["failureStatus"] == "FAILED"
      assert %{"workflowId" => ^id} = failure.input["failedWorkflow"]
      assert [{"lambda", :completed}] = statuses(failure)
    end

    test "Test workflow with a task failed in subworkflow" do
      id = start("test_task_failed_parent_wf", %{"a" => 1}, correlation_id: "")
      complete(id, "lambdaTask1", %{"testvalue" => "Lambda value was NOT 1", "iValue" => 13})

      child_id = child_of(id, "test_task_failed_sub_wf")
      complete(child_id, "lambda0", %{"testvalue" => true})
      fail(child_id, "terminate0", "Early exit in terminate")

      child = workflow(child_id)
      assert child.status == :failed
      assert child.reason_for_incompletion =~ "Early exit in terminate"
      assert [{"lambda", :completed}, {"terminate", :failed}] = names(child)
      assert Enum.map(child.tasks, & &1.seq) == [1, 2]
      # the child has no failure workflow of its own
      refute Map.has_key?(child.output, "conductor.failure_workflow")

      parent = await_status(id, :failed)

      assert [{"test_lambda_task1", :completed}, {"test_task_failed_sub_wf", :failed}] =
               names(parent)

      assert hd(parent.tasks).reference_task_name == "lambdaTask1"
      assert Enum.map(parent.tasks, & &1.seq) == [1, 2]
      sub_task_id = Enum.at(parent.tasks, 1).task_id

      failure_id = parent.output["conductor.failure_workflow"]
      complete(failure_id, "lambda0", %{"testvalue" => true})
      failure = await_status(failure_id, :completed)
      assert failure.correlation_id == ""
      assert failure.input["workflowId"] == id
      assert failure.input["failureTaskId"] == sub_task_id
      assert failure.input["failedWorkflow"] != nil
      assert [{"lambda", :completed}] = statuses(failure)
    end

    test "a failure workflow without a definition leaves upstream's message in the output" do
      define(
        @terminate_task_failed,
        &%{
          &1
          | name: "archon_no_failure_wf_parent",
            failure_workflow: "archon_missing_failure_wf"
        }
      )

      id = start("archon_no_failure_wf_parent", %{"a" => 1})
      complete(id, "lambda0")
      fail(id, "terminate0", "Early exit in terminate")

      assert eventually(fn ->
               workflow(id).output["conductor.failure_workflow"] ==
                 "Error workflow archon_missing_failure_wf failed to start.  reason: " <>
                   "No such workflow defined. name=archon_missing_failure_wf, version=null"
             end)
    end
  end

  defp names(%Workflow{tasks: tasks}), do: Enum.map(tasks, &{&1.task_def_name, &1.status})

  describe "NestedForkJoinSubWorkflowSpec (the setup every case shares)" do
    test "a failed task in the leaf workflow fails the nested fork join parent" do
      input = %{"param1" => "p1 value", "param2" => "p2 value", "subwf" => "integration_test_wf"}
      id = start("nested_fork_join_swf", input, correlation_id: "retry_on_root_in_3level_wf")

      # a top-level start answers before it starts the child
      await_statuses(id, [
        {"FORK", :completed},
        {"FORK", :completed},
        {"SUB_WORKFLOW", :in_progress},
        {"integration_task_2", :scheduled},
        {"JOIN", :in_progress},
        {"integration_task_2", :scheduled},
        {"JOIN", :in_progress}
      ])

      assert workflow(id).status == :running

      complete(id, "t2")
      complete(id, "t3")

      assert [
               {"FORK", :completed},
               {"FORK", :completed},
               {"SUB_WORKFLOW", :in_progress},
               {"integration_task_2", :completed},
               {"JOIN", :in_progress},
               {"integration_task_2", :completed},
               {"JOIN", :in_progress}
             ] = statuses(workflow(id))

      child_id = task(id, "st1").sub_workflow_id
      await_statuses(child_id, [{"integration_task_1", :scheduled}])

      complete(child_id, "t1")
      fail(child_id, "t2", "task2 failed")

      child = await_status(child_id, :failed)

      assert [{"integration_task_1", :completed}, {"integration_task_2", :failed}] =
               statuses(child)

      parent = await_status(id, :failed)

      assert [
               {"FORK", :completed},
               {"FORK", :completed},
               {"SUB_WORKFLOW", :failed},
               {"integration_task_2", :completed},
               {"JOIN", :canceled},
               {"integration_task_2", :completed},
               {"JOIN", :canceled}
             ] = statuses(parent)
    end
  end

  describe "starting a child" do
    test "a child whose definition does not exist fails the task with upstream's message" do
      {id, _child_id} = start_with_child_named("archon_no_such_sub_wf")
      sub_task = task(id, "t2")

      assert sub_task.status == :failed

      assert sub_task.reason_for_incompletion ==
               "No such workflow defined. name=archon_no_such_sub_wf, version=1"

      assert workflow(id).status == :failed
    end

    test "a child that belongs to another parent is refused" do
      {id, child_id} = start_with_child("sub_workflow")
      sub_task = task(id, "t2")

      start = %{
        workflow_id: child_id,
        name: "sub_workflow",
        input: %{},
        parent_workflow_id: "archon-other-parent",
        parent_workflow_task_id: sub_task.task_id
      }

      assert {:error, message} = SubWorkflows.start_child(start)

      assert message ==
               "Workflow id #{child_id} already belongs to parent workflow #{id} task " <>
                 "#{sub_task.task_id}, cannot attach to parent workflow archon-other-parent " <>
                 "task #{sub_task.task_id}"

      assert {:ok, %Workflow{workflow_id: ^child_id}} =
               SubWorkflows.start_child(%{start | parent_workflow_id: id})
    end

    test "a commit failure is transient: the task waits and the next :wake starts the child" do
      parent_id = "archon-parent-" <> Runtime.new_id()

      RuntimeHooks.install(
        clock: 1_000_000,
        timer: self(),
        hook: fn
          :commit, id, _commit when id != parent_id -> raise "store down"
          _point, _id, _data -> :ok
        end
      )

      input = %{"param1" => "p1 value", "param2" => "p2 value", "subwf" => "sub_workflow"}

      start("integration_test_wf_with_sub_wf", input, workflow_id: parent_id)
      complete(parent_id, "t1")

      sub_task = task(parent_id, "t2")
      assert sub_task.status == :scheduled
      assert sub_task.sub_workflow_id == nil
      assert sub_task.output_data["subWorkflowLaunchError"] == "commit: store down"

      assert sub_task.reason_for_incompletion =~
               "Transient error starting sub workflow sub_workflow: "

      assert Runtime.get_workflow(SubWorkflow.child_id(parent_id, sub_task)) ==
               {:error, :not_found}

      # the retry waits for the task's delay, as upstream's queue would
      RuntimeHooks.install(hook: fn _point, _id, _data -> :ok end)
      parent_pid = WorkflowServer.whereis(parent_id)
      send(parent_pid, :wake)
      :sys.get_state(parent_pid)
      assert %Task{status: :scheduled, sub_workflow_id: nil} = task(parent_id, "t2")

      RuntimeHooks.advance(30_000)
      send(WorkflowServer.whereis(parent_id), :wake)

      sub_task =
        eventually(fn ->
          t = task(parent_id, "t2")
          t.status == :in_progress and t
        end)

      assert sub_task.sub_workflow_id == SubWorkflow.child_id(parent_id, sub_task)
      refute Map.has_key?(sub_task.output_data, "subWorkflowLaunchError")
      assert sub_task.reason_for_incompletion == nil
      assert workflow(sub_task.sub_workflow_id).status == :running
    end
  end

  describe "the effects on their own" do
    test "a worker-supplied child ID naming the parent does not block the parent's termination" do
      {id, child_id} = start_with_child("sub_workflow")
      sub_task = task(id, "t2")

      assert %Task{sub_workflow_id: ^id} =
               WorkflowServer.update(%TaskResult{
                 workflow_instance_id: id,
                 task_id: sub_task.task_id,
                 status: :in_progress,
                 sub_workflow_id: id
               })

      assert Runtime.terminate_workflow(id, "stop") == :ok
      assert workflow(id).status == :terminated
      assert task(id, "t2").status == :canceled
      # the task no longer names the real child: it is not cancelled now (the recovery check ends
      # it later)
      assert workflow(child_id).status == :running
    end

    test "a worker-supplied child ID naming an ancestor terminates it without a deadlock" do
      input = %{
        "param1" => "p1 value",
        "param2" => "p2 value",
        "subwf" => "integration_test_wf_with_sub_wf",
        "nextSubwf" => "sub_workflow"
      }

      grandparent = start("integration_test_wf_with_sub_wf", input)
      complete(grandparent, "t1")
      parent = child_of(grandparent, "t2")
      complete(parent, "t1")

      sub_task =
        eventually(fn ->
          t = task(parent, "t2")
          t.sub_workflow_id && t
        end)

      assert %Task{} =
               WorkflowServer.update(%TaskResult{
                 workflow_instance_id: parent,
                 task_id: sub_task.task_id,
                 status: :in_progress,
                 sub_workflow_id: grandparent
               })

      # a synchronous cancel would wait for the grandparent, which calls back into the parent
      {micros, :ok} = :timer.tc(fn -> Runtime.terminate_workflow(parent, "stop") end)
      assert micros < 5_000_000
      assert workflow(parent).status == :terminated
      assert await_status(grandparent, :terminated).status == :terminated
    end

    test "a child ID that names the parent itself fails the ownership check" do
      {id, _child_id} = start_with_child("sub_workflow")
      sub_task = task(id, "t2")

      start = %{
        workflow_id: id,
        name: "sub_workflow",
        input: %{},
        parent_workflow_id: id,
        parent_workflow_task_id: sub_task.task_id
      }

      assert {:error, message} = SubWorkflows.start_child(start)
      assert message =~ "Workflow id #{id} already belongs to parent workflow null task null"
    end

    test "terminating a child that does not exist succeeds" do
      assert SubWorkflows.terminate_child("archon-no-such-child", "parent ended") == :ok
    end

    test "a notice to a parent that does not exist is dropped" do
      child = %Workflow{workflow_id: "archon-orphan", status: :completed}
      assert SubWorkflows.notify_parent("archon-no-such-parent", "t", child) == :ok
      assert SubWorkflows.notify_parent("archon-no-such-parent", nil, child) == :ok
    end

    test "a failure workflow whose ID exists counts as started" do
      start = %{workflow_id: Runtime.new_id(), name: "failure_workflow", input: %{"a" => 1}}

      assert SubWorkflows.start_failure_workflow(start) == :ok
      assert SubWorkflows.start_failure_workflow(start) == :ok

      assert SubWorkflows.start_failure_workflow(%{
               start
               | name: "archon_missing",
                 workflow_id: Runtime.new_id()
             }) ==
               {:error, "No such workflow defined. name=archon_missing, version=null"}
    end
  end

  defp start_with_child_named(subwf) do
    input = %{"param1" => "p1 value", "param2" => "p2 value", "subwf" => subwf}
    id = start("integration_test_wf_with_sub_wf", input)
    complete(id, "t1")
    {id, task(id, "t2").sub_workflow_id}
  end
end
