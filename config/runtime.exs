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
