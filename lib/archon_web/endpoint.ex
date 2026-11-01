# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.Endpoint do
  @moduledoc """
  The HTTP endpoint (ADR 0023, decision 1), served by Bandit on `127.0.0.1:8080` unless
  `ARCHON_HTTP_IP` and `PORT` say otherwise (`config/runtime.exs`, ADR 0024 decision 4).

  There is no `Plug.Parsers`: controllers read the body themselves (`ArchonWeb.Request`), and no
  session, static files or sockets. `HEAD` is answered as `GET` without the body, as Spring does;
  `OPTIONS` is not (upstream answers it with an `Allow` header, Archon with the 404).
  """

  use Phoenix.Endpoint, otp_app: :archon

  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  # Spring answers HEAD on every GET mapping, without the body.
  plug Plug.Head
  plug :trailing_slash
  plug ArchonWeb.Router

  # Spring 6 does not match a path with a trailing slash to its handler (`POST /api/workflow/`
  # is a 404 upstream); the Phoenix router would.
  defp trailing_slash(%Plug.Conn{request_path: path} = conn, _opts) do
    if path != "/" and String.ends_with?(path, "/"),
      do: conn |> ArchonWeb.Errors.send_no_route() |> halt(),
      else: conn
  end
end
