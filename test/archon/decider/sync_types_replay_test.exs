# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Decider.SyncTypesReplayTest do
  @moduledoc """
  Replays the captured `TERMINATE`, `SET_VARIABLE`, `NOOP`, `HUMAN` and `EXCLUSIVE_JOIN`
  scenarios (`p7_*`) through `Archon.Runtime.Step.run/3` and compares the stored workflow with
  what the upstream server returned (ADR 0026, decisions 3 and 8).

  The definition is the one the server stored in the workflow (task definitions filled in at the
  start), with the registered `variables`: the stored one shows what a `SET_VARIABLE` of the
  start changed (`Archon.Runtime.Step.State`'s `shared_variables?`).
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay

  alias Archon.Contract
  alias Archon.Decider.Parameters
  alias Archon.Domain.{Task, TaskResult, WorkflowDef}

  defp started(scenario, get, clock) do
    start = Contract.fixture(scenario <> "_start")

    {:ok, stored} =
      WorkflowDef.from_json(Contract.fixture(get)["response"]["body"]["workflowDefinition"])

    {:ok, registered} = fixture_workflow_def(stored.name, stored.version)
    definition = %{stored | variables: registered.variables}

    start(
      definition,
      [
        workflow_id: start["response"]["body"],
        input: Parameters.workflow_input(definition, start["request"]["body"]),
        variables: definition.variables || %{}
      ],
      clock
    )
  end

  # A task update as the capture sent it: to the task with the reference name, polled or not.
  defp updated(workflow, ref, fixture, clock) do
    assert [task] =
             Enum.filter(
               workflow.tasks,
               &(&1.reference_task_name == ref and not Task.terminal?(&1.status))
             )

    json = Contract.fixture(fixture)["request"]["body"]
    {:ok, result} = TaskResult.from_json(Map.put(json, "taskId", task.task_id))
    {%Task{}, stored, _pre, _post} = run(workflow, {:update, result}, env(clock))
    stored
  end

  test "TERMINATE ends the workflow with each of the three statuses" do
    for {status, scenario} <- [
          completed: "p7_terminate_completed",
          failed: "p7_terminate_failed",
          terminated: "p7_terminate_terminated"
        ] do
      workflow = started(scenario, scenario <> "_get", clock())
      assert workflow.status == status
      assert_matches(workflow, scenario <> "_get")
    end
  end

  test "SET_VARIABLE overwrites, fails over the size limit, and runs in a FORK branch" do
    for scenario <- ~w(p7_set_variable p7_set_variable_big p7_set_variable_fork) do
      assert_matches(started(scenario, scenario <> "_get", clock()), scenario <> "_get")
    end
  end

  test "NOOP completes" do
    assert_matches(started("p7_noop", "p7_noop_get", clock()), "p7_noop_get")
  end

  test "HUMAN waits IN_PROGRESS until the task update" do
    clock = clock()
    workflow = started("p7_human", "p7_human_get", clock)
    assert_matches(workflow, "p7_human_get")

    workflow = updated(workflow, "human_ref", "p7_human_update", clock)
    assert_matches(workflow, "p7_human_get_completed")
  end

  test "EXCLUSIVE_JOIN joins the case that ran and the default case" do
    for {scenario, ref} <- [
          {"p7_exclusive_join_case", "a_ref"},
          {"p7_exclusive_join_default", "c_ref"}
        ] do
      clock = clock()
      workflow = started(scenario, scenario <> "_get", clock)
      assert_matches(workflow, scenario <> "_get")

      workflow = updated(workflow, ref, scenario <> "_update", clock)
      assert workflow.status == :completed
      assert_matches(workflow, scenario <> "_get_ended")
    end
  end
end
