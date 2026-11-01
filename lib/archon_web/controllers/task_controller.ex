# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/TaskResource.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: Phoenix actions for the MVP handlers only.

defmodule ArchonWeb.TaskController do
  @moduledoc """
  The worker loop (upstream `TaskResource`, ADR 0023 decision 2), filled by slice 5e with
  `Archon.Runtime.Tasks` once slice 5b closed the worker-input paths (ADR 0024). Until then every
  action answers like a path without a handler (`ArchonWeb.Errors.send_no_route/1`).
  """

  use ArchonWeb, :controller

  @doc "`GET /api/tasks/poll/{tasktype}` (`poll`, `workerid`, `domain`): a task or 204."
  @spec poll(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def poll(conn, _params), do: Errors.send_no_route(conn)

  @doc "`GET /api/tasks/poll/batch/{tasktype}` (`batchPoll`, `count`, `timeout`)."
  @spec batch_poll(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def batch_poll(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/tasks` (`updateTask`, a `TaskResult` body): the task ID as text."
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, _params), do: Errors.send_no_route(conn)

  @doc "`POST /api/tasks/update-v2` (`updateTaskV2`): the next task or 204."
  @spec update_v2(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_v2(conn, _params), do: Errors.send_no_route(conn)

  @doc "`GET /api/tasks/{taskId}` (`getTask`)."
  @spec get(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get(conn, _params), do: Errors.send_no_route(conn)
end
