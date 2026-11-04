# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# WorkflowResource.java and TaskResource.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: skeletons of the Phase 8 search handlers (ADR 0027); every action
# answers the 404 of a path without a handler until slice 8e implements it.

defmodule ArchonWeb.SearchController do
  @moduledoc """
  Workflow and task search over the index (upstream `WorkflowResource#search*` and
  `TaskResource#search*`, ADR 0027 decisions 1 and 5).

  The actions are skeletons (ADR 0027, decision 7): each answers the 404 of a path without a
  handler, and the contract replay (`ArchonWeb.ContractCase`) skips the steps that reach an
  action of `unimplemented/0`. Slice 8e empties the list.
  """

  use ArchonWeb, :controller

  # Persisted and read back at run time, so the list may shrink to [] without a spec to change.
  Module.register_attribute(__MODULE__, :unimplemented, persist: true)

  @unimplemented [
    :search_workflows,
    :search_workflows_v2,
    :search_workflows_by_tasks,
    :search_workflows_by_tasks_v2,
    :search_tasks,
    :search_tasks_v2
  ]

  @doc "The actions not implemented yet."
  @spec unimplemented() :: [atom()]
  def unimplemented, do: Keyword.fetch!(__MODULE__.__info__(:attributes), :unimplemented)

  @doc """
  `GET /api/workflow/search` (`search`: `start`, `size`, `sort`, `freeText`, `query`,
  `classifier`, `topLevelOnly`): a `SearchResult` of workflow summaries. Not implemented yet.
  """
  @spec search_workflows(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_workflows(conn, _params), do: Errors.send_no_route(conn)

  @doc """
  `GET /api/workflow/search-v2` (`searchV2`, the queries of `search`): a `SearchResult` of
  workflows. Not implemented yet.
  """
  @spec search_workflows_v2(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_workflows_v2(conn, _params), do: Errors.send_no_route(conn)

  @doc """
  `GET /api/workflow/search-by-tasks` (`searchWorkflowsByTasks`: `start`, `size`, `sort`,
  `freeText`, `query`): a `SearchResult` of workflow summaries. Not implemented yet.
  """
  @spec search_workflows_by_tasks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_workflows_by_tasks(conn, _params), do: Errors.send_no_route(conn)

  @doc """
  `GET /api/workflow/search-by-tasks-v2` (`searchWorkflowsByTasksV2`): a `SearchResult` of
  workflows. Not implemented yet.
  """
  @spec search_workflows_by_tasks_v2(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_workflows_by_tasks_v2(conn, _params), do: Errors.send_no_route(conn)

  @doc """
  `GET /api/tasks/search` (`search`: `start`, `size`, `sort`, `freeText`, `query`): a
  `SearchResult` of task summaries. Not implemented yet.
  """
  @spec search_tasks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_tasks(conn, _params), do: Errors.send_no_route(conn)

  @doc "`GET /api/tasks/search-v2` (`searchV2`): a `SearchResult` of tasks. Not implemented yet."
  @spec search_tasks_v2(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_tasks_v2(conn, _params), do: Errors.send_no_route(conn)
end
