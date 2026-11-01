# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/model/BulkResponse.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.BulkResponse do
  @moduledoc """
  The answer of `PUT /api/metadata/workflow` (ADR 0023, decision 3): the names that were stored,
  in request order, and the error message for each name that failed.

  Upstream's `message` field has no getter, so it is never written. `bulkErrorResults` is a map
  by name: a later failure with the same name replaces the earlier one, as upstream's `put`.
  """

  alias Archon.Domain.Codec

  @fields [
    {:bulk_error_results, "bulkErrorResults", :string_map, default: %{}},
    {:bulk_successful_results, "bulkSuccessfulResults", {:list, :string}, default: []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          bulk_error_results: %{optional(String.t()) => String.t()},
          bulk_successful_results: [String.t()]
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = response), do: Codec.encode(__MODULE__, @fields, response)

  @doc "Upstream `appendFailedResponse`."
  @spec failure(t(), String.t(), String.t()) :: t()
  def failure(%__MODULE__{} = response, name, message),
    do: %{response | bulk_error_results: Map.put(response.bulk_error_results, name, message)}
end
