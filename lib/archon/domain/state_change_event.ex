# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/workflow/StateChangeEvent.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec and validation function.

defmodule Archon.Domain.StateChangeEvent do
  @moduledoc "An event published when a task changes state (`WorkflowTask.onStateChange`)."

  alias Archon.Domain.{Codec, Validation}

  @fields [
    {:type, "type", :string, []},
    {:payload, "payload", :object, []}
  ]

  defstruct Codec.defaults(@fields)

  @doc false
  @spec __fields__() :: [Codec.field()]
  def __fields__, do: @fields

  @type t :: %__MODULE__{type: String.t() | nil, payload: Codec.json_object() | nil}

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = event), do: Codec.encode(__MODULE__, @fields, event)

  @doc "Bean validation: `type` is `@NotNull`."
  @spec validate(t()) :: Validation.result()
  def validate(%__MODULE__{type: nil}), do: {:error, [{"type", "must not be null"}]}
  def validate(%__MODULE__{}), do: :ok
end
