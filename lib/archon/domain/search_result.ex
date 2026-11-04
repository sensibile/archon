# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/run/SearchResult.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; the results are
# tasks, workflows or summary JSON text.

defmodule Archon.Domain.SearchResult do
  @moduledoc """
  Upstream's generic `SearchResult<T>`: the number of matching results and one page of them.

  It answers `GET /api/workflow/{workflowId}/tasks` (ADR 0025, decision 4) with tasks and the
  searches (ADR 0027, decision 5) with tasks, workflows or summaries. A summary is the JSON text
  the search index stored, an `Archon.Domain.SearchResult.Json`, written into the answer as it is
  (ADR 0027, decision 5). Decoding reads tasks only (the shape of the task answers).
  """

  alias Archon.Domain.{Codec, Task, Workflow}

  defmodule Json do
    @moduledoc """
    JSON text written into an encoded answer as it is (a stored summary). The text is not
    checked: it comes from the search index Archon writes (`Archon.Runtime.SearchIndex`).
    """

    @enforce_keys [:text]
    defstruct [:text]

    @type t :: %__MODULE__{text: String.t()}

    defimpl JSON.Encoder do
      def encode(%{text: text}, _encoder), do: text
    end
  end

  @fields [
    {:total_hits, "totalHits", :int, default: 0},
    {:results, "results", {:list, {:struct, Task}}, []}
  ]

  defstruct Codec.defaults(@fields)

  @type result :: Task.t() | Workflow.t() | Json.t()

  @type t :: %__MODULE__{total_hits: integer(), results: [result()] | nil}

  @doc "Decodes upstream JSON whose results are tasks."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc """
  Encodes to upstream JSON. `now_ms` is passed to `Archon.Domain.Task.to_json/2` and
  `Archon.Domain.Workflow.to_json/2` for each task's `queueWaitTime`.
  """
  @spec to_json(t(), integer()) :: Codec.json_object()
  def to_json(%__MODULE__{} = result, now_ms \\ System.system_time(:millisecond)) do
    json = Codec.encode(__MODULE__, @fields, %{result | results: nil})

    case result.results do
      nil -> json
      results -> Map.put(json, "results", Enum.map(results, &encode_result(&1, now_ms)))
    end
  end

  defp encode_result(%Task{} = task, now_ms), do: Task.to_json(task, now_ms)
  defp encode_result(%Workflow{} = workflow, now_ms), do: Workflow.to_json(workflow, now_ms)
  defp encode_result(%Json{} = json, _now_ms), do: json
end
