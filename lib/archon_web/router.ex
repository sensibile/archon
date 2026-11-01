# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Paths derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# {HealthCheckResource,MetadataResource,WorkflowResource,TaskResource}.java and
# rest/.../rest/config/RequestMappingConstants.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: only the MVP routes of ADR 0001; every other request is a 404.

defmodule ArchonWeb.Router do
  @moduledoc """
  The 19 MVP routes of ADR 0001 (ADR 0023, decision 2). Everything else is a 404 with the body
  upstream gives a path it has no handler for (`ArchonWeb.Errors.send_no_route/1`): unknown
  paths, Later and Unsupported routes, and an MVP path with another method (upstream's 405 is
  not reproduced).

  Some Later routes have the shape of an MVP parameter route (`POST /api/workflow/test` would
  start a workflow named `test`). They are listed before the parameter routes and sent to the
  404. A slice that opens one of them removes it from these lists and routes it to its action.
  """

  use ArchonWeb, :router
  use Plug.ErrorHandler

  alias Archon.Domain.ErrorResponse

  # WorkflowResource: GET /api/workflow/{workflowId} would take these.
  @later_workflow_gets ~w(search search-v2 search-by-tasks search-by-tasks-v2
                          externalstoragelocation external-storage-location)
  # MetadataResource: GET /api/metadata/workflow/{name} would take these.
  @later_metadata_workflow_gets ~w(names-and-versions names latest-versions)
  # TaskResource: GET /api/tasks/{taskId} would take these.
  @later_task_gets ~w(search search-v2 externalstoragelocation external-storage-location)

  scope "/", ArchonWeb do
    get "/health", HealthController, :check
    get "/api/health", HealthController, :check
  end

  scope "/api/metadata", ArchonWeb do
    post "/workflow", MetadataController, :create_workflow
    put "/workflow", MetadataController, :update_workflows

    for path <- @later_metadata_workflow_gets do
      get "/workflow/#{path}", Errors, :no_route
    end

    get "/workflow/:name", MetadataController, :get_workflow
    post "/taskdefs", MetadataController, :create_task_defs
    put "/taskdefs", MetadataController, :update_task_def
    get "/taskdefs", MetadataController, :list_task_defs
    get "/taskdefs/:tasktype", MetadataController, :get_task_def
  end

  scope "/api/workflow", ArchonWeb do
    post "/", WorkflowController, :start
    post "/test", Errors, :no_route
    post "/:name", WorkflowController, :start_by_name

    for path <- @later_workflow_gets do
      get "/#{path}", Errors, :no_route
    end

    # GET /api/workflow/running/status would otherwise be the status of workflow "running".
    get "/running/:name", Errors, :no_route
    get "/:workflowId", WorkflowController, :get
    get "/:workflowId/status", WorkflowController, :status
    delete "/:workflowId", WorkflowController, :terminate
  end

  scope "/api/tasks", ArchonWeb do
    get "/poll/batch/:tasktype", TaskController, :batch_poll
    get "/poll/:tasktype", TaskController, :poll
    post "/", TaskController, :update
    post "/update-v2", TaskController, :update_v2

    for path <- @later_task_gets do
      get "/#{path}", Errors, :no_route
    end

    get "/:taskId", TaskController, :get
  end

  match :*, "/*path", ArchonWeb.Errors, :no_route

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason}) do
    response = ArchonWeb.Errors.exception_response(kind, reason)
    ArchonWeb.Response.json(conn, response.status, ErrorResponse.to_json(response))
  end
end
