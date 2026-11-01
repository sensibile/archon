# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# WorkflowBulkResource.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: skeletons of the Phase 6 handlers (ADR 0025); every action answers
# the 404 of a path without a handler until its slice implements it.

defmodule ArchonWeb.WorkflowBulkController do
  @moduledoc """
  Bulk workflow operations (upstream `WorkflowBulkResource`, ADR 0025 decision 6) on the single
  workflow functions of `Archon.Runtime` and `Archon.Runtime.Lifecycle`.

  The actions are skeletons (ADR 0025, decision 7): each answers the 404 of a path without a
  handler, and the contract replay (`ArchonWeb.ContractCase`) skips the steps that reach an
  action of `unimplemented/0`. Slice 6g empties the list.
  """

  use ArchonWeb, :controller

  # Persisted and read back at run time, so the list may shrink to [] without a spec to change.
  Module.register_attribute(__MODULE__, :unimplemented, persist: true)

  @unimplemented [
    :pause,
    :resume,
    :restart,
    :retry,
    :terminate,
    :remove,
    :terminate_remove
  ]

  @doc "The actions not implemented yet."
  @spec unimplemented() :: [atom()]
  def unimplemented, do: Keyword.fetch!(__MODULE__.__info__(:attributes), :unimplemented)

  @doc "`PUT /api/workflow/bulk/pause` (`pauseWorkflow`). Not implemented yet."
  @spec pause(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pause(conn, _params), do: Errors.send_no_route(conn)

  @doc "`PUT /api/workflow/bulk/resume` (`resumeWorkflow`). Not implemented yet."
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/workflow/bulk/restart` (`restart`, `useLatestDefinitions` query). Not implemented yet."
  @spec restart(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def restart(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/workflow/bulk/retry` (`retry`). Not implemented yet."
  @spec retry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def retry(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/workflow/bulk/terminate` (`terminate`, `reason` query). Not implemented yet."
  @spec terminate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def terminate(conn, _params), do: Errors.send_no_route(conn)

  @doc "`DELETE /api/workflow/bulk/remove` (`deleteWorkflow`, `archiveWorkflow` query). Not implemented yet."
  @spec remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def remove(conn, _params), do: Errors.send_no_route(conn)

  @doc "`DELETE /api/workflow/bulk/terminate-remove` (`terminateRemove`, `archiveWorkflow` and `reason` queries). Not implemented yet."
  @spec terminate_remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def terminate_remove(conn, _params), do: Errors.send_no_route(conn)
end
