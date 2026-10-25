# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/workflow/RateLimitConfig.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.RateLimitConfig do
  @moduledoc "Workflow-level concurrency limit (`WorkflowDef.rateLimitConfig`)."

  alias Archon.Domain.Codec

  @type policy :: :queue | :reject

  @fields [
    {:rate_limit_key, "rateLimitKey", :string, []},
    {:concurrent_exec_limit, "concurrentExecLimit", :int, []},
    {:policy, "policy", {:enum, [:queue, :reject]}, default: :queue}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          rate_limit_key: String.t() | nil,
          concurrent_exec_limit: integer(),
          policy: policy() | nil
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = config), do: Codec.encode(__MODULE__, @fields, config)
end
