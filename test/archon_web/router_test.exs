defmodule ArchonWeb.RouterTest do
  @moduledoc """
  The MVP routes of ADR 0001, the Phase 6 routes of ADR 0025 and the 404 for every other request
  (ADR 0023 decision 2, ADR 0025 decision 1). Paths and handlers come from upstream's
  `MetadataResource`, `WorkflowResource`, `WorkflowBulkResource`, `TaskResource` and
  `HealthCheckResource` (conductor-oss 1488804). The Phase 6 routes are checked by resolution
  only (`Phoenix.Router.route_info/4`), so the slices implementing their actions leave this file
  alone.
  """

  use ArchonWeb.ContractCase, async: true

  alias ArchonWeb.{
    HealthController,
    MetadataController,
    SignalController,
    TaskController,
    WorkflowBulkController,
    WorkflowController,
    WorkflowLifecycleController,
    WorkflowQueryController
  }

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

  # The 33 Phase 6 paths (ADR 0025, decision 1), and the paths where two upstream patterns meet:
  # Spring takes the more specific one.
  @phase6 [
    {"PUT", "/api/workflow/#{@id}/pause", WorkflowLifecycleController, :pause},
    {"PUT", "/api/workflow/#{@id}/resume", WorkflowLifecycleController, :resume},
    {"POST", "/api/workflow/#{@id}/retry", WorkflowLifecycleController, :retry},
    {"POST", "/api/workflow/#{@id}/restart", WorkflowLifecycleController, :restart},
    {"POST", "/api/workflow/#{@id}/rerun", WorkflowLifecycleController, :rerun},
    {"PUT", "/api/workflow/#{@id}/skiptask/task_a_ref", WorkflowLifecycleController, :skip_task},
    {"POST", "/api/workflow/#{@id}/resetcallbacks", WorkflowLifecycleController,
     :reset_callbacks},
    {"DELETE", "/api/workflow/#{@id}/remove", WorkflowLifecycleController, :remove},
    {"DELETE", "/api/workflow/#{@id}/terminate-remove", WorkflowLifecycleController,
     :terminate_remove},
    {"GET", "/api/workflow/#{@id}/tasks", WorkflowQueryController, :tasks},
    {"GET", "/api/workflow/archon_simple/correlated/archon-corr-1", WorkflowQueryController,
     :correlated},
    {"POST", "/api/workflow/archon_simple/correlated", WorkflowQueryController, :correlated_many},
    {"GET", "/api/workflow/running/archon_simple", WorkflowQueryController, :running},
    {"POST", "/api/workflow/execute/archon_simple/1", SignalController, :execute},
    {"POST", "/api/tasks/#{@id}/task_a_ref/COMPLETED", SignalController, :update_by_ref},
    {"POST", "/api/tasks/#{@id}/task_a_ref/COMPLETED/sync", SignalController,
     :update_by_ref_sync},
    {"POST", "/api/tasks/#{@id}/COMPLETED/signal", SignalController, :signal},
    {"POST", "/api/tasks/#{@id}/COMPLETED/signal/sync", SignalController, :signal_sync},
    {"GET", "/api/metadata/workflow", MetadataController, :list_workflows},
    {"GET", "/api/metadata/workflow/names-and-versions", MetadataController,
     :workflow_names_and_versions},
    {"GET", "/api/metadata/workflow/names", MetadataController, :workflow_names},
    {"GET", "/api/metadata/workflow/latest-versions", MetadataController, :latest_workflows},
    {"GET", "/api/metadata/workflow/archon_simple/versions", MetadataController,
     :workflow_versions},
    {"DELETE", "/api/metadata/workflow/archon_simple/1", MetadataController, :delete_workflow},
    {"DELETE", "/api/metadata/taskdefs/archon_task_a", MetadataController, :delete_task_def},
    {"POST", "/api/metadata/workflow/validate", MetadataController, :validate_workflow},
    {"PUT", "/api/workflow/bulk/pause", WorkflowBulkController, :pause},
    {"PUT", "/api/workflow/bulk/resume", WorkflowBulkController, :resume},
    {"POST", "/api/workflow/bulk/restart", WorkflowBulkController, :restart},
    {"POST", "/api/workflow/bulk/retry", WorkflowBulkController, :retry},
    {"POST", "/api/workflow/bulk/terminate", WorkflowBulkController, :terminate},
    {"DELETE", "/api/workflow/bulk/remove", WorkflowBulkController, :remove},
    {"DELETE", "/api/workflow/bulk/terminate-remove", WorkflowBulkController, :terminate_remove},
    # Where patterns meet: the literal segments win.
    {"GET", "/api/workflow/running/tasks", WorkflowQueryController, :running},
    {"GET", "/api/workflow/running/status", WorkflowQueryController, :running},
    {"POST", "/api/tasks/#{@id}/COMPLETED/signal", SignalController, :signal},
    {"POST", "/api/tasks/#{@id}/signal/COMPLETED", SignalController, :update_by_ref},
    {"POST", "/api/tasks/#{@id}/COMPLETED/signal/sync", SignalController, :signal_sync},
    {"GET", "/api/metadata/workflow/names/versions", MetadataController, :workflow_versions},
    {"POST", "/api/workflow/bulk/correlated", WorkflowQueryController, :correlated_many},
    {"PUT", "/api/workflow/bulk/skiptask/task_a_ref", WorkflowLifecycleController, :skip_task},
    {"POST", "/api/workflow/bulk/rerun", WorkflowLifecycleController, :rerun},
    {"POST", "/api/workflow/execute/correlated", WorkflowQueryController, :correlated_many},
    {"GET", "/api/workflow/#{@id}/correlated/x", WorkflowQueryController, :correlated}
  ]

  # Later and Unsupported routes shaped like an MVP or Phase 6 parameter route, and requests no
  # route takes.
  @no_route [
    {"GET", "/api/workflow/search"},
    {"GET", "/api/workflow/search-v2"},
    {"GET", "/api/workflow/search-by-tasks"},
    {"GET", "/api/workflow/search-by-tasks-v2"},
    {"GET", "/api/workflow/externalstoragelocation"},
    {"GET", "/api/workflow/external-storage-location"},
    {"POST", "/api/workflow/test"},
    {"GET", "/api/tasks/search"},
    {"GET", "/api/tasks/search-v2"},
    {"GET", "/api/tasks/externalstoragelocation"},
    {"GET", "/api/tasks/external-storage-location"},
    # Unsupported decide is `{workflowId}/pause` and `/resume` in shape.
    {"PUT", "/api/workflow/decide/#{@id}"},
    {"PUT", "/api/workflow/decide/pause"},
    {"PUT", "/api/workflow/decide/resume"},
    # Later requeue is a task update by reference in shape (`queue/requeue/signal` too).
    {"POST", "/api/tasks/queue/requeue/archon_task_a"},
    {"POST", "/api/tasks/queue/requeue/signal"},
    # Later routes no Phase 6 route meets: no route of their shape.
    {"POST", "/api/workflow/bulk/search"},
    {"POST", "/api/tasks/#{@id}/log"},
    {"GET", "/api/tasks/#{@id}/log"},
    {"POST", "/api/workflow/#{@id}/messages"},
    {"GET", "/api/admin/config"},
    {"GET", "/api/tasks/queue/sizes"},
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

  test "every Phase 6 path reaches its action" do
    for {method, path, controller, action} <- @phase6 do
      assert %{plug: ^controller, plug_opts: ^action} =
               Phoenix.Router.route_info(ArchonWeb.Router, method, path, "localhost"),
             "#{method} #{path}"
    end
  end

  test "the Phase 6 routes are the 33 of ADR 0025, each with an action" do
    actions =
      @phase6
      |> Enum.take(33)
      |> MapSet.new(fn {_method, _path, controller, action} -> {controller, action} end)

    new_controllers = [
      WorkflowLifecycleController,
      WorkflowQueryController,
      SignalController,
      WorkflowBulkController
    ]

    routes =
      for route <- ArchonWeb.Router.__routes__(),
          route.plug in new_controllers or {route.plug, route.plug_opts} in actions,
          do: {route.plug, route.plug_opts}

    assert MapSet.size(actions) == 33
    assert length(routes) == 33
    assert MapSet.new(routes) == actions

    for {controller, action} <- routes do
      assert Code.ensure_loaded?(controller) and function_exported?(controller, action, 2)
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

    replay(
      for name <- ~w(route_unsupported_workflow_decide route_later_tasks_requeue
                     route_later_workflow_bulk_search route_later_task_log),
          do: {:exchange, name, expect: :no_route}
    )
  end
end
