# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# TaskResource.java (log, getTaskLogs) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the Phase 8 task log handlers (ADR 0027, decision 6) on
# Archon.Runtime.Tasks; a browser's cross-origin log request is refused.

defmodule ArchonWeb.TaskLogController do
  @moduledoc """
  Task execution logs (upstream `TaskResource#log` and `#getTaskLogs`, ADR 0027 decision 6) on
  `Archon.Runtime.Tasks`.

  `POST /api/tasks/{taskId}/log` takes its body as text whatever its `Content-Type`, as upstream's
  `@RequestBody String` does (`ArchonWeb.Request.read_text/2`), so the JSON `Content-Type` check
  that keeps a browser's cross-origin "simple" request from an action does not run for it.
  `ArchonWeb.Plugs.RefuseCrossOrigin` refuses such a request with a 403 instead (a deliberate
  difference, as for ADR 0025's bodyless actions).
  """

  use ArchonWeb, :controller

  alias Archon.Domain.TaskExecLog
  alias Archon.Runtime.Tasks

  @log_handler "public void com.netflix.conductor.rest.controllers.TaskResource.log(" <>
                 "java.lang.String,java.lang.String)"

  plug ArchonWeb.Plugs.RefuseCrossOrigin when action in [:log]

  @doc """
  `POST /api/tasks/{taskId}/log` (`log`, the body's text as the log): 200 without a body, whether
  or not the task exists. An empty body is the missing-body 500.
  """
  @spec log(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def log(conn, %{"taskId" => task_id}) do
    case Request.read_text(conn, handler: @log_handler) do
      {:ok, text, conn} ->
        case Tasks.log(task_id, text) do
          :ok -> Response.empty(conn)
          {:error, reason} -> Errors.send_error(conn, reason)
        end

      {:error, reason, conn} ->
        Errors.send_error(conn, reason)
    end
  end

  @doc """
  `GET /api/tasks/{taskId}/log` (`getTaskLogs`): the task's logs in `createdTime` order, or 204
  without any.
  """
  @spec get_logs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get_logs(conn, %{"taskId" => task_id}) do
    case Tasks.logs(task_id) do
      [] -> Response.no_content(conn)
      logs -> Response.json(conn, Enum.map(logs, &TaskExecLog.to_json/1))
    end
  end
end
