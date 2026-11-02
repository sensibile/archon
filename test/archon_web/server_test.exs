# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.ServerTest do
  @moduledoc """
  Smoke test over real HTTP (ADR 0023, slice 5f): Bandit started the way Phoenix starts it for
  `server: true` (`Bandit.PhoenixAdapter.child_specs/2`), on the address `config/runtime.exs`
  reads (ADR 0024, decision 4), and a few routes asked through a socket, one Phase 6 lifecycle
  among them (ADR 0025, slice 6h). The other web tests call the endpoint through
  `Phoenix.ConnTest` without one.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Archon.Contract
  alias Archon.Domain.Codec

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    Archon.RuntimeCase.register_definitions()
    Archon.RuntimeCase.isolate_queues(~w(archon_task_a))

    # The default address with any free port: PORT=0 lets the system pick one.
    saved = for name <- ~w(ARCHON_HTTP_IP PORT), into: %{}, do: {name, System.get_env(name)}
    System.delete_env("ARCHON_HTTP_IP")
    System.put_env("PORT", "0")

    http =
      @runtime |> Config.Reader.read!(env: :test) |> get_in([:archon, ArchonWeb.Endpoint, :http])

    for {name, value} <- saved,
        do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

    config = Keyword.put(Application.get_env(:archon, ArchonWeb.Endpoint), :http, http)
    [spec] = Bandit.PhoenixAdapter.child_specs(ArchonWeb.Endpoint, [otp_app: :archon] ++ config)
    server = start_supervised!(spec)
    {:ok, {ip, port}} = ThousandIsland.listener_info(server)

    %{ip: ip, base: "http://127.0.0.1:#{port}"}
  end

  test "listens on 127.0.0.1 by default", %{ip: ip} do
    assert ip == {127, 0, 0, 1}
  end

  test "health answers as the fixture", %{base: base} do
    expected = Contract.fixture("health")["response"]

    assert {200, "application/json", body} = request(:get, base <> "/health")
    assert JSON.decode!(body) == expected["body"]

    assert {200, "application/json", ""} = request(:head, base <> "/health")
  end

  test "a workflow starts, reads and terminates", %{base: base} do
    assert {200, "text/plain;charset=UTF-8", id} =
             request(:post, base <> "/api/workflow/archon_simple", "{}")

    assert {200, "application/json", body} =
             request(:get, base <> "/api/workflow/#{id}?includeTasks=false")

    assert %{"workflowId" => ^id, "workflowName" => "archon_simple", "status" => "RUNNING"} =
             JSON.decode!(body)

    assert {200, nil, ""} = request(:delete, base <> "/api/workflow/#{id}?reason=smoke")
    assert {:ok, workflow} = Archon.Runtime.get_workflow(id, false)
    assert Codec.enum_name(workflow.status) == "TERMINATED"
  end

  # The origin check compares with the host and port a real client sends in its Host header
  # (ADR 0025, decision 3).
  test "a workflow pauses, resumes and is terminated and removed", %{base: base} do
    assert {200, "text/plain;charset=UTF-8", id} =
             request(:post, base <> "/api/workflow/archon_simple", "{}")

    assert {200, nil, ""} = request(:put, base <> "/api/workflow/#{id}/pause", "")
    assert {:ok, %{status: :paused}} = Archon.Runtime.get_workflow(id, false)
    assert {200, nil, ""} = request(:put, base <> "/api/workflow/#{id}/resume", "")
    assert {:ok, %{status: :running}} = Archon.Runtime.get_workflow(id, false)

    same_origin = [{~c"origin", String.to_charlist(base)}]

    assert {204, nil, ""} =
             request(:post, base <> "/api/workflow/#{id}/resetcallbacks", "",
               headers: same_origin
             )

    other_origin = [{~c"origin", ~c"http://archon.example"}]

    assert {403, "application/json", body} =
             request(:post, base <> "/api/workflow/#{id}/resetcallbacks", "",
               headers: other_origin
             )

    assert %{"message" => "Cross-origin request refused"} = JSON.decode!(body)

    assert {200, nil, ""} = request(:delete, base <> "/api/workflow/#{id}/terminate-remove")
    assert Archon.Runtime.get_workflow(id, false) == {:error, :not_found}
  end

  test "errors keep upstream's shape", %{base: base} do
    assert {404, "application/json", body} = request(:get, base <> "/api/nope/")

    assert %{"status" => 404, "message" => "No static resource api/nope.", "retryable" => false} =
             JSON.decode!(body)

    assert {500, "application/json", body} =
             request(:post, base <> "/api/workflow/archon_simple", "{}",
               content_type: ~c"text/plain"
             )

    assert %{"message" => "Content-Type 'text/plain;charset=UTF-8' is not supported"} =
             JSON.decode!(body)
  end

  defp request(method, url, body \\ nil, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, ~c"application/json")
    headers = Keyword.get(opts, :headers, [])

    request =
      if body,
        do: {String.to_charlist(url), headers, content_type, body},
        else: {String.to_charlist(url), headers}

    {:ok, {{_version, status, _reason}, headers, body}} =
      :httpc.request(method, request, [autoredirect: false], body_format: :binary)

    content_type =
      Enum.find_value(headers, fn {name, value} ->
        if name == ~c"content-type", do: List.to_string(value)
      end)

    {status, content_type, body}
  end
end
