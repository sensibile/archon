# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/workflow/RerunWorkflowRequest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.RerunWorkflowRequest do
  @moduledoc """
  The body of `POST /api/workflow/{workflowId}/rerun` (ADR 0025, decision 2). Every field may be
  missing: a `nil` `reRunFromTaskId` reruns the whole workflow, and a `nil` input or correlation
  ID leaves the workflow's own. `reRunFromWorkflowId` is replaced by the path value.
  """

  alias Archon.Domain.Codec

  @fields [
    {:re_run_from_workflow_id, "reRunFromWorkflowId", :string, []},
    {:workflow_input, "workflowInput", :object, []},
    {:re_run_from_task_id, "reRunFromTaskId", :string, []},
    {:task_input, "taskInput", :object, []},
    {:correlation_id, "correlationId", :string, []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          re_run_from_workflow_id: String.t() | nil,
          workflow_input: map() | nil,
          re_run_from_task_id: String.t() | nil,
          task_input: map() | nil,
          correlation_id: String.t() | nil
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = request), do: Codec.encode(__MODULE__, @fields, request)
end
