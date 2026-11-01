# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.WorkflowControllerTest do
  @moduledoc """
  `ArchonWeb.WorkflowController` (ADR 0023 decisions 2 and 4, slice 5d).

  The `workflow_*` fixtures are replayed with the task exchanges between them. The definitions
  are put in the runtime's metadata as `ArchonWeb.TaskControllerTest` does (the `metadata_*`
  exchanges are left out: other tests keep `archon_simple` registered, so registering it again
  would be a 409), and the task queues the replay polls are emptied first
  (`Archon.RuntimeCase.isolate_queues/1`).

  The messages that are not in a fixture were seen on the upstream server (the commit of the
  file headers, an empty SQLite store) and are written here as upstream answered.
  """

  use ArchonWeb.ContractCase, async: false

  @moduletag :capture_log

  alias Archon.Contract
  alias Archon.Domain.{TaskDef, TaskResult, WorkflowDef}
  alias Archon.Runtime
  alias Archon.Runtime.Tasks
  alias Archon.RuntimeCase

  @queues ~w(archon_task_a archon_task_b archon_task_c)

  setup do
    Archon.RuntimeHooks.reset()
    on_exit(&Archon.RuntimeHooks.reset/0)
    RuntimeCase.register_definitions()

    for name <- ~w(metadata_get_workflow_switch metadata_get_workflow_fork) do
      {:ok, definition} = WorkflowDef.from_json(Contract.fixture(name)["response"]["body"])
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

    # `archon_task_c` as the capture left it before the inline starts (registered, then updated).
    {:ok, task_def} =
      TaskDef.from_json(Contract.fixture("metadata_get_taskdef_updated")["response"]["body"])

    :ok = Runtime.metadata().update_task_def(task_def)

    RuntimeCase.isolate_queues(@queues)
  end

  # The scenario from `first` through `last` without the metadata exchanges.
  defp workflow_steps(first, last) do
    first
    |> steps(last)
    |> Enum.reject(&match?({:exchange, "metadata_" <> _rest}, &1))
  end

  describe "replay of the workflow fixtures" do
    # One run: the later fetch options read the SIMPLE workflow of the first part.
    test "runs, terminate, start errors, inline definition, fetch options, terminate errors" do
      replay(workflow_steps("workflow_start_simple", "workflow_terminate_not_found"))
    end
  end

  describe "POST /api/workflow" do
    @handler "public java.lang.String com.netflix.conductor.rest.controllers.WorkflowResource." <>
               "startWorkflow(com.netflix.conductor.common.metadata.workflow.StartWorkflowRequest)"

    test "a missing or null body names the handler" do
      for body <- ["", "null"],
          do: assert(message(post_json("/api/workflow", body), 500) == missing_body(@handler))
    end

    test "a value of the wrong type is a 500 JSON parse error" do
      for {body, detail} <- [
            {"[]", "must be object"},
            {~s({"name":"archon_simple","input":[]}), "input must be object"},
            {~s({"name":"archon_simple","priority":"abc"}), "priority must be integer"},
            {~s({"name":{}}), "name must be string"}
          ] do
        assert message(post_json("/api/workflow", body), 500) == "JSON parse error: " <> detail
      end
    end

    test "validation errors are under startWorkflow.arg0" do
      assert validation_errors(post_json("/api/workflow", "{}")) == [
               %{
                 "path" => "startWorkflow.arg0.name",
                 "message" => "Workflow name cannot be null or empty"
               }
             ]

      body = ~s({"name":"x","priority":100,"workflowDef":{"name":"","tasks":[)
      body = body <> ~s({"name":"archon_task_a","taskReferenceName":"a","type":"SIMPLE"}]}})

      assert validation_errors(post_json("/api/workflow", body)) == [
               %{
                 "path" => "startWorkflow.arg0.priority",
                 "message" => "priority: 100 should be maximum 99",
                 "invalidValue" => "100"
               },
               %{
                 "path" => "startWorkflow.arg0.workflowDef.name",
                 "message" => "WorkflowDef name cannot be null or empty",
                 "invalidValue" => ""
               }
             ]

      body =
        ~s({"name":"x","priority":-1,"workflowDef":{"name":"d","tasks":[) <>
          ~s({"name":"archon_task_a","type":"SIMPLE"}]}})

      assert validation_errors(post_json("/api/workflow", body)) == [
               %{
                 "path" => "startWorkflow.arg0.priority",
                 "message" => "priority: -1 should be minimum 0",
                 "invalidValue" => "-1"
               },
               %{
                 "path" => "startWorkflow.arg0.workflowDef.tasks[0].taskReferenceName",
                 "message" => "WorkflowTask taskReferenceName name cannot be empty or null"
               }
             ]
    end

    test "a class-level definition error is at the workflowDef path" do
      task = ~s({"name":"archon_task_a","taskReferenceName":"a","type":"SIMPLE"})
      body = ~s({"name":"x","workflowDef":{"name":"d","tasks":[#{task},#{task}]}})

      assert validation_errors(post_json("/api/workflow", body)) == [
               %{
                 "path" => "startWorkflow.arg0.workflowDef",
                 "message" =>
                   "taskReferenceName: a should be unique across tasks for a given " <>
                     "workflowDefinition: d"
               }
             ]
    end

    test "a blank name without a definition is a 400, as upstream's definition lookup" do
      for name <- ["", "  "] do
        conn = post_json("/api/workflow", JSON.encode!(%{name: name, version: 2}))

        assert %{"status" => 400, "retryable" => false, "instance" => _} = json(conn, 400)

        assert message(conn, 400) ==
                 "Workflow name must be specified when searching for a definition"
      end
    end

    test "with an inline definition the name is not looked up" do
      definition = %{
        name: "archon_inline_5d",
        version: 1,
        tasks: [%{name: "archon_task_a", taskReferenceName: "a", type: "SIMPLE"}]
      }

      for name <- ["", "archon_missing"] do
        conn = post_json("/api/workflow", JSON.encode!(%{name: name, workflowDef: definition}))
        id = text(conn)
        {:ok, workflow} = Runtime.get_workflow(id, false)
        assert workflow.workflow_definition.name == "archon_inline_5d"
        :ok = Runtime.terminate_workflow(id, nil)
      end
    end

    test "a null input is upstream's 400; null priority and taskToDomain are the defaults" do
      conn = post_json("/api/workflow", ~s({"name":"archon_simple","input":null}))
      assert message(conn, 400) == "NULL input passed when starting workflow"

      body = ~s({"name":"archon_simple","priority":null,"taskToDomain":null})
      id = text(post_json("/api/workflow", body))

      assert %{"priority" => 0, "taskToDomain" => %{}, "input" => %{}} =
               json(get(build_conn(), "/api/workflow/#{id}?includeTasks=false"), 200)

      :ok = Runtime.terminate_workflow(id, nil)
    end

    test "an external input path without an input is refused, as upstream without the storage" do
      body = ~s({"name":"archon_simple","externalInputPayloadStoragePath":"p"})

      assert message(post_json("/api/workflow", body), 500) ==
               "Unable to download payload from external storage path: p"

      body = ~s({"name":"archon_simple","input":{"x":1},"externalInputPayloadStoragePath":"p"})
      id = text(post_json("/api/workflow", body))
      :ok = Runtime.terminate_workflow(id, nil)
    end

    test "parent fields, createdBy and idempotency fields are not copied to the workflow" do
      body =
        JSON.encode!(%{
          name: "archon_simple",
          input: %{x: 1},
          workflowId: "00000000-0000-0000-0000-00000000005d",
          parentWorkflowId: "parent",
          parentWorkflowTaskId: "parent-task",
          createdBy: "someone",
          idempotencyKey: "k",
          idempotencyStrategy: "FAIL"
        })

      id = text(post_json("/api/workflow", body))
      refute id == "00000000-0000-0000-0000-00000000005d"

      workflow = json(get(build_conn(), "/api/workflow/#{id}?includeTasks=false"), 200)
      refute Map.has_key?(workflow, "parentWorkflowId")
      refute Map.has_key?(workflow, "parentWorkflowTaskId")
      # Read and, as upstream's StartWorkflowInput, not used.
      refute Map.has_key?(workflow, "createdBy")
      refute Map.has_key?(workflow, "idempotencyKey")
      :ok = Runtime.terminate_workflow(id, nil)
    end

    test "an inline definition enforcing a schema Archon cannot check is a 400" do
      definition = %{
        name: "archon_schema_5d",
        tasks: [%{name: "archon_task_a", taskReferenceName: "a", type: "SIMPLE"}],
        inputSchema: %{name: "s", data: %{}}
      }

      conn = post_json("/api/workflow", JSON.encode!(%{name: "x", workflowDef: definition}))

      assert %{"status" => 400, "retryable" => false, "instance" => _} = json(conn, 400)

      assert message(conn, 400) ==
               "Schema validation is not supported yet: archon_schema_5d inputSchema"
    end
  end

  describe "POST /api/workflow/{name}" do
    @handler "public java.lang.String com.netflix.conductor.rest.controllers.WorkflowResource." <>
               "startWorkflow(java.lang.String,java.lang.Integer,java.lang.String,int," <>
               "java.util.Map<java.lang.String, java.lang.Object>)"

    test "a missing or null body names the handler" do
      for body <- ["", "null"],
          do:
            assert(
              message(post_json("/api/workflow/archon_simple", body), 500) ==
                missing_body(@handler)
            )
    end

    test "a body that is not an object is a 500 JSON parse error" do
      for body <- ["[]", ~s("x")],
          do:
            assert(
              message(post_json("/api/workflow/archon_simple", body), 500) ==
                "JSON parse error: must be object"
            )
    end

    test "the query values convert before the body" do
      assert message(post_json("/api/workflow/archon_simple?priority=abc", "[]"), 500) ==
               "Method parameter 'priority': Failed to convert value of type 'java.lang.String' " <>
                 "to required type 'int'; For input string: \"abc\""

      assert message(post_json("/api/workflow/archon_simple?version=abc&priority=abc", "{}"), 500) ==
               "Method parameter 'version': Failed to convert value of type 'java.lang.String' " <>
                 "to required type 'java.lang.Integer'; For input string: \"abc\""
    end

    test "the priority is validated under startWorkflow.arg3, before the definition lookup" do
      for {priority, text} <- [
            {"100", "99 is the maximum priority value"},
            {"-1", "0 is the minimum priority value"}
          ] do
        assert validation_errors(
                 post_json("/api/workflow/archon_missing?priority=#{priority}", "{}")
               ) ==
                 [
                   %{
                     "path" => "startWorkflow.arg3",
                     "message" => text,
                     "invalidValue" => priority
                   }
                 ]
      end
    end

    test "an unknown definition is the service's 404" do
      assert message(post_json("/api/workflow/archon_simple?version=7", "{}"), 404) ==
               "No such workflow found by name: archon_simple, version: 7"

      assert message(post_json("/api/workflow/%20", "{}"), 404) ==
               "No such workflow found by name:  , version: null"
    end

    test "starts with the version, correlation ID, priority and input" do
      path = "/api/workflow/archon_simple?version=1&correlationId=c5d&priority=5"
      id = text(post_json(path, ~s({"x":null})))

      assert %{
               "workflowName" => "archon_simple",
               "workflowVersion" => 1,
               "correlationId" => "c5d",
               "priority" => 5,
               "input" => %{"x" => nil}
             } = json(get(build_conn(), "/api/workflow/#{id}?includeTasks=false"), 200)

      :ok = Runtime.terminate_workflow(id, nil)
    end
  end

  describe "GET /api/workflow/{workflowId} and /status" do
    test "a boolean that does not convert is Spring's conversion error" do
      for {path, name} <- [
            {"/api/workflow/x?includeTasks=abc", "includeTasks"},
            {"/api/workflow/x/status?includeOutput=abc", "includeOutput"},
            {"/api/workflow/x/status?includeVariables=abc", "includeVariables"}
          ] do
        assert message(get(build_conn(), path), 500) ==
                 "Method parameter '#{name}': Failed to convert value of type " <>
                   "'java.lang.String' to required type 'boolean'; Invalid boolean value [abc]"
      end
    end

    test "an unknown workflow is a 404 with the decoded ID" do
      for path <- ["/api/workflow/x%20y", "/api/workflow/x%20y/status"],
          do: assert(message(get(build_conn(), path), 404) == "No such workflow found by id: x y")
    end

    test "the status leaves out an empty correlation ID" do
      id = text(post_json("/api/workflow/archon_simple?correlationId=", ~s({"k":1})))

      assert json(
               get(
                 build_conn(),
                 "/api/workflow/#{id}/status?includeOutput=1&includeVariables=yes"
               ),
               200
             ) ==
               %{"workflowId" => id, "output" => %{}, "variables" => %{}, "status" => "RUNNING"}

      :ok = Runtime.terminate_workflow(id, nil)
    end
  end

  describe "DELETE /api/workflow/{workflowId}" do
    test "terminates once, then answers 200 again; the reason is kept" do
      id = RuntimeCase.start_simple(%{"x" => 1})

      for _ <- 1..2 do
        conn = delete(build_conn(), "/api/workflow/#{id}?reason=archon-5d")
        assert conn.status == 200 and conn.resp_body == ""
        assert get_resp_header(conn, "content-type") == []
      end

      assert {:ok, %{status: :terminated, reason_for_incompletion: "archon-5d"}} =
               Runtime.get_workflow(id, false)
    end

    test "a COMPLETED workflow is a 409 and an unknown one a 404" do
      id = RuntimeCase.start_simple(%{"x" => 1})
      complete(id)

      assert message(delete(build_conn(), "/api/workflow/#{id}"), 409) ==
               "Cannot terminate a COMPLETED workflow."

      assert message(delete(build_conn(), "/api/workflow/x%20y"), 404) ==
               "No such workflow found by id: x y"
    end
  end

  # Completes the workflow's tasks in order, as a worker would without polling.
  defp complete(id) do
    {:ok, workflow} = Runtime.get_workflow(id)

    case Enum.find(workflow.tasks, &(&1.status == :scheduled)) do
      nil ->
        assert workflow.status == :completed

      task ->
        {:ok, _task} =
          Tasks.update(%TaskResult{
            workflow_instance_id: id,
            task_id: task.task_id,
            status: :completed
          })

        complete(id)
    end
  end

  defp missing_body(handler), do: "Required request body is missing: " <> handler

  defp post_json(path, body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, body)
  end

  defp text(conn) do
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/plain;charset=UTF-8"]
    conn.resp_body
  end

  defp json(conn, status) do
    assert conn.status == status
    assert get_resp_header(conn, "content-type") == ["application/json"]
    JSON.decode!(conn.resp_body)
  end

  defp message(conn, status), do: json(conn, status)["message"]

  defp validation_errors(conn) do
    assert %{"status" => 400, "retryable" => false, "validationErrors" => errors} =
             body = json(conn, 400)

    refute Map.has_key?(body, "instance")
    Enum.sort_by(errors, & &1["path"])
  end
end
