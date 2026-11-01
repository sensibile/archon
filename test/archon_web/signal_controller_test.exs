# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.SignalControllerTest do
  @moduledoc """
  `ArchonWeb.SignalController` (ADR 0025 decision 5, slice 6e) outside the contract replay:
  Spring's conversion failures in argument order, the missing body of each handler, and
  `executeWorkflow`'s own failures before the start (the unboxed `version`,
  `markAsDynamicWorkflow`).

  The messages are not in a fixture; they were seen on the upstream server (the commit of the
  file headers, an empty SQLite store) and are written here as upstream answered.
  """

  use ArchonWeb.ContractCase, async: false

  @moduletag :capture_log

  alias Archon.Contract
  alias Archon.Domain.{Codec, TaskDef, WorkflowDef}
  alias Archon.Runtime
  alias Archon.RuntimeCase

  @status_type "com.netflix.conductor.common.metadata.tasks.TaskResult$Status"
  @strategy_type "org.conductoross.conductor.model.WorkflowSignalReturnStrategy"
  @output_map "java.util.Map<java.lang.String, java.lang.Object>"
  @task_resource "com.netflix.conductor.rest.controllers.TaskResource"
  @mono "public reactor.core.publisher.Mono<org.conductoross.conductor.model.SignalResponse>"

  setup do
    Archon.RuntimeHooks.reset()
    on_exit(&Archon.RuntimeHooks.reset/0)

    {:ok, task_defs} =
      Codec.cast(
        {:list, {:struct, TaskDef}},
        Contract.fixture("metadata_register_ops_taskdefs")["request"]["body"],
        []
      )

    for task_def <- task_defs, do: :ok = Runtime.metadata().update_task_def(task_def)

    for name <- ~w(waits idle noop) do
      body = Contract.fixture("metadata_register_workflow_ops_#{name}")["request"]["body"]
      {:ok, definition} = WorkflowDef.from_json(body)
      :ok = Runtime.metadata().update_workflow_def(definition)
    end

    RuntimeCase.isolate_queues(["archon_ops_idle"])
  end

  describe "conversion failures" do
    test "a status that is not a TaskResult.Status constant" do
      for path <- ["/api/tasks/wf/completed/signal", "/api/tasks/wf/ref/completed"] do
        assert message(post_json(path, %{}), 500) ==
                 "Method parameter 'status': Failed to convert value of type 'java.lang.String' " <>
                   "to required type '#{@status_type}'; Failed to convert from type " <>
                   "[java.lang.String] to type [@org.springframework.web.bind.annotation." <>
                   "PathVariable #{@status_type}] for value [completed]"
      end
    end

    test "a long value is cut to 100 characters" do
      long = String.duplicate("A", 120)

      assert message(post_json("/api/tasks/wf/#{long}/signal", %{}), 500) =~
               "for value [#{String.duplicate("A", 100)} (truncated)...]"
    end

    test "a blank status converts to null" do
      assert message(post_json("/api/tasks/wf/%20/signal", %{}), 500) ==
               "Required URI template variable 'status' for method parameter type Status is " <>
                 "present but converted to null"
    end

    test "the status converts before the body is read" do
      conn = post(build_conn(), "/api/tasks/wf/BAD/signal")
      assert message(conn, 500) =~ "Method parameter 'status'"
    end

    test "a returnStrategy that is not a constant, also repeated" do
      expected = fn source, value ->
        "Method parameter 'returnStrategy': Failed to convert value of type '#{source}' to " <>
          "required type '#{@strategy_type}'; Failed to convert from type [java.lang.String] " <>
          "to type [@org.springframework.web.bind.annotation.RequestParam #{@strategy_type}] " <>
          "for value [#{value}]"
      end

      assert message(
               post_json("/api/tasks/wf/COMPLETED/signal/sync?returnStrategy=BAD", %{}),
               500
             ) ==
               expected.("java.lang.String", "BAD")

      assert message(
               post_json("/api/workflow/execute/x/1?returnStrategy=%20blocking_task", %{}),
               500
             ) == expected.("java.lang.String", " blocking_task")

      assert message(
               post_json(
                 "/api/tasks/wf/COMPLETED/signal/sync?returnStrategy=X&returnStrategy=Y",
                 %{}
               ),
               500
             ) == expected.("java.lang.String[]", "X")
    end

    test "numbers: timeoutMillis is a long, version and waitForSeconds Integers" do
      assert message(post_json("/api/tasks/wf/COMPLETED/signal/sync?timeoutMillis=abc", %{}), 500) ==
               "Method parameter 'timeoutMillis': Failed to convert value of type " <>
                 ~s('java.lang.String' to required type 'long'; For input string: "abc")

      assert message(post_json("/api/workflow/execute/x/abc", %{}), 500) ==
               "Method parameter 'version': Failed to convert value of type 'java.lang.String' " <>
                 ~s(to required type 'java.lang.Integer'; For input string: "abc")

      assert message(post_json("/api/workflow/execute/x/1?waitForSeconds=abc", %{}), 500) ==
               "Method parameter 'waitForSeconds': Failed to convert value of type " <>
                 ~s('java.lang.String' to required type 'java.lang.Integer'; For input string: "abc")
    end

    test "a timeoutMillis beyond an int is a long" do
      id = start("archon_ops_waits")

      conn = post_json("/api/tasks/#{id}/COMPLETED/signal/sync?timeoutMillis=3000000000", %{})
      assert %{"responseType" => "TARGET_WORKFLOW", "signalTimeout" => false} = json(conn, 200)
    end
  end

  describe "the body" do
    test "every handler needs one" do
      by_ref =
        "(java.lang.String,java.lang.String,#{@status_type},java.lang.String,#{@output_map})"

      for {path, handler} <- [
            {"/api/tasks/wf/ref/COMPLETED",
             "public java.lang.String #{@task_resource}.updateTask#{by_ref}"},
            {"/api/tasks/wf/ref/COMPLETED/sync",
             "public com.netflix.conductor.common.run.Workflow #{@task_resource}.updateTaskSync#{by_ref}"},
            {"/api/tasks/wf/COMPLETED/signal",
             "public void #{@task_resource}.signalWorkflowTaskAsync(java.lang.String," <>
               "#{@status_type},#{@output_map})"},
            {"/api/tasks/wf/COMPLETED/signal/sync",
             "#{@mono} #{@task_resource}.signalWorkflowTaskSync(java.lang.String," <>
               "#{@status_type},#{@strategy_type},long,#{@output_map})"},
            {"/api/workflow/execute/x/1",
             "#{@mono} com.netflix.conductor.rest.controllers.WorkflowResource.executeWorkflow(" <>
               "java.lang.String,java.lang.Integer,java.lang.String,java.lang.String," <>
               "java.lang.Integer,java.lang.String,#{@strategy_type}," <>
               "com.netflix.conductor.common.metadata.workflow.StartWorkflowRequest)"}
          ] do
        assert message(post(build_conn(), path), 500) ==
                 "Required request body is missing: " <> handler

        assert message(post_json(path, "null"), 500) ==
                 "Required request body is missing: " <> handler
      end
    end

    test "the output must be an object" do
      assert message(post_json("/api/tasks/wf/ref/COMPLETED", "[1]"), 500) =~
               ~r/^JSON parse error: /
    end
  end

  describe "execute" do
    test "a blank version is null, which the handler unboxes" do
      assert message(post_json("/api/workflow/execute/archon_ops_noop/%20", %{}), 500) ==
               ~s(Cannot invoke "java.lang.Integer.intValue\(\)" because "version" is null)
    end

    test "an inline definition with tasks marks the input dynamic" do
      definition = %{
        "name" => "archon_6e_inline",
        "version" => 1,
        "tasks" => [%{"name" => "w", "taskReferenceName" => "w1", "type" => "WAIT"}]
      }

      body = %{
        "input" => %{"_systemMetadata" => %{"a" => 1}},
        "workflowDef" => definition
      }

      assert %{"input" => %{"_systemMetadata" => %{"a" => 1, "dynamic" => true}}} =
               json(post_json("/api/workflow/execute/archon_6e_inline/1", body), 200)

      assert message(
               post_json("/api/workflow/execute/archon_6e_inline/1", %{body | "input" => nil}),
               500
             ) ==
               ~s(Cannot invoke "java.util.Map.containsKey\(Object\)" because "workflowInput" is null)

      assert message(
               post_json("/api/workflow/execute/archon_6e_inline/1", %{
                 body
                 | "input" => %{"_systemMetadata" => "str"}
               }),
               500
             ) ==
               "class java.lang.String cannot be cast to class java.util.Map (java.lang.String " <>
                 "and java.util.Map are in module java.base of loader 'bootstrap')"
    end

    test "the version 0 is the latest; a blank returnStrategy and requestId are the defaults" do
      body =
        json(
          post_json("/api/workflow/execute/archon_ops_noop/0?returnStrategy=%20&requestId=%20", %{
            "name" => "other",
            "version" => 7
          }),
          200
        )

      assert %{"responseType" => "TARGET_WORKFLOW", "status" => "COMPLETED"} = body
      assert {:ok, _uuid} = Ecto.UUID.cast(body["requestId"])
    end

    test "a waitForSeconds below 0 times out at once" do
      {ms, conn} =
        elapsed_ms(fn ->
          post_json("/api/workflow/execute/archon_ops_idle/1?waitForSeconds=-1", %{})
        end)

      assert %{"signalTimeout" => true, "status" => "RUNNING"} = json(conn, 200)
      assert ms < 1_000
    end
  end

  defp start(name) do
    {:ok, id} = Runtime.start_workflow(%{name: name, input: %{}})
    id
  end

  defp elapsed_ms(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - start, result}
  end

  defp post_json(path, body) when is_binary(body) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> post(path, body)
  end

  defp post_json(path, body), do: post_json(path, JSON.encode!(body))

  defp json(conn, status) do
    assert conn.status == status
    assert get_resp_header(conn, "content-type") == ["application/json"]
    JSON.decode!(conn.resp_body)
  end

  defp message(conn, status), do: json(conn, status)["message"]
end
