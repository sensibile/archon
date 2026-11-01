# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/validation/ValidationError.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.ValidationError do
  @moduledoc "One failed constraint in an `Archon.Domain.ErrorResponse` (`validationErrors`)."

  alias Archon.Domain.Codec

  @fields [
    {:path, "path", :string, []},
    {:message, "message", :string, []},
    {:invalid_value, "invalidValue", :string, []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          path: String.t() | nil,
          message: String.t() | nil,
          invalid_value: String.t() | nil
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = error), do: Codec.encode(__MODULE__, @fields, error)
end
