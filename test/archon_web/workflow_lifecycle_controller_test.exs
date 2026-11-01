# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.WorkflowLifecycleControllerTest do
  @moduledoc """
  `ArchonWeb.WorkflowLifecycleController` beyond the contract replay (ADR 0025, decisions 2 and
  3, slice 6d): the bodyless `POST` actions refuse a browser's cross-origin request, and a
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
    test "that a browser marks as cross-origin is refused before the action" do
      id = start()

      for action <- ~w(retry restart resetcallbacks),
          headers <- [
            [{"sec-fetch-site", "cross-site"}],
            [{"sec-fetch-site", "same-site"}, {"origin", "http://www.example.com"}],
            [{"origin", "http://evil.example"}],
            [{"origin", "null"}],
            [{"origin", "http://www.example.com:8080"}],
            [{"content-type", "text/ping"}, {"sec-fetch-site", "cross-site"}]
          ] do
        conn =
          Enum.reduce(headers, build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
          |> post("/api/workflow/#{id}/#{action}")

        assert %{"status" => 403, "retryable" => false, "message" => message} =
                 json_response(conn, 403)

        assert message == "Cross-origin request refused"
      end

      # resetcallbacks would have answered 204, retry 404 and restart 409
      assert {:ok, %{status: :running}} = Runtime.get_workflow(id)
    end

    test "from the same origin or a client that is not a browser runs the action" do
      id = start()

      for headers <- [
            [],
            [{"sec-fetch-site", "same-origin"}],
            [{"sec-fetch-site", "none"}],
            [{"origin", "http://www.example.com"}],
            [{"content-type", "application/x-www-form-urlencoded"}]
          ] do
        conn =
          Enum.reduce(headers, build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
          |> post("/api/workflow/#{id}/resetcallbacks")

        assert response(conn, 204)
      end

      # running: retry's own 404
      assert %{"status" => 404} =
               build_conn()
               |> put_req_header("origin", "http://www.example.com")
               |> post("/api/workflow/#{id}/retry")
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
