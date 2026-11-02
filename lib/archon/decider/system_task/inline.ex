# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/Inline.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the finished task instead of mutating it; evaluates through
# Archon.Decider.Evaluator and the injected evaluate_script; an input that is not a string fails
# the task instead of throwing out of the decide (ADR 0026, decision 5).

defmodule Archon.Decider.SystemTask.Inline do
  @moduledoc """
  Upstream `Inline#execute`: evaluates the task input's `expression` with the evaluator its
  `evaluatorType` names (`javascript` when absent) and completes with the output `result`
  (ADR 0026, decision 5).

  The evaluators are `Archon.Decider.Evaluator`'s: `javascript` and `graaljs` run the script
  with the task input as `$` (ADR 0015), `value-param` reads the input key the expression names.
  A failure sets the output `error` and `reasonForIncompletion` to the same message. As in
  upstream, the status follows what failed:

    * `FAILED_WITH_TERMINAL_ERROR` - a blank `evaluatorType`, an evaluator that is not registered
      (`python` too, ADR 0015 decision 5), a blank `expression`, or a script that throws or does
      not parse (upstream's `TerminateWorkflowException`);
    * `FAILED` - anything else: the time limit, the result could not be read, the evaluator pool
      could not take the request.

  An `evaluatorType` or `expression` that is not a string fails the task with `FAILED` and the
  message of upstream's `ClassCastException`, which upstream throws out of the decide instead
  (its start answers 500 and leaves no workflow).
  """

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.{Context, Evaluator, SystemTask}
  alias Archon.Domain.{Task, Validation}
  alias Archon.Script

  @impl true
  def execute(_workflow, %Task{input_data: input} = task, %Context{} = context) do
    # Only null takes the default: false is cast like any other value that is not a string.
    evaluator_type =
      case Map.get(input, "evaluatorType") do
        nil -> "javascript"
        value -> value
      end

    expression = Map.get(input, "expression")

    with :ok <- string(evaluator_type),
         :ok <- string(expression),
         :ok <- check_evaluator_type(evaluator_type),
         :ok <- check_expression(expression),
         {:ok, result} <-
           evaluate(evaluator_type, expression, input, context.evaluate_script) do
      SystemTask.changed(%{
        task
        | output_data: Map.put(task.output_data, "result", Script.storable(result)),
          status: :completed
      })
    else
      {:error, status, message} ->
        SystemTask.changed(%{
          task
          | status: status,
            reason_for_incompletion: message,
            output_data: Map.put(task.output_data, "error", message)
        })
    end
  end

  # The casts upstream makes before its try.
  defp string(value) when is_binary(value) or is_nil(value), do: :ok
  defp string(value), do: {:error, :failed, string_cast_message(value)}

  defp check_evaluator_type(evaluator_type) do
    cond do
      Validation.java_blank?(evaluator_type) ->
        terminal(
          "Empty 'evaluatorType' in INLINE task's input parameters. " <>
            "A non-empty String value must be provided."
        )

      not Evaluator.registered?(evaluator_type) ->
        terminal("Unknown evaluator '#{evaluator_type}' in INLINE task.")

      true ->
        :ok
    end
  end

  defp check_expression(expression) do
    if Validation.java_blank?(expression),
      do:
        terminal(
          "Empty 'expression' in Inline task's input parameters. " <>
            "A non-empty String value must be provided."
        ),
      else: :ok
  end

  defp evaluate(evaluator_type, expression, input, evaluate_script) do
    case Evaluator.evaluate(evaluator_type, expression, input, evaluate_script) do
      {:ok, result} ->
        {:ok, result}

      # ScriptEvaluator.handlePolyglotException throws TerminateWorkflowException.
      {:error, %Script.Error{kind: kind} = error} when kind in [:syntax, :runtime] ->
        terminal(Exception.message(error))

      {:error, %Script.Error{} = error} ->
        {:error, :failed, Exception.message(error)}

      :unregistered ->
        terminal("Unknown evaluator '#{evaluator_type}' in INLINE task.")
    end
  end

  defp terminal(message), do: {:error, :failed_with_terminal_error, message}

  @doc false
  # The message of upstream's ClassCastException when it casts this JSON value to a String: the
  # class is the one Jackson gives the untyped value (checked against the upstream server).
  @spec string_cast_message(boolean() | number() | list() | map()) :: String.t()
  def string_cast_message(value) do
    class = java_class(value)

    "class #{class} cannot be cast to class java.lang.String (#{class} and java.lang.String " <>
      "are in module java.base of loader 'bootstrap')"
  end

  defp java_class(value) when is_boolean(value), do: "java.lang.Boolean"
  defp java_class(value) when is_map(value), do: "java.util.LinkedHashMap"
  defp java_class(value) when is_list(value), do: "java.util.ArrayList"
  defp java_class(value) when is_float(value), do: "java.lang.Double"
  defp java_class(value) when value in -2_147_483_648..2_147_483_647, do: "java.lang.Integer"

  defp java_class(value) when value in -9_223_372_036_854_775_808..9_223_372_036_854_775_807,
    do: "java.lang.Long"

  defp java_class(value) when is_integer(value), do: "java.math.BigInteger"
end
