# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/model/BulkResponse.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; the successful
# results are names or IDs, or workflows encoded by the caller.

defmodule Archon.Domain.BulkResponse do
  @moduledoc """
  Upstream's generic `BulkResponse<T>`: the results that succeeded, in request order, and the
  error message for each name or ID that failed.

  It answers `PUT /api/metadata/workflow` (ADR 0023, decision 3) and the bulk workflow operations
  (ADR 0025, decision 6) with names or IDs, and `POST /api/workflow/bulk/search` (ADR 0027,
  decision 5) with workflows, which `to_json/2` encodes with the caller's function (upstream's
  `WorkflowModel` shape). Decoding reads names or IDs only.

  Upstream's `message` field has no getter, so it is never written. `bulkErrorResults` is a map
  by name: a later failure with the same name replaces the earlier one, as upstream's `put`.
  """

  alias Archon.Domain.Codec

  @fields [
    {:bulk_error_results, "bulkErrorResults", :string_map, default: %{}},
    {:bulk_successful_results, "bulkSuccessfulResults", {:list, :string}, default: []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: t(String.t())

  @type t(result) :: %__MODULE__{
          bulk_error_results: %{optional(String.t()) => String.t()},
          bulk_successful_results: [result]
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc """
  Encodes to upstream JSON. With `encode_result`, each successful result is encoded by it
  (results that are not strings); without, they are the strings they are.
  """
  @spec to_json(t(term()), (term() -> Codec.json()) | nil) :: Codec.json_object()
  def to_json(response, encode_result \\ nil)

  def to_json(%__MODULE__{} = response, nil), do: Codec.encode(__MODULE__, @fields, response)

  def to_json(%__MODULE__{bulk_successful_results: results} = response, encode_result)
      when is_function(encode_result, 1) do
    __MODULE__
    |> Codec.encode(@fields, %{response | bulk_successful_results: []})
    |> Map.put("bulkSuccessfulResults", Enum.map(results, encode_result))
  end

  @doc "Upstream `appendFailedResponse`."
  @spec failure(t(term()), String.t(), String.t()) :: t(term())
  def failure(%__MODULE__{} = response, name, message),
    do: %{response | bulk_error_results: Map.put(response.bulk_error_results, name, message)}
end
