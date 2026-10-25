# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/tasks/Task.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; derived getters
# became functions; the protobuf `inputMessage`/`outputMessage` fields are not modelled.

defmodule Archon.Domain.Task do
  @moduledoc """
  Execution state of one task instance, as returned by `GET /api/tasks/poll/...` and inside
  `Workflow.tasks`.

  Upstream getters add derived keys on the wire, reproduced by `to_json/1`:

    * `taskDefinition` - `workflowTask.taskDefinition` (an `Optional`, written as `null` when
      absent)
    * `queueWaitTime` - see `queue_wait_time/2`
    * `loopOverTask` - `iteration > 0`

  `taskDefName` falls back to `taskType` and `subWorkflowId` to the `subWorkflowId` key of
  `outputData`/`inputData`, as upstream's getters do. `executionMetadata` is always written (the
  getter creates an empty one) and `runtimeMetadata` only when non-empty (`NON_EMPTY`).

  The protobuf `inputMessage`/`outputMessage` fields (`@Hidden` upstream) are not modelled.
  """

  alias Archon.Domain.{Codec, ExecutionMetadata, TaskDef, WorkflowTask}

  @type status ::
          :in_progress
          | :canceled
          | :failed
          | :failed_with_terminal_error
          | :completed
          | :completed_with_errors
          | :scheduled
          | :timed_out
          | :skipped

  @statuses [
    :in_progress,
    :canceled,
    :failed,
    :failed_with_terminal_error,
    :completed,
    :completed_with_errors,
    :scheduled,
    :timed_out,
    :skipped
  ]

  @reason_limit 500

  @fields [
    {:task_type, "taskType", :string, []},
    {:status, "status", {:enum, @statuses}, []},
    {:input_data, "inputData", :object, default: %{}, null: :default},
    {:reference_task_name, "referenceTaskName", :string, []},
    {:retry_count, "retryCount", :int, []},
    {:seq, "seq", :int, []},
    {:correlation_id, "correlationId", :string, []},
    {:poll_count, "pollCount", :int, []},
    {:task_def_name, "taskDefName", :string, []},
    {:scheduled_time, "scheduledTime", :int, []},
    {:start_time, "startTime", :int, []},
    {:end_time, "endTime", :int, []},
    {:update_time, "updateTime", :int, []},
    {:start_delay_in_seconds, "startDelayInSeconds", :int, []},
    {:retried_task_id, "retriedTaskId", :string, []},
    {:retried, "retried", :bool, []},
    {:executed, "executed", :bool, []},
    {:callback_from_worker, "callbackFromWorker", :bool, default: true},
    {:response_timeout_seconds, "responseTimeoutSeconds", :int, []},
    {:workflow_instance_id, "workflowInstanceId", :string, []},
    {:workflow_type, "workflowType", :string, []},
    {:task_id, "taskId", :string, []},
    {:reason_for_incompletion, "reasonForIncompletion", :string, []},
    {:callback_after_seconds, "callbackAfterSeconds", :int, []},
    {:worker_id, "workerId", :string, []},
    {:output_data, "outputData", :object, default: %{}, null: :default},
    {:workflow_task, "workflowTask", {:struct, WorkflowTask}, []},
    {:domain, "domain", :string, []},
    {:rate_limit_per_frequency, "rateLimitPerFrequency", :int, []},
    {:rate_limit_frequency_in_seconds, "rateLimitFrequencyInSeconds", :int, []},
    {:external_input_payload_storage_path, "externalInputPayloadStoragePath", :string, []},
    {:external_output_payload_storage_path, "externalOutputPayloadStoragePath", :string, []},
    {:workflow_priority, "workflowPriority", :int, []},
    {:execution_name_space, "executionNameSpace", :string, []},
    {:isolation_group_id, "isolationGroupId", :string, []},
    {:iteration, "iteration", :int, []},
    {:sub_workflow_id, "subWorkflowId", :string, []},
    {:subworkflow_changed, "subworkflowChanged", :bool, []},
    {:first_start_time, "firstStartTime", :int, []},
    {:execution_metadata, "executionMetadata", {:struct, ExecutionMetadata}, []},
    {:parent_task_id, "parentTaskId", :string, []},
    {:parent_task_reference_name, "parentTaskReferenceName", :string, []},
    {:runtime_metadata, "runtimeMetadata", :string_map, default: %{}, null: :default}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          task_type: String.t() | nil,
          status: status() | nil,
          input_data: Codec.json_object(),
          reference_task_name: String.t() | nil,
          retry_count: integer(),
          seq: integer(),
          correlation_id: String.t() | nil,
          poll_count: integer(),
          task_def_name: String.t() | nil,
          scheduled_time: integer(),
          start_time: integer(),
          end_time: integer(),
          update_time: integer(),
          start_delay_in_seconds: integer(),
          retried_task_id: String.t() | nil,
          retried: boolean(),
          executed: boolean(),
          callback_from_worker: boolean(),
          response_timeout_seconds: integer(),
          workflow_instance_id: String.t() | nil,
          workflow_type: String.t() | nil,
          task_id: String.t() | nil,
          reason_for_incompletion: String.t() | nil,
          callback_after_seconds: integer(),
          worker_id: String.t() | nil,
          output_data: Codec.json_object(),
          workflow_task: WorkflowTask.t() | nil,
          domain: String.t() | nil,
          rate_limit_per_frequency: integer(),
          rate_limit_frequency_in_seconds: integer(),
          external_input_payload_storage_path: String.t() | nil,
          external_output_payload_storage_path: String.t() | nil,
          workflow_priority: integer(),
          execution_name_space: String.t() | nil,
          isolation_group_id: String.t() | nil,
          iteration: integer(),
          sub_workflow_id: String.t() | nil,
          subworkflow_changed: boolean(),
          first_start_time: integer(),
          execution_metadata: ExecutionMetadata.t() | nil,
          parent_task_id: String.t() | nil,
          parent_task_reference_name: String.t() | nil,
          runtime_metadata: %{optional(String.t()) => String.t() | nil}
        }

  @doc "All task statuses, in upstream declaration order."
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  @doc "Upstream `Task.Status#isTerminal`."
  @spec terminal?(status()) :: boolean()
  def terminal?(status) when status in [:in_progress, :scheduled], do: false
  def terminal?(status) when status in @statuses, do: true

  @doc "Upstream `Task.Status#isSuccessful`."
  @spec successful?(status()) :: boolean()
  def successful?(status)
      when status in [:in_progress, :completed, :completed_with_errors, :scheduled, :skipped],
      do: true

  def successful?(status) when status in @statuses, do: false

  @doc "Upstream `Task.Status#isRetriable`."
  @spec retriable?(status()) :: boolean()
  def retriable?(status) when status in [:canceled, :failed_with_terminal_error, :skipped],
    do: false

  def retriable?(status) when status in @statuses, do: true

  @doc """
  Decodes upstream JSON. Derived keys (`taskDefinition`, `queueWaitTime`, `loopOverTask`) are
  ignored, and `reasonForIncompletion` is cut to 500 characters as upstream's setter does.
  """
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []) do
    with {:ok, task} <- Codec.decode(__MODULE__, @fields, json, path) do
      {:ok, %{task | reason_for_incompletion: truncate_reason(task.reason_for_incompletion)}}
    end
  end

  @doc """
  Encodes to upstream JSON with the derived getter keys. `now_ms` is the clock used for
  `queueWaitTime` (see `queue_wait_time/2`).
  """
  @spec to_json(t(), integer()) :: Codec.json_object()
  def to_json(%__MODULE__{} = task, now_ms \\ System.system_time(:millisecond)) do
    resolved = %{
      task
      | task_def_name: task_def_name(task),
        sub_workflow_id: sub_workflow_id(task),
        execution_metadata: task.execution_metadata || %ExecutionMetadata{},
        runtime_metadata: non_empty(task.runtime_metadata)
    }

    __MODULE__
    |> Codec.encode(@fields, resolved)
    |> Map.merge(%{
      "taskDefinition" => Codec.encode_value({:struct, TaskDef}, task_definition(task)),
      "queueWaitTime" => queue_wait_time(task, now_ms),
      "loopOverTask" => loop_over_task?(task)
    })
  end

  @doc "Upstream `getTaskDefName`: the stored name, or `taskType` when it is empty."
  @spec task_def_name(t()) :: String.t() | nil
  def task_def_name(%__MODULE__{task_def_name: name, task_type: type}) when name in [nil, ""],
    do: type

  def task_def_name(%__MODULE__{task_def_name: name}), do: name

  @doc """
  Upstream `getSubWorkflowId`: the stored id unless blank, else `outputData["subWorkflowId"]`,
  else `inputData["subWorkflowId"]`.
  """
  @spec sub_workflow_id(t()) :: String.t() | nil
  def sub_workflow_id(%__MODULE__{} = task) do
    if blank?(task.sub_workflow_id) do
      case task.output_data do
        %{"subWorkflowId" => id} when not is_nil(id) -> id
        _other -> Map.get(task.input_data || %{}, "subWorkflowId")
      end
    else
      task.sub_workflow_id
    end
  end

  @doc "Upstream `getTaskDefinition`: the task definition embedded in `workflowTask`."
  @spec task_definition(t()) :: TaskDef.t() | nil
  def task_definition(%__MODULE__{workflow_task: %WorkflowTask{task_definition: definition}}),
    do: definition

  def task_definition(%__MODULE__{}), do: nil

  @doc """
  Upstream `getQueueWaitTime`. Once started, the wait is `startTime - scheduledTime`; for a task
  that asked to be called back, it is the time since the callback became due (`now_ms` minus
  `updateTime + callbackAfterSeconds`), floored at 0. Before the task starts it is 0.
  """
  @spec queue_wait_time(t(), integer()) :: integer()
  def queue_wait_time(
        %__MODULE__{
          start_time: start,
          scheduled_time: scheduled,
          update_time: updated,
          callback_after_seconds: callback
        },
        now_ms
      )
      when is_integer(start) and is_integer(scheduled) and is_integer(updated) and
             is_integer(callback) and is_integer(now_ms) and start > 0 and scheduled > 0 do
    if updated > 0 and callback > 0 do
      max(now_ms - (updated + callback * 1000), 0)
    else
      start - scheduled
    end
  end

  def queue_wait_time(%__MODULE__{}, _now_ms), do: 0

  @doc "Upstream `isLoopOverTask`: the task runs inside a `DO_WHILE` iteration."
  @spec loop_over_task?(t()) :: boolean()
  def loop_over_task?(%__MODULE__{iteration: iteration}), do: iteration > 0

  @doc false
  @spec truncate_reason(String.t() | nil) :: String.t() | nil
  def truncate_reason(nil), do: nil
  def truncate_reason(reason), do: String.slice(reason, 0, @reason_limit)

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""

  defp non_empty(map) when map_size(map) == 0, do: nil
  defp non_empty(map), do: map
end
