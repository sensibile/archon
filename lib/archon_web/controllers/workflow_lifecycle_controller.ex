# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# WorkflowResource.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the Phase 6 handlers (ADR 0025) on Archon.Runtime.Lifecycle.

defmodule ArchonWeb.WorkflowLifecycleController do
  @moduledoc """
  Workflow lifecycle and removal (upstream `WorkflowResource`, ADR 0025 decisions 2 and 3) on
  `Archon.Runtime.Lifecycle`.

  A workflow the store does not have is a 404 `"No such workflow found by id: <id>"`
  (`ExecutionDAOFacade#getWorkflowModel`); the other errors are `ArchonWeb.Errors`'s.

  `retry`, `restart` and `resetcallbacks` read no body, so the JSON `Content-Type` check of
  `ArchonWeb.Request` that keeps a browser's cross-origin "simple" request from an action (ADR 0023,
  decision 3) does not run for them, and a browser can `POST` to them from another site without a
  CORS preflight (a form, `fetch` in `no-cors` mode with no body, `<a ping>`). A request a browser
  marks as cross-origin is refused with a 403 instead (ADR 0025, decision 3, a deliberate
  difference): `Sec-Fetch-Site` other than `same-origin` or `none`, or, without it, an `Origin`
  whose host and port are not the request's (`conn.host`, `conn.port`, from its `Host`).
  `rerun` reads a required JSON body, so the `Content-Type` check already keeps those requests
  from it (a form or `text/plain` is refused, no body is the missing-body 500). Clients that are not browsers send neither
  header and are answered as upstream.
  """

  use ArchonWeb, :controller

  alias Archon.Domain.RerunWorkflowRequest
  alias Archon.Runtime.Lifecycle

  @rerun_handler "public java.lang.String " <>
                   "com.netflix.conductor.rest.controllers.WorkflowResource.rerun(" <>
                   "java.lang.String," <>
                   "com.netflix.conductor.common.metadata.workflow.RerunWorkflowRequest)"

  plug :refuse_cross_origin when action in [:retry, :restart, :reset_callbacks]

  @doc "`PUT /api/workflow/{workflowId}/pause` (`pauseWorkflow`): 200 without a body."
  @spec pause(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pause(conn, %{"workflowId" => id}),
    do: reply(conn, id, Lifecycle.pause(id), &Response.empty/1)

  @doc "`PUT /api/workflow/{workflowId}/resume` (`resumeWorkflow`): 200 without a body."
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, %{"workflowId" => id}),
    do: reply(conn, id, Lifecycle.resume(id), &Response.empty/1)

  @doc """
  `POST /api/workflow/{workflowId}/retry` (`retry`, `resumeSubworkflowTasks` false): 204.
  """
  @spec retry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def retry(conn, %{"workflowId" => id}) do
    with {:ok, resume?} <- query(conn, Request.boolean(conn, "resumeSubworkflowTasks", false)) do
      reply(conn, id, Lifecycle.retry(id, resume?), &Response.no_content/1)
    end
  end

  @doc """
  `POST /api/workflow/{workflowId}/restart` (`restart`, `useLatestDefinitions` false): 204.
  """
  @spec restart(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def restart(conn, %{"workflowId" => id}) do
    with {:ok, latest?} <- query(conn, Request.boolean(conn, "useLatestDefinitions", false)) do
      reply(conn, id, Lifecycle.restart(id, latest?), &Response.no_content/1)
    end
  end

  @doc """
  `POST /api/workflow/{workflowId}/rerun` (`rerun`, a required `RerunWorkflowRequest` body whose
  `reRunFromWorkflowId` the path replaces): the workflow ID as text.
  """
  @spec rerun(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rerun(conn, %{"workflowId" => id}) do
    with {:ok, json, conn} <- body(conn),
         {:ok, request} <- decode(conn, RerunWorkflowRequest.from_json(json)) do
      request = %{request | re_run_from_workflow_id: id}

      case Lifecycle.rerun(id, request) do
        :ok -> Response.text(conn, id)
        result -> reply(conn, id, result, & &1)
      end
    end
  end

  @doc """
  `PUT /api/workflow/{workflowId}/skiptask/{taskReferenceName}` (`skipTaskFromWorkflow`): 200
  without a body. The `SkipTaskRequest` has no `@RequestBody` upstream, so a JSON body is not
  read (ADR 0025, decision 2).
  """
  @spec skip_task(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def skip_task(conn, %{"workflowId" => id, "taskReferenceName" => ref}),
    do: reply(conn, id, Lifecycle.skip_task(id, ref), &Response.empty/1)

  @doc "`POST /api/workflow/{workflowId}/resetcallbacks` (`resetWorkflow`): 204."
  @spec reset_callbacks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset_callbacks(conn, %{"workflowId" => id}),
    do: reply(conn, id, Lifecycle.reset_callbacks(id), &Response.no_content/1)

  @doc """
  `DELETE /api/workflow/{workflowId}/remove` (`delete`, `archiveWorkflow` true): 200 without a
  body.
  """
  @spec remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def remove(conn, %{"workflowId" => id}) do
    with {:ok, archive?} <- query(conn, Request.boolean(conn, "archiveWorkflow", true)) do
      reply(conn, id, Lifecycle.remove(id, archive?), &Response.empty/1)
    end
  end

  @doc """
  `DELETE /api/workflow/{workflowId}/terminate-remove` (`terminateRemove`, `reason`,
  `archiveWorkflow` true): 200 without a body; a `COMPLETED` workflow is the termination's 409.
  """
  @spec terminate_remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def terminate_remove(conn, %{"workflowId" => id}) do
    with {:ok, archive?} <- query(conn, Request.boolean(conn, "archiveWorkflow", true)) do
      case Lifecycle.terminate_remove(id, Request.string(conn, "reason"), archive?) do
        {:error, :conflict} ->
          Errors.send_error(conn, {:conflict, "Cannot terminate a COMPLETED workflow."})

        result ->
          reply(conn, id, result, &Response.empty/1)
      end
    end
  end

  defp refuse_cross_origin(conn, _opts) do
    if cross_origin?(conn) do
      conn
      |> Errors.send_error({:forbidden, "Cross-origin request refused"})
      |> halt()
    else
      conn
    end
  end

  defp cross_origin?(conn) do
    case get_req_header(conn, "sec-fetch-site") do
      [site | _rest] ->
        String.downcase(String.trim(site)) not in ["same-origin", "none"]

      [] ->
        case get_req_header(conn, "origin") do
          [origin | _rest] -> authority(origin) != host(conn)
          [] -> false
        end
    end
  end

  # "scheme://host[:port]" as "host:port", the default port of the scheme filled in.
  defp authority(origin) do
    case URI.parse(String.trim(origin)) do
      %URI{host: host, port: port} when is_binary(host) and host != "" ->
        "#{String.downcase(host)}:#{port}"

      _opaque ->
        nil
    end
  end

  # The adapter takes the request's host and port from its Host header (or HTTP/2 authority),
  # keeping an IPv6 literal's brackets, which URI.parse/1 drops.
  defp host(conn) do
    host = conn.host |> String.trim_leading("[") |> String.trim_trailing("]")
    "#{String.downcase(host)}:#{conn.port}"
  end

  defp reply(conn, _id, :ok, send), do: send.(conn)

  defp reply(conn, id, {:error, :not_found}, _send),
    do: Errors.send_error(conn, {:not_found, "No such workflow found by id: #{id}"})

  defp reply(conn, _id, {:error, reason}, _send), do: Errors.send_error(conn, reason)

  defp body(conn) do
    case Request.read_json(conn, handler: @rerun_handler) do
      {:ok, json, conn} -> {:ok, json, conn}
      {:error, reason, conn} -> Errors.send_error(conn, reason)
    end
  end

  defp decode(_conn, {:ok, value}), do: {:ok, value}
  defp decode(conn, {:error, errors}), do: Errors.send_error(conn, Request.codec_error(errors))

  defp query(_conn, {:ok, value}), do: {:ok, value}
  defp query(conn, {:error, reason}), do: Errors.send_error(conn, reason)
end
