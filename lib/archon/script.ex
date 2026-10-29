# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/events/ScriptEvaluator.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: scripts run in a separate QuickJS-ng process managed by
# Archon.Script.Pool instead of an in-process GraalJS context (ADR 0015).

defmodule Archon.Script do
  @moduledoc """
  The JavaScript evaluator (upstream `ScriptEvaluator`, ADR 0015).

  Scripts run in `archon_js` processes (QuickJS-ng) owned by `Archon.Script.Pool`, each
  evaluation in a fresh realm with the input bound to the global `$`. The result is the value of
  the last expression, converted as upstream `getObject` converts a GraalJS value:

    * a number is an integer when it is integral and within the Java `long` range, otherwise a
      float; `-0` is the float `-0.0`;
    * `NaN`, `Infinity` and `-Infinity` are `:nan`, `:infinity` and `:neg_infinity` (see
      `t:value/0`); `storable/1` turns them into what upstream stores;
    * `undefined` is `nil`; arrays, typed arrays and `arguments` are lists; a `Map` is a map whose
      keys are converted like values and then turned into strings as Java does
      (`Archon.Decider.Parameters.java_string/1`); `Number`, `String` and `Boolean` objects are
      their primitive; any other object is a map of its own enumerable string-keyed properties
      (a proxy too, even of an array); a `BigInt` is an integer within the `long` range, a float
      when a double holds it exactly, otherwise an empty map.
  """

  alias Archon.Decider.Parameters
  alias Archon.Domain.Codec
  alias Archon.Script.{Error, Pool}

  @typedoc """
  An evaluation result: JSON, plus the three non-finite numbers JSON cannot carry.
  """
  @type value ::
          nil
          | boolean()
          | number()
          | :nan
          | :infinity
          | :neg_infinity
          | String.t()
          | [value()]
          | %{optional(String.t()) => value()}

  @type op :: :eval | :parse

  @typedoc "The `evaluate_script` function of `Archon.Decider.Context`."
  @type evaluator :: (op(), String.t(), Codec.json() -> {:ok, value()} | {:error, Error.t()})

  @doc """
  Runs `op` on the default pool: `:eval` evaluates `script` with `input` bound to `$`, `:parse`
  only checks its syntax (the result is then `nil`).
  """
  @spec evaluate(op(), String.t(), Codec.json()) :: {:ok, value()} | {:error, Error.t()}
  def evaluate(op, script, input), do: Pool.run(Pool, op, script, input)

  @doc "Evaluates `script` with `input` bound to `$` (upstream `ScriptEvaluator.eval`)."
  @spec eval(String.t(), Codec.json()) :: {:ok, value()} | {:error, Error.t()}
  def eval(script, input), do: evaluate(:eval, script, input)

  @doc """
  Upstream `ScriptEvaluator.validateScriptSyntax`: `{:error, reason}` with the engine's syntax
  error message when `script` does not parse. Anything else that stops the check (a time or
  memory limit, an unavailable evaluator) is not a syntax error and counts as valid, as upstream.
  """
  @spec validate_syntax(String.t(), evaluator()) :: :ok | {:error, String.t()}
  def validate_syntax(script, evaluate \\ &evaluate/3) do
    case evaluate.(:parse, script, nil) do
      {:error, %Error{kind: :syntax, reason: reason}} -> {:error, reason}
      _valid_or_not_a_syntax_error -> :ok
    end
  end

  @doc """
  Upstream `ScriptEvaluator.toBoolean`: a boolean as is, a number when it is greater than zero
  (so `Infinity` is true and `NaN` is not), anything else false.
  """
  @spec to_boolean(value()) :: boolean()
  def to_boolean(value) when is_boolean(value), do: value
  def to_boolean(value) when is_number(value), do: value > 0
  def to_boolean(:infinity), do: true
  def to_boolean(_value), do: false

  @doc """
  The value as upstream stores it: Jackson writes the non-finite doubles as the strings `"NaN"`,
  `"Infinity"` and `"-Infinity"` (checked against Jackson 2.18.8 with upstream's
  `ObjectMapperProvider` settings).
  """
  @spec storable(value()) :: Codec.json()
  def storable(:nan), do: "NaN"
  def storable(:infinity), do: "Infinity"
  def storable(:neg_infinity), do: "-Infinity"
  def storable(list) when is_list(list), do: Enum.map(list, &storable/1)
  def storable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, storable(v)} end)
  def storable(value), do: value

  @doc false
  # Decodes a typed value of the archon_js protocol (ADR 0015, decision 2).
  @spec decode_value(term()) :: value()
  def decode_value(["null"]), do: nil
  def decode_value(["bool", value]) when is_boolean(value), do: value
  def decode_value(["int", digits]) when is_binary(digits), do: String.to_integer(digits)
  def decode_value(["float", value]) when is_number(value), do: value / 1
  def decode_value(["nonfinite", "NaN"]), do: :nan
  def decode_value(["nonfinite", "Infinity"]), do: :infinity
  def decode_value(["nonfinite", "-Infinity"]), do: :neg_infinity
  def decode_value(["str", value]) when is_binary(value), do: value
  def decode_value(["list", items]) when is_list(items), do: Enum.map(items, &decode_value/1)

  def decode_value(["map", entries]) when is_list(entries) do
    Map.new(entries, fn [key, value] ->
      {key |> decode_value() |> Parameters.java_string(), decode_value(value)}
    end)
  end
end
