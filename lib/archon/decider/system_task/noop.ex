# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/Noop.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the updated task instead of mutating it (ADR 0026, decision 2).

defmodule Archon.Decider.SystemTask.Noop do
  @moduledoc "Upstream `Noop#execute`: completes the task (ADR 0026, decision 3)."

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.SystemTask
  alias Archon.Domain.Task

  @impl true
  def execute(_workflow, %Task{} = task, _context),
    do: SystemTask.changed(%{task | status: :completed})
end
