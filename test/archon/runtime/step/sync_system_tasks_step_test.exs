# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss test-harness/src/test/groovy/.../integration/LambdaAndTerminateTaskSpec.groovy,
# SetVariableTaskSpec.groovy and ExclusiveJoinSpec.groovy
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the specs run as steps over the pure runtime (ADR 0026, decision 3).

defmodule Archon.Runtime.Step.SyncSystemTasksStepTest do
  @moduledoc """
  `TERMINATE`, `SET_VARIABLE`, `NOOP`, `HUMAN` and `EXCLUSIVE_JOIN` through
  `Archon.Runtime.Step.run/3` (ADR 0026, decision 3): what each step saves.

  Upstream's `startWorkflow` decides on the workflow object it made, whose `variables` map is the
  definition's, so a `SET_VARIABLE` of that first decide also changes the stored
  `workflowDefinition.variables`. A later decide reads the workflow again and changes only the
  variables.
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay, only: [apply_commit: 2]

  alias Archon.Domain.{Task, TaskDef, TaskResult, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Commit
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.Env

  @now 1_000_000

  # IDs unique across the steps of a test.
  defp env, do: Env.new(now: @now, new_id: fn -> "id-#{System.unique_integer([:positive])}" end)

  defp task(type, ref, fields \\ []) do
    struct!(
      %WorkflowTask{
        name: ref,
        task_reference_name: ref,
        type: type,
        task_definition: %TaskDef{name: ref, retry_count: 0, response_timeout_seconds: 0}
      },
      fields
    )
  end

  defp definition(tasks),
    do: %WorkflowDef{name: "wf", version: 1, tasks: tasks, variables: %{"keep" => 1}}

  defp new_workflow(tasks) do
    definition = definition(tasks)

    %Workflow{
      workflow_id: "wf",
      status: :running,
      owner_app: "",
      variables: definition.variables,
      workflow_definition: definition
    }
  end

  defp start(tasks) do
    {{:ok, "wf"}, stored, _pre, commit, _post} =
      Step.run(nil, {:start, new_workflow(tasks)}, env())

    assert apply_commit(nil, commit) == stored
    stored
  end

  defp run(workflow, event) do
    {reply, stored, _pre, commit, _post} = Step.run(workflow, event, env())
    assert apply_commit(workflow, commit) == stored
    {reply, stored, commit}
  end

  defp by_ref(workflow, ref), do: Enum.find(workflow.tasks, &(&1.reference_task_name == ref))

  defp complete(workflow, ref, status \\ :completed, output \\ %{}) do
    task = by_ref(workflow, ref)

    workflow =
      if task.status == :scheduled do
        {%Task{}, workflow, _commit} = run(workflow, {:poll, task.task_id, "w"})
        workflow
      else
        workflow
      end

    result = %TaskResult{
      workflow_instance_id: "wf",
      task_id: task.task_id,
      status: status,
      output_data: output
    }

    run(workflow, {:update, result})
  end

  describe "SET_VARIABLE" do
    test "in the first decide of a start, the definition's variables change too" do
      stored =
        start([
          task("SET_VARIABLE", "set1", input_parameters: %{"a" => 1}),
          task("SET_VARIABLE", "set2", input_parameters: %{"b" => "${workflow.variables.a}"})
        ])

      assert stored.status == :completed
      assert stored.variables == %{"keep" => 1, "a" => 1, "b" => 1}
      assert stored.workflow_definition.variables == stored.variables
    end

    test "after a worker task the decide changes only the variables, and saves them" do
      workflow =
        start([
          task("SIMPLE", "worker"),
          task("SET_VARIABLE", "set", input_parameters: %{"v" => 2})
        ])

      {_task, stored, %Commit{workflow: %Workflow{} = saved}} = complete(workflow, "worker")

      assert stored.status == :completed
      assert saved.variables == %{"keep" => 1, "v" => 2}
      assert stored.variables == saved.variables
      assert stored.workflow_definition.variables == %{"keep" => 1}
    end

    # ADR 0026, decision 2: the decide ends with the JOIN waiting, which saves nothing of its own.
    test "at the end of a FORK branch after a worker task the variables are saved" do
      workflow =
        start([
          task("FORK_JOIN", "fork",
            fork_tasks: [
              [task("SIMPLE", "worker")],
              [
                task("SIMPLE", "first"),
                task("SET_VARIABLE", "set", input_parameters: %{"v" => 3})
              ]
            ]
          ),
          task("JOIN", "join", join_on: ["worker", "set"])
        ])

      {_task, stored, %Commit{workflow: %Workflow{} = saved}} = complete(workflow, "first")

      assert %Task{status: :completed} = by_ref(stored, "set")
      assert %Task{status: :in_progress} = by_ref(stored, "join")
      assert saved.variables == %{"keep" => 1, "v" => 3}
      assert stored.workflow_definition.variables == %{"keep" => 1}
    end

    # Upstream's JOIN is asynchronous: the decide after it reads the workflow again.
    test "a start's decide after its JOIN no longer shares the definition's variables" do
      stored =
        start([
          task("FORK_JOIN", "fork",
            fork_tasks: [
              [task("SET_VARIABLE", "set_a", input_parameters: %{"a" => 1})],
              [task("SET_VARIABLE", "set_b", input_parameters: %{"b" => 2})]
            ]
          ),
          task("JOIN", "join", join_on: ["set_a", "set_b"]),
          task("SET_VARIABLE", "set_c", input_parameters: %{"c" => 3})
        ])

      assert stored.status == :completed
      assert stored.variables == %{"keep" => 1, "a" => 1, "b" => 2, "c" => 3}
      assert stored.workflow_definition.variables == %{"keep" => 1, "a" => 1, "b" => 2}
    end

    # startWorkflowIdempotent (a sub-workflow) queues its decide, which reads the workflow again.
    test "an idempotent start's decide does not share the definition's variables" do
      {{:ok, _created}, workflow, _pre, _commit, _post} =
        Step.run(
          nil,
          {:start_idempotent,
           new_workflow([task("SET_VARIABLE", "set", input_parameters: %{"v" => 4})])},
          env()
        )

      {_reply, stored, _commit} = run(workflow, :wake)

      assert stored.variables == %{"keep" => 1, "v" => 4}
      assert stored.workflow_definition.variables == %{"keep" => 1}
    end

    test "too large variables fail the task and the workflow, keeping the variables" do
      big = String.duplicate("x", 300 * 1024)
      stored = start([task("SET_VARIABLE", "set", input_parameters: %{"big" => big})])

      assert %Task{status: :failed_with_terminal_error, reason_for_incompletion: reason} =
               by_ref(stored, "set")

      assert reason =~ "The variables payload size: #{300 * 1024 + 19} of workflow: wf"
      assert stored.status == :failed
      assert stored.variables == %{"keep" => 1}
      assert stored.workflow_definition.variables == %{"keep" => 1}
    end
  end

  describe "TERMINATE (LambdaAndTerminateTaskSpec)" do
    defp terminate(status, fields \\ []) do
      task(
        "TERMINATE",
        "end",
        Keyword.merge(
          [
            input_parameters: %{
              "terminationStatus" => status,
              "workflowOutput" => %{"result" => "${workflow.input.v}"}
            }
          ],
          fields
        )
      )
    end

    test "COMPLETED completes the workflow with the workflow output, canceling a running branch" do
      stored =
        start([
          task("FORK_JOIN", "fork",
            fork_tasks: [[task("SIMPLE", "worker")], [terminate("COMPLETED")]]
          ),
          task("JOIN", "join", join_on: ["worker", "end"])
        ])

      assert stored.status == :completed
      assert stored.output == %{"result" => nil}
      assert %Task{status: :completed, output_data: %{"result" => nil}} = by_ref(stored, "end")
      assert %Task{status: :canceled} = by_ref(stored, "worker")
    end

    test "FAILED fails the workflow with the termination reason" do
      stored =
        start([
          task("SIMPLE", "worker"),
          terminate("FAILED",
            input_parameters: %{"terminationStatus" => "FAILED", "terminationReason" => "stop"}
          )
        ])

      {_task, stored, _commit} = complete(stored, "worker")

      assert stored.status == :failed
      assert stored.reason_for_incompletion == "stop"
      assert %Task{status: :completed} = by_ref(stored, "end")
    end

    test "TERMINATED inside a SWITCH branch terminates the workflow" do
      stored =
        start([
          task("SWITCH", "switch",
            evaluator_type: "value-param",
            expression: "route",
            input_parameters: %{"route" => "x"},
            decision_cases: %{"x" => [terminate("TERMINATED")]}
          ),
          task("SIMPLE", "after")
        ])

      assert stored.status == :terminated
      assert stored.reason_for_incompletion =~ "Workflow is TERMINATED by TERMINATE task: "
      assert by_ref(stored, "after") == nil
    end

    # Upstream's execute answers false with the task FAILED (ADR 0026, decision 2): the task is
    # kept, and the decide it caused fails the workflow and saves it.
    test "a status that is not valid fails the task, which is saved, and then the workflow" do
      stored = start([terminate("PAUSED")])

      assert %Task{
               status: :failed,
               reason_for_incompletion: "given termination status is not valid"
             } =
               by_ref(stored, "end")

      assert stored.status == :failed
    end
  end

  describe "NOOP and HUMAN" do
    test "NOOP completes in the decide" do
      stored = start([task("NOOP", "noop"), task("NOOP", "noop2")])
      assert stored.status == :completed
      assert Enum.all?(stored.tasks, &(&1.status == :completed and &1.task_type == "NOOP"))
    end

    test "HUMAN waits IN_PROGRESS, without a queue, for a task update" do
      {{:ok, "wf"}, workflow, _pre, commit, post} =
        Step.run(nil, {:start, new_workflow([task("HUMAN", "human")])}, env())

      assert apply_commit(nil, commit) == workflow
      refute Enum.any?(post, &match?({:queue_push, _, _, _, _}, &1))
      assert [%Task{task_type: "HUMAN", status: :in_progress}] = workflow.tasks

      {_reply, still, _commit} = run(workflow, :wake)
      assert [%Task{status: :in_progress}] = still.tasks

      {_task, stored, _commit} = complete(workflow, "human", :completed, %{"approved" => true})
      assert stored.status == :completed
      assert [%Task{status: :completed, output_data: %{"approved" => true}}] = stored.tasks
    end

    test "terminating the workflow cancels a HUMAN task" do
      workflow = start([task("HUMAN", "human")])
      {:ok, stored, _commit} = run(workflow, {:terminate, "stop"})
      assert stored.status == :terminated
      assert [%Task{status: :canceled}] = stored.tasks
    end
  end

  describe "EXCLUSIVE_JOIN (ExclusiveJoinSpec)" do
    defp switch(route, permissive? \\ false) do
      [
        task("SWITCH", "switch",
          evaluator_type: "value-param",
          expression: "route",
          input_parameters: %{"route" => route},
          decision_cases: %{
            "a" => [task("SIMPLE", "a")],
            "b" => [task("SIMPLE", "b", permissive: permissive?)]
          },
          default_case: [task("SIMPLE", "c")]
        ),
        task("EXCLUSIVE_JOIN", "xjoin", join_on: ["a", "b"], default_exclusive_join_task: ["c"]),
        task("SIMPLE", "after", input_parameters: %{"joined" => "${xjoin.output.from}"})
      ]
    end

    test "the branch that ran is joined and its output passed on" do
      {_task, stored, _commit} = complete(start(switch("b")), "b", :completed, %{"from" => "b"})

      assert %Task{status: :completed, output_data: %{"from" => "b"}} = by_ref(stored, "xjoin")
      assert %Task{status: :scheduled, input_data: %{"joined" => "b"}} = by_ref(stored, "after")
    end

    test "the default case is joined through defaultExclusiveJoinTask" do
      {_task, stored, _commit} =
        complete(start(switch("none")), "c", :completed, %{"from" => "c"})

      assert %Task{status: :completed, output_data: %{"from" => "c"}} = by_ref(stored, "xjoin")
      assert %Task{input_data: %{"joined" => "c"}} = by_ref(stored, "after")
    end

    # Upstream throws a NullPointerException here (the captured p7_exclusive_join_failed_*):
    # a deliberate difference (ADR 0026, decision 3).
    test "a failed permissive branch completes the join, and the workflow fails at its end" do
      {_task, stored, _commit} =
        complete(start(switch("b", true)), "b", :failed, %{"from" => "b"})

      assert %Task{status: :failed} = by_ref(stored, "b")
      assert %Task{status: :completed, output_data: %{"from" => "b"}} = by_ref(stored, "xjoin")
      assert %Task{input_data: %{"joined" => "b"}} = by_ref(stored, "after")
      assert stored.status == :running

      {_task, stored, _commit} = complete(stored, "after")
      assert stored.status == :failed

      assert stored.reason_for_incompletion ==
               "Task #{by_ref(stored, "b").task_id} failed with status: FAILED and reason: 'null'"
    end
  end
end
