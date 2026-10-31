# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/tasks/ExecutionMetadata.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.ExecutionMetadata do
  @moduledoc """
  Worker-reported timing measurements attached to a task (`Task.executionMetadata`,
  `TaskResult.executionMetadata`).

  Upstream's getters add three derived keys on the wire, reproduced by `to_json/1`:
  `additionalContextMap` (same map as `additionalContext`), `empty` (no data at all) and
  `executionDuration` (end minus start, only when both are set).
  """

  alias Archon.Domain.Codec

  @fields [
    {:server_send_time, "serverSendTime", :integer, []},
    {:client_receive_time, "clientReceiveTime", :integer, []},
    {:execution_start_time, "executionStartTime", :integer, []},
    {:execution_end_time, "executionEndTime", :integer, []},
    {:client_send_time, "clientSendTime", :integer, []},
    {:poll_network_latency, "pollNetworkLatency", :integer, []},
    {:update_network_latency, "updateNetworkLatency", :integer, []},
    # setAdditionalContext replaces null with an empty map.
    {:additional_context, "additionalContext", :object, default: %{}, null: :default}
  ]

  @timings ~w(server_send_time client_receive_time execution_start_time execution_end_time
              client_send_time poll_network_latency update_network_latency)a

  defstruct Codec.defaults(@fields)

  @doc false
  @spec __fields__() :: [Codec.field()]
  def __fields__, do: @fields

  @type t :: %__MODULE__{
          server_send_time: integer() | nil,
          client_receive_time: integer() | nil,
          execution_start_time: integer() | nil,
          execution_end_time: integer() | nil,
          client_send_time: integer() | nil,
          poll_network_latency: integer() | nil,
          update_network_latency: integer() | nil,
          additional_context: Codec.json_object()
        }

  @doc """
  Decodes upstream JSON. `additionalContextMap` is accepted as an alias of `additionalContext`
  (upstream has setters for both).
  """
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ [])

  def from_json(%{"additionalContextMap" => context} = json, path)
      when not is_map_key(json, "additionalContext") do
    Codec.decode(__MODULE__, @fields, Map.put(json, "additionalContext", context), path)
  end

  def from_json(json, path), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON, including the derived getter keys."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = metadata) do
    json =
      __MODULE__
      |> Codec.encode(@fields, metadata)
      |> Map.merge(%{
        "additionalContextMap" => metadata.additional_context,
        "empty" => not data?(metadata)
      })

    case execution_duration(metadata) do
      nil -> json
      duration -> Map.put(json, "executionDuration", duration)
    end
  end

  @doc "Upstream `hasData`: any timing is set or the additional context is non-empty."
  @spec data?(t()) :: boolean()
  def data?(%__MODULE__{} = metadata) do
    Enum.any?(@timings, &(Map.fetch!(metadata, &1) != nil)) or
      map_size(metadata.additional_context) > 0
  end

  @doc "The metadata if it carries data, else `nil` (upstream `getExecutionMetadataIfHasData`)."
  @spec with_data(t() | nil) :: t() | nil
  def with_data(%__MODULE__{} = metadata), do: if(data?(metadata), do: metadata)
  def with_data(nil), do: nil

  @doc "Upstream `getExecutionDuration`: end minus start when both are known."
  @spec execution_duration(t()) :: integer() | nil
  def execution_duration(%__MODULE__{execution_start_time: start, execution_end_time: finish})
      when is_integer(start) and is_integer(finish),
      do: finish - start

  def execution_duration(%__MODULE__{}), do: nil
end
