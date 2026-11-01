# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.WorkflowQueryControllerTest do
  @moduledoc """
  `ArchonWeb.WorkflowQueryController` (ADR 0025 decision 4, slice 6b) beyond the fixtures, which
  the contract replay covers: Java's `int` overflow in the page, the `status` list conversion,
  the correlated body, the running branches and the order of the lists.

  Each test uses its own correlation IDs and definition names, as other tests share the runtime.
  """

  use ArchonWeb.ContractCase, async: false

  @moduletag :capture_log

  alias Archon.Domain.WorkflowDef
  alias Archon.Runtime
  alias Archon.RuntimeCase

  @handler "public java.util.Map<java.lang.String, " <>
             "java.util.List<com.netflix.conductor.common.run.Workflow>> " <>
             "com.netflix.conductor.rest.controllers.WorkflowResource.getWorkflows(" <>
             "java.lang.String,boolean,boolean,java.util.List<java.lang.String>)"

  setup do
    Archon.RuntimeHooks.reset()
    on_exit(&Archon.RuntimeHooks.reset/0)
    RuntimeCase.register_definitions()
    RuntimeCase.isolate_queues(~w(archon_task_a archon_task_b archon_task_c))
    %{tag: "query-#{System.unique_integer([:positive])}"}
  end

  # archon_simple under another name and version, so a test's running list is its own.
  defp define(name, version) do
    {:ok, definition} = Runtime.metadata().get_workflow_def("archon_simple", 1)

    :ok =
      Runtime.metadata().update_workflow_def(%WorkflowDef{
        definition
        | name: name,
          version: version
      })
  end

  defp start(name, version, correlation_id) do
    {:ok, id} =
      Runtime.start_workflow(%{
        name: name,
        version: version,
        input: %{},
        correlation_id: correlation_id
      })

    on_exit(fn -> Runtime.terminate_workflow(id, nil) end)
    id
  end

  # By create time and then ID, the order of the lists.
  defp ordered(ids) do
    Enum.sort_by(ids, fn id ->
      {:ok, workflow} = Runtime.get_workflow(id, false)
      {workflow.create_time, id}
    end)
  end

  describe "GET /api/workflow/{workflowId}/tasks" do
    test "the end of the page wraps as Java's int addition", %{tag: tag} do
      id = start("archon_simple", 1, tag)
      path = "/api/workflow/#{id}/tasks"

      assert %{"totalHits" => 1, "results" => [_task]} =
               json(get(build_conn(), path <> "?count=2147483647"), 200)

      for {query, from, to} <- [
            {"start=1&count=2147483647", 1, -2_147_483_648},
            {"start=2147483647", 1, -2_147_483_634}
          ] do
        assert message(get(build_conn(), "#{path}?#{query}"), 400) ==
                 "fromIndex(#{from}) > toIndex(#{to})"
      end

      assert message(get(build_conn(), path <> "?start=-2147483648&count=-1"), 500) ==
               "fromIndex = -2147483648"
    end

    test "status is split at commas and trimmed only as a single value", %{tag: tag} do
      id = start("archon_simple", 1, tag)
      path = "/api/workflow/#{id}/tasks"

      for {query, hits} <- [
            {"status=%20scheduled%20,%20completed", 1},
            {"status=", 1},
            {"status=SCHEDULED,", 1},
            {"status=%20scheduled&status=FAILED", 0},
            {"status=&status=", 0},
            {"status=scheduled&status=FAILED", 1}
          ] do
        assert json(get(build_conn(), "#{path}?#{query}"), 200)["totalHits"] == hits, query
      end
    end

    test "start and count are boxed Integers" do
      assert message(get(build_conn(), "/api/workflow/x/tasks?start=abc"), 500) ==
               "Method parameter 'start': Failed to convert value of type 'java.lang.String' " <>
                 ~s(to required type 'java.lang.Integer'; For input string: "abc")

      # Blank text is the default, then the unknown workflow.
      assert message(get(build_conn(), "/api/workflow/x/tasks?count=%20"), 404) ==
               "No such workflow found by id: x"
    end
  end

  describe "correlated" do
    test "lists by create time and then ID, any version, with tasks when asked", %{tag: tag} do
      name = "archon_query_#{tag}"
      define(name, 1)
      define(name, 2)
      ids = ordered([start(name, 1, tag), start(name, 2, tag), start(name, 1, tag)])

      assert Enum.map(
               json(get(build_conn(), "/api/workflow/#{name}/correlated/#{tag}"), 200),
               & &1["workflowId"]
             ) ==
               ids

      assert [%{"tasks" => [%{"seq" => 1}]} | _rest] =
               json(
                 get(build_conn(), "/api/workflow/#{name}/correlated/#{tag}?includeTasks=true"),
                 200
               )

      assert [%{"tasks" => []} | _rest] =
               json(get(build_conn(), "/api/workflow/#{name}/correlated/#{tag}"), 200)
    end

    test "the POST body is a list of strings, a single value a list of one", %{tag: tag} do
      id = start("archon_simple", 1, tag)
      path = "/api/workflow/archon_simple/correlated"

      assert %{^tag => [%{"workflowId" => ^id}]} = json(post_json(path, JSON.encode!(tag)), 200)

      # Jackson's coercion of scalars to strings; a repeated ID is one key.
      assert json(post_json(path, JSON.encode!([tag, 1, true, tag])), 200)
             |> Map.keys()
             |> Enum.sort() ==
               Enum.sort([tag, "1", "true"])
    end

    test "a null ID is upstream's 500, a missing body names the handler" do
      path = "/api/workflow/archon_simple/correlated"
      assert message(post_json(path, ~s(["a", null])), 500) == "correlationId cannot be null"

      for body <- ["", "null"],
          do:
            assert(
              message(post_json(path, body), 500) ==
                "Required request body is missing: " <> @handler
            )

      assert message(post_json(path, ~s([{}])), 500) =~ "JSON parse error: "

      # The query values convert before the body.
      assert message(post_json(path <> "?includeClosed=maybe", ""), 500) ==
               "Method parameter 'includeClosed': Failed to convert value of type " <>
                 "'java.lang.String' to required type 'boolean'; Invalid boolean value [maybe]"
    end
  end

  describe "GET /api/workflow/running/{name}" do
    test "without both times: RUNNING and PAUSED of any version; with them: the version", %{
      tag: tag
    } do
      name = "archon_query_#{tag}"
      define(name, 1)
      define(name, 2)
      v1 = start(name, 1, tag)
      v2 = start(name, 2, tag)
      done = start(name, 1, tag)
      :ok = Runtime.terminate_workflow(done, nil)

      for query <- ["", "?version=7", "?startTime=1", "?startTime=0&endTime=4102444800000"],
          do:
            assert(
              json(get(build_conn(), "/api/workflow/running/#{name}#{query}"), 200) ==
                ordered([v1, v2])
            )

      assert json(
               get(
                 build_conn(),
                 "/api/workflow/running/#{name}?startTime=1&endTime=4102444800000"
               ),
               200
             ) ==
               ordered([v1, done])

      assert json(
               get(
                 build_conn(),
                 "/api/workflow/running/#{name}?version=2&startTime=1&endTime=4102444800000"
               ),
               200
             ) == [v2]

      # Long bounds beyond the create times, and an empty range.
      assert json(
               get(
                 build_conn(),
                 "/api/workflow/running/#{name}?startTime=-9223372036854775808&endTime=9223372036854775807"
               ),
               200
             ) == ordered([v1, done])

      assert json(get(build_conn(), "/api/workflow/running/#{name}?startTime=5&endTime=4"), 200) ==
               []
    end

    test "version is an int and the times Longs" do
      assert message(get(build_conn(), "/api/workflow/running/x?version=abc"), 500) ==
               "Method parameter 'version': Failed to convert value of type 'java.lang.String' " <>
                 ~s(to required type 'int'; For input string: "abc")

      assert message(
               get(build_conn(), "/api/workflow/running/x?endTime=9223372036854775808"),
               500
             ) ==
               "Method parameter 'endTime': Failed to convert value of type 'java.lang.String' " <>
                 ~s(to required type 'java.lang.Long'; For input string: "9223372036854775808")
    end
  end

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, body)
  end

  defp json(conn, status) do
    assert conn.status == status
    assert get_resp_header(conn, "content-type") == ["application/json"]
    JSON.decode!(conn.resp_body)
  end

  defp message(conn, status), do: json(conn, status)["message"]
end
