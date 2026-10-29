# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/evaluators/Evaluator.java,
# core/.../execution/evaluators/ValueParamEvaluator.java,
# core/.../execution/evaluators/JavascriptEvaluator.java
# and core/.../execution/evaluators/GraalJSEvaluator.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the Spring bean map became a function over the registered type; the
# script evaluators call the injected evaluate_script (ADR 0014, decision 6; ADR 0015).

defmodule Archon.Decider.Evaluator do
  @moduledoc """
  `SWITCH` expression evaluators by `evaluatorType` (upstream `Evaluator` beans).

    * `value-param` - the expression names a key of the task input and the result is its value
      (`nil` when absent).
    * `javascript` and `graaljs` - the expression is a script evaluated with the task input as
      `$` by the context's `evaluate_script` (ADR 0015). Both use the same engine, as upstream.
      The script sees a copy of the input, so it cannot change it.

  `python` is not registered (ADR 0015, decision 5); `evaluate/4` answers `:unregistered` for it
  as for any other type.
  """

  alias Archon.Domain.Codec
  alias Archon.Script

  @doc "Evaluates `expression` against the task input with the evaluator of `type`."
  @spec evaluate(String.t() | nil, String.t() | nil, Codec.json_object(), Script.evaluator()) ::
          {:ok, Codec.json() | Script.value()} | {:error, Script.Error.t()} | :unregistered
  def evaluate("value-param", expression, input, _evaluate_script) when is_map(input),
    do: {:ok, Map.get(input, expression)}

  def evaluate(type, expression, input, evaluate_script)
      when type in ["javascript", "graaljs"] and is_binary(expression),
      do: evaluate_script.(:eval, expression, input)

  # Upstream builds a GraalJS Source from the null expression and fails with a
  # NullPointerException, which fails the SWITCH task. Registration rejects a SWITCH without an
  # expression, so only a definition stored some other way gets here.
  def evaluate(type, nil, _input, _evaluate_script) when type in ["javascript", "graaljs"],
    do: {:error, %Script.Error{kind: :request, reason: "expression is null"}}

  def evaluate(_type, _expression, _input, _evaluate_script), do: :unregistered
end
