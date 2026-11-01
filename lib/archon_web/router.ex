# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Paths derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# {HealthCheckResource,MetadataResource,WorkflowResource,WorkflowBulkResource,TaskResource}.java and
# rest/.../rest/config/RequestMappingConstants.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: only the MVP routes of ADR 0001 and the Phase 6 routes of ADR 0025;
# every other request is a 404.

defmodule ArchonWeb.Router do
  @moduledoc """
  The 19 MVP routes of ADR 0001 (ADR 0023, decision 2) and the 33 workflow operation routes of
  Phase 6 (ADR 0025, decision 1). Everything else is a 404 with the body upstream gives a path it
  has no handler for (`ArchonWeb.Errors.send_no_route/1`): unknown paths, Later and Unsupported
  routes, and a path with another method (upstream's 405 is not reproduced).

  Phoenix takes the first route that matches, Spring the most specific pattern. Where two
  upstream patterns take the same path, the more specific one is listed first:

    * the bulk literals (`PUT /api/workflow/bulk/pause`) before `{workflowId}/pause` and the like;
    * `GET /api/workflow/running/{name}` before `{workflowId}/tasks` and `{workflowId}/status`;
    * the signal routes (`POST /api/tasks/{workflowId}/{status}/signal`) before the task update
      by reference (`POST /api/tasks/{workflowId}/{taskRefName}/{status}`).

  Later and Unsupported routes with the shape of a parameter route (`POST /api/workflow/test`
  would start a workflow named `test`, `PUT /api/workflow/decide/{workflowId}` would pause one
  named `decide`) are listed before it and sent to the 404. A slice that opens one of them
  removes it from these lists and routes it to its action.
  """

  use ArchonWeb, :router
  use Plug.ErrorHandler

  alias Archon.Domain.ErrorResponse

  # WorkflowResource: GET /api/workflow/{workflowId} would take these.
  @later_workflow_gets ~w(search search-v2 search-by-tasks search-by-tasks-v2
                          externalstoragelocation external-storage-location)
  # TaskResource: GET /api/tasks/{taskId} would take these.
  @later_task_gets ~w(search search-v2 externalstoragelocation external-storage-location)

  scope "/", ArchonWeb do
    get "/health", HealthController, :check
    get "/api/health", HealthController, :check
  end

  scope "/api/metadata", ArchonWeb do
    post "/workflow", MetadataController, :create_workflow
    put "/workflow", MetadataController, :update_workflows
    get "/workflow", MetadataController, :list_workflows
    post "/workflow/validate", MetadataController, :validate_workflow
    # GET /api/metadata/workflow/{name} would take these.
    get "/workflow/names-and-versions", MetadataController, :workflow_names_and_versions
    get "/workflow/names", MetadataController, :workflow_names
    get "/workflow/latest-versions", MetadataController, :latest_workflows
    get "/workflow/:name", MetadataController, :get_workflow
    get "/workflow/:name/versions", MetadataController, :workflow_versions
    delete "/workflow/:name/:version", MetadataController, :delete_workflow
    post "/taskdefs", MetadataController, :create_task_defs
    put "/taskdefs", MetadataController, :update_task_def
    get "/taskdefs", MetadataController, :list_task_defs
    get "/taskdefs/:tasktype", MetadataController, :get_task_def
    delete "/taskdefs/:tasktype", MetadataController, :delete_task_def
  end

  # WorkflowBulkResource: the {workflowId} routes below would take these.
  scope "/api/workflow/bulk", ArchonWeb do
    put "/pause", WorkflowBulkController, :pause
    put "/resume", WorkflowBulkController, :resume
    post "/restart", WorkflowBulkController, :restart
    post "/retry", WorkflowBulkController, :retry
    post "/terminate", WorkflowBulkController, :terminate
    delete "/remove", WorkflowBulkController, :remove
    delete "/terminate-remove", WorkflowBulkController, :terminate_remove
  end

  scope "/api/workflow", ArchonWeb do
    post "/", WorkflowController, :start
    post "/test", Errors, :no_route
    post "/execute/:name/:version", SignalController, :execute
    post "/:name", WorkflowController, :start_by_name
    get "/:name/correlated/:correlationId", WorkflowQueryController, :correlated
    post "/:name/correlated", WorkflowQueryController, :correlated_many

    for path <- @later_workflow_gets do
      get "/#{path}", Errors, :no_route
    end

    # GET /api/workflow/running/tasks would otherwise be the tasks of workflow "running".
    get "/running/:name", WorkflowQueryController, :running
    get "/:workflowId", WorkflowController, :get
    get "/:workflowId/status", WorkflowController, :status
    get "/:workflowId/tasks", WorkflowQueryController, :tasks
    delete "/:workflowId", WorkflowController, :terminate

    # Unsupported (ADR 0001); PUT /api/workflow/decide/pause is decide's in Spring.
    put "/decide/:workflowId", Errors, :no_route
    put "/:workflowId/pause", WorkflowLifecycleController, :pause
    put "/:workflowId/resume", WorkflowLifecycleController, :resume
    post "/:workflowId/retry", WorkflowLifecycleController, :retry
    post "/:workflowId/restart", WorkflowLifecycleController, :restart
    post "/:workflowId/rerun", WorkflowLifecycleController, :rerun
    put "/:workflowId/skiptask/:taskReferenceName", WorkflowLifecycleController, :skip_task
    post "/:workflowId/resetcallbacks", WorkflowLifecycleController, :reset_callbacks
    delete "/:workflowId/remove", WorkflowLifecycleController, :remove
    delete "/:workflowId/terminate-remove", WorkflowLifecycleController, :terminate_remove
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

    # Later; the task update by reference would take it.
    post "/queue/requeue/:taskType", Errors, :no_route
    post "/:workflowId/:status/signal", SignalController, :signal
    post "/:workflowId/:status/signal/sync", SignalController, :signal_sync
    post "/:workflowId/:taskRefName/:status", SignalController, :update_by_ref
    post "/:workflowId/:taskRefName/:status/sync", SignalController, :update_by_ref_sync
  end

  match :*, "/*path", ArchonWeb.Errors, :no_route

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: kind, reason: reason}) do
    response = ArchonWeb.Errors.exception_response(kind, reason)
    ArchonWeb.Response.json(conn, response.status, ErrorResponse.to_json(response))
  end
end
