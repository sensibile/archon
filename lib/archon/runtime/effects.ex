# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (addTaskToQueue, the queue calls of updateTask and terminateWorkflow) at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the effects a step returns are run here after (or before) the
# workflow's commit (ADR 0018, decision 2).

defmodule Archon.Runtime.Effects do
  @moduledoc """
  Runs one `t:Archon.Runtime.Step.Effect.t/0` for `Archon.Runtime.WorkflowServer` (ADR 0018,
  decision 2). The timer effects (`{:wake_at, ms}`, `{:wake_before, ms}`) belong to the process
  and are not run here.

  Returns `:ok`, `{:event, event}` when the result goes back to the step in the same message
  (a `SUB_WORKFLOW` start, a failed failure-workflow start) or `{:error, reason}`. Queue effects
  use the configured `Archon.Runtime.Queue`; the effects between workflows are
  `Archon.Runtime.SubWorkflows`.
  """

  alias Archon.Runtime
  alias Archon.Runtime.Step.{Effect, Event}
  alias Archon.Runtime.SubWorkflows

  @spec run(Effect.t()) :: :ok | {:event, Event.t()} | {:error, term()}
  def run({:queue_push, queue, id, priority, delay_ms}),
    do: Runtime.queue().push(queue, id, priority, delay_ms)

  def run({:queue_remove, queue, id}), do: Runtime.queue().remove(queue, id)

  def run({:queue_postpone, queue, id, priority, delay_ms}),
    do: Runtime.queue().postpone(queue, id, priority, delay_ms)

  def run({:start_sub_workflow, task_id, start}),
    do: {:event, {:sub_workflow_started, task_id, SubWorkflows.start_child(start)}}

  def run({:terminate_sub_workflow, child_id, reason}),
    do: SubWorkflows.terminate_child(child_id, reason)

  def run({:notify_parent, parent_id, parent_task_id, child}),
    do: SubWorkflows.notify_parent(parent_id, parent_task_id, child)

  def run({:start_failure_workflow, start}),
    do: start |> SubWorkflows.start_failure_workflow() |> failure_workflow_started()

  @doc false
  # Public so the type checker does not judge the clauses by the 3c placeholder's result.
  @spec failure_workflow_started(:ok | {:error, String.t()}) :: :ok | {:event, Event.t()}
  def failure_workflow_started({:error, reason}),
    do: {:event, {:failure_workflow_started, {:error, reason}}}

  def failure_workflow_started(:ok), do: :ok
end
