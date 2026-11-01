# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# WorkflowResource.java (getExecutionStatusTaskList, getWorkflows, getRunningWorkflow),
# core/src/main/java/com/netflix/conductor/service/WorkflowServiceImpl.java (getWorkflows) and
# sqlite-persistence/.../dao/SqliteExecutionDAO.java (getWorkflowsByCorrelationId: the null
# correlation ID) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: Phoenix actions on `Archon.Runtime` (ADR 0025, decision 4); Java's
# `subList` checks are written out.

defmodule ArchonWeb.WorkflowQueryController do
  @moduledoc """
  Workflow queries (upstream `WorkflowResource`, ADR 0025 decision 4) on `Archon.Runtime`.

  The correlated and running lists are ordered by create time and then workflow ID; upstream
  leaves the order unspecified.
  """

  use ArchonWeb, :controller

  alias Archon.Domain.{Codec, SearchResult, Workflow}
  alias Archon.Runtime

  # Persisted and read back at run time, so the list may shrink to [] without a spec to change.
  Module.register_attribute(__MODULE__, :unimplemented, persist: true)

  @unimplemented []

  @int_range -2_147_483_648..2_147_483_647

  @correlated_many_handler "public java.util.Map<java.lang.String, " <>
                             "java.util.List<com.netflix.conductor.common.run.Workflow>> " <>
                             "com.netflix.conductor.rest.controllers.WorkflowResource." <>
                             "getWorkflows(java.lang.String,boolean,boolean," <>
                             "java.util.List<java.lang.String>)"

  @doc "The actions not implemented yet."
  @spec unimplemented() :: [atom()]
  def unimplemented, do: Keyword.fetch!(__MODULE__.__info__(:attributes), :unimplemented)

  @doc """
  `GET /api/workflow/{workflowId}/tasks` (`getExecutionStatusTaskList`, `start` 0, `count` 15,
  `status`): a `SearchResult` of the tasks in `seq` order whose status is one of `status`
  (compared in upper case), one page of them, and their number as `totalHits`.

  The page is upstream's `subList(min(start, total), min(start + count, total))` with Java's
  `int` overflow and checks: a negative start is a 500 `"fromIndex = <start>"`, and an end before
  the start a 400 `"fromIndex(<from>) > toIndex(<to>)"` (`start=5&count=-1` of three tasks is an
  empty page).
  """
  @spec tasks(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def tasks(conn, %{"workflowId" => id}) do
    with {:ok, start} <- query(conn, Request.int(conn, "start", 0, "java.lang.Integer")),
         {:ok, count} <- query(conn, Request.int(conn, "count", 15, "java.lang.Integer")),
         statuses = Request.strings(conn, "status"),
         {:ok, workflow} <- workflow(conn, id) do
      tasks = filter(workflow.tasks, statuses)
      total = length(tasks)

      case page(tasks, total, start, count) do
        {:ok, page} ->
          Response.json(
            conn,
            SearchResult.to_json(%SearchResult{total_hits: total, results: page})
          )

        {:error, reason} ->
          Errors.send_error(conn, reason)
      end
    end
  end

  defp filter(tasks, statuses) when statuses in [nil, []], do: tasks

  defp filter(tasks, statuses) do
    names = MapSet.new(statuses, &String.upcase/1)
    Enum.filter(tasks, &MapSet.member?(names, Codec.enum_name(&1.status)))
  end

  # Math.min(start, total), Math.min(start + count, total) in int arithmetic, then
  # ArrayList#subList's checks in their order.
  defp page(tasks, total, start, count) do
    from = min(start, total)
    to = min(int(start + count), total)

    cond do
      from < 0 -> {:error, {:server_error, "fromIndex = #{from}"}}
      from > to -> {:error, {:invalid, "fromIndex(#{from}) > toIndex(#{to})"}}
      true -> {:ok, Enum.slice(tasks, from, to - from)}
    end
  end

  # Wraps a sum of two ints as Java's int addition.
  defp int(value) when value in @int_range, do: value
  defp int(value) when value > 0, do: value - 4_294_967_296
  defp int(value), do: value + 4_294_967_296

  defp workflow(conn, id) do
    case Runtime.get_workflow(id, true) do
      {:ok, workflow} ->
        {:ok, workflow}

      {:error, :not_found} ->
        Errors.send_error(conn, {:not_found, "No such workflow found by id: #{id}"})
    end
  end

  @doc """
  `GET /api/workflow/{name}/correlated/{correlationId}` (`getWorkflows`, `includeClosed` and
  `includeTasks` false): the workflows of the definition `name` (any version) with that
  correlation ID, only the `RUNNING` ones unless `includeClosed`.
  """
  @spec correlated(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def correlated(conn, %{"name" => name, "correlationId" => correlation_id}) do
    with {:ok, closed?, tasks?} <- include(conn) do
      now = System.system_time(:millisecond)

      Response.json(
        conn,
        Enum.map(
          Runtime.correlated_workflows(name, correlation_id, closed?, tasks?),
          &Workflow.to_json(&1, now)
        )
      )
    end
  end

  @doc """
  `POST /api/workflow/{name}/correlated` (`getWorkflows`, `includeClosed` and `includeTasks`
  false, a list of correlation IDs as the body): `{correlationId: [Workflow]}`, a repeated ID
  once. As for upstream's other list bodies, a single value is a list of one; a `null` ID is
  upstream's 500 `"correlationId cannot be null"`.
  """
  @spec correlated_many(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def correlated_many(conn, %{"name" => name}) do
    # Spring converts the handler's arguments in their order: the query values, then the body.
    with {:ok, closed?, tasks?} <- include(conn),
         {:ok, json, conn} <- body(conn),
         {:ok, ids} <- decode(conn, ids(json)),
         :ok <- check_ids(conn, ids) do
      now = System.system_time(:millisecond)

      result =
        Map.new(ids, fn id ->
          workflows = Runtime.correlated_workflows(name, id, closed?, tasks?)
          {id, Enum.map(workflows, &Workflow.to_json(&1, now))}
        end)

      Response.json(conn, result)
    end
  end

  # accept-single-value-as-array: a value that is not an array is a list of one.
  defp ids(json) when is_list(json), do: Codec.cast({:list, :string}, json, [])
  defp ids(json), do: ids([json])

  # SqliteExecutionDAO#getWorkflowsByCorrelationId's Preconditions.checkNotNull, an
  # unmapped NullPointerException.
  defp check_ids(conn, ids) do
    if Enum.member?(ids, nil),
      do: Errors.send_error(conn, {:server_error, "correlationId cannot be null"}),
      else: :ok
  end

  defp include(conn) do
    with {:ok, closed?} <- query(conn, Request.boolean(conn, "includeClosed", false)),
         {:ok, tasks?} <- query(conn, Request.boolean(conn, "includeTasks", false)) do
      {:ok, closed?, tasks?}
    end
  end

  @doc """
  `GET /api/workflow/running/{name}` (`getRunningWorkflow`, `version` 1, `startTime`, `endTime`):
  workflow IDs. With both times given and not 0, the workflows of that name and version created
  between them in any status; otherwise the `RUNNING` and `PAUSED` workflows of that name,
  whatever `version` says (upstream's SQLite store ignores it).
  """
  @spec running(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def running(conn, %{"name" => name}) do
    with {:ok, version} <- query(conn, Request.int(conn, "version", 1)),
         {:ok, start_ms} <- query(conn, Request.long(conn, "startTime", nil)),
         {:ok, end_ms} <- query(conn, Request.long(conn, "endTime", nil)) do
      Response.json(conn, Runtime.running_workflow_ids(name, version, start_ms, end_ms))
    end
  end

  # Every failure below is answered here, so a `with` falls through with the sent conn.
  defp body(conn) do
    case Request.read_json(conn, handler: @correlated_many_handler) do
      {:ok, json, conn} -> {:ok, json, conn}
      {:error, reason, conn} -> Errors.send_error(conn, reason)
    end
  end

  defp decode(_conn, {:ok, value}), do: {:ok, value}
  defp decode(conn, {:error, errors}), do: Errors.send_error(conn, Request.codec_error(errors))

  defp query(_conn, {:ok, value}), do: {:ok, value}
  defp query(conn, {:error, reason}), do: Errors.send_error(conn, reason)
end
