# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss json-jq-task/src/main/java/com/netflix/conductor/tasks/json/JsonJqTransform.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the query runs through the Decider context's evaluate_jq (jqlang in an
# archon_jq process) instead of jackson-jq; start returns the task instead of changing it, and a
# queryExpression that is not a string is a start error instead of a ClassCastException
# (ADR 0026, decision 6).

defmodule Archon.Decider.SystemTask.JsonJqTransform do
  @moduledoc """
  Upstream `JsonJqTransform`: runs the task input's `queryExpression` with the whole task input
  (`queryExpression` included) as `.`, when the task is scheduled (`start/3`).

    * No `queryExpression` (absent or `null`): `FAILED` with
      `Missing 'queryExpression' in input parameters`.
    * Results: `COMPLETED` with the output `result` (the first result, `nil` when there is none)
      and `resultList` (all of them).
    * The query does not compile, raises an error or goes over a limit: `FAILED` with the
      message (`Archon.Jq.message/1`) as `reasonForIncompletion` and the output `error`.
    * A `queryExpression` that is not a string: upstream's cast throws out of `start`, which
      fails the scheduling of the task (`Archon.Runtime.Step.Schedule`), so `start/3` answers
      `{:error, reason}`.

  `execute/3` runs the query again, as upstream's `execute` calls `start`. It is not reached:
  `start` always leaves the task terminal, so the decide loop never executes it.
  """

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.{Context, SystemTask}
  alias Archon.Domain.{Task, Workflow}
  alias Archon.Jq

  @impl true
  def start(%Workflow{}, %Task{input_data: input} = task, %Context{} = context) do
    case Map.get(input, "queryExpression") do
      nil ->
        SystemTask.changed(%{
          task
          | reason_for_incompletion: "Missing 'queryExpression' in input parameters",
            status: :failed
        })

      query when is_binary(query) ->
        SystemTask.changed(run(task, query, input, context))

      _not_a_string ->
        {:error, "queryExpression is not a string"}
    end
  end

  @impl true
  def execute(%Workflow{} = workflow, %Task{} = task, %Context{} = context) do
    case start(workflow, task, context) do
      %SystemTask.Result{} = result -> result
      {:error, _reason} -> SystemTask.unchanged(task)
    end
  end

  defp run(task, query, input, context) do
    case context.evaluate_jq.(query, input) do
      {:ok, results} ->
        output =
          Map.merge(task.output_data, %{"result" => first(results), "resultList" => results})

        %{task | status: :completed, output_data: output}

      {:error, error} ->
        message = Jq.message(error)

        %{
          task
          | status: :failed,
            reason_for_incompletion: message,
            output_data: Map.put(task.output_data, "error", message)
        }
    end
  end

  defp first([result | _rest]), do: result
  defp first([]), do: nil
end
