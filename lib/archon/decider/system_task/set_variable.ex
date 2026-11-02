# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/SetVariable.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the updated task and workflow instead of mutating them and
# saving the workflow (ADR 0026, decision 2); the payload size is counted without writing the
# JSON.

defmodule Archon.Decider.SystemTask.SetVariable do
  @moduledoc """
  Upstream `SetVariable#execute`: puts every key of the task input into the workflow's
  `variables` and completes the task (ADR 0026, decision 3).

  When the variables, serialized as Jackson does, are more than
  `max_workflow_variables_payload_kb` kilobytes, the variables stay as they were and the task
  ends `FAILED_WITH_TERMINAL_ERROR` with `The variables payload size: <bytes> of workflow: <id>
  is greater than the permissible limit: <kb> kilobytes`. Only a successful execute answers the
  workflow, which the runtime saves (upstream's `updateWorkflow`); an empty input does too.
  """

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.{Context, Parameters, SystemTask}
  alias Archon.Domain.{Task, Workflow}

  @impl true
  def execute(%Workflow{} = workflow, %Task{input_data: input} = task, %Context{} = context) do
    variables = Map.merge(workflow.variables || %{}, input || %{})
    limit = context.max_workflow_variables_payload_kb
    size = json_size(variables)

    if input not in [nil, %{}] and size > limit * 1024 do
      reason =
        "The variables payload size: #{size} of workflow: #{Parameters.java_string(workflow.workflow_id)} " <>
          "is greater than the permissible limit: #{limit} kilobytes"

      SystemTask.changed(%{
        task
        | reason_for_incompletion: reason,
          status: :failed_with_terminal_error
      })
    else
      %SystemTask.Result{
        changed?: true,
        task: %{task | status: :completed},
        workflow: %{workflow | variables: variables}
      }
    end
  end

  @doc """
  The number of bytes Jackson's `ObjectMapper#writeValue` writes for a JSON value: compact, UTF-8,
  only `"`, `\\` and control characters escaped (`\\b \\t \\n \\f \\r` short, the others
  `\\u00XX`), floats as `Double#toString` and non-finite numbers as strings.
  """
  @spec json_size(term()) :: non_neg_integer()
  def json_size(nil), do: 4
  def json_size(true), do: 4
  def json_size(false), do: 5
  def json_size(value) when is_integer(value), do: byte_size(Integer.to_string(value))
  def json_size(value) when is_float(value), do: byte_size(Parameters.java_string(value))

  def json_size(value) when value in [:nan, :infinity, :neg_infinity],
    do: string_size(Parameters.java_string(value))

  def json_size(value) when is_binary(value), do: string_size(value)

  def json_size(list) when is_list(list),
    do: 2 + Enum.sum_by(list, &json_size/1) + max(length(list) - 1, 0)

  def json_size(map) when is_map(map) do
    pairs = Enum.sum_by(map, fn {key, value} -> string_size(key) + 1 + json_size(value) end)
    2 + pairs + max(map_size(map) - 1, 0)
  end

  defp string_size(string), do: 2 + escaped_size(string, 0)

  defp escaped_size(<<>>, size), do: size

  defp escaped_size(<<char, rest::binary>>, size) when char in [?", ?\\, ?\b, ?\t, ?\n, ?\f, ?\r],
    do: escaped_size(rest, size + 2)

  defp escaped_size(<<char, rest::binary>>, size) when char < 0x20,
    do: escaped_size(rest, size + 6)

  defp escaped_size(<<_byte, rest::binary>>, size), do: escaped_size(rest, size + 1)
end
