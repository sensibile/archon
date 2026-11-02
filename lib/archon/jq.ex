# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Jq do
  @moduledoc """
  The jq evaluator of `JSON_JQ_TRANSFORM` (ADR 0026, decision 6): jqlang in `archon_jq`
  processes owned by `Archon.Jq.Pool`, one new jq state per query, isolated from the server
  (no environment, no module files, no extra input, a time, memory and output limit; see
  `c_src/archon_jq/archon_jq.c`).

  Results come back as upstream's `extractBody` turns jackson-jq nodes into Java values: a
  number is an integer when it is integral and within the `long` range, otherwise a float, and a
  number jq keeps as written (from the input or the query) is an integer only when it is
  written as one. `NaN` and the infinities are the strings `"NaN"`, `"Infinity"` and
  `"-Infinity"`, as upstream stores a non-finite double.
  """

  alias Archon.Domain.Codec
  alias Archon.Script

  @doc """
  Runs `query` with `input` as `.` on the default pool and answers all its results (the
  `evaluate_jq` of `Archon.Decider.Context`).
  """
  @spec evaluate(String.t(), Codec.json()) :: {:ok, [Codec.json()]} | {:error, Script.Error.t()}
  def evaluate(query, input) when is_binary(query),
    do: Script.Pool.request(Archon.Jq.Pool, %{"op" => "eval", "query" => query, "input" => input})

  @doc """
  The message of a failed query, which `JSON_JQ_TRANSFORM` puts in `reasonForIncompletion` and
  its `error` output. jq's own message for a query that does not compile or raises an error
  (upstream shows jackson-jq's, which reads differently); Archon's for the limits upstream does
  not have.
  """
  @spec message(Script.Error.t()) :: String.t()
  def message(%Script.Error{kind: kind, reason: reason}) when kind in [:syntax, :runtime],
    do: reason

  def message(%Script.Error{kind: :timeout} = error) do
    "JQ query not evaluated within #{seconds(error.timeout)} seconds, interrupted."
  end

  def message(%Script.Error{kind: :limit, reason: reason}), do: "JQ query #{reason}"
  def message(%Script.Error{kind: :crashed, reason: reason}), do: "JQ evaluator #{reason}"
  def message(%Script.Error{reason: reason}), do: "JQ query rejected: #{reason}"

  # As Archon.Script.Error: whole seconds, or the fraction of a test's millisecond limit.
  defp seconds(ms) when rem(ms, 1000) == 0, do: Integer.to_string(div(ms, 1000))
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, [:short])
end
