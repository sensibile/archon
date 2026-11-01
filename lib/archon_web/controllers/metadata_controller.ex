# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/MetadataResource.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: Phoenix actions for the MVP handlers only.

defmodule ArchonWeb.MetadataController do
  @moduledoc """
  Definition registration and lookup (upstream `MetadataResource`, ADR 0023 decision 2) on
  `Archon.Metadata`.

  As in Spring, the body is converted before the query values. A list body
  (`POST /api/metadata/taskdefs`, `PUT /api/metadata/workflow`) also takes a single object as a
  list of one (upstream's `spring.jackson.deserialization.accept-single-value-as-array`). A body
  the domain codec cannot convert (`"retryCount": "abc"`) is a 500 whose message starts with
  upstream's `"JSON parse error: "` followed by the codec's path and reason instead of Jackson's
  wording (ADR 0023, decision 4).

  Validation errors carry upstream's method and argument prefix (`registerTaskDef.arg0`,
  `updateTaskDef.arg0`, `registerWorkflowDef.arg0`, `updateWorkflowDef.arg0`), seen on the
  upstream server.
  """

  use ArchonWeb, :controller

  alias Archon.Domain.{BulkResponse, Codec, TaskDef, Validation, WorkflowDef}
  alias Archon.Metadata

  @resource "com.netflix.conductor.rest.controllers.MetadataResource"
  @task_def "com.netflix.conductor.common.metadata.tasks.TaskDef"
  @workflow_def "com.netflix.conductor.common.metadata.workflow.WorkflowDef"

  @doc """
  `POST /api/metadata/workflow` (`create`, `overwrite` query): a definition without a name is
  registered (and fails validation); one whose name and version are stored is replaced with
  `overwrite`, else a 409.
  """
  @spec create_workflow(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_workflow(conn, _params) do
    handler = "public void #{@resource}.create(#{@workflow_def},boolean)"

    with {:ok, definition, conn} <- body(conn, handler, &one(&1, WorkflowDef)),
         {:ok, overwrite} <- query(conn, Request.boolean(conn, "overwrite", false)) do
      {result, prefix} = create(definition, overwrite)
      reply(conn, result, path: prefix, value: definition)
    end
  end

  # MetadataResource#create
  defp create(%WorkflowDef{name: name, version: version} = definition, overwrite) do
    cond do
      Validation.java_blank?(name) ->
        {Metadata.register_workflow_def(definition), "registerWorkflowDef.arg0"}

      Metadata.find_workflow_def(name, version) == {:error, :not_found} ->
        {Metadata.register_workflow_def(definition), "registerWorkflowDef.arg0"}

      overwrite ->
        {Metadata.update_workflow_def(definition), "updateWorkflowDef.arg0"}

      true ->
        message = "Workflow with #{WorkflowDef.key(name, version)} already exists!"
        {{:error, {:conflict, message}}, ""}
    end
  end

  @doc "`PUT /api/metadata/workflow` (`update`): a `BulkResponse`."
  @spec update_workflows(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_workflows(conn, _params) do
    handler =
      "public com.netflix.conductor.common.model.BulkResponse<java.lang.String> " <>
        "#{@resource}.update(java.util.List<#{@workflow_def}>)"

    with {:ok, definitions, conn} <- body(conn, handler, &list(&1, WorkflowDef)) do
      case Metadata.update_workflow_defs(definitions) do
        {:ok, %BulkResponse{} = response} ->
          Response.json(conn, BulkResponse.to_json(response))

        {:error, reason} ->
          Errors.send_error(conn, reason, path: "updateWorkflowDef.arg0", value: definitions)
      end
    end
  end

  @doc "`GET /api/metadata/workflow/{name}` (`get`, `version` query, the latest without it)."
  @spec get_workflow(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get_workflow(conn, %{"name" => name}) do
    with {:ok, version} <- query(conn, Request.int(conn, "version", nil, "java.lang.Integer")) do
      case Metadata.get_workflow_def(name, version) do
        {:ok, definition} -> Response.json(conn, WorkflowDef.to_json(definition))
        {:error, reason} -> Errors.send_error(conn, reason)
      end
    end
  end

  @doc "`POST /api/metadata/taskdefs` (`registerTaskDef`, an array body)."
  @spec create_task_defs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_task_defs(conn, _params) do
    handler = "public void #{@resource}.registerTaskDef(java.util.List<#{@task_def}>)"

    with {:ok, task_defs, conn} <- body(conn, handler, &list(&1, TaskDef)) do
      reply(conn, Metadata.register_task_defs(task_defs),
        path: "registerTaskDef.arg0",
        value: task_defs
      )
    end
  end

  @doc "`PUT /api/metadata/taskdefs` (`registerTaskDef`, one definition)."
  @spec update_task_def(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_task_def(conn, _params) do
    handler = "public void #{@resource}.registerTaskDef(#{@task_def})"

    with {:ok, task_def, conn} <- body(conn, handler, &one(&1, TaskDef)) do
      reply(conn, Metadata.update_task_def(task_def), path: "updateTaskDef.arg0", value: task_def)
    end
  end

  @doc "`GET /api/metadata/taskdefs` (`getTaskDefs`)."
  @spec list_task_defs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list_task_defs(conn, _params),
    do: Response.json(conn, Enum.map(Metadata.get_task_defs(), &TaskDef.to_json/1))

  @doc "`GET /api/metadata/taskdefs/{tasktype}` (`getTaskDef`)."
  @spec get_task_def(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get_task_def(conn, %{"tasktype" => task_type}) do
    case Metadata.get_task_def(task_type) do
      {:ok, task_def} -> Response.json(conn, TaskDef.to_json(task_def))
      {:error, reason} -> Errors.send_error(conn, reason)
    end
  end

  # A void handler: 200 without a body, or the error.
  defp reply(conn, :ok, _opts), do: Response.empty(conn)
  defp reply(conn, {:error, reason}, opts), do: Errors.send_error(conn, reason, opts)

  # The body read, then converted; every failure is answered here, so a `with` falls through
  # with the sent conn.
  defp body(conn, handler, convert) do
    with {:ok, json, conn} <- Request.read_json(conn, handler: handler),
         {:ok, value} <- convert.(json) do
      {:ok, value, conn}
    else
      {:error, reason, conn} -> Errors.send_error(conn, reason)
      {:error, reason} -> Errors.send_error(conn, reason)
    end
  end

  defp query(_conn, {:ok, value}), do: {:ok, value}
  defp query(conn, {:error, reason}), do: Errors.send_error(conn, reason)

  defp one(json, module), do: module.from_json(json) |> parse_error()

  # accept-single-value-as-array: a value that is not an array is a list of one. A `null`
  # element stays `nil` for the service's validation.
  defp list(json, module) when is_list(json),
    do: Codec.cast({:list, {:struct, module}}, json, [], []) |> parse_error()

  defp list(json, module), do: list([json], module)

  defp parse_error({:ok, value}), do: {:ok, value}

  # Jackson stops at the first value it cannot convert; the message has the same shape as
  # ArchonWeb.TaskController's (ADR 0023, decision 4).
  defp parse_error({:error, [{path, message} | _rest]}),
    do: {:error, {:server_error, "JSON parse error: " <> String.trim("#{path} #{message}")}}
end
