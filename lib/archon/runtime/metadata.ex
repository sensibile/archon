# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/dao/MetadataDAO.java and
# sqlite-persistence/src/main/java/com/netflix/conductor/sqlite/dao/metadata/SqliteMetadataDAO.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: reduced to the operations the MVP runtime and metadata REST use (ADR 0018,
# decision 3; ADR 0023, decision 2; ADR 0025, decision 6); results are tagged tuples instead of
# exceptions and `Optional`.

defmodule Archon.Runtime.Metadata do
  @moduledoc """
  Metadata behaviour: the MVP part of upstream `MetadataDAO` (ADR 0018, decision 3).

  Callbacks:

    * `c:create_task_def/1`, `c:update_task_def/1` - insert or replace the task definition with
      that name (upstream both do `insertOrUpdateTaskDef`).
    * `c:get_task_def/1` - by name.
    * `c:get_all_task_defs/0` - every task definition, ordered by name (byte order). Upstream's
      `getAllTaskDefs` has no defined order (SQLite answers in insertion order).
    * `c:create_workflow_def/1` - adds a workflow definition; `{:error, :conflict}` if that name and
      version exist (upstream `Workflow with <name>.<version> already exists!`).
    * `c:update_workflow_def/1` - inserts or replaces that name and version.
    * `c:get_workflow_def/2` - by name and version.
    * `c:get_latest_workflow_def/1` - the highest version of a name.
    * `c:get_all_workflow_defs/0` - every workflow definition, ordered by name (byte order) and
      version (upstream SQLite `ORDER BY name, version`).
    * `c:remove_workflow_def/2`, `c:remove_task_def/1` - delete one definition;
      `{:error, :not_found}` when it is not stored (upstream's `NotFoundException`).

  The store keeps definitions as given; upstream's `MetadataServiceImpl` sets audit times and
  validates before calling the DAO, and so does the caller here.
  """

  alias Archon.Domain.{TaskDef, WorkflowDef}

  @callback create_task_def(TaskDef.t()) :: :ok
  @callback update_task_def(TaskDef.t()) :: :ok
  @callback get_task_def(name :: String.t()) :: {:ok, TaskDef.t()} | {:error, :not_found}
  @callback get_all_task_defs() :: [TaskDef.t()]
  @callback create_workflow_def(WorkflowDef.t()) :: :ok | {:error, :conflict}
  @callback update_workflow_def(WorkflowDef.t()) :: :ok
  @callback get_workflow_def(name :: String.t(), version :: integer()) ::
              {:ok, WorkflowDef.t()} | {:error, :not_found}
  @callback get_latest_workflow_def(name :: String.t()) ::
              {:ok, WorkflowDef.t()} | {:error, :not_found}
  @callback get_all_workflow_defs() :: [WorkflowDef.t()]
  @callback remove_workflow_def(name :: String.t(), version :: integer()) ::
              :ok | {:error, :not_found}
  @callback remove_task_def(name :: String.t()) :: :ok | {:error, :not_found}
end
