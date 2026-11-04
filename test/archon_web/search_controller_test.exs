# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.SearchControllerTest do
  @moduledoc """
  `ArchonWeb.SearchController` and `ArchonWeb.WorkflowBulkController.search/2` beyond the
  contract replay (ADR 0027, decisions 1 and 5, slice 8e): the query defaults and their
  conversion order, the 5000 `size` limit of the workflow `search` and `search-v2` only, the
  `classifier` and `topLevelOnly` clauses, the re-reads of the `-v2` and by-tasks searches and
  their `totalHits`, and the 1000-ID limit, validation order and `WorkflowModel` shape of
  `bulk/search`. The suite runs on both backends (`ARCHON_BACKEND`).
  """

  use ArchonWeb.ContractCase, async: false

  @moduletag :capture_log

  alias Archon.Domain.Task, as: DomainTask
  alias Archon.Domain.WorkflowDef
  alias Archon.Runtime
  alias Archon.Runtime.Lifecycle
  alias Archon.RuntimeCase

  @search_handler "public com.netflix.conductor.common.model.BulkResponse" <>
                    "<com.netflix.conductor.model.WorkflowModel> " <>
                    "com.netflix.conductor.rest.controllers.WorkflowBulkResource." <>
                    "searchWorkflow(java.util.List<java.lang.String>,boolean)"

  setup do
    Archon.RuntimeHooks.reset()
    on_exit(&Archon.RuntimeHooks.reset/0)
    RuntimeCase.register_definitions()
    {:ok, name: "archon_8e_#{System.unique_integer([:positive])}"}
  end

  # Two SET_VARIABLE tasks that run and are indexed at the start, then a worker task that is
  # only scheduled (not indexed), so the workflow stays RUNNING, and one not scheduled yet.
  defp start(name, fields \\ []) do
    {:ok, definition} =
      WorkflowDef.from_json(%{
        "name" => name,
        "version" => 1,
        "schemaVersion" => 2,
        "tasks" => [
          %{"name" => "set_a", "taskReferenceName" => "set_a", "type" => "SET_VARIABLE"},
          %{"name" => "set_b", "taskReferenceName" => "set_b", "type" => "SET_VARIABLE"},
          %{"name" => "archon_8e_worker", "taskReferenceName" => "work", "type" => "SIMPLE"},
          %{"name" => "archon_8e_later", "taskReferenceName" => "later", "type" => "SIMPLE"}
        ]
      })

    {:ok, id} =
      Runtime.start_workflow(Map.merge(%{definition: definition, input: %{}}, Map.new(fields)))

    id
  end

  defp fetch(path), do: build_conn() |> get(path) |> then(&{&1.status, json(&1)})

  defp json(%{resp_body: ""}), do: nil
  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp query(params), do: URI.encode_query(params)

  defp ids(%{"results" => results}), do: Enum.map(results, &(&1["workflowId"] || &1["taskId"]))

  defp bulk(body, query \\ "") do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/api/workflow/bulk/search#{query}", body)
  end

  describe "query values" do
    test "the defaults: start 0, size 100, freeText *", %{name: name} do
      first = start(name)
      second = start(name)

      assert {200, %{"totalHits" => 2} = result} =
               fetch(
                 "/api/workflow/search?" <> query(query: "workflowType=#{name}", freeText: "")
               )

      assert ids(result) == [first, second]

      assert {200, %{"totalHits" => 2, "results" => [_one]}} =
               fetch("/api/workflow/search?" <> query(query: "workflowType=#{name}", size: 1))
    end

    test "size over 5000 is refused by the workflow search and search-v2 only", %{name: name} do
      start(name)

      for {path, method} <- [{"search", "searchWorkflows"}, {"search-v2", "searchWorkflowsV2"}] do
        assert {400,
                %{
                  "status" => 400,
                  "message" => "Validation failed, check below errors for detail.",
                  "validationErrors" => [
                    %{
                      "path" => path_name,
                      "message" =>
                        "Cannot return more than 5000 workflows. Please use pagination.",
                      "invalidValue" => "5001"
                    }
                  ]
                }} =
                 fetch(
                   "/api/workflow/#{path}?" <> query(query: "workflowType=#{name}", size: 5001)
                 )

        assert path_name == method <> ".arg1"

        assert {200, %{"totalHits" => 1}} =
                 fetch(
                   "/api/workflow/#{path}?" <> query(query: "workflowType=#{name}", size: 5000)
                 )
      end

      for path <- ~w(/api/workflow/search-by-tasks /api/workflow/search-by-tasks-v2
                     /api/tasks/search /api/tasks/search-v2) do
        assert {200, %{"totalHits" => hits}} =
                 fetch(path <> "?" <> query(query: "workflowType=#{name}", size: 5001))

        assert hits > 0
      end
    end

    test "the values are converted in order before the size is checked and the query parsed" do
      # start is converted before size
      assert {500, %{"message" => message}} =
               fetch("/api/workflow/search?" <> query(start: "x", size: "y"))

      assert message =~ "Method parameter 'start'"

      # every conversion before the size limit
      assert {500, %{"message" => message}} =
               fetch("/api/workflow/search?" <> query(size: 5001, topLevelOnly: "maybe"))

      assert message =~ "Method parameter 'topLevelOnly'"

      # the size limit before the query
      assert {400, %{"validationErrors" => [_error]}} =
               fetch("/api/workflow/search?" <> query(size: 5001, query: "a~b"))
    end

    test "a malformed clause is a 400, a bad time value and a missing column a 500" do
      for path <- ~w(/api/workflow/search /api/workflow/search-v2 /api/tasks/search
                     /api/tasks/search-v2 /api/workflow/search-by-tasks
                     /api/workflow/search-by-tasks-v2) do
        assert {400, %{"message" => "Incorrectly formatted query string: a~b", "instance" => _}} =
                 fetch(path <> "?" <> query(query: "a~b"))

        assert {500, %{"message" => ~s(For input string: "soon")}} =
                 fetch(path <> "?" <> query(query: "startTime>soon"))
      end

      assert {500, %{"message" => message}} =
               fetch("/api/workflow/search?" <> query(sort: "taskId:ASC"))

      assert message =~ "no such column: task_id"
    end

    test "a repeated sort is one value joined with a comma, which is no sort item", %{name: name} do
      first = start(name)
      second = start(name)

      base = query(query: "workflowType=#{name}")

      assert {200, result} = fetch("/api/workflow/search?#{base}&sort=workflowId:DESC")
      assert ids(result) == Enum.sort([first, second], :desc)

      # "workflowId:DESC,status:ASC" has no valid direction: the order is the index order
      assert {200, result} =
               fetch("/api/workflow/search?#{base}&sort=workflowId:DESC&sort=status:ASC")

      assert ids(result) == [first, second]
    end
  end

  describe "classifier and topLevelOnly" do
    test "classifier values are trimmed, empty ones dropped, and added as an IN clause",
         %{name: name} do
      id = start(name)
      base = %{query: "workflowType=#{name}"}

      for {classifier, expected} <- [
            {" workflow , ", [id]},
            {"agent,  workflow", [id]},
            {"agent", []},
            {" , ", [id]},
            {"", [id]}
          ] do
        assert {200, result} =
                 fetch("/api/workflow/search?" <> query(Map.put(base, :classifier, classifier)))

        assert ids(result) == expected, "classifier #{inspect(classifier)}"
      end

      # without a query the clause is the whole query
      assert {200, %{"results" => results}} =
               fetch("/api/workflow/search?" <> query(classifier: "agent", size: -1))

      refute id in Enum.map(results, & &1["workflowId"])
    end

    test "a byte that is not UTF-8 is U+FFFD, as Tomcat decodes it", %{name: name} do
      start(name)

      for params <- [
            "classifier=%FF",
            "query=workflowType%3D%FF&topLevelOnly=true",
            "query=workflowType%3D#{name}&classifier=%FF",
            "query=workflowType%3D#{name}%FF&topLevelOnly=true"
          ],
          path <- ~w(search search-v2) do
        assert {200, %{"totalHits" => 0, "results" => []}} =
                 fetch("/api/workflow/#{path}?#{params}"),
               params
      end
    end

    test "topLevelOnly leaves out the workflows that have a parent", %{name: name} do
      top = start(name)
      child = start(name, parent_workflow_id: top, parent_workflow_task_id: "parent-task")

      for path <- ~w(search search-v2) do
        base = %{query: "workflowType=#{name}"}

        assert {200, result} = fetch("/api/workflow/#{path}?" <> query(base))
        assert ids(result) == [top, child]

        assert {200, result} =
                 fetch("/api/workflow/#{path}?" <> query(Map.put(base, :topLevelOnly, true)))

        assert ids(result) == [top]
      end
    end
  end

  describe "re-reads" do
    test "search-v2 leaves out a removed workflow and takes it off the total", %{name: name} do
      kept = start(name)
      removed = start(name)
      :ok = Runtime.store().remove_workflow(removed, true)

      base = query(query: "workflowType=#{name}")

      # the archived index row is still found
      assert {200, %{"totalHits" => 2} = result} = fetch("/api/workflow/search?" <> base)
      assert ids(result) == [kept, removed]

      assert {200, %{"totalHits" => 1, "results" => [workflow]}} =
               fetch("/api/workflow/search-v2?" <> base)

      assert %{"workflowId" => ^kept, "tasks" => []} = workflow
    end

    test "search-by-tasks gives each workflow once and takes the repeats off the total",
         %{name: name} do
      first = start(name)
      second = start(name)

      base = query(query: "workflowType=#{name}", sort: "taskDefName:ASC")

      assert {200, %{"totalHits" => 4} = tasks} = fetch("/api/tasks/search?" <> base)
      assert length(tasks["results"]) == 4

      assert {200, %{"totalHits" => 2, "results" => summaries}} =
               fetch("/api/workflow/search-by-tasks?" <> base)

      assert Enum.map(summaries, & &1["workflowId"]) == [first, second]
      assert Enum.all?(summaries, &match?(%{"workflowType" => ^name, "status" => "RUNNING"}, &1))

      assert {200, %{"totalHits" => 2, "results" => workflows}} =
               fetch("/api/workflow/search-by-tasks-v2?" <> base)

      assert Enum.map(workflows, & &1["workflowId"]) == [first, second]

      # a page of one task: no repeat to take off
      assert {200, %{"totalHits" => 4, "results" => [_one]}} =
               fetch("/api/workflow/search-by-tasks?" <> base <> "&size=1")
    end

    test "the task searches and by-tasks lose the tasks and workflows that cannot be read",
         %{name: name} do
      kept = start(name)
      removed = start(name)
      :ok = Runtime.store().remove_workflow(removed, true)

      base = query(query: "workflowType=#{name}")

      assert {200, %{"totalHits" => 4}} = fetch("/api/tasks/search?" <> base)

      assert {200, %{"totalHits" => 2, "results" => tasks}} =
               fetch("/api/tasks/search-v2?" <> base)

      assert Enum.all?(tasks, &(&1["workflowInstanceId"] == kept))

      # two tasks read, one workflow: one repeat off the total of the two read
      assert {200, %{"totalHits" => 1, "results" => [%{"workflowId" => ^kept}]}} =
               fetch("/api/workflow/search-by-tasks-v2?" <> base)

      # four summaries, one workflow: two unreadable and one repeat off the total
      assert {200, %{"totalHits" => 1, "results" => [%{"workflowId" => ^kept}]}} =
               fetch("/api/workflow/search-by-tasks?" <> base)
    end
  end

  describe "bulk/search" do
    test "the ID list may hold 1000 IDs, not 1001 or none" do
      ids = Enum.map(1..1000, &"archon-8e-missing-#{&1}")

      assert %{"bulkSuccessfulResults" => [], "bulkErrorResults" => errors} =
               json_response(bulk(Jason.encode!(ids)), 200)

      assert map_size(errors) == 1000
      assert errors["archon-8e-missing-1"] == "No such workflow found by id: archon-8e-missing-1"

      for {list, message} <- [
            {[], "WorkflowIds list cannot be null."},
            {["x" | ids],
             "Cannot process more than 1000 workflows. Please use multiple requests."}
          ] do
        assert %{
                 "validationErrors" => [%{"path" => "searchWorkflow.arg0", "message" => ^message}]
               } =
                 json_response(bulk(Jason.encode!(list)), 400)
      end
    end

    test "the body, then the query, then the list are checked" do
      for body <- ["", "null"] do
        assert %{"message" => message} = json_response(bulk(body, "?includeTasks=maybe"), 500)
        assert message == "Required request body is missing: " <> @search_handler
      end

      assert %{"message" => message} = json_response(bulk("[]", "?includeTasks=maybe"), 500)
      assert message =~ "Method parameter 'includeTasks'"
    end

    test "each ID in request order, with or without tasks, in the WorkflowModel shape",
         %{name: name} do
      id = start(name)

      body = Jason.encode!([id, "archon-8e-missing", id])

      assert %{"bulkSuccessfulResults" => [workflow, again], "bulkErrorResults" => errors} =
               json_response(bulk(body), 200)

      assert again == workflow
      assert errors == %{"archon-8e-missing" => "No such workflow found by id: archon-8e-missing"}

      assert %{"workflowId" => ^id, "status" => "RUNNING", "updatedTime" => _, "tasks" => tasks} =
               workflow

      for key <- ~w(startTime updateTime history rateLimited failedReferenceTaskNames
                    failedTaskNames),
          do: refute(Map.has_key?(workflow, key), key)

      assert [%{"taskType" => "SET_VARIABLE"} = task | _rest] = tasks

      assert %{
               "callbackAfterMs" => 0,
               "idempotent" => false,
               "notifications" => %{},
               "asyncComplete" => false,
               "idempotentExecution" => false
             } = task

      for key <- ~w(firstStartTime executionMetadata), do: refute(Map.has_key?(task, key), key)

      assert %{"bulkSuccessfulResults" => [%{"tasks" => []}]} =
               json_response(bulk(Jason.encode!([id]), "?includeTasks=false"), 200)
    end

    test "a task skiptask created has no workflowTask or onStateChange", %{name: name} do
      id = start(name)
      :ok = Lifecycle.skip_task(id, "later")

      assert %{"bulkSuccessfulResults" => [%{"tasks" => tasks}]} =
               json_response(bulk(Jason.encode!([id])), 200)

      assert %{"status" => "SKIPPED"} =
               skipped = Enum.find(tasks, &(&1["referenceTaskName"] == "later"))

      refute Map.has_key?(skipped, "workflowTask")
      refute Map.has_key?(skipped, "onStateChange")

      # the REST Task keeps upstream toTask's name and reference stub
      {:ok, workflow} = Runtime.get_workflow(id)
      later = Enum.find(workflow.tasks, &(&1.reference_task_name == "later"))

      assert %{"workflowTask" => %{"taskReferenceName" => "later"}} =
               DomainTask.to_json(later)
    end

    test "a null ID fails the answer with Jackson's null key error", %{name: name} do
      id = start(name)

      assert %{"message" => message} = json_response(bulk(Jason.encode!([id, nil])), 500)
      assert message =~ "Null key for a Map not allowed in JSON"
    end
  end
end
