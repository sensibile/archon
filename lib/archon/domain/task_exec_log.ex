# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/tasks/TaskExecLog.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; a missing createdTime
# decodes as nil for the write to stamp (ADR 0027, decision 6).

defmodule Archon.Domain.TaskExecLog do
  @moduledoc "A log line reported by a worker (`TaskResult.logs`, `GET /api/tasks/{taskId}/log`)."

  alias Archon.Domain.Codec

  @fields [
    {:log, "log", :string, []},
    {:task_id, "taskId", :string, []},
    # Upstream's constructor stamps the time a log without one is read; a write takes it then
    # (`Archon.Runtime.TaskLogs.prepare/4`). `null` is a Java primitive's 0.
    {:created_time, "createdTime", :int, default: nil}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          log: String.t() | nil,
          task_id: String.t() | nil,
          created_time: integer() | nil
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = log), do: Codec.encode(__MODULE__, @fields, log)
end
