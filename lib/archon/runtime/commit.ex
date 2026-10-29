# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Commit do
  @moduledoc """
  One atomic change to a workflow and its tasks in `Archon.Runtime.Store` (ADR 0018, decision 2).

    * `create` - a new workflow with its tasks, or `nil`. The store refuses it with
      `{:error, :conflict}` when the ID already exists.
    * `workflow` - the changed workflow, or `nil`. Its `tasks` field is ignored.
    * `upsert_tasks` - tasks to insert or replace.
    * `delete_task_ids` - tasks to delete (DO_WHILE `keepLastN`).

  The store applies the fields in that order and never stamps times: `Archon.Runtime.Step` sets
  the `updateTime`/`endTime` values upstream's `ExecutionDAOFacade` stamps when it saves.
  """

  alias Archon.Domain.{Task, Workflow}

  defstruct create: nil, workflow: nil, upsert_tasks: [], delete_task_ids: []

  @type t :: %__MODULE__{
          create: Workflow.t() | nil,
          workflow: Workflow.t() | nil,
          upsert_tasks: [Task.t()],
          delete_task_ids: [String.t()]
        }
end
