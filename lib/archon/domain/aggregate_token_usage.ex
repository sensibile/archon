# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/run/AggregateTokenUsage.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.AggregateTokenUsage do
  @moduledoc "LLM token totals of a workflow execution (`Workflow.aggregateTokenUsage`)."

  alias Archon.Domain.Codec

  @fields [
    {:prompt_tokens, "promptTokens", :int, []},
    {:completion_tokens, "completionTokens", :int, []},
    {:total_tokens, "totalTokens", :int, []}
  ]

  defstruct Codec.defaults(@fields)

  @doc false
  @spec __fields__() :: [Codec.field()]
  def __fields__, do: @fields

  @type t :: %__MODULE__{
          prompt_tokens: integer(),
          completion_tokens: integer(),
          total_tokens: integer()
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = usage), do: Codec.encode(__MODULE__, @fields, usage)
end
