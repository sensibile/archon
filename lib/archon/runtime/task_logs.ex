# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/dal/ExecutionDAOFacade.java
# (addTaskExecLog) and core/.../execution/WorkflowExecutorOps.java (updateTask,
# updateAndPushParents) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the logs of one write are prepared before the store sees them, and
# `null` entries and text a store cannot hold are dealt with instead of failing the write
# (ADR 0027, decision 6).

defmodule Archon.Runtime.TaskLogs do
  @moduledoc """
  The task execution logs of one write (ADR 0027, decision 6), as every write path prepares
  them for the store (`Archon.Runtime.Commit` `task_logs`, `c:Archon.Runtime.Store.add_task_logs/1`).

    * `prepare/4` - upstream `addTaskExecLog` with `updateTask`'s task ID: `null` entries and
      entries without a log are dropped (upstream fails after saving the task), each log takes
      the task ID, a log without `createdTime` takes the time of the write, a `createdTime`
      outside a Java `long` becomes the nearest `long` (Jackson refuses it), and only the first
      `limit` (`task_exec_log_size_limit`, 10) are kept.
    * `revived/4` - the log `updateAndPushParents` writes on a parent's `SUB_WORKFLOW` task.
    * `text/1` - log text as both stores keep it: invalid UTF-8 and the NUL character become
      U+FFFD, as Java's UTF-8 decoding does for the first (PostgreSQL text cannot hold either).
  """

  alias Archon.Domain.TaskExecLog

  @default_limit 10
  @max_long 0x7FFFFFFFFFFFFFFF
  @min_long -0x8000000000000000

  @doc "The configured `task_exec_log_size_limit` (upstream `taskExecLogSizeLimit`, 10)."
  @spec limit(keyword()) :: non_neg_integer()
  def limit(settings),
    do: settings |> Keyword.get(:task_exec_log_size_limit, @default_limit) |> max(0)

  @doc "The logs of one write for `task_id`, ready for the store."
  @spec prepare([TaskExecLog.t() | nil] | nil, String.t(), integer(), non_neg_integer()) ::
          [TaskExecLog.t()]
  def prepare(logs, task_id, now, limit) do
    for(%TaskExecLog{log: log} = entry when is_binary(log) <- logs || [], do: entry)
    |> Enum.take(max(limit, 0))
    |> Enum.map(fn entry ->
      %TaskExecLog{
        task_id: task_id,
        log: text(entry.log),
        created_time: time(entry.created_time || now)
      }
    end)
  end

  @doc """
  The log of a child workflow that runs again, on its parent's `SUB_WORKFLOW` task:
  `"Sub workflow <chain> <operation>."`, `chain` being `name.version/id` of each workflow from the
  one below this parent down to the one the operation ran on, joined by `" -> "`.
  """
  @spec revived(String.t(), String.t(), String.t(), integer()) :: TaskExecLog.t()
  def revived(task_id, chain, operation, now),
    do: %TaskExecLog{
      task_id: task_id,
      log: text("Sub workflow #{chain} #{operation}."),
      created_time: now
    }

  # The nearest Java long.
  defp time(ms), do: ms |> max(@min_long) |> min(@max_long)

  @doc "Log text both stores can keep."
  @spec text(binary()) :: String.t()
  def text(text) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> String.replace(<<0>>, "\uFFFD")
  end
end
