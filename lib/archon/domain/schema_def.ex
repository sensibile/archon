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

  alias Archon.Domain.{Codec, Validation}

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

  @doc """
  Whether the schema is a reference by name (ADR 0023, decision 5): no `data` and no
  `externalRef` (a missing key or `null`; `{}` and `""` are present, as for upstream's `null`
  checks in `SchemaService#resolve`) and a `name` that is not blank (`StringUtils.isBlank`).
  Upstream looks such a schema up in `/api/schema` and leaves the payload unchecked when it is
  not registered; any other schema is validated inline or refused.
  """
  @spec name_reference?(t()) :: boolean()
  def name_reference?(%__MODULE__{data: nil, external_ref: nil, name: name}),
    do: not Validation.java_blank?(name)

  def name_reference?(%__MODULE__{}), do: false

  @doc false
  # The refusal shared by `WorkflowDef.check_schema/1` and `TaskDef.check_schema/1` for a
  # definition that enforces its schemas: the first schema that is not a reference by name.
  @spec check(String.t() | nil, input: t() | nil, output: t() | nil) ::
          :ok | {:error, {:invalid, String.t()}}
  def check(definition_name, schemas) do
    Enum.find_value(schemas, :ok, fn {kind, schema} ->
      if schema != nil and not name_reference?(schema) do
        {:error,
         {:invalid,
          "Schema validation is not supported yet: #{definition_name || "null"} #{kind}Schema"}}
      end
    end)
  end
end
