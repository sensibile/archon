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
