# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.MetadataControllerTest do
  @moduledoc """
  `ArchonWeb.MetadataController` (ADR 0023, slice 5c; ADR 0025, slice 6c): the `metadata_*`
  fixtures replayed in capture order, and the answers no fixture holds (seen on the upstream
  server at the ADR's commit, or Archon's own schema refusal of ADR 0023 decision 5). The Phase 6
  fixtures are replayed by `ArchonWeb.ContractReplayTest`, after the workflows they follow.
  """

  use ArchonWeb.ContractCase, async: false

  alias Archon.Domain.TaskDef

  # Every definition name the metadata fixtures use.
  @names ~w(archon_task_a archon_task_b archon_task_c archon_coerced archon_missing archon_simple
            archon_switch archon_fork archon_no_tasks archon_bulk archon_bulk_valid
            archon_bulk_invalid archon_meta6 archon_meta6_agent)

  setup do
    # The fixtures were captured on an empty server; other tests register some of these names.
    remove_definitions(@names)

    on_exit(fn ->
      remove_definitions(@names)
      Archon.RuntimeCase.register_definitions()
    end)
  end

  describe "fixture replay" do
    test "registration and lookup before any workflow ran" do
      replay(steps("metadata_register_taskdefs", "metadata_get_workflow_not_found"))
    end

    test "list, single update, overwrite, bulk update and validation" do
      # The state the first part left; the workflow steps between do not change definitions.
      replay(steps("metadata_register_taskdefs", "metadata_register_workflow_fork"))
      replay(steps("metadata_list_taskdefs", "metadata_update_workflows_empty"))
    end
  end

  describe "POST /api/metadata/workflow" do
    test "a conflict comes before validation" do
      post_json("/api/metadata/workflow", workflow("archon_simple"))

      assert {409, %{"message" => "Workflow with archon_simple.1 already exists!"}} =
               post_json("/api/metadata/workflow", %{workflow("archon_simple") | "tasks" => []})
    end
  end

  describe "PUT /api/metadata/workflow" do
    test "a single object is a list of one" do
      assert put_json("/api/metadata/workflow", workflow("archon_bulk")) ==
               {200, %{"bulkErrorResults" => %{}, "bulkSuccessfulResults" => ["archon_bulk"]}}
    end

    test "a refused schema fails that definition only" do
      refused =
        workflow("archon_bulk_invalid")
        |> Map.put("inputSchema", %{"name" => "s", "externalRef" => "x"})

      assert put_json("/api/metadata/workflow", [workflow("archon_bulk"), refused]) ==
               {200,
                %{
                  "bulkErrorResults" => %{
                    "archon_bulk_invalid" =>
                      "Schema validation is not supported yet: archon_bulk_invalid inputSchema"
                  },
                  "bulkSuccessfulResults" => ["archon_bulk"]
                }}

      assert {:ok, _definition} = Archon.Metadata.find_workflow_def("archon_bulk", 1)
      assert {:error, :not_found} = Archon.Metadata.find_workflow_def("archon_bulk_invalid", 1)
    end
  end

  describe "schema refusal (ADR 0023, decision 5)" do
    test "an inline, external or nameless schema enforced by a workflow definition is a 400" do
      for schema <- [%{"data" => %{}}, %{"name" => "s", "externalRef" => ""}, %{"name" => " "}] do
        assert {400,
                %{
                  "status" => 400,
                  "message" =>
                    "Schema validation is not supported yet: archon_simple outputSchema",
                  "retryable" => false,
                  "instance" => _host
                }} =
                 post_json(
                   "/api/metadata/workflow",
                   Map.put(workflow("archon_simple"), "outputSchema", schema)
                 )
      end

      assert {:error, :not_found} = Archon.Metadata.find_workflow_def("archon_simple", 1)
    end

    test "a name reference, or a schema not enforced, is registered" do
      named = Map.put(workflow("archon_simple"), "inputSchema", %{"name" => "s", "data" => nil})
      assert post_json("/api/metadata/workflow", named) == {200, nil}

      not_enforced =
        workflow("archon_switch")
        |> Map.merge(%{"enforceSchema" => false, "inputSchema" => %{"data" => %{}}})

      assert post_json("/api/metadata/workflow", not_enforced) == {200, nil}
    end

    test "a task definition is refused only when it enforces its schema" do
      inline = %{"name" => "archon_task_a", "outputSchema" => %{"data" => %{}}}
      assert post_json("/api/metadata/taskdefs", [inline]) == {200, nil}

      assert {400,
              %{"message" => "Schema validation is not supported yet: archon_task_b inputSchema"}} =
               post_json("/api/metadata/taskdefs", [
                 %{"name" => "archon_task_c"},
                 %{"name" => "archon_task_b", "enforceSchema" => true, "inputSchema" => %{}}
               ])

      # Nothing of the refused request is stored.
      assert {:error, _} = Archon.Metadata.get_task_def("archon_task_c")

      post_json("/api/metadata/taskdefs", [%{"name" => "archon_task_c"}])

      assert {400, %{"message" => "Schema validation is not supported yet: archon_task_c " <> _}} =
               put_json("/api/metadata/taskdefs", %{
                 "name" => "archon_task_c",
                 "enforceSchema" => true,
                 "outputSchema" => %{"externalRef" => "x"}
               })
    end

    # ADR 0023, decision 5: the refusal comes after upstream's own checks.
    test "after the conflict, the unknown task definition and the whole list" do
      post_json("/api/metadata/workflow", workflow("archon_simple"))
      refused = Map.put(workflow("archon_simple"), "inputSchema", %{"data" => %{}})

      assert {409, %{"message" => "Workflow with archon_simple.1 already exists!"}} =
               post_json("/api/metadata/workflow", refused)

      assert {400, %{"message" => "Schema validation is not supported yet: " <> _}} =
               post_json("/api/metadata/workflow?overwrite=true", refused)

      assert {404, %{"message" => "No such task by name archon_missing"}} =
               put_json("/api/metadata/taskdefs", %{
                 "name" => "archon_missing",
                 "enforceSchema" => true,
                 "inputSchema" => %{"data" => %{}}
               })

      assert {400, %{"message" => "Schema validation is not supported yet: archon_task_b " <> _}} =
               post_json("/api/metadata/taskdefs", [
                 %{"name" => "archon_task_c"},
                 nil,
                 %{"name" => "archon_task_b", "enforceSchema" => true, "inputSchema" => %{}}
               ])

      assert {:error, _} = Archon.Metadata.get_task_def("archon_task_c")
    end

    test "an embedded definition is checked too" do
      embedded = %{
        "name" => "archon_task_b",
        "enforceSchema" => true,
        "inputSchema" => %{"data" => %{}}
      }

      sub = %{
        "name" => "archon_simple",
        "inputSchema" => %{"externalRef" => "x"},
        "tasks" => [simple_task()]
      }

      for task <- [
            Map.put(simple_task(), "taskDefinition", embedded),
            %{
              "name" => "sw",
              "taskReferenceName" => "sw",
              "type" => "SWITCH",
              "evaluatorType" => "value-param",
              "expression" => "x",
              "decisionCases" => %{"a" => [Map.put(simple_task(), "taskDefinition", embedded)]}
            },
            %{
              "name" => "sub",
              "taskReferenceName" => "sub",
              "type" => "SUB_WORKFLOW",
              "subWorkflowParam" => %{"workflowDefinition" => sub}
            }
          ] do
        assert {400, %{"message" => "Schema validation is not supported yet: " <> what}} =
                 post_json("/api/metadata/workflow", %{
                   workflow("archon_fork")
                   | "tasks" => [task]
                 })

        assert what in ["archon_task_b inputSchema", "archon_simple inputSchema"]
      end
    end
  end

  describe "task definitions" do
    test "a null element is upstream's NullPointerException after the ones before it" do
      assert {500,
              %{
                "message" =>
                  ~s|Cannot invoke "com.netflix.conductor.common.metadata.tasks.TaskDef.| <>
                    ~s|setCreatedBy(String)" because "taskDefinition" is null|,
                "retryable" => false
              }} = post_json("/api/metadata/taskdefs", [%{"name" => "archon_task_c"}, nil])

      assert {:ok, %TaskDef{created_by: ""}} = Archon.Metadata.get_task_def("archon_task_c")
    end

    test "PUT validates as updateTaskDef, a class-level error at the argument" do
      assert {400,
              %{
                "validationErrors" => [
                  %{
                    "path" => "updateTaskDef.arg0",
                    "message" =>
                      "TaskDef: archon_missing responseTimeoutSeconds: 3600 must be less than " <>
                        "timeoutSeconds: 1"
                  }
                ]
              }} =
               put_json("/api/metadata/taskdefs", %{
                 "name" => "archon_missing",
                 "timeoutSeconds" => 1
               })
    end

    test "the list is ordered by name" do
      post_json("/api/metadata/taskdefs", [
        %{"name" => "archon_task_b"},
        %{"name" => "archon_task_a"}
      ])

      {200, list} = get_json("/api/metadata/taskdefs")
      names = for %{"name" => name} <- list, name in @names, do: name
      assert names == ["archon_task_a", "archon_task_b"]
    end
  end

  describe "Phase 6 lists, deletion and validation (ADR 0025, decision 6)" do
    test "the lists through REST" do
      agent = Map.put(workflow("archon_meta6_agent"), "metadata", %{"classifier" => "Agent"})
      assert post_json("/api/metadata/workflow", agent) == {200, nil}
      assert post_json("/api/metadata/workflow", workflow("archon_meta6")) == {200, nil}
      assert {200, _bulk} = put_json("/api/metadata/workflow", [workflow("archon_meta6", 2)])

      names = fn {200, list} ->
        for %{"name" => "archon_meta6" <> _} = d <- list, do: d["name"]
      end

      assert names.(get_json("/api/metadata/workflow?classifier=%20aGeNt")) == [
               "archon_meta6_agent"
             ]

      assert names.(get_json("/api/metadata/workflow?classifier=workflow")) == [
               "archon_meta6",
               "archon_meta6"
             ]

      assert names.(get_json("/api/metadata/workflow")) ==
               ["archon_meta6", "archon_meta6", "archon_meta6_agent"]

      assert {200, [%{"version" => 2} = latest]} =
               get_json("/api/metadata/workflow/latest-versions")
               |> then(fn {200, list} ->
                 {200, Enum.filter(list, &(&1["name"] == "archon_meta6"))}
               end)

      assert latest["tasks"] != nil

      # {name}/versions leaves updateTime out; names-and-versions writes it, 0 when unset.
      assert {200, [%{"version" => 1, "createTime" => created} = v1, %{"version" => 2} = v2]} =
               get_json("/api/metadata/workflow/archon_meta6/versions")

      assert created > 0
      assert Map.keys(v1) == ["createTime", "name", "version"]
      assert v2["createTime"] == 0

      assert {200, %{"archon_meta6" => [n1, n2]}} =
               get_json("/api/metadata/workflow/names-and-versions")

      assert n1 == Map.put(v1, "updateTime", 0)
      assert n2["updateTime"] > 0

      assert {200, names} = get_json("/api/metadata/workflow/names")

      assert Enum.filter(names, &String.starts_with?(&1, "archon_meta6")) == [
               "archon_meta6",
               "archon_meta6_agent"
             ]
    end

    # Seen on the upstream server: the version converts as NumberUtils.parseNumber does.
    test "the version path value" do
      for version <- ["%201", "0x1", "+1"] do
        assert post_json("/api/metadata/workflow", workflow("archon_meta6")) == {200, nil}
        assert delete("/api/metadata/workflow/archon_meta6/#{version}") == {200, nil}
      end

      assert {500, %{"message" => message}} = delete("/api/metadata/workflow/archon_meta6/%20")

      assert message ==
               "Required URI template variable 'version' for method parameter type Integer is " <>
                 "present but converted to null"

      # A no-break space is not Character#isWhitespace.
      assert {500, %{"message" => message}} =
               delete("/api/metadata/workflow/archon_meta6/1%C2%A0")

      assert message =~ ~s(For input string: "1\u00A0")
      assert post_json("/api/metadata/workflow", workflow("archon_meta6")) == {200, nil}
      assert delete("/api/metadata/workflow/archon_meta6/1%E3%80%80") == {200, nil}

      assert {500, %{"message" => message}} =
               delete("/api/metadata/workflow/archon_meta6/99999999999")

      assert message ==
               "Method parameter 'version': Failed to convert value of type 'java.lang.String' " <>
                 ~s(to required type 'java.lang.Integer'; For input string: "99999999999")

      assert {500, %{"message" => "No such workflow definition: archon_meta6 version: 1"}} =
               delete("/api/metadata/workflow/archon_meta6/1")
    end

    test "a task definition is deleted whatever refers to it" do
      assert post_json("/api/metadata/taskdefs", [%{"name" => "archon_meta6"}]) == {200, nil}
      assert delete("/api/metadata/taskdefs/archon_meta6") == {200, nil}

      assert {500, %{"message" => "No such task definition", "retryable" => false}} =
               delete("/api/metadata/taskdefs/archon_meta6")
    end

    test "validation: a missing body names the handler, a refused schema is a 400" do
      assert {500, %{"message" => message}} =
               send_json("POST", "/api/metadata/workflow/validate", "null")

      assert message ==
               "Required request body is missing: public void " <>
                 "com.netflix.conductor.rest.controllers.MetadataResource.validate(" <>
                 "com.netflix.conductor.common.metadata.workflow.WorkflowDef)"

      refused = Map.put(workflow("archon_meta6"), "inputSchema", %{"data" => %{}})

      assert {400, %{"message" => message}} =
               post_json("/api/metadata/workflow/validate", refused)

      assert {400, %{"message" => ^message}} = post_json("/api/metadata/workflow", refused)
      assert {404, _not_stored} = get_json("/api/metadata/workflow/archon_meta6")

      assert {400, %{"validationErrors" => [%{"path" => "validateWorkflowDef.arg0.name"}]}} =
               post_json("/api/metadata/workflow/validate", %{"tasks" => [simple_task()]})
    end
  end

  describe "request errors" do
    # Seen on the upstream server: the handler signature completes the message.
    test "a missing body names the handler" do
      for {method, path, handler} <- [
            {"POST", "/api/metadata/workflow",
             "public void com.netflix.conductor.rest.controllers.MetadataResource.create(" <>
               "com.netflix.conductor.common.metadata.workflow.WorkflowDef,boolean)"},
            {"PUT", "/api/metadata/workflow",
             "public com.netflix.conductor.common.model.BulkResponse<java.lang.String> " <>
               "com.netflix.conductor.rest.controllers.MetadataResource.update(java.util.List<" <>
               "com.netflix.conductor.common.metadata.workflow.WorkflowDef>)"},
            {"POST", "/api/metadata/taskdefs",
             "public void com.netflix.conductor.rest.controllers.MetadataResource.registerTaskDef(" <>
               "java.util.List<com.netflix.conductor.common.metadata.tasks.TaskDef>)"},
            {"PUT", "/api/metadata/taskdefs",
             "public void com.netflix.conductor.rest.controllers.MetadataResource.registerTaskDef(" <>
               "com.netflix.conductor.common.metadata.tasks.TaskDef)"}
          ] do
        assert {500, %{"message" => message, "retryable" => false}} =
                 send_json(method, path, "null")

        assert message == "Required request body is missing: " <> handler
      end
    end

    # Upstream: "JSON parse error: Cannot deserialize value of type `int` from String "abc": ..."
    test "a value the codec cannot convert is a 500 parse error" do
      assert {500, %{"message" => "JSON parse error: " <> detail}} =
               post_json("/api/metadata/taskdefs", [%{"name" => "x", "retryCount" => "abc"}])

      assert detail == "[0].retryCount must be integer"

      # As Jackson, a numeric string is a number (seen upstream).
      assert post_json("/api/metadata/taskdefs", [
               %{"name" => "archon_task_c", "retryCount" => "7"}
             ]) ==
               {200, nil}

      assert {:ok, %TaskDef{retry_count: 7}} = Archon.Metadata.get_task_def("archon_task_c")

      assert {500, %{"message" => "JSON parse error: must be object"}} =
               put_json("/api/metadata/taskdefs", [%{"name" => "x"}])
    end
  end

  ## Helpers

  defp workflow(name, version \\ 1),
    do: %{"name" => name, "version" => version, "tasks" => [simple_task()]}

  defp simple_task,
    do: %{"name" => "archon_task_a", "taskReferenceName" => "a", "type" => "SIMPLE"}

  defp get_json(path), do: send_json("GET", path, nil)
  defp post_json(path, body), do: send_json("POST", path, JSON.encode!(body))
  defp put_json(path, body), do: send_json("PUT", path, JSON.encode!(body))
  defp delete(path), do: send_json("DELETE", path, nil)

  defp send_json(method, path, raw) do
    conn = build_conn()

    conn =
      if raw,
        do:
          conn
          |> put_req_header("content-type", "application/json")
          |> dispatch(@endpoint, method, path, raw),
        else: dispatch(conn, @endpoint, method, path, nil)

    body = if conn.resp_body in [nil, ""], do: nil, else: JSON.decode!(conn.resp_body)
    {conn.status, body}
  end
end
