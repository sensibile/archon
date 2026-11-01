# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

import Config

# The workflow runtime (ADR 0018); see Archon.Runtime for every key.
config :archon, Archon.Runtime,
  store: Archon.Runtime.Store.Memory,
  queue: Archon.Runtime.Queue.Memory,
  metadata: Archon.Runtime.Metadata.Memory,
  call_timeout: 30_000,
  idle_timeout: 5_000,
  hibernate_after: 15_000,
  waker_interval: 1_000,
  activation_margin: 5_000,
  activation_page_size: 100

# Deployments run on Postgres (ADR 0021): the database must be migrated (Archon.Release.migrate/0)
# and DATABASE_URL set (runtime.exs) before the application starts.
if config_env() == :prod do
  config :archon, Archon.Runtime,
    store: Archon.Runtime.Store.Postgres,
    queue: Archon.Runtime.Queue.Postgres,
    metadata: Archon.Runtime.Metadata.Postgres
end

# `evict_after` (ADR 0021, decision 6) is left to its default by backend: off with the memory
# store, 60 s with the Postgres one.

# The Postgres backend's repository (ADR 0021, decision 1); the connection is in runtime.exs.
config :archon, ecto_repos: [Archon.Repo]

# The REST endpoint (ADR 0023, decision 1). It listens on 127.0.0.1:8080 unless runtime.exs reads
# ARCHON_HTTP_IP and PORT (ADR 0024, decision 4).
config :archon, ArchonWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 8080],
  server: true,
  render_errors: [formats: [json: ArchonWeb.ErrorJSON], layout: false]

# The domain codecs already use the built-in JSON module (ADR 0002); Phoenix uses it too.
config :phoenix, :json_library, JSON

if config_env() == :test, do: import_config("test.exs")
