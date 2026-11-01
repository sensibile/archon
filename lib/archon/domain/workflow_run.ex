# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/org/conductoross/conductor/model/WorkflowRun.java
# and SignalResponse.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; the fields of the
# abstract SignalResponse are declared in each subclass.

defmodule Archon.Domain.WorkflowRun do
  @moduledoc """
  The `TARGET_WORKFLOW` and `BLOCKING_WORKFLOW` answer of `POST /api/workflow/execute/{name}/{version}`
  and `POST /api/tasks/{workflowId}/{status}/signal/sync` (ADR 0025, decision 5): a workflow's
  state with the target workflow's ID and status. Built by `Archon.Domain.SignalResponse.new/6`.
  """

  alias Archon.Domain.{Codec, SignalResponse, Task, Workflow}

  # WorkflowSignalReturnStrategy (`Archon.Domain.SignalResponse.strategies/0`), literal so that this
  # module does not need SignalResponse at compile time.
  @strategies [:target_workflow, :blocking_workflow, :blocking_task, :blocking_task_input]

  # SignalResponse's fields, then this class's, as Jackson writes them.
  @fields [
    {:response_type, "responseType", {:enum, @strategies}, []},
    {:target_workflow_id, "targetWorkflowId", :string, []},
    {:target_workflow_status, "targetWorkflowStatus", :string, []},
    {:request_id, "requestId", :string, []},
    {:workflow_id, "workflowId", :string, []},
    {:correlation_id, "correlationId", :string, []},
    {:input, "input", :object, []},
    {:output, "output", :object, []},
    {:signal_timeout, "signalTimeout", :bool, []},
    {:priority, "priority", :int, []},
    {:variables, "variables", :object, []},
    {:tasks, "tasks", {:list, {:struct, Task}}, []},
    {:created_by, "createdBy", :string, []},
    {:create_time, "createTime", :int, []},
    {:status, "status", {:enum, Workflow.statuses()}, []},
    {:update_time, "updateTime", :int, []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          response_type: SignalResponse.strategy() | nil,
          target_workflow_id: String.t() | nil,
          target_workflow_status: String.t() | nil,
          request_id: String.t() | nil,
          workflow_id: String.t() | nil,
          correlation_id: String.t() | nil,
          input: Codec.json_object() | nil,
          output: Codec.json_object() | nil,
          signal_timeout: boolean(),
          priority: integer(),
          variables: Codec.json_object() | nil,
          tasks: [Task.t() | nil] | nil,
          created_by: String.t() | nil,
          create_time: integer(),
          status: Workflow.status() | nil,
          update_time: integer()
        }

  @doc false
  @spec __fields__() :: [Codec.field()]
  def __fields__, do: @fields

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = run), do: Codec.encode(__MODULE__, @fields, run)
end
