# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/workflow/SubWorkflowParams.java
# and common/.../metadata/workflow/IdempotencyStrategy.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; the
# workflowDefinition setter checks became decode errors.

defmodule Archon.Domain.SubWorkflowParams do
  @moduledoc """
  Parameters of a `SUB_WORKFLOW` task (`WorkflowTask.subWorkflowParam`).

  `workflow_definition` is either an inline `Archon.Domain.WorkflowDef`, a `${...}` expression
  resolved at runtime, or `nil`. With an inline definition, upstream's getters report its name
  and version instead of the `name`/`version` fields, and so does `to_json/1`.

  `priority` is kept as raw JSON: upstream types it `Object` and accepts an integer or an
  expression string.
  """

  alias Archon.Domain.{Codec, WorkflowDef}

  @type idempotency_strategy :: :fail | :return_existing | :fail_on_running

  @fields [
    {:name, "name", :string, []},
    {:version, "version", :integer, []},
    {:task_to_domain, "taskToDomain", :string_map, []},
    {:workflow_definition, "workflowDefinition", :custom, []},
    {:idempotency_key, "idempotencyKey", :string, []},
    {:idempotency_strategy, "idempotencyStrategy",
     {:enum, [:fail, :return_existing, :fail_on_running]}, []},
    {:priority, "priority", :any, []}
  ]

  defstruct Codec.defaults(@fields)

  @doc false
  @spec __fields__() :: [Codec.field()]
  def __fields__, do: @fields

  @type t :: %__MODULE__{
          name: String.t() | nil,
          version: integer() | nil,
          task_to_domain: %{optional(String.t()) => String.t() | nil} | nil,
          workflow_definition: WorkflowDef.t() | String.t() | nil,
          idempotency_key: String.t() | nil,
          idempotency_strategy: idempotency_strategy() | nil,
          priority: Codec.json()
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = params) do
    __MODULE__
    |> Codec.encode(@fields, %{params | name: name(params), version: version(params)})
  end

  @doc "Upstream `getName`: the inline definition's name when there is one."
  @spec name(t()) :: String.t() | nil
  def name(%__MODULE__{workflow_definition: %WorkflowDef{name: name}}), do: name
  def name(%__MODULE__{name: name}), do: name

  @doc "Upstream `getVersion`: the inline definition's version when there is one."
  @spec version(t()) :: integer() | nil
  def version(%__MODULE__{workflow_definition: %WorkflowDef{version: version}}), do: version
  def version(%__MODULE__{version: version}), do: version

  @doc false
  @spec decode_custom(:workflow_definition, Codec.json(), Codec.path(), Codec.opts()) ::
          Codec.result(WorkflowDef.t() | String.t())
  def decode_custom(:workflow_definition, value, path, codec_opts) when is_binary(value) do
    # SubWorkflowParams#setWorkflowDefinition; the storage encoding keeps what was stored.
    if Keyword.get(codec_opts, :internal, false) or
         (String.starts_with?(value, "${") and String.ends_with?(value, "}")) do
      {:ok, value}
    else
      {:error,
       [
         {Codec.format_path(path), "workflowDefinition is a string, but not a valid DSL string"}
       ]}
    end
  end

  def decode_custom(:workflow_definition, value, path, codec_opts) when is_map(value),
    do: Codec.cast({:struct, WorkflowDef}, value, path, codec_opts)

  def decode_custom(:workflow_definition, _value, path, _codec_opts) do
    {:error,
     [
       {Codec.format_path(path),
        "workflowDefinition must be either null, or WorkflowDef, or a valid DSL string"}
     ]}
  end

  @doc false
  @spec encode_custom(:workflow_definition, WorkflowDef.t() | String.t(), Codec.opts()) ::
          Codec.json()
  def encode_custom(:workflow_definition, %WorkflowDef{} = definition, codec_opts),
    do: Codec.encode_value({:struct, WorkflowDef}, definition, codec_opts)

  def encode_custom(:workflow_definition, expression, _codec_opts) when is_binary(expression),
    do: expression
end
