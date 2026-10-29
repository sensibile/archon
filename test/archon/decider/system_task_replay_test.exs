# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Decider.SystemTaskReplayTest do
  @moduledoc """
  Replays the captured SWITCH and FORK_JOIN scenarios through `Archon.Decider.decide/2` and
  `Archon.Decider.SystemTask.execute/2` and compares the workflow with what the upstream server
  returned (ADR 0014, decision 8, slice 2c). The runtime is played by `Archon.DeciderReplay`.

  In the FORK_JOIN scenario the branch updates skip the decide (`isLazyEvaluateWorkflow`) and the
  `JOIN` is evaluated three times, once after it is scheduled and once after each branch, as its
  `pollCount` on the server shows. The decide after the `JOIN` completes ends the workflow
  without persisting tasks, which is why the branches and the `JOIN` keep `executed: false`.
  """

  use ExUnit.Case, async: true

  import Archon.DeciderReplay

  alias Archon.Contract
  alias Archon.Decider.Parameters

  test "the SWITCH scenario takes case b and ends as the upstream server's workflow" do
    start = Contract.fixture("workflow_start_request_switch")
    request = start["request"]["body"]
    definition = populated_definition("metadata_get_workflow_switch")
    clock = clock()

    workflow =
      start(
        definition,
        [
          workflow_id: start["response"]["body"],
          correlation_id: request["correlationId"],
          input: Parameters.workflow_input(definition, request["input"])
        ],
        clock
      )

    assert [%{task_type: "SWITCH", status: :completed, executed: true}, %{status: :scheduled}] =
             workflow.tasks

    workflow =
      workflow
      |> poll("case_b_ref", clock)
      |> update("case_b_ref", Contract.fixture("task_update_switch_b"), clock)

    assert workflow.status == :completed
    assert_matches(workflow, "workflow_get_completed_switch")
  end

  test "the FORK_JOIN scenario joins both branches and ends as the upstream server's workflow" do
    start = Contract.fixture("workflow_start_fork")
    definition = populated_definition("metadata_get_workflow_fork")
    clock = clock()

    workflow =
      definition
      |> start(
        [
          workflow_id: start["response"]["body"],
          input: Parameters.workflow_input(definition, start["request"]["body"])
        ],
        clock
      )
      |> run_async(clock)

    assert ["FORK", "archon_task_a", "archon_task_b", "JOIN"] =
             Enum.map(workflow.tasks, & &1.task_type)

    workflow =
      workflow
      |> poll("branch_a_ref", clock)
      |> update("branch_a_ref", Contract.fixture("task_update_fork_a"), clock)
      |> run_async(clock)

    assert %{status: :running} = workflow

    workflow =
      workflow
      |> poll("branch_b_ref", clock)
      |> update("branch_b_ref", Contract.fixture("task_update_fork_b"), clock)
      |> run_async(clock)

    assert workflow.status == :completed
    assert_matches(workflow, "workflow_get_completed_fork")
  end
end
