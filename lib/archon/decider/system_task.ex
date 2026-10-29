# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/WorkflowSystemTask.java,
# core/.../execution/tasks/Switch.java, core/.../execution/tasks/Decision.java,
# core/.../execution/tasks/Fork.java and core/.../execution/tasks/Wait.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: execute returns the updated task with its boolean instead of mutating
# it, takes the clock instead of reading it, and does not take the WorkflowExecutor
# (ADR 0014, decision 5).

defmodule Archon.Decider.SystemTask do
  @moduledoc """
  The state-deciding part of upstream `WorkflowSystemTask#execute`, as a pure function
  (ADR 0014, decision 5).

  `execute/3` returns upstream's boolean (`true` when the task changed and should be persisted)
  with the updated task. `now` is epoch milliseconds. `SWITCH` and `DECISION` complete; `FORK`
  keeps the default `execute` (nothing changes); `JOIN` is `Archon.Decider.SystemTask.Join`;
  `WAIT` completes once `now` is past its `wait_timeout`. `SUB_WORKFLOW` needs the child
  workflow, which the runtime loads, so it is `Archon.Decider.SystemTask.SubWorkflow.execute/2`.
  `DO_WHILE` evaluates scripts and schedules its next iteration, so it is
  `Archon.Decider.SystemTask.DoWhile.execute/3`, which takes the Decider context.
  When to call it (synchronously in the decide loop or from the system task queue) is the
  runtime's choice (Phase 3).
  """

  alias Archon.Decider.SystemTask.Join
  alias Archon.Domain.{Task, Workflow}

  @doc "Upstream `execute` of the task's system task type."
  @spec execute(Workflow.t(), Task.t(), integer()) :: {boolean(), Task.t()}
  def execute(%Workflow{}, %Task{task_type: type} = task, _now)
      when type in ["SWITCH", "DECISION"],
      do: {true, %{task | status: :completed}}

  def execute(%Workflow{}, %Task{task_type: "FORK"} = task, _now), do: {false, task}

  def execute(%Workflow{} = workflow, %Task{task_type: "JOIN"} = task, _now),
    do: Join.execute(workflow, task)

  # Wait#execute: a zero wait_timeout waits forever.
  def execute(%Workflow{}, %Task{task_type: "WAIT", wait_timeout: timeout} = task, now) do
    if timeout != 0 and now > timeout,
      do: {true, %{task | status: :completed}},
      else: {false, task}
  end
end
