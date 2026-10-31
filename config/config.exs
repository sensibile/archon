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

# `evict_after` (ADR 0021, decision 6) is left to its default by backend: off with the memory
# store, 60 s with the Postgres one.

# The Postgres backend's repository (ADR 0021, decision 1); the connection is in runtime.exs.
config :archon, ecto_repos: [Archon.Repo]

if config_env() == :test, do: import_config("test.exs")
