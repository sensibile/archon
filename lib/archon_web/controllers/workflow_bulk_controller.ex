# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# WorkflowBulkResource.java, core/src/main/java/com/netflix/conductor/service/
# WorkflowBulkService.java and WorkflowBulkServiceImpl.java at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the Phase 6 handlers (ADR 0025, decision 6) on the single workflow
# functions of Archon.Runtime and Archon.Runtime.Lifecycle; a failure's message is the one the
# single REST action answers; the Phase 8 search handler (ADR 0027, decision 5) reads each
# workflow with Archon.Runtime.get_workflow/2 and answers upstream's WorkflowModel shape.

defmodule ArchonWeb.WorkflowBulkController do
  @moduledoc """
  Bulk workflow operations (upstream `WorkflowBulkResource`, ADR 0025 decision 6) on the single
  workflow functions of `Archon.Runtime` and `Archon.Runtime.Lifecycle`.

  The body is a list of workflow IDs (a value that is not an array is a list of one, an integer
  or boolean is its text as Jackson converts them, a decimal the text of its float). Spring
  converts the body first, then the query values, and only then does the service's method
  validation check the list: an empty list and a list of more than 1000 IDs are a 400
  `validationErrors` on `<method>.arg0`.

  Each ID is handled in turn by the single function, as `WorkflowBulkServiceImpl` does, and the
  answer is a `BulkResponse`: the IDs that succeeded in request order, and for each ID that
  failed the message of the single REST action's error (a later failure of the same ID replaces
  the earlier one, upstream's `HashMap#put`). A raised exception or exit fails that ID only, as
  upstream catches every `Exception`. A `null` ID fails like an unknown one, and upstream then
  cannot write the `null` key of the error map: the other IDs are handled and the answer is a
  500.

  Every action reads its body before it does anything, so a browser's cross-origin "simple"
  request (a form, `fetch` in `no-cors` mode) is refused by the JSON `Content-Type` check of
  `ArchonWeb.Request` (ADR 0023, decision 3), or, without a body, by the missing body. `PUT` and
  `DELETE` always need a CORS preflight. Unlike the single `retry`, `restart` and
  `resetcallbacks` (ADR 0025, decision 3) no cross-origin check is added.

  `search` (ADR 0027, decision 5) checks its body the same way and reads each ID's workflow; its
  successful results are workflows in upstream's internal `WorkflowModel` shape
  (`Archon.Domain.WorkflowModelJson`), not the REST `Workflow`.
  """

  use ArchonWeb, :controller

  alias Archon.Domain.{BulkResponse, Codec, WorkflowModelJson}
  alias Archon.Runtime
  alias Archon.Runtime.Lifecycle

  # WorkflowBulkService.MAX_REQUEST_ITEMS
  @max_ids 1000
  @empty_message "WorkflowIds list cannot be null."
  @too_many_message "Cannot process more than #{@max_ids} workflows. Please use multiple requests."
  @completed_message "Cannot terminate a COMPLETED workflow."
  # Jackson's default null-key serializer, through Spring's HttpMessageNotWritableException.
  @null_key_message "Could not write JSON: Null key for a Map not allowed in JSON " <>
                      "(use a converting NullKeySerializer?)"

  @handler "public com.netflix.conductor.common.model.BulkResponse<java.lang.String> " <>
             "com.netflix.conductor.rest.controllers.WorkflowBulkResource."
  @search_handler "public com.netflix.conductor.common.model.BulkResponse" <>
                    "<com.netflix.conductor.model.WorkflowModel> " <>
                    "com.netflix.conductor.rest.controllers.WorkflowBulkResource."
  @ids_type "java.util.List<java.lang.String>"

  @doc """
  `POST /api/workflow/bulk/search` (`searchWorkflow`, `includeTasks` true): each ID's workflow,
  with its tasks unless `includeTasks` is false, read with `Archon.Runtime.get_workflow/2` in
  request order (a repeated ID is there again). An unknown ID fails with
  `"No such workflow found by id: <id>"`. No index is used.
  """
  @spec search(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def search(conn, _params) do
    with {:ok, ids, conn} <- ids(conn, "searchWorkflow", ["boolean"], @search_handler),
         {:ok, tasks?} <- query(conn, Request.boolean(conn, "includeTasks", true)),
         :ok <- check(conn, ids, "searchWorkflow") do
      {workflows, response} = Enum.reduce(ids, {[], %BulkResponse{}}, &read_one(&1, tasks?, &2))

      if Enum.member?(ids, nil) do
        Errors.send_error(conn, {:server_error, @null_key_message})
      else
        now = System.system_time(:millisecond)
        response = %{response | bulk_successful_results: Enum.reverse(workflows)}

        Response.json(conn, BulkResponse.to_json(response, &WorkflowModelJson.workflow(&1, now)))
      end
    end
  end

  defp read_one(id, tasks?, {workflows, response}) do
    case read(id, tasks?) do
      {:ok, workflow} -> {[workflow | workflows], response}
      {:error, reason} -> {workflows, BulkResponse.failure(response, id, message(id, reason))}
    end
  end

  # A null ID is not found upstream; its failure is never written (search/2).
  defp read(nil, _tasks?), do: {:error, :not_found}
  defp read(id, tasks?), do: run(&Runtime.get_workflow(&1, tasks?), id)

  @doc "`PUT /api/workflow/bulk/pause` (`pauseWorkflow`): `Archon.Runtime.Lifecycle.pause/1` for each ID."
  @spec pause(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pause(conn, _params) do
    with {:ok, ids, conn} <- ids(conn, "pauseWorkflow", []),
         :ok <- check(conn, ids, "pauseWorkflow") do
      bulk(conn, ids, &Lifecycle.pause/1)
    end
  end

  @doc "`PUT /api/workflow/bulk/resume` (`resumeWorkflow`): `Archon.Runtime.Lifecycle.resume/1` for each ID."
  @spec resume(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resume(conn, _params) do
    with {:ok, ids, conn} <- ids(conn, "resumeWorkflow", []),
         :ok <- check(conn, ids, "resumeWorkflow") do
      bulk(conn, ids, &Lifecycle.resume/1)
    end
  end

  @doc """
  `POST /api/workflow/bulk/restart` (`restart`, `useLatestDefinitions` false):
  `Archon.Runtime.Lifecycle.restart/2` for each ID.
  """
  @spec restart(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def restart(conn, _params) do
    with {:ok, ids, conn} <- ids(conn, "restart", ["boolean"]),
         {:ok, latest?} <- query(conn, Request.boolean(conn, "useLatestDefinitions", false)),
         :ok <- check(conn, ids, "restart") do
      bulk(conn, ids, &Lifecycle.restart(&1, latest?))
    end
  end

  @doc """
  `POST /api/workflow/bulk/retry` (`retry`): `Archon.Runtime.Lifecycle.retry/2` for each ID, with
  `resumeSubworkflowTasks` false.
  """
  @spec retry(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def retry(conn, _params) do
    with {:ok, ids, conn} <- ids(conn, "retry", []),
         :ok <- check(conn, ids, "retry") do
      bulk(conn, ids, &Lifecycle.retry(&1, false))
    end
  end

  @doc """
  `POST /api/workflow/bulk/terminate` (`terminate`, `reason`): `Archon.Runtime.terminate_workflow/2`
  for each ID; a `COMPLETED` workflow fails with `"Cannot terminate a COMPLETED workflow."`.
  """
  @spec terminate(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def terminate(conn, _params) do
    with {:ok, ids, conn} <- ids(conn, "terminate", ["java.lang.String"]),
         reason = Request.string(conn, "reason"),
         :ok <- check(conn, ids, "terminate") do
      bulk(conn, ids, &terminate_workflow(&1, reason))
    end
  end

  @doc """
  `DELETE /api/workflow/bulk/remove` (`deleteWorkflow`, `archiveWorkflow` true):
  `Archon.Runtime.Lifecycle.remove/2` for each ID, which may wait up to its `remove_timeout`
  (10 s) for each (ADR 0025, decision 3).
  """
  @spec remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def remove(conn, _params) do
    with {:ok, ids, conn} <- ids(conn, "deleteWorkflow", ["boolean"]),
         {:ok, archive?} <- query(conn, Request.boolean(conn, "archiveWorkflow", true)),
         :ok <- check(conn, ids, "deleteWorkflow") do
      bulk(conn, ids, &Lifecycle.remove(&1, archive?))
    end
  end

  @doc """
  `DELETE /api/workflow/bulk/terminate-remove` (`terminateRemove`, `archiveWorkflow` true,
  `reason`): for each ID the termination of `terminate/2`, then the removal of `remove/2`
  whatever the termination did. Each that succeeds adds the ID to the successful results, so a
  workflow both terminated and removed is there twice, and a `COMPLETED` one fails to terminate
  and is still removed (upstream's two `try` blocks, ADR 0025 decision 6).
  """
  @spec terminate_remove(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def terminate_remove(conn, _params) do
    with {:ok, ids, conn} <- ids(conn, "terminateRemove", ["boolean", "java.lang.String"]),
         {:ok, archive?} <- query(conn, Request.boolean(conn, "archiveWorkflow", true)),
         reason = Request.string(conn, "reason"),
         :ok <- check(conn, ids, "terminateRemove") do
      bulk(conn, ids, [&terminate_workflow(&1, reason), &Lifecycle.remove(&1, archive?)])
    end
  end

  defp terminate_workflow(id, reason) do
    case Runtime.terminate_workflow(id, reason) do
      {:error, :conflict} -> {:error, {:conflict, @completed_message}}
      result -> result
    end
  end

  defp bulk(conn, ids, operation) when is_function(operation, 1),
    do: bulk(conn, ids, [operation])

  defp bulk(conn, ids, operations) do
    operations = Enum.with_index(operations)

    {successes, response, _pending} =
      Enum.reduce(ids, {[], %BulkResponse{}, MapSet.new()}, fn id, acc ->
        Enum.reduce(operations, acc, &apply_one(&1, id, &2))
      end)

    if Enum.member?(ids, nil) do
      Errors.send_error(conn, {:server_error, @null_key_message})
    else
      response = %{response | bulk_successful_results: Enum.reverse(successes)}
      Response.json(conn, BulkResponse.to_json(response))
    end
  end

  # A null ID is not found upstream; its failure is never written (bulk/3).
  defp apply_one(_operation, nil, acc), do: acc

  # A removal that already waited out its outbox for this ID in this request (ADR 0025,
  # decision 3) fails the same way again without another wait, so repeating an ID does not
  # multiply the request's time.
  defp apply_one({operation, index}, id, {successes, response, pending}) do
    result =
      if MapSet.member?(pending, {index, id}),
        do: {:error, :outbox_pending},
        else: run(operation, id)

    case result do
      :ok ->
        {[id | successes], response, pending}

      {:error, reason} ->
        pending =
          if reason == :outbox_pending, do: MapSet.put(pending, {index, id}), else: pending

        {successes, BulkResponse.failure(response, id, message(id, reason)), pending}
    end
  end

  defp run(operation, id) do
    operation.(id)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # The message the single REST action answers (`ExecutionDAOFacade#getWorkflowModel` for an
  # unknown ID); a 500's is its fixed message, never an Elixir term.
  defp message(id, :not_found), do: "No such workflow found by id: #{id}"
  defp message(_id, reason), do: Errors.error_response(reason).message

  # Every failure below is answered here, so a `with` falls through with the sent conn.
  defp ids(conn, method, query_types, prefix \\ @handler) do
    handler = "#{prefix}#{method}(#{Enum.join([@ids_type | query_types], ",")})"

    with {:ok, json, conn} <- body(conn, handler),
         {:ok, ids} <- decode(conn, cast_ids(json)) do
      {:ok, ids, conn}
    end
  end

  # A list over the limit is only counted by check/3, so it is not converted: only its first
  # value that would fail to convert is looked for, the error Jackson would stop at.
  defp cast_ids(json) when is_list(json) and length(json) > @max_ids do
    case Enum.find_index(json, &(is_map(&1) or is_list(&1))) do
      nil -> {:ok, json}
      index -> Codec.cast(:string, Enum.at(json, index), [index])
    end
  end

  # accept-single-value-as-array: a value that is not an array is a list of one.
  defp cast_ids(json) when is_list(json), do: Codec.cast({:list, :string}, json, [])
  defp cast_ids(json), do: cast_ids([json])

  # The service's @NotEmpty and @Size(max = 1000) on its first argument.
  defp check(conn, [], method), do: invalid(conn, method, [], @empty_message)

  defp check(conn, ids, method) when length(ids) > @max_ids,
    do: invalid(conn, method, ids, @too_many_message)

  defp check(_conn, _ids, _method), do: :ok

  defp invalid(conn, method, ids, message),
    do: Errors.send_error(conn, {:invalid, [{"", message}]}, path: "#{method}.arg0", value: ids)

  defp body(conn, handler) do
    case Request.read_json(conn, handler: handler) do
      {:ok, json, conn} -> {:ok, json, conn}
      {:error, reason, conn} -> Errors.send_error(conn, reason)
    end
  end

  defp decode(_conn, {:ok, value}), do: {:ok, value}
  defp decode(conn, {:error, errors}), do: Errors.send_error(conn, Request.codec_error(errors))

  defp query(_conn, {:ok, value}), do: {:ok, value}
  defp query(conn, {:error, reason}), do: Errors.send_error(conn, reason)
end
