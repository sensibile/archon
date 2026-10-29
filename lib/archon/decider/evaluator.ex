# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/evaluators/Evaluator.java
# and core/.../execution/evaluators/ValueParamEvaluator.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the Spring bean map became a function over the registered type; only
# value-param is registered (ADR 0014, decision 6).

defmodule Archon.Decider.Evaluator do
  @moduledoc """
  `SWITCH` expression evaluators by `evaluatorType` (upstream `Evaluator` beans).

  Only `value-param` is registered: the expression names a key of the task input and the result
  is its value (`nil` when absent). `javascript`, `graaljs` and `python` wait for the script
  evaluator ADR (ADR 0014, decision 6); `evaluate/3` answers `:unregistered` for them as for any
  other type.
  """

  alias Archon.Domain.Codec

  @doc "Evaluates `expression` against the task input with the evaluator of `type`."
  @spec evaluate(String.t() | nil, String.t() | nil, Codec.json_object()) ::
          {:ok, Codec.json()} | :unregistered
  def evaluate("value-param", expression, input) when is_map(input),
    do: {:ok, Map.get(input, expression)}

  def evaluate(_type, _expression, _input), do: :unregistered
end
