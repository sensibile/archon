# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.HttpStub do
  @moduledoc """
  The fixed-response HTTP target of the `HTTP` task fixtures (ADR 0026, decision 8).

  The capture script starts it for the upstream server to call
  (`scripts/contract/capture_fixtures.sh`), and the replay starts it for Archon, so both see the
  same answers. Its address differs between the two; the replay puts its own in place of the
  captured one (`ArchonWeb.ContractCase`).

  Every answer is fixed by the path alone. Nothing of the request (headers such as `User-Agent`
  or `Accept`, which differ between HTTP clients, or the body) is put in an answer.

    * `/json` - 200, a JSON object.
    * `/text` - 200, `text/plain` text that is not JSON.
    * `/number` - 200, a JSON number.
    * `/status/<code>` - that status with an empty body (`299`, `404`, ...).
    * `/short/<code>` - that status with a short `text/plain` body.
    * `/long/<code>` - that status with a 1,010-byte `text/plain` body.

  Any other path answers 404 with an empty body.
  """

  @behaviour Plug

  import Plug.Conn

  @long String.duplicate("archon-long-body-", 59) <> "0123456"

  @doc "Starts the stub on `127.0.0.1:port` (`0` picks a free port); returns its base URL."
  @spec start(non_neg_integer()) :: {:ok, pid(), String.t()}
  def start(port \\ 0) do
    {:ok, pid} =
      Bandit.start_link(plug: __MODULE__, ip: {127, 0, 0, 1}, port: port, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {:ok, pid, "http://127.0.0.1:#{port}"}
  end

  @doc "A child spec for an ExUnit `start_supervised`."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start:
        {Bandit, :start_link,
         [
           [
             plug: __MODULE__,
             ip: {127, 0, 0, 1},
             port: Keyword.get(opts, :port, 0),
             startup_log: false
           ]
         ]}
    }
  end

  @doc "The base URL of a stub started under a supervisor."
  @spec url(pid()) :: String.t()
  def url(pid) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # The body is read and dropped, so a client that sends one gets its answer.
    conn = drain(conn)

    case conn.path_info do
      ["json"] -> answer(conn, 200, "application/json", ~s({"ok":true,"n":1,"list":[1,2]}))
      ["text"] -> answer(conn, 200, "text/plain", "archon plain text")
      ["number"] -> answer(conn, 200, "application/json", "42")
      ["status", code] -> answer(conn, status(code), nil, "")
      ["short", code] -> answer(conn, status(code), "text/plain", "archon short body")
      ["long", code] -> answer(conn, status(code), "text/plain", @long)
      _other -> answer(conn, 404, nil, "")
    end
  end

  defp drain(conn) do
    case read_body(conn) do
      {:ok, _body, conn} -> conn
      {:more, _body, conn} -> drain(conn)
      {:error, _reason} -> conn
    end
  end

  defp status(code), do: String.to_integer(code)

  defp answer(conn, status, nil, body), do: send_resp(conn, status, body)

  defp answer(conn, status, content_type, body) do
    conn
    |> put_resp_header("content-type", content_type)
    |> send_resp(status, body)
  end
end
