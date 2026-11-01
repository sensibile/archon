# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/tasks/TaskResult.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; bean validation
# annotations ported to validate/1; the protobuf `outputMessage` field is not modelled.

defmodule Archon.Domain.TaskResult do
  @moduledoc """
  A worker's update for a task (`POST /api/tasks`, `POST /api/tasks/update-v2`).

  `executionMetadata` is written only when it carries data, as upstream's getter returns `null`
  otherwise. The protobuf `outputMessage` field (`@Hidden` upstream) is not modelled.
  """

  alias Archon.Domain.{Codec, ExecutionMetadata, Task, TaskExecLog, Validation}

  @type status :: :in_progress | :failed | :failed_with_terminal_error | :completed | :canceled

  @fields [
    {:workflow_instance_id, "workflowInstanceId", :string, []},
    {:task_id, "taskId", :string, []},
    {:reason_for_incompletion, "reasonForIncompletion", :string, []},
    {:callback_after_seconds, "callbackAfterSeconds", :int, []},
    {:worker_id, "workerId", :string, []},
    {:status, "status",
     {:enum, [:in_progress, :failed, :failed_with_terminal_error, :completed, :canceled]}, []},
    {:output_data, "outputData", :object, default: %{}},
    {:execution_metadata, "executionMetadata", {:struct, ExecutionMetadata}, []},
    {:logs, "logs", {:list, {:struct, TaskExecLog}}, default: []},
    {:external_output_payload_storage_path, "externalOutputPayloadStoragePath", :string, []},
    {:sub_workflow_id, "subWorkflowId", :string, []},
    {:extend_lease, "extendLease", :bool, []},
    {:supports_cancellation, "supportsCancellation", :bool, []}
  ]

  defstruct Codec.defaults(@fields)

  @doc false
  @spec __fields__() :: [Codec.field()]
  def __fields__, do: @fields

  @type t :: %__MODULE__{
          workflow_instance_id: String.t() | nil,
          task_id: String.t() | nil,
          reason_for_incompletion: String.t() | nil,
          callback_after_seconds: integer(),
          worker_id: String.t() | nil,
          status: status() | nil,
          output_data: Codec.json_object() | nil,
          execution_metadata: ExecutionMetadata.t() | nil,
          logs: [TaskExecLog.t() | nil] | nil,
          external_output_payload_storage_path: String.t() | nil,
          sub_workflow_id: String.t() | nil,
          extend_lease: boolean(),
          supports_cancellation: boolean()
        }

  @doc """
  Decodes upstream JSON. `reasonForIncompletion` is cut to 500 characters as upstream's setter
  does.
  """
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []) do
    with {:ok, result} <- Codec.decode(__MODULE__, @fields, json, path) do
      {:ok,
       %{result | reason_for_incompletion: Task.truncate_reason(result.reason_for_incompletion)}}
    end
  end

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = result) do
    metadata = ExecutionMetadata.with_data(result.execution_metadata)
    Codec.encode(__MODULE__, @fields, %{result | execution_metadata: metadata})
  end

  @doc """
  Upstream `new TaskResult(Task)`: a result carrying the task's current state. Statuses a worker
  cannot report map as `COMPLETED_WITH_ERRORS`/`TIMED_OUT`/`SKIPPED` -> `FAILED` and
  `SCHEDULED` -> `IN_PROGRESS`.
  """
  @spec from_task(Task.t()) :: t()
  def from_task(%Task{} = task) do
    %__MODULE__{
      workflow_instance_id: task.workflow_instance_id,
      task_id: task.task_id,
      reason_for_incompletion: task.reason_for_incompletion,
      callback_after_seconds: task.callback_after_seconds,
      worker_id: task.worker_id,
      output_data: task.output_data,
      execution_metadata: ExecutionMetadata.with_data(task.execution_metadata),
      external_output_payload_storage_path: task.external_output_payload_storage_path,
      sub_workflow_id: Task.sub_workflow_id(task),
      status: status_from_task(task.status)
    }
  end

  defp status_from_task(status) when status in [:completed_with_errors, :timed_out, :skipped],
    do: :failed

  defp status_from_task(:scheduled), do: :in_progress
  defp status_from_task(status), do: status

  @doc """
  Bean validation: `workflowInstanceId` and `taskId` are `@NotEmpty`.
  """
  @spec validate(t()) :: Validation.result()
  def validate(%__MODULE__{} = result) do
    Validation.result(
      Validation.not_empty(
        "workflowInstanceId",
        result.workflow_instance_id,
        "Workflow Id cannot be null or empty"
      ) ++
        Validation.not_empty("taskId", result.task_id, "Task ID cannot be null or empty")
    )
  end
end
