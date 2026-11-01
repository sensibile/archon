# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/validation/ErrorResponse.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.ErrorResponse do
  @moduledoc """
  The body of every REST error (ADR 0023, decision 4).

  `status` and `retryable` are Java primitives and always written. `instance` (the server host)
  is set by upstream's `ApplicationExceptionMapper` but not by its `ValidationExceptionMapper`,
  so a validation failure has no `instance`. Upstream's mappers never fill `code` or `metadata`.
  """

  alias Archon.Domain.{Codec, ValidationError}

  @fields [
    {:status, "status", :int, []},
    {:code, "code", :string, []},
    {:message, "message", :string, []},
    {:instance, "instance", :string, []},
    {:retryable, "retryable", :bool, []},
    {:validation_errors, "validationErrors", {:list, {:struct, ValidationError}}, []},
    {:metadata, "metadata", :object, []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          status: integer(),
          code: String.t() | nil,
          message: String.t() | nil,
          instance: String.t() | nil,
          retryable: boolean(),
          validation_errors: [ValidationError.t()] | nil,
          metadata: map() | nil
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = response), do: Codec.encode(__MODULE__, @fields, response)
end
