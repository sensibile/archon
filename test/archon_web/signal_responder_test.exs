# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.SignalResponderTest do
  @moduledoc """
  `ArchonWeb.SignalResponder` (ADR 0025 decision 5, slice 6e): which tasks block (a `WAIT`
  without an end, a terminal task of a named reference, a child's tasks only when its task owns
  it), the timeout, and the strategies that have no answer. Runs on the backend the suite runs
  on.
  """

  use Archon.RuntimeCase

  @moduletag :capture_log

  alias Archon.Contract
  alias Archon.Domain.{Codec, Task, TaskDef, TaskRun, Workflow, WorkflowDef, WorkflowRun}
  alias ArchonWeb.SignalResponder

  @null_mapper "The mapper [com.netflix.conductor.rest.controllers.WorkflowSignalResponder$$Lambda] " <>
                 "returned a null value."

  setup do
    {:ok, task_defs} =
      Codec.cast(
        {:list, {:struct, TaskDef}},
        Contract.fixture("metadata_register_ops_taskdefs")["request"]["body"],
        []
      )

    for task_def <- task_defs, do: :ok = Runtime.metadata().update_task_def(task_def)

    for name <- ~w(waits signal_parent idle noop) do
      body = Contract.fixture("metadata_register_workflow_ops_#{name}")["request"]["body"]
      {:ok, definition} = WorkflowDef.from_json(body)
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

    isolate_queues(["archon_ops_idle"])
  end

  defp start(name, input \\ %{}) do
    {:ok, id} = Runtime.start_workflow(%{name: name, input: input})
    id
  end

  defp workflow(id) do
    {:ok, workflow} = Runtime.get_workflow(id, true)
    workflow
  end

  defp child(parent_id) do
    eventually(fn ->
      with [%Task{} = task | _rest] <- workflow(parent_id).tasks,
           id when is_binary(id) <- Task.sub_workflow_id(task),
           {:ok, %Workflow{tasks: [_ | _]}} <- Runtime.get_workflow(id, true),
           do: id,
           else: (_not_yet -> nil)
    end)
  end

  defp elapsed_ms(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - start, result}
  end

  describe "blocking_tasks/2" do
    test "a WAIT task without an end blocks, a WAIT with one does not" do
      waiting = %Task{task_type: "WAIT", status: :in_progress, wait_timeout: 0, task_id: "a"}
      timed = %Task{waiting | wait_timeout: 1_000, task_id: "b"}
      done = %Task{waiting | status: :completed, task_id: "c"}
      wf = %Workflow{workflow_id: "wf", tasks: [timed, done, waiting]}

      assert SignalResponder.blocking_tasks(wf, []) == {[waiting], wf}
      assert SignalResponder.blocking_tasks(%{wf | tasks: [timed, done]}, []) == {[], nil}
    end

    test "a terminal task of a named reference blocks, once per matching name" do
      running = %Task{task_type: "SIMPLE", status: :in_progress, reference_task_name: "r"}
      done = %Task{running | status: :completed, task_id: "done"}
      wf = %Workflow{workflow_id: "wf", tasks: [running, done]}

      assert SignalResponder.blocking_tasks(wf, ["r"]) == {[done], wf}
      assert SignalResponder.blocking_tasks(wf, ["r", "x", "r"]) == {[done, done], wf}
      assert SignalResponder.blocking_tasks(wf, ["x"]) == {[], nil}
    end

    test "a child's blocking tasks, with the child as the blocking workflow" do
      parent = start("archon_ops_signal_parent")
      child = child(parent)

      assert {[%Task{reference_task_name: "wait1_ref", workflow_instance_id: ^child}],
              %Workflow{workflow_id: ^child}} =
               SignalResponder.blocking_tasks(workflow(parent), [])
    end

    test "a child its SUB_WORKFLOW task does not own is passed over" do
      other = start("archon_ops_waits")
      assert {[_wait], _blocking} = SignalResponder.blocking_tasks(workflow(other), [])

      sub = %Task{
        task_type: "SUB_WORKFLOW",
        status: :in_progress,
        task_id: "sub",
        sub_workflow_id: other
      }

      parent = %Workflow{workflow_id: "not-the-parent", tasks: [sub]}
      assert SignalResponder.blocking_tasks(parent, []) == {[], nil}

      missing = %Workflow{parent | tasks: [%{sub | sub_workflow_id: "missing"}]}
      assert SignalResponder.blocking_tasks(missing, []) == {[], nil}
    end
  end

  describe "await/5" do
    test "answers once a task blocks" do
      id = start("archon_ops_waits")

      assert {:ok, %WorkflowRun{} = run} =
               SignalResponder.await(id, [], :target_workflow, "req", 5_000)

      assert %WorkflowRun{
               response_type: :target_workflow,
               target_workflow_id: ^id,
               target_workflow_status: "RUNNING",
               workflow_id: ^id,
               request_id: "req",
               signal_timeout: false,
               status: :running
             } = run

      assert {:ok,
              %TaskRun{reference_task_name: "wait1_ref", response_type: :blocking_task_input}} =
               SignalResponder.await(id, [], :blocking_task_input, "req", 5_000)
    end

    test "the blocking workflow is the child, the target the parent" do
      parent = start("archon_ops_signal_parent")
      child = child(parent)

      assert {:ok,
              %WorkflowRun{
                workflow_id: ^child,
                target_workflow_id: ^parent,
                response_type: :blocking_workflow
              }} = SignalResponder.await(parent, [], :blocking_workflow, "req", 5_000)

      assert {:ok, %TaskRun{workflow_id: ^child, target_workflow_id: ^parent}} =
               SignalResponder.await(parent, [], :blocking_task, "req", 5_000)
    end

    test "a terminal workflow answers at once, without an answer for BLOCKING_TASK" do
      id = start("archon_ops_noop")
      eventually(fn -> workflow(id).status == :completed end)

      assert {:ok, %WorkflowRun{status: :completed, signal_timeout: false}} =
               SignalResponder.await(id, [], :blocking_workflow, "req", 5_000)

      assert SignalResponder.await(id, [], :blocking_task, "req", 5_000) ==
               {:error, {:server_error, @null_mapper}}

      assert {:ok, %TaskRun{reference_task_name: "noop_ref", status: :completed}} =
               SignalResponder.await(id, [" noop_ref "], :blocking_task, "req", 5_000)
    end

    test "after the timeout, the workflow as it is, and no answer for BLOCKING_TASK" do
      id = start("archon_ops_idle")

      {ms, result} =
        elapsed_ms(fn -> SignalResponder.await(id, [], :target_workflow, "r", 300) end)

      assert {:ok, %WorkflowRun{signal_timeout: true, status: :running}} = result
      assert ms >= 300

      assert SignalResponder.await(id, [], :blocking_task, "r", 150) ==
               {:error, {:server_error, "value"}}

      assert workflow(id).status == :running
    end

    test "a timeout of 0 or less answers at once" do
      id = start("archon_ops_idle")

      {ms, result} =
        elapsed_ms(fn -> SignalResponder.await(id, [], :target_workflow, "r", -1) end)

      assert {:ok, %WorkflowRun{signal_timeout: true}} = result
      assert ms < 100
    end

    test "an unknown workflow is not found" do
      assert SignalResponder.await("missing", [], :target_workflow, "r", 0) ==
               {:error, {:not_found, "No such workflow found by id: missing"}}
    end
  end
end
