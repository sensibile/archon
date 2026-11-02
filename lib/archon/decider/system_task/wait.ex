# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/Wait.java
# (start, execute) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the updated task instead of mutating it and takes the clock
# from the context (ADR 0026, decision 2).

defmodule Archon.Decider.SystemTask.Wait do
  @moduledoc """
  Upstream `Wait`: `start` makes the task `IN_PROGRESS`; `execute` completes it once `now` is
  past its `wait_timeout` (a zero `wait_timeout` waits forever).
  """

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.{Context, SystemTask}
  alias Archon.Domain.Task

  @impl true
  def start(_workflow, %Task{} = task, _context),
    do: SystemTask.changed(%{task | status: :in_progress})

  @impl true
  def execute(_workflow, %Task{wait_timeout: timeout} = task, %Context{now: now}) do
    if timeout != 0 and now > timeout,
      do: SystemTask.changed(%{task | status: :completed}),
      else: SystemTask.unchanged(task)
  end
end
