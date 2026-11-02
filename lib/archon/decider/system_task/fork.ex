# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/Fork.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: a behaviour module (ADR 0026, decision 2).

defmodule Archon.Decider.SystemTask.Fork do
  @moduledoc "Upstream `Fork`: keeps the default `execute`, which changes nothing."

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.SystemTask

  @impl true
  def execute(_workflow, task, _context), do: SystemTask.unchanged(task)
end
