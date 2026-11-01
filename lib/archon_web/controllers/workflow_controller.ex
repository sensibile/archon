# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/WorkflowResource.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: Phoenix actions for the MVP handlers only.

defmodule ArchonWeb.WorkflowController do
  @moduledoc """
  Workflow start, lookup and termination (upstream `WorkflowResource`, ADR 0023 decision 2),
  filled by slice 5d with `Archon.Runtime`. Until then every action answers like a path without
  a handler (`ArchonWeb.Errors.send_no_route/1`).
  """

  use ArchonWeb, :controller

  @doc "`POST /api/workflow` (`startWorkflow`, a `StartWorkflowRequest` body): the ID as text."
  @spec start(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/workflow/{name}` (`startWorkflow`, `version`, `correlationId`, `priority`)."
  @spec start_by_name(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def start_by_name(conn, _params), do: Errors.send_no_route(conn)

  @doc "`GET /api/workflow/{workflowId}` (`getExecutionStatus`, `includeTasks`)."
  @spec get(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get(conn, _params), do: Errors.send_no_route(conn)

  @doc "`GET /api/workflow/{workflowId}/status` (`getWorkflowStatusSummary`)."
  @spec status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def status(conn, _params), do: Errors.send_no_route(conn)

  @doc "`DELETE /api/workflow/{workflowId}` (`terminate`, `reason`)."
  @spec terminate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def terminate(conn, _params), do: Errors.send_no_route(conn)
end
