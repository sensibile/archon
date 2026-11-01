# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/workflow/StartWorkflowRequest.java
# and core/src/main/java/com/netflix/conductor/core/execution/StartWorkflowInput.java
# (StartWorkflowInput(StartWorkflowRequest)) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; bean validation
# annotations ported to validate/1; the start input is built from the request fields only.

defmodule Archon.Domain.StartWorkflowRequest do
  @moduledoc """
  The body of `POST /api/workflow` (ADR 0023, decision 3).

  `idempotencyKey` and `idempotencyStrategy` are read but, as upstream's `startWorkflow`, not
  used to start. `createdBy` is read and not used either (upstream's `StartWorkflowInput` does
  not copy it). `externalInputPayloadStoragePath` is read for the controller, which refuses what
  Archon cannot download (external payload storage is out of scope).

  A request has no parent fields: `to_start_input/1` builds the runtime's start map from the
  request fields only, so a REST client cannot start a workflow as another workflow's child
  (ADR 0024, decision 4).
  """

  alias Archon.Domain.{Codec, Validation, WorkflowDef}

  @type idempotency_strategy :: :fail | :return_existing | :fail_on_running

  @fields [
    {:name, "name", :string, []},
    {:version, "version", :integer, []},
    {:correlation_id, "correlationId", :string, []},
    {:input, "input", :object, default: %{}},
    {:task_to_domain, "taskToDomain", :string_map, default: %{}},
    {:workflow_def, "workflowDef", {:struct, WorkflowDef}, []},
    {:external_input_payload_storage_path, "externalInputPayloadStoragePath", :string, []},
    {:priority, "priority", :integer, default: 0},
    {:created_by, "createdBy", :string, []},
    {:idempotency_key, "idempotencyKey", :string, []},
    {:idempotency_strategy, "idempotencyStrategy",
     {:enum, [:fail, :return_existing, :fail_on_running]}, []}
  ]

  defstruct Codec.defaults(@fields)

  @doc false
  @spec __fields__() :: [Codec.field()]
  def __fields__, do: @fields

  @type t :: %__MODULE__{
          name: String.t() | nil,
          version: integer() | nil,
          correlation_id: String.t() | nil,
          input: Codec.json_object() | nil,
          task_to_domain: %{optional(String.t()) => String.t() | nil} | nil,
          workflow_def: WorkflowDef.t() | nil,
          external_input_payload_storage_path: String.t() | nil,
          priority: integer() | nil,
          created_by: String.t() | nil,
          idempotency_key: String.t() | nil,
          idempotency_strategy: idempotency_strategy() | nil
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = request), do: Codec.encode(__MODULE__, @fields, request)

  @doc """
  Bean validation: `name` `@NotNull` (an empty name passes, as upstream), `priority` `@Min(0)
  @Max(99)` (a `null` priority passes) and `workflowDef` `@Valid` (`Archon.Domain.WorkflowDef`'s
  validation under `workflowDef`). See `Archon.Domain.Validation` for `opts`.
  """
  @spec validate(t(), Validation.opts()) :: Validation.result()
  def validate(%__MODULE__{} = request, opts \\ []) do
    Validation.result(
      name_errors(request.name) ++
        Validation.min(
          "priority",
          request.priority,
          0,
          "priority: #{request.priority} should be minimum 0"
        ) ++
        Validation.max(
          "priority",
          request.priority,
          99,
          "priority: #{request.priority} should be maximum 99"
        ) ++
        workflow_def_errors(request.workflow_def, opts)
    )
  end

  defp name_errors(nil), do: [{"name", "Workflow name cannot be null or empty"}]
  defp name_errors(_name), do: []

  defp workflow_def_errors(nil, _opts), do: []

  defp workflow_def_errors(%WorkflowDef{} = definition, opts) do
    case WorkflowDef.validate(definition, opts) do
      :ok -> []
      {:error, errors} -> Validation.nest(errors, "workflowDef")
    end
  end

  @doc """
  The `t:Archon.Runtime.start_input/0` for this request, upstream's
  `new StartWorkflowInput(request)`: the inline `workflowDef` when there is one (the name and
  version are then not looked up), else the name and version. Only request fields are copied:
  no workflow ID (the runtime makes one) and no parent fields.
  """
  @spec to_start_input(t()) :: map()
  def to_start_input(%__MODULE__{} = request) do
    %{
      name: request.name,
      version: request.version,
      definition: request.workflow_def,
      input: request.input,
      correlation_id: request.correlation_id,
      priority: request.priority,
      task_to_domain: request.task_to_domain
    }
  end
end
