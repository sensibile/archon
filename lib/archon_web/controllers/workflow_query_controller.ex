# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# WorkflowResource.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: skeletons of the Phase 6 handlers (ADR 0025); every action answers
# the 404 of a path without a handler until its slice implements it.

defmodule ArchonWeb.WorkflowQueryController do
  @moduledoc """
  Workflow queries (upstream `WorkflowResource`, ADR 0025 decision 4) on `Archon.Runtime`.

  The actions are skeletons (ADR 0025, decision 7): each answers the 404 of a path without a
  handler, and the contract replay (`ArchonWeb.ContractCase`) skips the steps that reach an
  action of `unimplemented/0`. Slice 6b empties the list.
  """

  use ArchonWeb, :controller

  # Persisted and read back at run time, so the list may shrink to [] without a spec to change.
  Module.register_attribute(__MODULE__, :unimplemented, persist: true)

  @unimplemented [
    :tasks,
    :correlated,
    :correlated_many,
    :running
  ]

  @doc "The actions not implemented yet."
  @spec unimplemented() :: [atom()]
  def unimplemented, do: Keyword.fetch!(__MODULE__.__info__(:attributes), :unimplemented)

  @doc "`GET /api/workflow/{workflowId}/tasks` (`getExecutionStatusTaskList`, `start`, `count` and `status` queries). Not implemented yet."
  @spec tasks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def tasks(conn, _params), do: Errors.send_no_route(conn)

  @doc "`GET /api/workflow/{name}/correlated/{correlationId}` (`getWorkflows`, `includeClosed` and `includeTasks` queries). Not implemented yet."
  @spec correlated(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def correlated(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/workflow/{name}/correlated` (`getWorkflows`, a list of correlation IDs). Not implemented yet."
  @spec correlated_many(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def correlated_many(conn, _params), do: Errors.send_no_route(conn)

  @doc "`GET /api/workflow/running/{name}` (`getRunningWorkflow`, `version`, `startTime` and `endTime` queries). Not implemented yet."
  @spec running(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def running(conn, _params), do: Errors.send_no_route(conn)
end
