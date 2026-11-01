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
  Definition registration and lookup (upstream `MetadataResource`, ADR 0023 decision 2), filled
  by slice 5c with `Archon.Metadata`. Until then every action answers like a path without a
  handler (`ArchonWeb.Errors.send_no_route/1`).
  """

  use ArchonWeb, :controller

  @doc "`POST /api/metadata/workflow` (`create`, `overwrite` query)."
  @spec create_workflow(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_workflow(conn, _params), do: Errors.send_no_route(conn)

  @doc "`PUT /api/metadata/workflow` (`update`): a `BulkResponse`."
  @spec update_workflows(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_workflows(conn, _params), do: Errors.send_no_route(conn)

  @doc "`GET /api/metadata/workflow/{name}` (`get`, `version` query)."
  @spec get_workflow(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get_workflow(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/metadata/taskdefs` (`registerTaskDef`, an array body)."
  @spec create_task_defs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create_task_defs(conn, _params), do: Errors.send_no_route(conn)

  @doc "`PUT /api/metadata/taskdefs` (`registerTaskDef`, one definition)."
  @spec update_task_def(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_task_def(conn, _params), do: Errors.send_no_route(conn)

  @doc "`GET /api/metadata/taskdefs` (`getTaskDefs`)."
  @spec list_task_defs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list_task_defs(conn, _params), do: Errors.send_no_route(conn)

  @doc "`GET /api/metadata/taskdefs/{tasktype}` (`getTaskDef`)."
  @spec get_task_def(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get_task_def(conn, _params), do: Errors.send_no_route(conn)
end
