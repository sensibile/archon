defmodule ArchonWeb.RouterTest do
  @moduledoc """
  The MVP routes of ADR 0001 and the 404 for every other request (ADR 0023, decision 2). Paths
  and handlers come from upstream's `MetadataResource`, `WorkflowResource`, `TaskResource` and
  `HealthCheckResource` (conductor-oss 1488804).
  """

  use ArchonWeb.ContractCase, async: true

  alias ArchonWeb.{HealthController, MetadataController, TaskController, WorkflowController}

  @id "00000000-0000-0000-0000-000000000000"

  # The 19 MVP paths (18 methods: /api/health is /health's alias).
  @mvp [
    {"GET", "/health", HealthController, :check},
    {"GET", "/api/health", HealthController, :check},
    {"POST", "/api/metadata/workflow", MetadataController, :create_workflow},
    {"PUT", "/api/metadata/workflow", MetadataController, :update_workflows},
    {"GET", "/api/metadata/workflow/archon_simple", MetadataController, :get_workflow},
    {"POST", "/api/metadata/taskdefs", MetadataController, :create_task_defs},
    {"PUT", "/api/metadata/taskdefs", MetadataController, :update_task_def},
    {"GET", "/api/metadata/taskdefs", MetadataController, :list_task_defs},
    {"GET", "/api/metadata/taskdefs/archon_task_a", MetadataController, :get_task_def},
    {"POST", "/api/workflow", WorkflowController, :start},
    {"POST", "/api/workflow/archon_simple", WorkflowController, :start_by_name},
    {"GET", "/api/workflow/#{@id}", WorkflowController, :get},
    {"GET", "/api/workflow/#{@id}/status", WorkflowController, :status},
    {"DELETE", "/api/workflow/#{@id}", WorkflowController, :terminate},
    {"GET", "/api/tasks/poll/archon_task_a", TaskController, :poll},
    {"GET", "/api/tasks/poll/batch/archon_task_a", TaskController, :batch_poll},
    {"POST", "/api/tasks", TaskController, :update},
    {"POST", "/api/tasks/update-v2", TaskController, :update_v2},
    {"GET", "/api/tasks/#{@id}", TaskController, :get}
  ]

  # Later routes shaped like an MVP parameter route, and requests no MVP route takes.
  @no_route [
    {"GET", "/api/workflow/search"},
    {"GET", "/api/workflow/search-v2"},
    {"GET", "/api/workflow/search-by-tasks"},
    {"GET", "/api/workflow/search-by-tasks-v2"},
    {"GET", "/api/workflow/externalstoragelocation"},
    {"GET", "/api/workflow/external-storage-location"},
    {"GET", "/api/workflow/running/archon_simple"},
    {"GET", "/api/workflow/running/status"},
    {"POST", "/api/workflow/test"},
    {"GET", "/api/metadata/workflow/names-and-versions"},
    {"GET", "/api/metadata/workflow/names"},
    {"GET", "/api/metadata/workflow/latest-versions"},
    {"GET", "/api/tasks/search"},
    {"GET", "/api/tasks/search-v2"},
    {"GET", "/api/tasks/externalstoragelocation"},
    {"GET", "/api/tasks/external-storage-location"},
    # Later and Unsupported routes on other paths
    {"GET", "/api/metadata/workflow"},
    {"DELETE", "/api/metadata/taskdefs/archon_task_a"},
    {"PUT", "/api/workflow/#{@id}/pause"},
    {"POST", "/api/workflow/#{@id}/retry"},
    {"PUT", "/api/workflow/decide/#{@id}"},
    {"GET", "/api/admin/config"},
    # An MVP path with another method (upstream: 405)
    {"PATCH", "/api/workflow"},
    {"PUT", "/api/tasks/#{@id}"},
    {"POST", "/health"},
    {"OPTIONS", "/api/workflow"},
    # Unknown paths
    {"GET", "/"},
    {"GET", "/api"},
    {"GET", "/api/archon/missing"}
  ]

  test "every MVP path reaches its action" do
    for {method, path, controller, action} <- @mvp do
      assert %{plug: ^controller, plug_opts: ^action} =
               Phoenix.Router.route_info(ArchonWeb.Router, method, path, "localhost"),
             "#{method} #{path}"
    end
  end

  test "every other request reaches the 404" do
    for {method, path} <- @no_route do
      assert %{plug: ArchonWeb.Errors, plug_opts: :no_route} =
               Phoenix.Router.route_info(ArchonWeb.Router, method, path, "localhost"),
             "#{method} #{path}"

      conn = dispatch(build_conn(), @endpoint, method, path, nil)
      "/" <> rest = path

      assert %{"status" => 404, "message" => message, "retryable" => false, "instance" => _} =
               JSON.decode!(conn.resp_body)

      assert {conn.status, get_resp_header(conn, "content-type")} == {404, ["application/json"]}
      assert message == "No static resource #{rest}."
    end
  end

  # Spring answers HEAD on a GET mapping like GET, without the body.
  test "HEAD is GET without the body" do
    conn = dispatch(build_conn(), @endpoint, "HEAD", "/health", nil)
    assert {conn.status, conn.resp_body} == {200, ""}
    assert get_resp_header(conn, "content-type") == ["application/json"]

    conn = dispatch(build_conn(), @endpoint, "HEAD", "/api/archon/missing", nil)
    assert {conn.status, conn.resp_body} == {404, ""}
  end

  # Checked against the upstream server: no trailing-slash match, empty segments left out of
  # the message, escapes kept.
  test "a trailing slash is not an MVP route, and the message is the normalized path" do
    for {method, path, message} <- [
          {"POST", "/api/workflow/", "api/workflow"},
          {"GET", "/health/", "health"},
          {"GET", "/api/workflow/abc/", "api/workflow/abc"},
          {"GET", "/api/a%20b/c?x=1", "api/a%20b/c"}
        ] do
      conn = dispatch(build_conn(), @endpoint, method, path, nil)
      assert conn.status == 404, path
      assert JSON.decode!(conn.resp_body)["message"] == "No static resource #{message}.", path
    end
  end

  test "the routing fixtures replay: Later routes and other methods are 404s, not upstream's answers" do
    replay(steps("route_not_found", "route_method_put_task"))
  end
end
