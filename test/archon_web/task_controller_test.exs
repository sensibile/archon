# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.TaskControllerTest do
  @moduledoc """
  `ArchonWeb.TaskController` (ADR 0023 decisions 2 and 4, slice 5e).

  The `task_*` fixtures are replayed against workflows this test starts through
  `Archon.Runtime.start_workflow/1`, with the definitions put in the runtime's metadata, as the
  metadata and workflow controllers (slices 5c and 5d) may not be there yet: the captured start's
  workflow ID is bound to the started one (`ArchonWeb.ContractCase.bind/3`), and only the task
  steps of the scenario are replayed.

  The task queues are the application's, shared with other tests, so each test empties the
  queues it polls first (`Archon.RuntimeCase.isolate_queues/1`).
  """

  use ArchonWeb.ContractCase, async: false

  @moduletag :capture_log

  alias Archon.Contract
  alias Archon.Domain.{TaskDef, TaskResult, WorkflowDef}
  alias Archon.Runtime
  alias Archon.RuntimeCase
  alias ArchonWeb.TaskController

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

  # Starts the workflow fixture `name` started upstream and binds its captured ID.
  defp start(state, name, input) do
    {:ok, id} = Runtime.start_workflow(input)
    bind(state, Contract.fixture(name)["response"]["body"], id)
  end

  # The task steps of the scenario from `first` through `last`: the metadata and workflow
  # exchanges between them are other slices' (the waits stay; they read the runtime).
  defp task_steps(first, last) do
    first
    |> steps(last)
    |> Enum.reject(&other_slice?/1)
  end

  defp other_slice?(step) when elem(step, 0) == :exchange,
    do: String.starts_with?(elem(step, 1), ["workflow_", "metadata_"])

  defp other_slice?(_step), do: false

  defp inline_input(name) do
    body = Contract.fixture(name)["request"]["body"]
    {:ok, definition} = WorkflowDef.from_json(body["workflowDef"])

    %{
      name: body["name"],
      definition: definition,
      input: body["input"],
      correlation_id: body["correlationId"]
    }
  end

  describe "replay of the task fixtures" do
    test "SIMPLE: poll, update, update-v2 without a next task, get, empty poll" do
      new_state()
      |> start("workflow_start_simple", %{
        name: "archon_simple",
        input: %{"x" => 1},
        correlation_id: "archon-corr-1"
      })
      |> then(&replay(task_steps("task_poll_simple_a", "task_poll_empty"), &1))
    end

    test "SWITCH: poll and update the chosen case" do
      new_state()
      |> start("workflow_start_request_switch", %{
        name: "archon_switch",
        version: 1,
        input: %{"route" => "b"},
        correlation_id: "archon-corr-2"
      })
      |> then(&replay(task_steps("task_poll_switch_b", "task_update_switch_b"), &1))
    end

    test "FORK_JOIN: batch poll and update both branches" do
      new_state()
      |> start("workflow_start_fork", %{name: "archon_fork", input: %{}})
      |> then(&replay(task_steps("task_batch_poll_fork_a", "task_update_fork_b"), &1))
    end

    test "update-v2 returns the next task; then the unknown task and validation errors" do
      state =
        new_state()
        |> start("workflow_start_inline", inline_input("workflow_start_inline"))
        |> start("workflow_start_inline_second", inline_input("workflow_start_inline_second"))

      state = replay(task_steps("task_poll_inline_c", "task_update_v2_next"), state)
      state = replay([{:wait_status, "workflow_start_inline", "COMPLETED"}], state)
      replay(task_steps("task_batch_poll_empty", "task_update_v2_invalid"), state)
    end
  end

  describe "poll" do
    test "a domain is the queue's prefix; an empty workerid is kept" do
      domain = "d#{System.unique_integer([:positive])}"

      {:ok, id} =
        Runtime.start_workflow(%{
          name: "archon_simple",
          input: %{"x" => 1},
          task_to_domain: %{"archon_task_a" => domain}
        })

      assert get(build_conn(), "/api/tasks/poll/archon_task_a").status == 204

      conn = get(build_conn(), "/api/tasks/poll/archon_task_a?domain=#{domain}&workerid=")

      assert %{"workflowInstanceId" => ^id, "domain" => ^domain, "workerId" => ""} =
               json(conn, 200)
    end
  end

  describe "batch poll" do
    test "count and timeout default to 1 and 100; a zero or negative count is an empty list" do
      for _ <- 1..2, do: RuntimeCase.start_simple(%{"x" => 1})

      conn = get(build_conn(), "/api/tasks/poll/batch/archon_task_a")
      assert [%{"taskType" => "archon_task_a"}] = json(conn, 200)

      for query <- ["count=0", "count=-1", "timeout=-1&count=0"],
          do: assert(json(get(build_conn(), "/api/tasks/poll/batch/zz_none?#{query}"), 200) == [])
    end
  end

  describe "update" do
    test "both paths: a missing body names the handler, as upstream" do
      assert message(post_json("/api/tasks", "")) ==
               "Required request body is missing: public java.lang.String " <>
                 "com.netflix.conductor.rest.controllers.TaskResource.updateTask(" <>
                 "com.netflix.conductor.common.metadata.tasks.TaskResult)"

      assert message(post_json("/api/tasks/update-v2", "null")) ==
               "Required request body is missing: public org.springframework.http.ResponseEntity" <>
                 "<com.netflix.conductor.common.metadata.tasks.Task> " <>
                 "com.netflix.conductor.rest.controllers.TaskResource.updateTaskV2(" <>
                 "com.netflix.conductor.common.metadata.tasks.TaskResult)"
    end

    test "a field of the wrong type is a 500 JSON parse error, as Jackson's" do
      for path <- ["/api/tasks", "/api/tasks/update-v2"],
          body <- [~s({"taskId":"t","workflowInstanceId":"w","status":"BAD"}), "[]"] do
        conn = post_json(path, body)
        assert %{"status" => 500, "message" => "JSON parse error: " <> _} = json(conn, 500)
      end
    end

    test "POST /api/tasks with both IDs missing lists both violations" do
      conn = post_json("/api/tasks", "{}")

      assert json(conn, 400) == %{
               "status" => 400,
               "message" => "Validation failed, check below errors for detail.",
               "retryable" => false,
               "validationErrors" => [
                 %{
                   "path" => "updateTask.arg0.workflowInstanceId",
                   "message" => "Workflow Id cannot be null or empty"
                 },
                 %{
                   "path" => "updateTask.arg0.taskId",
                   "message" => "Task ID cannot be null or empty"
                 }
               ]
             }
    end

    test "update-v2 with both IDs missing is Spring's message, as the upstream server wrote it" do
      # The server's answer to the body {} (replayed in order by ArchonWeb.ContractReplayTest).
      expected = Contract.fixture("task_update_v2_invalid_both")["response"]["body"]["message"]

      assert TaskController.spring_validation_message(
               TaskResult.validate(%TaskResult{}) |> elem(1),
               %TaskResult{}
             ) == expected
    end

    test "an unknown task of an existing workflow, and extendLease, name the task" do
      id = RuntimeCase.start_simple(%{"x" => 1})
      unknown = "00000000-0000-0000-0000-000000000001"

      for path <- ["/api/tasks", "/api/tasks/update-v2"] do
        body = JSON.encode!(%{"workflowInstanceId" => id, "taskId" => unknown})
        assert message(post_json(path, body)) == "No such task found by id: #{unknown}"

        body =
          JSON.encode!(%{
            "workflowInstanceId" => "none",
            "taskId" => unknown,
            "extendLease" => true
          })

        assert message(post_json(path, body)) == "No such task found by id: #{unknown}"
      end
    end

    test "extendLease of a running task: the task ID, and 204 on update-v2" do
      id = RuntimeCase.start_simple(%{"x" => 1})
      task = RuntimeCase.task(id, "task_a_ref")

      body =
        JSON.encode!(%{
          "workflowInstanceId" => id,
          "taskId" => task.task_id,
          "extendLease" => true
        })

      conn = post_json("/api/tasks", body)
      assert conn.status == 200
      assert conn.resp_body == task.task_id
      assert get_resp_header(conn, "content-type") == ["text/plain;charset=UTF-8"]

      assert post_json("/api/tasks/update-v2", body).status == 204
    end
  end

  describe "get" do
    test "the path value is decoded in the message" do
      assert message(get(build_conn(), "/api/tasks/x%20y")) == "Task not found for taskId: x y"
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

  defp message(conn), do: JSON.decode!(conn.resp_body)["message"]
end
