# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/run/SearchResult.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec, for tasks only.

defmodule Archon.Domain.SearchResult do
  @moduledoc """
  The answer of `GET /api/workflow/{workflowId}/tasks` (ADR 0025, decision 4): the number of
  matching tasks and one page of them.

  Upstream's `SearchResult<T>` is generic; Archon answers it only with tasks
  (`SearchResult<Task>`), so `results` holds `Archon.Domain.Task` structs.
  """

  alias Archon.Domain.{Codec, Task}

  @fields [
    {:total_hits, "totalHits", :int, default: 0},
    {:results, "results", {:list, {:struct, Task}}, []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{total_hits: integer(), results: [Task.t()] | nil}

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc """
  Encodes to upstream JSON. `now_ms` is passed to `Archon.Domain.Task.to_json/2` for each task's
  `queueWaitTime`.
  """
  @spec to_json(t(), integer()) :: Codec.json_object()
  def to_json(%__MODULE__{} = result, now_ms \\ System.system_time(:millisecond)) do
    json = Codec.encode(__MODULE__, @fields, %{result | results: nil})

    case result.results do
      nil -> json
      tasks -> Map.put(json, "results", Enum.map(tasks, &Task.to_json(&1, now_ms)))
    end
  end
end
