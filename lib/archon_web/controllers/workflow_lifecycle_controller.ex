# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# WorkflowResource.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: skeletons of the Phase 6 handlers (ADR 0025); every action answers
# the 404 of a path without a handler until its slice implements it.

defmodule ArchonWeb.WorkflowLifecycleController do
  @moduledoc """
  Workflow lifecycle and removal (upstream `WorkflowResource`, ADR 0025 decisions 2 and 3) on
  `Archon.Runtime.Lifecycle`.

  The actions are skeletons (ADR 0025, decision 7): each answers the 404 of a path without a
  handler, and the contract replay (`ArchonWeb.ContractCase`) skips the steps that reach an
  action of `unimplemented/0`. Slice 6d empties the list but for `rerun`, which slice 6f implements.
  """

  use ArchonWeb, :controller

  # Persisted and read back at run time, so the list may shrink to [] without a spec to change.
  Module.register_attribute(__MODULE__, :unimplemented, persist: true)

  @unimplemented [
    :pause,
    :resume,
    :retry,
    :restart,
    :rerun,
    :skip_task,
    :reset_callbacks,
    :remove,
    :terminate_remove
  ]

  @doc "The actions not implemented yet."
  @spec unimplemented() :: [atom()]
  def unimplemented, do: Keyword.fetch!(__MODULE__.__info__(:attributes), :unimplemented)

  @doc "`PUT /api/workflow/{workflowId}/pause` (`pauseWorkflow`). Not implemented yet."
  @spec pause(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pause(conn, _params), do: Errors.send_no_route(conn)

  @doc "`PUT /api/workflow/{workflowId}/resume` (`resumeWorkflow`). Not implemented yet."
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/workflow/{workflowId}/retry` (`retry`, `resumeSubworkflowTasks` query). Not implemented yet."
  @spec retry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def retry(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/workflow/{workflowId}/restart` (`restart`, `useLatestDefinitions` query). Not implemented yet."
  @spec restart(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def restart(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/workflow/{workflowId}/rerun` (`rerun`, a `RerunWorkflowRequest` body). Not implemented yet."
  @spec rerun(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rerun(conn, _params), do: Errors.send_no_route(conn)

  @doc "`PUT /api/workflow/{workflowId}/skiptask/{taskReferenceName}` (`skipTaskFromWorkflow`). Not implemented yet."
  @spec skip_task(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def skip_task(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/workflow/{workflowId}/resetcallbacks` (`resetWorkflow`). Not implemented yet."
  @spec reset_callbacks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset_callbacks(conn, _params), do: Errors.send_no_route(conn)

  @doc "`DELETE /api/workflow/{workflowId}/remove` (`delete`, `archiveWorkflow` query). Not implemented yet."
  @spec remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def remove(conn, _params), do: Errors.send_no_route(conn)

  @doc "`DELETE /api/workflow/{workflowId}/terminate-remove` (`terminateRemove`, `reason` and `archiveWorkflow` queries). Not implemented yet."
  @spec terminate_remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def terminate_remove(conn, _params), do: Errors.send_no_route(conn)
end
