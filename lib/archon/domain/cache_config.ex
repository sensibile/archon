# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/workflow/CacheConfig.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.CacheConfig do
  @moduledoc "Task output cache settings (`WorkflowTask.cacheConfig`, `WorkflowDef.cacheConfig`)."

  alias Archon.Domain.Codec

  @fields [
    {:key, "key", :string, []},
    {:ttl_in_second, "ttlInSecond", :int, []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{key: String.t() | nil, ttl_in_second: integer()}

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = config), do: Codec.encode(__MODULE__, @fields, config)
end
