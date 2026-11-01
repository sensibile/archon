# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (addTaskToQueue, the queue calls of updateTask and terminateWorkflow) at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the effects a step returns are run here after (or before) the
# workflow's commit (ADR 0018, decision 2); the queue calls moved into the commit (ADR 0021,
# decision 3) and the work on other workflows into its outbox (ADR 0021, decision 4).

defmodule Archon.Runtime.Effects do
  @moduledoc """
  Runs the `t:Archon.Runtime.Step.Effect.t/0` that `Archon.Runtime.WorkflowServer` runs in the
  workflow's own process (ADR 0018, decision 2): a `SUB_WORKFLOW` start and a child termination
  before the commit. The timer effects belong to the process, the queue effects go into the
  commit (ADR 0021, decision 3), and the other effects on other workflows into its outbox, which
  `Archon.Runtime.Outbox` runs (ADR 0021, decision 4); none of them is run here.

  Returns `:ok`, `{:event, event}` when the result goes back to the step in the same message
  (a `SUB_WORKFLOW` start) or `{:error, reason}`. `owner_id` is the running workflow's ID.
  """

  alias Archon.Runtime.Step.{Effect, Event}
  alias Archon.Runtime.SubWorkflows

  @spec run(Effect.t(), String.t()) :: :ok | {:event, Event.t()} | {:error, term()}
  def run({:start_sub_workflow, task_id, start}, _owner_id),
    do: {:event, {:sub_workflow_started, task_id, SubWorkflows.start_child(start)}}

  def run({:terminate_sub_workflow, child_id, reason}, owner_id),
    do: SubWorkflows.terminate_child(owner_id, child_id, reason)
end
