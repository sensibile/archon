# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.Response do
  @moduledoc """
  The response shapes of the upstream fixtures (ADR 0023, decision 3). `Content-Type` is written
  exactly as upstream sends it, without the charset Phoenix's own helpers add.
  """

  import Plug.Conn

  @doc "A JSON body: `Content-Type: application/json`."
  @spec json(Plug.Conn.t(), Plug.Conn.status(), term()) :: Plug.Conn.t()
  def json(conn, status \\ 200, data) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, JSON.encode_to_iodata!(data))
  end

  @doc "A string body (a workflow or task ID): `Content-Type: text/plain;charset=UTF-8`."
  @spec text(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def text(conn, text) do
    conn
    |> put_resp_header("content-type", "text/plain;charset=UTF-8")
    |> send_resp(200, text)
  end

  @doc "200 without a body or `Content-Type` (a `void` handler)."
  @spec empty(Plug.Conn.t()) :: Plug.Conn.t()
  def empty(conn), do: send_resp(conn, 200, "")

  @doc "204 without a body or `Content-Type` (nothing to poll, no next task)."
  @spec no_content(Plug.Conn.t()) :: Plug.Conn.t()
  def no_content(conn), do: send_resp(conn, 204, "")
end
