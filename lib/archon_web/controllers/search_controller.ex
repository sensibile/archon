# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# WorkflowResource.java (search, searchV2, searchWorkflowsByTasks, searchWorkflowsByTasksV2,
# withClassifierFilter, withTopLevelFilter), TaskResource.java (search, searchV2) and
# core/src/main/java/com/netflix/conductor/service/WorkflowService.java (the @Max on size) at
# commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: Phoenix actions on the searches of Archon.Runtime (ADR 0027, decisions 1
# and 5); the agentHierarchy sort is not added.

defmodule ArchonWeb.SearchController do
  @moduledoc """
  Workflow and task search over the index (upstream `WorkflowResource#search*` and
  `TaskResource#search*`, ADR 0027 decisions 1 and 5) on the searches of `Archon.Runtime`.

  The queries and their defaults are upstream's: `start` 0, `size` 100, `sort`, `freeText` `*`,
  `query`, and for the workflow `search` and `search-v2` also `classifier` and `topLevelOnly`
  (false). Spring converts them in that order, and only then does the service's method
  validation refuse a `size` over 5000 (workflow `search` and `search-v2` only) with a 400 on
  `<method>.arg1`. A repeated `sort` is one value joined with `,`, as Spring joins it.

  `classifier` (comma-separated, each value trimmed, empty ones dropped) is added to `query` as a
  `classifier IN (...)` clause and `topLevelOnly` as a `parentWorkflowId=""` clause, as upstream
  does. The `agentHierarchy:DESC` sort upstream puts first for `classifier=agent` is not added
  (ADR 0027, decision 1).

  A malformed clause is upstream's 400 (`IllegalArgumentException`); a time value that is not a
  number, a column the index lacks and the other query errors are a 500 with upstream's message
  (`Archon.Search.Query.describe/1`).
  """

  use ArchonWeb, :controller

  alias Archon.Domain.{SearchResult, SummaryUtil}
  alias Archon.Runtime
  alias Archon.Search.Query

  # WorkflowService#searchWorkflows / #searchWorkflowsV2: @Max(5_000) on size.
  @max_size 5000
  @max_size_message "Cannot return more than #{@max_size} workflows. Please use pagination."

  @doc """
  `GET /api/workflow/search` (`search`: `start`, `size`, `sort`, `freeText`, `query`,
  `classifier`, `topLevelOnly`): a `SearchResult` of the index's workflow summaries.
  """
  @spec search_workflows(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_workflows(conn, _params),
    do: workflow_search(conn, "searchWorkflows", &Runtime.search_workflows/5)

  @doc """
  `GET /api/workflow/search-v2` (`searchV2`, the queries of `search`): a `SearchResult` of the
  found workflows, without their tasks.
  """
  @spec search_workflows_v2(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_workflows_v2(conn, _params),
    do: workflow_search(conn, "searchWorkflowsV2", &Runtime.search_workflows_v2/5)

  @doc """
  `GET /api/workflow/search-by-tasks` (`searchWorkflowsByTasks`: `start`, `size`, `sort`,
  `freeText`, `query`): a `SearchResult` of the summaries of the found tasks' workflows.
  """
  @spec search_workflows_by_tasks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_workflows_by_tasks(conn, _params),
    do: search(conn, &Runtime.search_workflows_by_tasks/5)

  @doc """
  `GET /api/workflow/search-by-tasks-v2` (`searchWorkflowsByTasksV2`): a `SearchResult` of the
  found tasks' workflows, without their tasks.
  """
  @spec search_workflows_by_tasks_v2(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_workflows_by_tasks_v2(conn, _params),
    do: search(conn, &Runtime.search_workflows_by_tasks_v2/5)

  @doc """
  `GET /api/tasks/search` (`search`: `start`, `size`, `sort`, `freeText`, `query`): a
  `SearchResult` of the index's task summaries.
  """
  @spec search_tasks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_tasks(conn, _params), do: search(conn, &Runtime.search_tasks/5)

  @doc "`GET /api/tasks/search-v2` (`searchV2`): a `SearchResult` of the found tasks."
  @spec search_tasks_v2(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search_tasks_v2(conn, _params), do: search(conn, &Runtime.search_tasks_v2/5)

  defp workflow_search(conn, method, fun) do
    with {:ok, start, size, sort, free_text, query} <- common(conn),
         classifier = utf8(Request.string(conn, "classifier")),
         {:ok, top_level?} <- convert(conn, Request.boolean(conn, "topLevelOnly", false)),
         :ok <- check_size(conn, method, size) do
      query = query |> utf8() |> with_classifier(classifier) |> with_top_level(top_level?)
      run(conn, fun, query, free_text, sort, start, size)
    end
  end

  defp search(conn, fun) do
    with {:ok, start, size, sort, free_text, query} <- common(conn),
         do: run(conn, fun, query, free_text, sort, start, size)
  end

  # start, size, sort, freeText, query: the handlers' first parameters, in their order.
  defp common(conn) do
    with {:ok, start} <- convert(conn, Request.int(conn, "start", 0)),
         {:ok, size} <- convert(conn, Request.int(conn, "size", 100)) do
      {:ok, start, size, Request.string(conn, "sort"), Request.string(conn, "freeText", "*"),
       Request.string(conn, "query")}
    end
  end

  defp check_size(conn, method, size) when size > @max_size do
    Errors.send_error(conn, {:invalid, [{"", @max_size_message}]},
      path: "#{method}.arg1",
      value: size
    )
  end

  defp check_size(_conn, _method, _size), do: :ok

  defp run(conn, fun, query, free_text, sort, start, size) do
    case fun.(query, free_text, Query.sort_list(sort), start, size) do
      {:ok, total, results} ->
        Response.json(
          conn,
          SearchResult.to_json(%SearchResult{
            total_hits: total,
            results: Enum.map(results, &result/1)
          })
        )

      {:error, error} ->
        Errors.send_error(conn, error_reason(error))
    end
  end

  # A summary is its stored JSON text.
  defp result(json) when is_binary(json), do: %SearchResult.Json{text: json}
  defp result(struct), do: struct

  defp error_reason(error) do
    case Query.describe(error) do
      {"IllegalArgumentException", message} -> {:invalid, message}
      {_exception, message} -> {:server_error, message}
    end
  end

  # WorkflowResource#withClassifierFilter
  defp with_classifier(query, classifier) do
    values =
      if classifier == nil or SummaryUtil.blank?(classifier),
        do: "",
        else:
          classifier
          |> String.split(",")
          |> Enum.map(&java_trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(",")

    if values == "", do: query, else: and_clause(query, "classifier IN (#{values})")
  end

  # WorkflowResource#withTopLevelFilter
  defp with_top_level(query, false), do: query
  defp with_top_level(query, true), do: and_clause(query, ~s(parentWorkflowId=""))

  defp and_clause(query, clause) do
    if query == nil or SummaryUtil.blank?(query), do: clause, else: query <> " AND " <> clause
  end

  # Tomcat decodes a byte that is not UTF-8 as U+FFFD (Archon.Search.Query does the same).
  defp utf8(nil), do: nil
  defp utf8(text), do: String.replace_invalid(text, "\uFFFD")

  # Java's String#trim: every character up to U+0020 at either end (as ArchonWeb.Request's
  # private one).
  defp java_trim(text), do: String.replace(text, ~r/\A[\x00-\x20]+|[\x00-\x20]+\z/, "")

  defp convert(_conn, {:ok, value}), do: {:ok, value}
  defp convert(conn, {:error, reason}), do: Errors.send_error(conn, reason)
end
