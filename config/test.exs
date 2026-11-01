# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

import Config

# Tests drive the runtime's clock, timer and failure points through Archon.RuntimeHooks
# (test/support); without hooks installed they behave as the defaults (ADR 0018, decision 10).
config :archon, Archon.Runtime,
  clock: {Archon.RuntimeHooks, :now, []},
  new_id: {Archon.RuntimeHooks, :new_id, []},
  timer: {Archon.RuntimeHooks, :send_after, []},
  hook: {Archon.RuntimeHooks, :hook, []},
  idle_timeout: 200

# ARCHON_BACKEND=postgres runs the runtime tests on the Postgres backend (ADR 0021, decision 9).
case System.get_env("ARCHON_BACKEND") do
  backend when backend in [nil, "", "memory"] ->
    :ok

  "postgres" ->
    config :archon, Archon.Runtime,
      store: Archon.Runtime.Store.Postgres,
      queue: Archon.Runtime.Queue.Postgres,
      metadata: Archon.Runtime.Metadata.Postgres

  other ->
    raise "ARCHON_BACKEND must be memory or postgres, got: #{inspect(other)}"
end

# test/test_helper.exs starts the runtime after setting up the database.
config :archon, start_runtime: false

# Postgres tests share one database without the Ecto sandbox (ADR 0021, decision 9).
config :archon, Archon.Repo, pool_size: 10, log: false

# Tests call the endpoint through Phoenix.ConnTest without a listening socket (ADR 0023,
# decision 1); test/test_helper.exs starts it after the runtime.
config :archon, ArchonWeb.Endpoint, server: false

# No request log lines in the test output.
config :phoenix, :logger, false
