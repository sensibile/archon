# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/Human.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the updated task instead of mutating it (ADR 0026, decision 2).

defmodule Archon.Decider.SystemTask.Human do
  @moduledoc """
  Upstream `Human`: `start` makes the task `IN_PROGRESS` (a `HUMAN` task a `DYNAMIC` task
  schedules arrives `SCHEDULED`), and `execute` is upstream's default, which changes nothing.
  The task ends by a task update (`POST /api/tasks` and the other update routes). Upstream's
  `cancel` (`CANCELED`) is what `Archon.Runtime.Step.Terminate.cancel_non_terminal/2` does to
  every task. Upstream's `humanTaskPreventsDeciderQueue` has no counterpart: the workflow
  process decides only on events (ADR 0026, decision 3).
  """

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.SystemTask
  alias Archon.Domain.Task

  @impl true
  def start(_workflow, %Task{} = task, _context),
    do: SystemTask.changed(%{task | status: :in_progress})

  @impl true
  def execute(_workflow, %Task{} = task, _context), do: SystemTask.unchanged(task)
end
