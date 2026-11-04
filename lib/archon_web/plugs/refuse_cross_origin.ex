# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.Plugs.RefuseCrossOrigin do
  @moduledoc """
  Refuses with a 403 `{:forbidden, "Cross-origin request refused"}` a request a browser marks as
  cross-origin (ADR 0025, decision 3; ADR 0027, decision 6), a deliberate difference from
  upstream.

  It guards the actions whose request a browser can send from another site without a CORS
  preflight, because the JSON `Content-Type` check of `ArchonWeb.Request` (ADR 0023, decision 3)
  does not run for them: actions that read no body (a form, `fetch` in `no-cors` mode with no
  body, `<a ping>`), and `POST /api/tasks/{taskId}/log`, which takes its body as text whatever its
  `Content-Type` (a `text/plain` form or `fetch`).

  Cross-origin is `Sec-Fetch-Site` other than `same-origin` or `none`, or, without it, an `Origin`
  whose host and port are not the request's (`conn.host`, `conn.port`, from its `Host`). Clients
  that are not browsers send neither header and are answered as upstream.
  """

  @behaviour Plug

  import Plug.Conn

  alias ArchonWeb.Errors

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if cross_origin?(conn) do
      conn
      |> Errors.send_error({:forbidden, "Cross-origin request refused"})
      |> halt()
    else
      conn
    end
  end

  defp cross_origin?(conn) do
    case get_req_header(conn, "sec-fetch-site") do
      [site | _rest] ->
        String.downcase(String.trim(site)) not in ["same-origin", "none"]

      [] ->
        case get_req_header(conn, "origin") do
          [origin | _rest] -> authority(origin) != host(conn)
          [] -> false
        end
    end
  end

  # "scheme://host[:port]" as "host:port", the default port of the scheme filled in.
  defp authority(origin) do
    case URI.parse(String.trim(origin)) do
      %URI{host: host, port: port} when is_binary(host) and host != "" ->
        "#{String.downcase(host)}:#{port}"

      _opaque ->
        nil
    end
  end

  # The adapter takes the request's host and port from its Host header (or HTTP/2 authority),
  # keeping an IPv6 literal's brackets, which URI.parse/1 drops.
  defp host(conn) do
    host = conn.host |> String.trim_leading("[") |> String.trim_trailing("]")
    "#{String.downcase(host)}:#{conn.port}"
  end
end
