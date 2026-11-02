# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Decider.ScriptTaskReplayTest do
  @moduledoc """
  Replays the captured INLINE and LAMBDA scenarios (`p7_inline_*`, `p7_lambda_*`) through
  `Archon.Runtime.Step.run/3` and compares the stored workflow with what the upstream server
  returned (ADR 0026, decisions 5 and 8). Both task types are synchronous, so the start's first
  decide ends the workflow.

  The script error scenarios differ only in the engine's own message text (`Cannot read property`
  in GraalJS, `cannot read property` in QuickJS-ng; ADR 0015), which the comparison accounts for.
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay

  alias Archon.Contract
  alias Archon.Domain.{Workflow, WorkflowDef, WorkflowTask}

  @scenarios [
    {"p7_inline_javascript_start", "p7_inline_javascript_get"},
    {"p7_inline_value_param_start", "p7_inline_value_param_get"},
    {"p7_inline_unknown_start", "p7_inline_unknown_get"},
    {"p7_inline_script_error_start", "p7_inline_script_error_get"},
    {"p7_lambda_start", "p7_lambda_get"},
    {"p7_lambda_error_start", "p7_lambda_error_get"},
    {"p7_lambda_empty_start", "p7_lambda_empty_get"}
  ]

  for {start, get} <- @scenarios do
    test "#{start} ends as #{get}" do
      start = Contract.fixture(unquote(start))
      expected = Contract.fixture(unquote(get))["response"]["body"]
      {:ok, definition} = WorkflowDef.from_json(expected["workflowDefinition"])

      workflow =
        start(
          definition,
          [workflow_id: start["response"]["body"], input: start["request"]["body"]],
          clock()
        )

      assert normalized(workflow) == expected |> engine_message() |> Contract.normalize()
    end
  end

  for fixture <- ["p7_inline_evaluator_not_string_start", "p7_inline_expression_not_string_start"] do
    test "#{fixture}: an input that is not a string fails the task instead of the start" do
      start = Contract.fixture(unquote(fixture))
      expected = Contract.fixture("p7_inline_javascript_get")["response"]["body"]
      {:ok, definition} = WorkflowDef.from_json(expected["workflowDefinition"])

      workflow =
        start(definition, [workflow_id: "not-string", input: start["request"]["body"]], clock())

      # Upstream's start answers this 500 and leaves no workflow (ADR 0026, decision 5).
      message = start["response"]["body"]["message"]
      assert workflow.status == :failed
      assert [task] = workflow.tasks
      assert task.status == :failed
      assert task.reason_for_incompletion == message
      assert task.output_data == %{"error" => message}
    end
  end

  test "a LAMBDA reads the result of an INLINE before it, in the same decide" do
    definition = %WorkflowDef{
      name: "script_chain",
      version: 1,
      schema_version: 2,
      tasks: [
        %WorkflowTask{
          name: "inline",
          task_reference_name: "inline_ref",
          type: "INLINE",
          input_parameters: %{"expression" => "$.n * 2", "n" => "${workflow.input.n}"}
        },
        %WorkflowTask{
          name: "lambda",
          task_reference_name: "lambda_ref",
          type: "LAMBDA",
          input_parameters: %{
            "scriptExpression" => "return {sum: $.doubled + 1};",
            "doubled" => "${inline_ref.output.result}"
          }
        }
      ],
      output_parameters: %{"sum" => "${lambda_ref.output.result.sum}"}
    }

    workflow = start(definition, [workflow_id: "chain", input: %{"n" => 20}], clock())

    assert workflow.status == :completed

    assert Enum.map(workflow.tasks, &{&1.task_type, &1.status}) == [
             {"INLINE", :completed},
             {"LAMBDA", :completed}
           ]

    assert workflow.output == %{"sum" => 41}
  end

  defp normalized(%Workflow{} = workflow),
    do: workflow |> Workflow.to_json() |> JSON.encode!() |> JSON.decode!() |> Contract.normalize()

  # GraalJS capitalizes the message QuickJS-ng gives in lower case (ADR 0015).
  defp engine_message(body) do
    body
    |> JSON.encode!()
    |> String.replace("TypeError: Cannot read property", "TypeError: cannot read property")
    |> JSON.decode!()
  end
end
