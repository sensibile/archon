# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/SchemaDef.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.SchemaDef do
  @moduledoc """
  Reference to, or inline body of, an input/output schema (`inputSchema`/`outputSchema` on
  workflow and task definitions).

  `version` 0 (the default) means "newest registered version" when used as a reference.
  """

  alias Archon.Domain.Codec

  @type schema_type :: :json | :avro | :protobuf

  @fields [
    {:owner_app, "ownerApp", :string, []},
    # Auditable#getCreateTime/getUpdateTime return 0 for null, so they are always written.
    {:create_time, "createTime", :int, []},
    {:update_time, "updateTime", :int, []},
    {:created_by, "createdBy", :string, []},
    {:updated_by, "updatedBy", :string, []},
    {:name, "name", :string, []},
    {:version, "version", :int, []},
    {:type, "type", {:enum, [:json, :avro, :protobuf]}, []},
    {:data, "data", :object, []},
    {:external_ref, "externalRef", :string, []}
  ]

  defstruct Codec.defaults(@fields)

  @doc false
  @spec __fields__() :: [Codec.field()]
  def __fields__, do: @fields

  @type t :: %__MODULE__{
          owner_app: String.t() | nil,
          create_time: integer(),
          update_time: integer(),
          created_by: String.t() | nil,
          updated_by: String.t() | nil,
          name: String.t() | nil,
          version: integer(),
          type: schema_type() | nil,
          data: Codec.json_object() | nil,
          external_ref: String.t() | nil
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = schema), do: Codec.encode(__MODULE__, @fields, schema)
end
