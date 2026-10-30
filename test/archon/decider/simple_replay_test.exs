# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Decider.SimpleReplayTest do
  @moduledoc """
  Replays the captured SIMPLE scenario (`workflow_start_simple`, `task_poll_simple_*`,
  `task_update_simple_a`, `task_update_v2_simple_b`) through `Archon.Runtime.Step.run/3` and
  compares the stored workflow with what the upstream server returned (ADR 0014, decision 8;
  ADR 0018, decision 10).
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay

  alias Archon.Contract
  alias Archon.Decider.Parameters

  test "the SIMPLE scenario ends as the upstream server's workflow" do
    start = Contract.fixture("workflow_start_simple")
    [_path, query] = String.split(start["request"]["path"], "?")
    %{"correlationId" => correlation_id} = URI.decode_query(query)

    definition = populated_definition("metadata_get_workflow")
    clock = clock()

    workflow =
      definition
      |> start(
        [
          workflow_id: start["response"]["body"],
          correlation_id: correlation_id,
          input: Parameters.workflow_input(definition, start["request"]["body"])
        ],
        clock
      )
      |> poll("task_a_ref", clock)

    assert_matches(workflow, "workflow_get_running")

    workflow =
      workflow
      |> update("task_a_ref", Contract.fixture("task_update_simple_a"), clock)
      |> poll("task_b_ref", clock)
      |> update("task_b_ref", Contract.fixture("task_update_v2_simple_b"), clock)

    assert workflow.status == :completed
    assert_matches(workflow, "workflow_get_completed_simple")
  end
end
