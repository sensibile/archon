# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/Lambda.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the finished task instead of mutating it; evaluates through the
# injected evaluate_script (ADR 0026, decision 5).

defmodule Archon.Decider.SystemTask.Lambda do
  @moduledoc """
  Upstream `Lambda#execute` (deprecated upstream in favour of `INLINE`): runs the task input's
  `scriptExpression` as the body of a function, `function scriptFun(){<body>} scriptFun();`,
  with the task input as `$` (ADR 0015), and completes with the output `result`.

  Every failure is `FAILED`, as upstream catches every exception: a blank `scriptExpression`
  (`reasonForIncompletion` only), one that is not a string (the message of the
  `ClassCastException` upstream catches) and any evaluation error (`reasonForIncompletion` and
  the output `error`). ADR 0026, decision 5.
  """

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.{Context, SystemTask}
  alias Archon.Decider.SystemTask.Inline
  alias Archon.Domain.{Task, Validation}
  alias Archon.Script

  @impl true
  def execute(_workflow, %Task{input_data: input} = task, %Context{} = context) do
    case Map.get(input, "scriptExpression") do
      script when is_binary(script) or is_nil(script) ->
        if Validation.java_blank?(script),
          do:
            failed(
              task,
              "Empty 'scriptExpression' in Lambda task's input parameters. " <>
                "A non-empty String value must be provided."
            ),
          else: evaluate(task, script, input, context.evaluate_script)

      script ->
        failed_with_error(task, Inline.string_cast_message(script))
    end
  end

  defp evaluate(task, script, input, evaluate_script) do
    case evaluate_script.(:eval, "function scriptFun(){" <> script <> "} scriptFun();", input) do
      {:ok, result} ->
        SystemTask.changed(%{
          task
          | output_data: Map.put(task.output_data, "result", Script.storable(result)),
            status: :completed
        })

      {:error, %Script.Error{} = error} ->
        failed_with_error(task, Exception.message(error))
    end
  end

  defp failed(task, message),
    do: SystemTask.changed(%{task | status: :failed, reason_for_incompletion: message})

  defp failed_with_error(task, message) do
    task
    |> Map.update!(:output_data, &Map.put(&1, "error", message))
    |> failed(message)
  end
end
