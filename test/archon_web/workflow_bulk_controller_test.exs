# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.WorkflowBulkControllerTest do
  @moduledoc """
  `ArchonWeb.WorkflowBulkController` beyond the contract replay (ADR 0025, decision 6, slice 6g):
  the 1000-ID limit, the order of the body, query and validation errors, the ID values Jackson
  converts, a `null` ID, repeated IDs, an ID that fails while the others go on, and a browser's
  cross-origin request. The expected values were observed on the upstream server.
  """

  use ArchonWeb.ContractCase, async: false

  @moduletag :capture_log

  alias Archon.Domain.Codec
  alias Archon.Runtime
  alias Archon.RuntimeCase
  alias ArchonWeb.Request

  @handler "public com.netflix.conductor.common.model.BulkResponse<java.lang.String> " <>
             "com.netflix.conductor.rest.controllers.WorkflowBulkResource."
  @ids "java.util.List<java.lang.String>"

  # {method, path, upstream method, the handler's parameters after the IDs}
  @actions [
    {:put, "pause", "pauseWorkflow", []},
    {:put, "resume", "resumeWorkflow", []},
    {:post, "restart", "restart", ["boolean"]},
    {:post, "retry", "retry", []},
    {:post, "terminate", "terminate", ["java.lang.String"]},
    {:delete, "remove", "deleteWorkflow", ["boolean"]},
    {:delete, "terminate-remove", "terminateRemove", ["boolean", "java.lang.String"]}
  ]

  @unknown "00000000-0000-0000-0000-000000000000"

  setup do
    Archon.RuntimeHooks.reset()
    on_exit(&Archon.RuntimeHooks.reset/0)
    RuntimeCase.register_definitions()
    :ok
  end

  defp start do
    {:ok, id} = Runtime.start_workflow(%{name: "archon_simple", input: %{}})
    id
  end

  defp bulk(method, path, body, headers \\ [{"content-type", "application/json"}]) do
    conn = Enum.reduce(headers, build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    dispatch(conn, @endpoint, method, "/api/workflow/bulk/#{path}", body)
  end

  defp status(id) do
    {:ok, workflow} = Runtime.get_workflow(id)
    workflow.status
  end

  defp server_error(conn), do: conn |> json_response(500) |> Map.fetch!("message")

  test "the ID list may hold 1000 IDs, not 1001" do
    ids = Enum.map(1..1000, &"archon-bulk-missing-#{&1}")

    for {method, path, upstream, _params} <- @actions, path in ~w(pause terminate) do
      conn = bulk(method, path, Jason.encode!(ids))

      assert %{"bulkSuccessfulResults" => [], "bulkErrorResults" => errors} =
               json_response(conn, 200)

      assert map_size(errors) == 1000

      for {list, message} <- [
            {[], "WorkflowIds list cannot be null."},
            {["x" | ids],
             "Cannot process more than 1000 workflows. Please use multiple requests."}
          ] do
        conn = bulk(method, path, Jason.encode!(list))

        assert %{
                 "status" => 400,
                 "message" => "Validation failed, check below errors for detail.",
                 "retryable" => false,
                 "validationErrors" => [%{"path" => path_name, "message" => ^message} = error]
               } = json_response(conn, 400)

        assert path_name == upstream <> ".arg0"
        refute Map.has_key?(error, "invalidValue")
      end
    end
  end

  test "a list over the limit is not converted, but its first bad value still fails first" do
    ids = Enum.map(1..1001, &"archon-bulk-missing-#{&1}")

    for bad <- [%{}, []] do
      list = List.replace_at(ids, 1000, bad) ++ [%{"x" => 1}]
      {:error, errors} = Codec.cast({:list, :string}, list, [])
      {:server_error, expected} = Request.codec_error(errors)

      assert server_error(bulk(:put, "pause", Jason.encode!(list))) == expected
      assert expected =~ "[1000]"
    end

    # every value converts: the count is checked
    assert %{"validationErrors" => [_error]} =
             json_response(bulk(:put, "pause", Jason.encode!([1, true, nil | ids])), 400)
  end

  test "every action checks its own body and names its own handler and method" do
    for {method, path, upstream, params} <- @actions do
      handler = "#{@handler}#{upstream}(#{Enum.join([@ids | params], ",")})"

      for body <- ["", "null"] do
        assert server_error(bulk(method, path, body)) ==
                 "Required request body is missing: " <> handler
      end

      assert %{"validationErrors" => [%{"path" => path_name}]} =
               json_response(bulk(method, path, "[]"), 400)

      assert path_name == upstream <> ".arg0"
    end
  end

  test "the body is converted first, then the query, and only then the list checked" do
    mismatch = fn name ->
      "Method parameter '#{name}': Failed to convert value of type 'java.lang.String' to " <>
        "required type 'boolean'; Invalid boolean value [abc]"
    end

    for {path, name} <- [
          {"restart?useLatestDefinitions=abc", "useLatestDefinitions"},
          {"remove?archiveWorkflow=abc", "archiveWorkflow"},
          {"terminate-remove?archiveWorkflow=abc", "archiveWorkflow"}
        ] do
      method = if String.starts_with?(path, "restart"), do: :post, else: :delete

      assert server_error(bulk(method, path, "")) =~ "Required request body is missing: "
      assert server_error(bulk(method, path, "[{}]")) =~ "JSON parse error: "
      assert server_error(bulk(method, path, "[]")) == mismatch.(name)
      assert server_error(bulk(method, path, ~s(["x"]))) == mismatch.(name)
    end
  end

  test "an ID that is a number or boolean is its text, an object or array is a 500" do
    conn = bulk(:put, "pause", "[1, true, 1.5]")

    assert json_response(conn, 200) == %{
             "bulkSuccessfulResults" => [],
             "bulkErrorResults" => %{
               "1" => "No such workflow found by id: 1",
               "true" => "No such workflow found by id: true",
               "1.5" => "No such workflow found by id: 1.5"
             }
           }

    assert json_response(bulk(:put, "pause", ~s("")), 200) == %{
             "bulkSuccessfulResults" => [],
             "bulkErrorResults" => %{"" => "No such workflow found by id: "}
           }

    for body <- ["[{}]", "[[]]", "{}"] do
      assert server_error(bulk(:put, "pause", body)) =~ "JSON parse error: "
    end
  end

  test "a null ID is a 500 after the other IDs were handled" do
    id = start()

    assert server_error(bulk(:put, "pause", Jason.encode!([id, nil]))) ==
             "Could not write JSON: Null key for a Map not allowed in JSON " <>
               "(use a converting NullKeySerializer?)"

    assert status(id) == :paused
  end

  test "a repeated ID is handled each time, its failure is one entry" do
    assert json_response(bulk(:put, "pause", Jason.encode!([@unknown, @unknown])), 200) == %{
             "bulkSuccessfulResults" => [],
             "bulkErrorResults" => %{@unknown => "No such workflow found by id: #{@unknown}"}
           }

    id = start()

    # terminated and removed the first time, unknown to both the second
    assert json_response(bulk(:delete, "terminate-remove", Jason.encode!([id, id])), 200) == %{
             "bulkSuccessfulResults" => [id, id],
             "bulkErrorResults" => %{id => "No such workflow found by id: #{id}"}
           }

    assert {:error, :not_found} = Runtime.get_workflow(id)
  end

  test "a failure is the single action's message and the next ID is still handled" do
    running = start()
    other = start()

    single = fn id ->
      conn = build_conn() |> delete("/api/workflow/#{id}/remove")
      {id, json_response(conn, 400)["message"]}
    end

    assert json_response(bulk(:delete, "remove", Jason.encode!([running, other])), 200) == %{
             "bulkSuccessfulResults" => [],
             "bulkErrorResults" => Map.new([running, other], single)
           }

    # a failure of one workflow's step: the single action's fixed message, never the Elixir term
    Archon.RuntimeHooks.install(
      hook: fn
        :step, ^running, _event -> raise "injected"
        _point, _id, _data -> :ok
      end
    )

    single = build_conn() |> put("/api/workflow/#{running}/pause")
    assert %{"message" => "Internal server error"} = json_response(single, 500)

    assert json_response(bulk(:put, "pause", Jason.encode!([running, other])), 200) == %{
             "bulkSuccessfulResults" => [other],
             "bulkErrorResults" => %{running => "Internal server error"}
           }

    assert status(running) == :running
    assert status(other) == :paused
  end

  test "a removal that waits too long for one workflow's outbox fails that ID only" do
    saved = Application.get_env(:archon, Archon.Runtime)
    on_exit(fn -> Application.put_env(:archon, Archon.Runtime, saved) end)
    Application.put_env(:archon, Archon.Runtime, Keyword.put(saved, :remove_timeout, 300))

    pending = start()
    other = start()

    # An entry the process has not handed to its runner, so it stays while the removal asks.
    :ok =
      Runtime.store().commit(pending, %Archon.Runtime.Commit{
        outbox: [{:retry_sub_workflow, "archon-missing-" <> Runtime.new_id()}]
      })

    started = System.monotonic_time(:millisecond)
    list = [pending, other, pending, pending]
    conn = bulk(:delete, "remove?archiveWorkflow=false", Jason.encode!(list))

    # the repeated pending ID did not wait again
    assert System.monotonic_time(:millisecond) - started < 550

    assert json_response(conn, 200) == %{
             "bulkSuccessfulResults" => [other],
             "bulkErrorResults" => %{pending => "Temporary server error, retry the request"}
           }

    assert {:ok, _workflow} = Runtime.get_workflow(pending)
    assert {:error, :not_found} = Runtime.get_workflow(other)
  end

  test "a browser's cross-origin request without a JSON body does nothing" do
    id = start()
    cross = {"sec-fetch-site", "cross-site"}

    for {method, path, _upstream, _params} <- @actions,
        headers <- [
          [cross],
          [cross, {"content-type", "text/plain"}],
          [cross, {"content-type", "application/x-www-form-urlencoded"}]
        ] do
      body = if Enum.count(headers) == 1, do: nil, else: Jason.encode!([id])
      conn = bulk(method, path, body, headers)
      assert json_response(conn, 500)["retryable"] == false
    end

    assert status(id) == :running
  end
end
