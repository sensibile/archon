# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/Switch.java
# and core/.../execution/tasks/Decision.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the completed task instead of mutating it (ADR 0026, decision 2).

defmodule Archon.Decider.SystemTask.Decision do
  @moduledoc "Upstream `Switch#execute` and `Decision#execute`: the task completes."

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.SystemTask

  @impl true
  def execute(_workflow, task, _context), do: SystemTask.changed(%{task | status: :completed})
end
