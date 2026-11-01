# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# {TaskResource,WorkflowResource}.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: skeletons of the Phase 6 handlers (ADR 0025); every action answers
# the 404 of a path without a handler until its slice implements it.

defmodule ArchonWeb.SignalController do
  @moduledoc """
  Task updates by reference, signals and the synchronous start (upstream `TaskResource` and
  `WorkflowResource#executeWorkflow`, ADR 0025 decision 5) on `Archon.Runtime` and
  `Archon.Runtime.Tasks`.

  The actions are skeletons (ADR 0025, decision 7): each answers the 404 of a path without a
  handler, and the contract replay (`ArchonWeb.ContractCase`) skips the steps that reach an
  action of `unimplemented/0`. Slice 6e empties the list.
  """

  use ArchonWeb, :controller

  # Persisted and read back at run time, so the list may shrink to [] without a spec to change.
  Module.register_attribute(__MODULE__, :unimplemented, persist: true)

  @unimplemented [
    :update_by_ref,
    :update_by_ref_sync,
    :signal,
    :signal_sync,
    :execute
  ]

  @doc "The actions not implemented yet."
  @spec unimplemented() :: [atom()]
  def unimplemented, do: Keyword.fetch!(__MODULE__.__info__(:attributes), :unimplemented)

  @doc "`POST /api/tasks/{workflowId}/{taskRefName}/{status}` (`updateTask`, `workerid` query). Not implemented yet."
  @spec update_by_ref(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_by_ref(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/tasks/{workflowId}/{taskRefName}/{status}/sync` (`updateTaskSync`, `workerid` query). Not implemented yet."
  @spec update_by_ref_sync(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_by_ref_sync(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/tasks/{workflowId}/{status}/signal` (`signalWorkflowTaskAsync`). Not implemented yet."
  @spec signal(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def signal(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/tasks/{workflowId}/{status}/signal/sync` (`signalWorkflowTaskSync`, `returnStrategy` and `timeoutMillis` queries). Not implemented yet."
  @spec signal_sync(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def signal_sync(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/workflow/execute/{name}/{version}` (`executeWorkflow`, `requestId`, `waitUntilTaskRef`, `waitForSeconds`, `consistency` and `returnStrategy` queries). Not implemented yet."
  @spec execute(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def execute(conn, _params), do: Errors.send_no_route(conn)
end
