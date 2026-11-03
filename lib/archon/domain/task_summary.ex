# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/run/TaskSummary.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct built from Archon.Domain.Task, with an
# encoder that writes upstream's JSON key order (ADR 0027).

defmodule Archon.Domain.TaskSummary do
  @moduledoc """
  The search index's view of a task (`GET /api/tasks/search`, the `json_data` of `task_index`;
  ADR 0027, decision 3).

  `new/2` is upstream's `new TaskSummary(task)` on the REST `Task` that `TaskModel#toTask` gives:
  `taskDefName` falls back to `taskType`, `reasonForIncompletion` is cut to 500 characters and
  `outputData` gets the task's own `subWorkflowId` back (`Archon.Domain.Task`). The four times are
  written even when 0 (the epoch). `queueWaitTime` is upstream's `Task#getQueueWaitTime` at
  `now_ms`, the clock of the step that indexes the task (ADR 0027, decision 2).

  `encode/1` writes the JSON both the index and the search response use, in upstream's Jackson
  order (declared fields) without `null` fields (`NON_NULL`). `input`/`output` are `Map#toString`
  with sorted keys; upstream keeps the input order (ADR 0027).
  """

  alias Archon.Domain.{Codec, SummaryUtil, Task}

  defstruct workflow_id: nil,
            workflow_type: nil,
            correlation_id: nil,
            scheduled_time: nil,
            start_time: nil,
            update_time: nil,
            end_time: nil,
            status: nil,
            reason_for_incompletion: nil,
            execution_time: 0,
            queue_wait_time: 0,
            task_def_name: nil,
            task_type: nil,
            input: nil,
            output: nil,
            task_id: nil,
            external_input_payload_storage_path: nil,
            external_output_payload_storage_path: nil,
            workflow_priority: 0,
            domain: nil

  @type t :: %__MODULE__{
          workflow_id: String.t() | nil,
          workflow_type: String.t() | nil,
          correlation_id: String.t() | nil,
          scheduled_time: String.t() | nil,
          start_time: String.t() | nil,
          update_time: String.t() | nil,
          end_time: String.t() | nil,
          status: Task.status() | nil,
          reason_for_incompletion: String.t() | nil,
          execution_time: integer(),
          queue_wait_time: integer(),
          task_def_name: String.t() | nil,
          task_type: String.t() | nil,
          input: String.t() | nil,
          output: String.t() | nil,
          task_id: String.t() | nil,
          external_input_payload_storage_path: String.t() | nil,
          external_output_payload_storage_path: String.t() | nil,
          workflow_priority: integer(),
          domain: String.t() | nil
        }

  @doc "Upstream `new TaskSummary(task)`, with `now_ms` as the clock of `queueWaitTime`."
  @spec new(Task.t(), integer()) :: t()
  def new(%Task{} = task, now_ms) when is_integer(now_ms) do
    task = Task.with_own_sub_workflow_id(task)

    %__MODULE__{
      task_id: task.task_id,
      task_def_name: Task.task_def_name(task),
      task_type: task.task_type,
      workflow_id: task.workflow_instance_id,
      workflow_type: task.workflow_type,
      workflow_priority: task.workflow_priority,
      correlation_id: task.correlation_id,
      scheduled_time: SummaryUtil.format_time(task.scheduled_time),
      start_time: SummaryUtil.format_time(task.start_time),
      update_time: SummaryUtil.format_time(task.update_time),
      end_time: SummaryUtil.format_time(task.end_time),
      status: task.status,
      reason_for_incompletion: Task.truncate_reason(task.reason_for_incompletion),
      queue_wait_time: Task.queue_wait_time(task, now_ms),
      domain: task.domain,
      input: io(task.input_data),
      output: io(task.output_data),
      execution_time: if(task.end_time > 0, do: task.end_time - task.start_time, else: 0),
      external_input_payload_storage_path: present(task.external_input_payload_storage_path),
      external_output_payload_storage_path: present(task.external_output_payload_storage_path)
    }
  end

  @doc """
  The summary's JSON text, shared by the index's `json_data` and the search response. Keys are
  in upstream's order and `nil` fields are left out.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = s) do
    [
      {"workflowId", s.workflow_id},
      {"workflowType", s.workflow_type},
      {"correlationId", s.correlation_id},
      {"scheduledTime", s.scheduled_time},
      {"startTime", s.start_time},
      {"updateTime", s.update_time},
      {"endTime", s.end_time},
      {"status", s.status && Codec.enum_name(s.status)},
      {"reasonForIncompletion", s.reason_for_incompletion},
      {"executionTime", s.execution_time},
      {"queueWaitTime", s.queue_wait_time},
      {"taskDefName", s.task_def_name},
      {"taskType", s.task_type},
      {"input", s.input},
      {"output", s.output},
      {"taskId", s.task_id},
      {"externalInputPayloadStoragePath", s.external_input_payload_storage_path},
      {"externalOutputPayloadStoragePath", s.external_output_payload_storage_path},
      {"workflowPriority", s.workflow_priority},
      {"domain", s.domain}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  defp io(nil), do: nil
  defp io(map), do: SummaryUtil.serialize_input_output(map)

  # StringUtils.isNotBlank
  defp present(nil), do: nil
  defp present(path), do: if(SummaryUtil.blank?(path), do: nil, else: path)
end
