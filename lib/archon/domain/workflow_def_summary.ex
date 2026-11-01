# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/workflow/WorkflowDefSummary.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.WorkflowDefSummary do
  @moduledoc """
  A workflow definition's name, version and audit times, without its body
  (`GET /api/metadata/workflow/names-and-versions` and `{name}/versions`, ADR 0025 decision 6).

  `createTime` and `updateTime` are boxed `Long`s: a `nil` one is not written (`{name}/versions`
  leaves `updateTime` out).
  """

  alias Archon.Domain.Codec

  @fields [
    {:name, "name", :string, []},
    {:version, "version", :int, default: 1},
    {:create_time, "createTime", :integer, []},
    {:update_time, "updateTime", :integer, []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          name: String.t() | nil,
          version: integer(),
          create_time: integer() | nil,
          update_time: integer() | nil
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = summary), do: Codec.encode(__MODULE__, @fields, summary)
end
