# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss sqlite-persistence/src/main/java/com/netflix/conductor/sqlite/dao/SqliteIndexDAO.java
# (indexWorkflow and indexTask) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: builds the row a commit carries instead of writing it, with times in
# epoch milliseconds and values an index column cannot hold as nil (ADR 0027, decision 2).

defmodule Archon.Runtime.SearchIndex do
  @moduledoc """
  The rows of the search index tables `workflow_index` and `task_index` (ADR 0027, decision 2).

  `Archon.Runtime.Step` builds them where upstream's `ExecutionDAOFacade` indexes a workflow or
  a task, puts them in the commit (`Archon.Runtime.Commit`) and the store upserts them in the same
  transaction; `Archon.Release.backfill_search_index/0` builds them for rows written before the
  index existed.

  A row has the columns of upstream's `SqliteIndexDAO#indexWorkflow`/`#indexTask` as
  `Archon.Search.Query` names them, and `json_data`, the summary's JSON
  (`Archon.Domain.WorkflowSummary.encode/1`, `Archon.Domain.TaskSummary.encode/1`). Times are
  epoch milliseconds: `start_time` is the workflow's create time or the task's start time, and an
  unfinished `end_time` is 0 (upstream's epoch default). Text a column cannot hold (NUL, invalid
  UTF-8) and a time outside `bigint` are `nil`, as for the workflow query columns of ADR 0025.
  `parent_workflow_id` is `""` without a parent (upstream's default, which `topLevelOnly` relies
  on).
  """

  alias Archon.Domain.{Codec, Task, TaskSummary, Workflow, WorkflowSummary}

  @bigint_range -0x8000000000000000..0x7FFFFFFFFFFFFFFF

  @typedoc "A `workflow_index` row."
  @type workflow_row :: %{
          workflow_id: String.t(),
          correlation_id: String.t() | nil,
          workflow_type: String.t() | nil,
          start_time: integer() | nil,
          end_time: integer() | nil,
          update_time: integer() | nil,
          status: String.t(),
          parent_workflow_id: String.t() | nil,
          classifier: String.t() | nil,
          json_data: String.t()
        }

  @typedoc "A `task_index` row."
  @type task_row :: %{
          task_id: String.t(),
          task_type: String.t() | nil,
          task_def_name: String.t() | nil,
          status: String.t(),
          start_time: integer() | nil,
          end_time: integer() | nil,
          update_time: integer() | nil,
          workflow_type: String.t() | nil,
          json_data: String.t()
        }

  @doc "Upstream `indexWorkflow(new WorkflowSummary(workflow))`."
  @spec workflow_row(Workflow.t()) :: workflow_row()
  def workflow_row(%Workflow{} = workflow) do
    summary = WorkflowSummary.new(workflow)

    %{
      workflow_id: workflow.workflow_id,
      correlation_id: queryable(workflow.correlation_id),
      workflow_type: queryable(summary.workflow_type),
      start_time: time(workflow.create_time),
      end_time: time(workflow.end_time),
      update_time: time(workflow.update_time),
      status: Codec.enum_name(workflow.status),
      parent_workflow_id:
        if(workflow.parent_workflow_id == nil,
          do: "",
          else: queryable(workflow.parent_workflow_id)
        ),
      classifier: queryable(summary.classifier),
      json_data: WorkflowSummary.encode(summary)
    }
  end

  @doc """
  Upstream `indexTask(new TaskSummary(task))` at `now_ms`, the step's clock (`queueWaitTime`).
  """
  @spec task_row(Task.t(), integer()) :: task_row()
  def task_row(%Task{} = task, now_ms) when is_integer(now_ms) do
    summary = TaskSummary.new(task, now_ms)

    %{
      task_id: task.task_id,
      task_type: queryable(summary.task_type),
      task_def_name: queryable(summary.task_def_name),
      status: Codec.enum_name(task.status),
      start_time: time(task.start_time),
      end_time: time(task.end_time),
      update_time: time(task.update_time),
      workflow_type: queryable(summary.workflow_type),
      json_data: TaskSummary.encode(summary)
    }
  end

  @doc "Whether text fits an index column: valid UTF-8 without NUL."
  @spec storable?(String.t()) :: boolean()
  def storable?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  defp queryable(value) when is_binary(value), do: if(storable?(value), do: value)
  defp queryable(_value), do: nil

  defp time(ms) when is_integer(ms) and ms in @bigint_range, do: ms
  defp time(_ms), do: nil
end
