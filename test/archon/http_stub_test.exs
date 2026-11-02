# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.HttpStubTest do
  @moduledoc "The fixed answers of the HTTP task fixtures' target (ADR 0026, decision 8)."

  use ExUnit.Case, async: true

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    :ok
  end

  setup do
    %{url: Archon.HttpStub.url(start_supervised!(Archon.HttpStub))}
  end

  defp get(url, headers \\ []) do
    {:ok, {{_version, status, _phrase}, response_headers, body}} =
      :httpc.request(:get, {String.to_charlist(url), headers}, [], body_format: :binary)

    {status, Map.new(response_headers, fn {k, v} -> {to_string(k), to_string(v)} end), body}
  end

  test "answers by path alone", %{url: url} do
    assert {200, %{"content-type" => "application/json"}, json} = get("#{url}/json")
    assert JSON.decode!(json) == %{"ok" => true, "n" => 1, "list" => [1, 2]}
    assert {200, %{"content-type" => "text/plain"}, "archon plain text"} = get("#{url}/text")
    assert {200, _headers, "42"} = get("#{url}/number")
    assert {299, _headers, ""} = get("#{url}/status/299")
    assert {503, _headers, "archon short body"} = get("#{url}/short/503")
    assert {400, _headers, long} = get("#{url}/long/400")
    assert byte_size(long) == 1010
    assert {404, _headers, ""} = get("#{url}/other")
  end

  test "puts nothing of the request in its answer", %{url: url} do
    {status, headers, body} = get("#{url}/json")

    assert {^status, other_headers, ^body} =
             get("#{url}/json", [{~c"user-agent", ~c"archon-test"}, {~c"accept", ~c"text/plain"}])

    assert Map.delete(other_headers, "date") == Map.delete(headers, "date")
  end
end
