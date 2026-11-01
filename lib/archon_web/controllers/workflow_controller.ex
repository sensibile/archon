# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/WorkflowResource.java,
# core/src/main/java/com/netflix/conductor/service/WorkflowServiceImpl.java (startWorkflow by
# name: the definition lookup and its message), core/.../core/metadata/MetadataMapperService.java
# (lookupWorkflowDefinition: the blank name), core/.../core/dal/ExecutionDAOFacade.java and
# core/.../core/execution/WorkflowExecutorOps.java (terminateWorkflow: the not-found and conflict
# messages) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: Phoenix actions for the MVP handlers only; the start map is built from
# the request fields only.

defmodule ArchonWeb.WorkflowController do
  @moduledoc """
  Workflow start, lookup and termination (upstream `WorkflowResource`, ADR 0023 decision 2,
  slice 5d) on `Archon.Runtime`.

  A start never carries parent fields: `POST /api/workflow` copies only the
  `StartWorkflowRequest` fields (`Archon.Domain.StartWorkflowRequest.to_start_input/1`) and
  `POST /api/workflow/{name}` only the name, version, correlation ID, priority and input, so a
  REST client cannot start a workflow as another workflow's child (ADR 0024, decision 4).

  As in Spring, handler arguments convert in their order: `POST /api/workflow/{name}` converts
  its query values before its body. The service method validation comes next (400 with
  `validationErrors` under `startWorkflow.arg0` or `startWorkflow.arg3`), then the service and the
  executor. A definition that enforces a schema Archon cannot check is refused by the runtime with
  `{:invalid, message}`, a 400 (ADR 0023, decision 5).
  """

  use ArchonWeb, :controller

  alias Archon.Domain.{Codec, StartWorkflowRequest, Validation, Workflow, WorkflowStatus}
  alias Archon.Metadata
  alias Archon.Runtime

  @resource "com.netflix.conductor.rest.controllers.WorkflowResource"
  @start_handler "public java.lang.String #{@resource}.startWorkflow(" <>
                   "com.netflix.conductor.common.metadata.workflow.StartWorkflowRequest)"
  @start_by_name_handler "public java.lang.String #{@resource}.startWorkflow(" <>
                           "java.lang.String,java.lang.Integer,java.lang.String,int," <>
                           "java.util.Map<java.lang.String, java.lang.Object>)"

  @doc "`POST /api/workflow` (`startWorkflow`, a `StartWorkflowRequest` body): the ID as text."
  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, _params) do
    with {:ok, json, conn} <- body(conn, @start_handler),
         {:ok, request} <- decode(conn, StartWorkflowRequest.from_json(json)),
         :ok <- validate(conn, request),
         :ok <- check_start(conn, request) do
      send_started(conn, Runtime.start_workflow(StartWorkflowRequest.to_start_input(request)))
    end
  end

  defp validate(conn, request) do
    case StartWorkflowRequest.validate(request) do
      :ok ->
        :ok

      {:error, errors} ->
        Errors.send_error(conn, {:invalid, errors}, path: "startWorkflow.arg0", value: request)
    end
  end

  # What upstream refuses after the validation and before a workflow exists, which the runtime
  # does not check.
  defp check_start(conn, %StartWorkflowRequest{} = request) do
    cond do
      # MetadataMapperService#lookupWorkflowDefinition: an IllegalArgumentException (400).
      request.workflow_def == nil and Validation.java_blank?(request.name) ->
        Errors.send_error(
          conn,
          {:invalid, "Workflow name must be specified when searching for a definition"}
        )

      # Without an input, upstream downloads the input from the external storage path, which
      # fails on a server without external payload storage (as Archon); with an input the path
      # is not used.
      request.input in [nil, %{}] and
          not Validation.java_blank?(request.external_input_payload_storage_path) ->
        Errors.send_error(
          conn,
          {:server_error,
           "Unable to download payload from external storage path: " <>
             request.external_input_payload_storage_path}
        )

      true ->
        :ok
    end
  end

  @doc """
  `POST /api/workflow/{name}` (`startWorkflow`, `version`, `correlationId`, `priority` 0, the
  input map as the body): the ID as text. Without a definition, upstream's
  `WorkflowServiceImpl` message (`"No such workflow found by name: <name>, version: <v|null>"`).
  """
  @spec start_by_name(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start_by_name(conn, %{"name" => name}) do
    with {:ok, version} <- query(conn, Request.int(conn, "version", nil, "java.lang.Integer")),
         {:ok, priority} <- query(conn, Request.int(conn, "priority", 0)),
         correlation_id = Request.string(conn, "correlationId"),
         {:ok, json, conn} <- body(conn, @start_by_name_handler),
         {:ok, input} <- decode(conn, Codec.cast(:object, json, [])),
         :ok <- validate_priority(conn, priority),
         {:ok, definition} <- definition(conn, name, version) do
      send_started(
        conn,
        Runtime.start_workflow(%{
          name: definition.name,
          version: definition.version,
          input: input,
          correlation_id: correlation_id,
          priority: priority
        })
      )
    end
  end

  # WorkflowService#startWorkflow(String, Integer, String, @Min(0) @Max(99) Integer, Map)
  defp validate_priority(conn, priority) do
    errors =
      Validation.min("", priority, 0, "0 is the minimum priority value") ++
        Validation.max("", priority, 99, "99 is the maximum priority value")

    case errors do
      [] ->
        :ok

      errors ->
        Errors.send_error(conn, {:invalid, errors}, path: "startWorkflow.arg3", value: priority)
    end
  end

  defp definition(conn, name, version) do
    case Metadata.get_workflow_def(name, version) do
      {:ok, definition} -> {:ok, definition}
      {:error, reason} -> Errors.send_error(conn, reason)
    end
  end

  # `{:error, :conflict}` (the generated ID exists) has no message; it raises in
  # `ArchonWeb.Errors` and is answered as a 500 by the router's error handler.
  defp send_started(conn, {:ok, id}), do: Response.text(conn, id)
  defp send_started(conn, {:error, reason}), do: Errors.send_error(conn, reason)

  @doc "`GET /api/workflow/{workflowId}` (`getExecutionStatus`, `includeTasks` true)."
  @spec get(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get(conn, %{"workflowId" => id}) do
    with {:ok, include_tasks?} <- query(conn, Request.boolean(conn, "includeTasks", true)),
         {:ok, workflow} <- workflow(conn, id, include_tasks?) do
      Response.json(conn, Workflow.to_json(workflow))
    end
  end

  @doc """
  `GET /api/workflow/{workflowId}/status` (`getWorkflowStatusSummary`, `includeOutput` and
  `includeVariables` false): a `WorkflowStatus`.
  """
  @spec status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def status(conn, %{"workflowId" => id}) do
    with {:ok, output?} <- query(conn, Request.boolean(conn, "includeOutput", false)),
         {:ok, variables?} <- query(conn, Request.boolean(conn, "includeVariables", false)),
         {:ok, workflow} <- workflow(conn, id, false) do
      Response.json(
        conn,
        WorkflowStatus.to_json(WorkflowStatus.new(workflow, output?, variables?))
      )
    end
  end

  @doc """
  `DELETE /api/workflow/{workflowId}` (`terminate`, `reason`): 200 without a body, also for a
  workflow already `TERMINATED`; a `COMPLETED` one is a 409.
  """
  @spec terminate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def terminate(conn, %{"workflowId" => id}) do
    case Runtime.terminate_workflow(id, Request.string(conn, "reason")) do
      :ok ->
        Response.empty(conn)

      {:error, :not_found} ->
        Errors.send_error(conn, {:not_found, not_found(id)})

      {:error, :conflict} ->
        Errors.send_error(conn, {:conflict, "Cannot terminate a COMPLETED workflow."})

      {:error, reason} ->
        Errors.send_error(conn, reason)
    end
  end

  # `Archon.Runtime.get_workflow/2` answers only `:not_found`; a store failure raises (a 500 by
  # the router's error handler).
  defp workflow(conn, id, include_tasks?) do
    case Runtime.get_workflow(id, include_tasks?) do
      {:ok, workflow} -> {:ok, workflow}
      {:error, :not_found} -> Errors.send_error(conn, {:not_found, not_found(id)})
    end
  end

  # ExecutionDAOFacade#getWorkflowModel, read before the service's own null check.
  defp not_found(id), do: "No such workflow found by id: #{id}"

  # Every failure below is answered here, so a `with` falls through with the sent conn.
  defp body(conn, handler) do
    case Request.read_json(conn, handler: handler) do
      {:ok, json, conn} -> {:ok, json, conn}
      {:error, reason, conn} -> Errors.send_error(conn, reason)
    end
  end

  defp decode(_conn, {:ok, value}), do: {:ok, value}
  defp decode(conn, {:error, errors}), do: Errors.send_error(conn, Request.codec_error(errors))

  defp query(_conn, {:ok, value}), do: {:ok, value}
  defp query(conn, {:error, reason}), do: Errors.send_error(conn, reason)
end
