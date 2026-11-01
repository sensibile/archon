# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

import Config

# The Postgres backend's connection (ADR 0021, decision 1). Development and tests fall back to a
# local server with the default credentials.
database_url =
  System.get_env("DATABASE_URL") ||
    if config_env() in [:dev, :test],
      do: "ecto://postgres:postgres@localhost/archon_#{config_env()}"

cond do
  database_url -> config(:archon, Archon.Repo, url: database_url)
  config_env() == :prod -> raise "DATABASE_URL is required: the runtime runs on Postgres"
  true -> :ok
end

# The REST endpoint's address (ADR 0024, decision 4): 127.0.0.1:8080 unless set here. Listening on
# another interface is a deployment decision; put the server behind a private network or an
# authenticating proxy, as the MVP REST has no authentication.
http_ip =
  case System.get_env("ARCHON_HTTP_IP") do
    value when value in [nil, ""] ->
      {127, 0, 0, 1}

    value ->
      case :inet.parse_strict_address(String.to_charlist(value)) do
        {:ok, ip} ->
          ip

        {:error, _reason} ->
          raise "ARCHON_HTTP_IP must be an IPv4 or IPv6 address, got: #{inspect(value)}"
      end
  end

http_port =
  case System.get_env("PORT") do
    value when value in [nil, ""] ->
      8080

    value ->
      case Integer.parse(value) do
        {port, ""} when port in 0..65_535 -> port
        _other -> raise "PORT must be a port number (0..65535), got: #{inspect(value)}"
      end
  end

config :archon, ArchonWeb.Endpoint, http: [ip: http_ip, port: http_port]
