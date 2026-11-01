# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.WorkflowLifecycleControllerTest do
  @moduledoc """
  `ArchonWeb.WorkflowLifecycleController` beyond the contract replay (ADR 0025, decisions 2 and
  3, slice 6d): the bodyless `POST` actions refuse a browser's cross-origin simple request, and a
  removal that waits too long for the outbox is a retryable 500.
  """

  use ArchonWeb.ContractCase, async: false

  @moduletag :capture_log

  alias Archon.Runtime
  alias Archon.RuntimeCase

  setup do
    Archon.RuntimeHooks.reset()
    on_exit(&Archon.RuntimeHooks.reset/0)
    RuntimeCase.register_definitions()
    :ok
  end

  defp start do
    {:ok, id} = Runtime.start_workflow(%{name: "archon_simple", input: %{}})
    id
  end

  describe "a bodyless POST" do
    test "with a form or text/plain type is refused before the action" do
      id = start()
      {:ok, before} = Runtime.get_workflow(id)

      for action <- ~w(retry restart resetcallbacks),
          type <- [
            "application/x-www-form-urlencoded",
            "multipart/form-data; boundary=x",
            "Text/Plain;charset=UTF-8"
          ] do
        conn =
          build_conn()
          |> put_req_header("content-type", type)
          |> post("/api/workflow/#{id}/#{action}", "")

        assert %{"status" => 500, "retryable" => false, "message" => message} =
                 json_response(conn, 500)

        assert message == "Content-Type '#{type}' is not supported"
      end

      assert Runtime.get_workflow(id) == {:ok, before}
    end

    test "without a type or with another one runs the action, as upstream" do
      id = start()

      assert build_conn() |> post("/api/workflow/#{id}/resetcallbacks") |> response(204)

      assert build_conn()
             |> put_req_header("content-type", "application/json")
             |> post("/api/workflow/#{id}/resetcallbacks", "")
             |> response(204)

      # running: retry's own 404, after the check
      assert %{"status" => 404} =
               build_conn()
               |> put_req_header("content-type", "application/octet-stream")
               |> post("/api/workflow/#{id}/retry", "")
               |> json_response(404)
    end
  end

  test "a removal that waits too long for the outbox is a retryable 500" do
    saved = Application.get_env(:archon, Archon.Runtime)
    on_exit(fn -> Application.put_env(:archon, Archon.Runtime, saved) end)
    Application.put_env(:archon, Archon.Runtime, Keyword.put(saved, :remove_timeout, 200))

    id = start()

    # An entry the process has not handed to its runner (no commit of its own added it), so it
    # stays while the removal asks.
    :ok =
      Runtime.store().commit(id, %Archon.Runtime.Commit{
        outbox: [{:retry_sub_workflow, "archon-missing-" <> Runtime.new_id()}]
      })

    conn = build_conn() |> delete("/api/workflow/#{id}/remove?archiveWorkflow=false")

    assert json_response(conn, 500) == %{
             "status" => 500,
             "message" => "Temporary server error, retry the request",
             "instance" => conn |> json_response(500) |> Map.fetch!("instance"),
             "retryable" => true
           }

    assert {:ok, _workflow} = Runtime.get_workflow(id)
  end
end
