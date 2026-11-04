# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.TaskLogControllerTest do
  @moduledoc """
  `ArchonWeb.TaskLogController` beyond the contract replay (ADR 0027, decision 6, slice 8d): the
  body is the log's text whatever its `Content-Type`, the 8 MB limit, text a store cannot keep,
  the order of `GET`, a browser's cross-origin `POST`, and a store that refuses the write.
  """

  use ArchonWeb.ContractCase, async: false

  @moduletag :capture_log

  alias Archon.Runtime

  defmodule FencedStore do
    @moduledoc false
    # The runtime's store, except that every log write is refused as a stale node's is.
    def add_task_logs(_logs), do: {:error, :fenced}
  end

  defp task_id, do: "archon-log-" <> Runtime.new_id()

  defp post_log(conn \\ build_conn(), task_id, body, content_type) do
    conn
    |> put_req_header("content-type", content_type)
    |> post("/api/tasks/#{task_id}/log", body)
  end

  defp logs(task_id), do: build_conn() |> get("/api/tasks/#{task_id}/log")

  test "the body is the text of the log whatever its Content-Type" do
    id = task_id()

    for {body, type} <- [
          {"plain", "text/plain"},
          {~s("json string"), "application/json"},
          {~s({"a": 1}), "application/json"},
          {"<form>", "application/x-www-form-urlencoded"},
          {"﻿bom", "application/octet-stream"},
          {"  spaced  ", "text/plain;charset=UTF-8"}
        ] do
      assert response(post_log(id, body, type), 200) == ""
    end

    assert [
             %{"log" => "plain", "taskId" => ^id, "createdTime" => time},
             %{"log" => ~s("json string")},
             %{"log" => ~s({"a": 1})},
             %{"log" => "<form>"},
             %{"log" => "﻿bom"},
             %{"log" => "  spaced  "}
           ] = json_response(logs(id), 200)

    assert is_integer(time) and abs(time - Runtime.now()) < 60_000
  end

  # StringHttpMessageConverter decodes with the Content-Type's charset, UTF-8 without one.
  test "the body is decoded with its declared charset" do
    id = task_id()

    for {body, type} <- [
          {<<0xE9>>, "text/plain; charset=ISO-8859-1"},
          {<<"a", 0xE9>>, ~s(text/plain;Charset="us-ascii")},
          {<<0x00, 0xE9>>, "text/plain;charset=UTF-16BE"},
          {<<0xFF, 0xFE, 0xE9, 0x00>>, "text/plain;charset=utf-16"},
          {<<0xE9, 0x00, 0x00, 0xD8>>, "text/plain;charset=UTF-16LE"},
          {"é", "text/plain;charset=windows-1252"},
          {"é", "application/json"}
        ] do
      assert response(post_log(id, body, type), 200) == ""
    end

    assert Enum.map(json_response(logs(id), 200), & &1["log"]) ==
             ["é", "a\uFFFD", "é", "é", "é\uFFFD", "é", "é"]
  end

  test "an empty body is the missing body and writes nothing" do
    id = task_id()

    assert %{"status" => 500, "retryable" => false, "message" => message} =
             json_response(post_log(id, "", "text/plain"), 500)

    assert message ==
             "Required request body is missing: public void " <>
               "com.netflix.conductor.rest.controllers.TaskResource.log(java.lang.String," <>
               "java.lang.String)"

    assert response(logs(id), 204) == ""
  end

  test "a body over 8 MB is refused" do
    id = task_id()
    conn = post_log(id, String.duplicate("a", 8_000_001), "text/plain")
    assert %{"status" => 413} = json_response(conn, 413)
    assert response(logs(id), 204) == ""
  end

  test "text a store cannot keep is kept with U+FFFD in its place" do
    id = task_id()
    assert response(post_log(id, "nul \u0000 and " <> <<0xFF>>, "text/plain"), 200)
    assert [%{"log" => "nul � and �"}] = json_response(logs(id), 200)

    # A task ID no store can keep is written nowhere, as no read can find it.
    assert response(post_log("nul%00id", "x", "text/plain"), 200)
    assert response(logs("nul%00id"), 204) == ""
  end

  test "logs come in createdTime order, a posted one after the task's earlier ones" do
    id = task_id()

    :ok =
      Runtime.store().add_task_logs([
        %Archon.Domain.TaskExecLog{
          task_id: id,
          log: "late",
          created_time: Runtime.now() + 60_000
        },
        %Archon.Domain.TaskExecLog{task_id: id, log: "early", created_time: 1}
      ])

    assert response(post_log(id, "now", "text/plain"), 200)
    assert Enum.map(json_response(logs(id), 200), & &1["log"]) == ~w(early now late)
  end

  describe "a browser's cross-origin POST" do
    test "is refused before the body is read" do
      id = task_id()

      for headers <- [
            [{"sec-fetch-site", "cross-site"}],
            [{"sec-fetch-site", "same-site"}, {"origin", "http://www.example.com"}],
            [{"origin", "http://evil.example"}],
            [{"origin", "null"}]
          ] do
        conn =
          Enum.reduce(headers, build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
          |> post_log(id, "cross", "text/plain")

        assert %{"status" => 403, "retryable" => false, "message" => message} =
                 json_response(conn, 403)

        assert message == "Cross-origin request refused"
      end

      assert response(logs(id), 204) == ""
    end

    test "from the same origin or a client that is not a browser is written" do
      id = task_id()

      for headers <- [
            [],
            [{"sec-fetch-site", "same-origin"}],
            [{"sec-fetch-site", "none"}],
            [{"origin", "http://www.example.com"}]
          ] do
        conn =
          Enum.reduce(headers, build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
          |> post_log(id, "ok", "text/plain")

        assert response(conn, 200) == ""
      end

      assert length(json_response(logs(id), 200)) == 4

      # GET reads only, as upstream's other GETs do.
      conn = build_conn() |> put_req_header("sec-fetch-site", "cross-site")
      assert [_ | _] = conn |> get("/api/tasks/#{id}/log") |> json_response(200)
    end
  end

  test "a write the store refuses (a fenced node) is a retryable 500" do
    saved = Application.get_env(:archon, Archon.Runtime)
    on_exit(fn -> Application.put_env(:archon, Archon.Runtime, saved) end)
    Application.put_env(:archon, Archon.Runtime, Keyword.put(saved, :store, FencedStore))

    assert %{"status" => 500, "retryable" => true} =
             json_response(post_log(task_id(), "x", "text/plain"), 500)
  end
end
