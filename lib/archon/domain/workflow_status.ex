# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/org/conductoross/conductor/model/WorkflowStatus.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec.

defmodule Archon.Domain.WorkflowStatus do
  @moduledoc """
  The answer of `GET /api/workflow/{workflowId}/status` (ADR 0023, decision 3): a workflow's ID,
  correlation ID and status, with its output and variables only when asked.
  """

  alias Archon.Domain.{Codec, Workflow}

  @fields [
    {:workflow_id, "workflowId", :string, []},
    {:correlation_id, "correlationId", :string, []},
    {:output, "output", :object, []},
    {:variables, "variables", :object, []},
    {:status, "status", {:enum, Workflow.statuses()}, []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          workflow_id: String.t() | nil,
          correlation_id: String.t() | nil,
          output: Codec.json_object() | nil,
          variables: Codec.json_object() | nil,
          status: Workflow.status() | nil
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = status), do: Codec.encode(__MODULE__, @fields, status)

  @doc """
  Upstream `new WorkflowStatus(workflow, includeOutput, includeVariables)`: an empty correlation
  ID is left out (`StringUtils.isNotEmpty`).
  """
  @spec new(Workflow.t(), boolean(), boolean()) :: t()
  def new(%Workflow{} = workflow, include_output?, include_variables?) do
    %__MODULE__{
      workflow_id: workflow.workflow_id,
      correlation_id:
        if(workflow.correlation_id in [nil, ""], do: nil, else: workflow.correlation_id),
      output: if(include_output?, do: workflow.output),
      variables: if(include_variables?, do: workflow.variables),
      status: workflow.status
    }
  end
end
