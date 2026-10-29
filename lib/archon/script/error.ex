# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/events/ScriptEvaluator.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the exceptions thrown by ScriptEvaluator.eval became one struct whose
# message is built from the failure kind (ADR 0015).

defmodule Archon.Script.Error do
  @moduledoc """
  A script that could not be evaluated or parsed (ADR 0015).

  `kind` says what went wrong and `reason` carries the engine's own text:

    * `:syntax` - the `parse` operation found a syntax error. Registration checks wrap `reason`
      as upstream wraps `PolyglotException#getMessage`.
    * `:runtime` - the script threw. The message is upstream `handlePolyglotException`'s
      ``Error evaluating the script `<reason>` at line <line>`` (without the line when none is
      known).
    * `:timeout` - the evaluation ran past the time limit. The message is upstream's
      `Script not evaluated within <N> seconds, interrupted.`
    * `:conversion` - reading the result threw (a getter, a proxy trap). Upstream lets that
      `PolyglotException` through unwrapped, so the message is `reason` as is.
    * `:limit` - the result is nested too deeply or too large to send back, or too many
      requests are already waiting for a worker.
    * `:crashed` - the evaluator process exited while evaluating.
    * `:request` - the evaluator rejected the request (an Archon bug, not the script's fault).
  """

  @enforce_keys [:kind, :reason]
  defexception [:kind, :reason, :line, timeout: 4_000]

  @type kind :: :syntax | :runtime | :timeout | :conversion | :limit | :crashed | :request

  @type t :: %__MODULE__{
          kind: kind(),
          reason: String.t(),
          line: pos_integer() | nil,
          timeout: pos_integer()
        }

  @impl true
  def message(%__MODULE__{kind: :timeout, timeout: timeout}),
    do: "Script not evaluated within #{seconds(timeout)} seconds, interrupted."

  def message(%__MODULE__{kind: kind, reason: reason, line: line})
      when kind in [:syntax, :runtime] do
    case line do
      nil -> "Error evaluating the script `#{reason}`"
      line -> "Error evaluating the script `#{reason}` at line #{line}"
    end
  end

  def message(%__MODULE__{kind: :conversion, reason: reason}), do: reason
  def message(%__MODULE__{kind: :limit, reason: reason}), do: "Script #{reason}"
  def message(%__MODULE__{kind: :crashed, reason: reason}), do: "Script evaluator #{reason}"

  def message(%__MODULE__{kind: :request, reason: reason}),
    do: "Script request rejected: #{reason}"

  # Upstream configures whole seconds; a millisecond limit that is not a whole second (tests)
  # shows its fraction.
  defp seconds(ms) when rem(ms, 1000) == 0, do: Integer.to_string(div(ms, 1000))
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, [:short])
end
