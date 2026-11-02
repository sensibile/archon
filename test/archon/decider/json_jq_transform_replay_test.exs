# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Decider.JsonJqTransformReplayTest do
  @moduledoc """
  Replays the captured `JSON_JQ_TRANSFORM` scenarios (`p7_jq_*`) through
  `Archon.Runtime.Step.run/3` with the `archon_jq` pool and compares the stored workflow with what
  the upstream server returned (ADR 0026, decisions 6 and 8).

  The workflow starts from the definition the server stored (`workflowDefinition` of the
  workflow GET) and ends with its first decide: the query runs when the task is scheduled.
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay

  alias Archon.Contract
  alias Archon.Decider.Parameters
  alias Archon.Domain.{Workflow, WorkflowDef}

  defp replay(scenario) do
    start = Contract.fixture("#{scenario}_start")
    stored = Contract.fixture("#{scenario}_get")["response"]["body"]
    {:ok, definition} = WorkflowDef.from_json(stored["workflowDefinition"])

    start(
      definition,
      [
        workflow_id: start["response"]["body"],
        input: Parameters.workflow_input(definition, start["request"]["body"])
      ],
      clock()
    )
  end

  test "several results: the first is result, all of them resultList, numbers as upstream's" do
    workflow = replay("p7_jq")
    assert workflow.status == :completed
    assert [%{status: :completed, output_data: output}] = workflow.tasks
    assert output == %{"result" => %{"v" => 2}, "resultList" => [%{"v" => 2}, %{"v" => 5}]}
    assert_matches(workflow, "p7_jq_get")
  end

  test "a null result" do
    assert_matches(replay("p7_jq_null"), "p7_jq_null_get")
  end

  test "no queryExpression fails the task and the workflow" do
    assert_matches(replay("p7_jq_missing"), "p7_jq_missing_get")
  end

  test "a queryExpression that is not a string fails the scheduling: workflow FAILED, task CANCELED" do
    workflow = replay("p7_jq_not_string")
    assert [%{status: :canceled, task_id: task_id}] = workflow.tasks

    assert workflow.reason_for_incompletion ==
             "Error scheduling tasks: [#{task_id}], for workflow: #{workflow.workflow_id}"

    assert_matches(workflow, "p7_jq_not_string_get")
  end

  # The message is jq's, not jackson-jq's (ADR 0026, decision 6); the rest is the server's.
  test "a syntax error fails the task with jq's message" do
    workflow = replay("p7_jq_syntax")
    [task] = workflow.tasks

    message =
      "syntax error, unexpected end of file at <top-level>, line 1, column 7:\n" <>
        "    .items[\n          ^"

    assert task.status == :failed
    assert task.reason_for_incompletion == message
    assert task.output_data == %{"error" => message}

    expected = Contract.fixture("p7_jq_syntax_get")["response"]["body"]
    upstream = expected["tasks"] |> hd() |> Map.fetch!("reasonForIncompletion")

    expected =
      expected
      |> put_in(
        ["reasonForIncompletion"],
        String.replace(expected["reasonForIncompletion"], upstream, message)
      )
      |> put_in(["output", "error"], message)
      |> update_in(["tasks"], fn [task] ->
        [%{task | "reasonForIncompletion" => message, "outputData" => %{"error" => message}}]
      end)

    actual = workflow |> Workflow.to_json() |> JSON.encode!() |> JSON.decode!()
    assert Contract.normalize(actual) == Contract.normalize(expected)
  end
end
