# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# TaskResource.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: skeletons of the Phase 8 task log handlers (ADR 0027); every action
# answers the 404 of a path without a handler until slice 8d implements it.

defmodule ArchonWeb.TaskLogController do
  @moduledoc """
  Task execution logs (upstream `TaskResource#log` and `#getTaskLogs`, ADR 0027 decision 6).

  The actions are skeletons (ADR 0027, decision 7): each answers the 404 of a path without a
  handler, and the contract replay (`ArchonWeb.ContractCase`) skips the steps that reach an
  action of `unimplemented/0`. Slice 8d empties the list.
  """

  use ArchonWeb, :controller

  # Persisted and read back at run time, so the list may shrink to [] without a spec to change.
  Module.register_attribute(__MODULE__, :unimplemented, persist: true)

  @unimplemented [:log, :get_logs]

  @doc "The actions not implemented yet."
  @spec unimplemented() :: [atom()]
  def unimplemented, do: Keyword.fetch!(__MODULE__.__info__(:attributes), :unimplemented)

  @doc """
  `POST /api/tasks/{taskId}/log` (`log`, the body's text as the log): 200 without a body. Not
  implemented yet.
  """
  @spec log(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def log(conn, _params), do: Errors.send_no_route(conn)

  @doc """
  `GET /api/tasks/{taskId}/log` (`getTaskLogs`): the task's logs, or 204 without any. Not
  implemented yet.
  """
  @spec get_logs(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get_logs(conn, _params), do: Errors.send_no_route(conn)
end
