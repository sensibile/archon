# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/DeciderService.java
# (DeciderOutcome) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the outcome also carries the updated workflow, since the Decider no
# longer changes its input in place.

defmodule Archon.Decider.Outcome do
  @moduledoc """
  Result of one `Archon.Decider.decide/2` call (upstream `DeciderOutcome`).

    * `tasks_to_be_scheduled` - new tasks to persist and queue, in upstream order.
    * `tasks_to_be_updated` - existing tasks whose state the Decider changed.
    * `complete?` - the workflow has nothing left to run.
    * `terminate_task` - the last successful `TERMINATE` task, if any.
    * `workflow` - the workflow with every change upstream made in place: task `executed`,
      `retried`, timeout and `COMPLETED_WITH_ERRORS` markings, `output` when complete or
      terminated by a failed task, and the definition's workflow tasks a mapper changed.
    * `changed_workflow_tasks` - the definition's workflow tasks a mapper changed in place
      (`Archon.Decider.Mapper.changes_definition?/1`), already written into
      `workflow.workflow_definition`. The runtime saves the workflow when there are any
      (ADR 0026, decision 4).
  """

  alias Archon.Domain.{Task, Workflow, WorkflowTask}

  @enforce_keys [:workflow]
  defstruct [
    :workflow,
    :terminate_task,
    tasks_to_be_scheduled: [],
    tasks_to_be_updated: [],
    changed_workflow_tasks: [],
    complete?: false
  ]

  @type t :: %__MODULE__{
          workflow: Workflow.t(),
          tasks_to_be_scheduled: [Task.t()],
          tasks_to_be_updated: [Task.t()],
          complete?: boolean(),
          terminate_task: Task.t() | nil,
          changed_workflow_tasks: [WorkflowTask.t()]
        }

  @doc "An outcome with nothing to do."
  @spec new(Workflow.t()) :: t()
  def new(%Workflow{} = workflow), do: %__MODULE__{workflow: workflow}
end
