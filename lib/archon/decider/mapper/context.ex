# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/TaskMapperContext.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: a builder class became a struct; the clock and the DeciderService
# reference became the Decider context.

defmodule Archon.Decider.Mapper.Context do
  @moduledoc """
  Upstream `TaskMapperContext`: what a mapper gets besides the `WorkflowTask`.

  `task_definition` is the one embedded in the `WorkflowTask`, `task_input` the task input
  resolved without a task ID or definition, and `decider` the `Archon.Decider.Context` of the
  current decision (clock, ID generator, task definitions).
  """

  alias Archon.Decider.Parameters
  alias Archon.Domain.{Codec, Task, TaskDef, Workflow, WorkflowTask}

  @enforce_keys [:workflow, :workflow_task, :task_id, :decider]
  defstruct [
    :workflow,
    :task_definition,
    :workflow_task,
    :retry_task_id,
    :task_id,
    :parent_task_reference_name,
    :decider,
    task_input: %{},
    retry_count: 0
  ]

  @type t :: %__MODULE__{
          workflow: Workflow.t(),
          task_definition: TaskDef.t() | nil,
          workflow_task: WorkflowTask.t(),
          task_input: Codec.json_object(),
          retry_count: integer(),
          retry_task_id: String.t() | nil,
          task_id: String.t(),
          parent_task_reference_name: String.t() | nil,
          decider: Archon.Decider.Context.t()
        }

  @doc """
  Upstream `createTaskModel`: the fields every mapper starts from. The task is scheduled at
  `decider.now` and has no status yet.
  """
  @spec create_task(t()) :: Task.t()
  def create_task(%__MODULE__{workflow_task: wt, workflow: workflow} = context) do
    %Task{
      reference_task_name: wt.task_reference_name,
      workflow_instance_id: workflow.workflow_id,
      workflow_type: Workflow.workflow_name(workflow),
      correlation_id: workflow.correlation_id,
      scheduled_time: context.decider.now,
      task_id: context.task_id,
      workflow_task: wt,
      workflow_priority: workflow.priority,
      parent_task_reference_name: context.parent_task_reference_name,
      task_type: wt.type,
      task_def_name: wt.name
    }
  end

  @doc """
  Upstream `getDeciderService().getTasksToBeScheduled(workflow, wt, retryCount, retryTaskId)`,
  as a mapper uses it to schedule a nested task. A termination comes back as its reason, the
  mapper's own termination value.
  """
  @spec tasks_to_be_scheduled(t(), WorkflowTask.t(), String.t() | nil) ::
          {:ok, [Task.t()]} | {:terminate, String.t()}
  def tasks_to_be_scheduled(%__MODULE__{} = context, %WorkflowTask{} = wt, retry_task_id) do
    case Archon.Decider.tasks_to_be_scheduled(
           context.workflow,
           wt,
           context.retry_count,
           retry_task_id,
           context.decider
         ) do
      {:ok, tasks} -> {:ok, tasks}
      {:terminate, %Archon.Decider.Termination{reason: reason}} -> {:terminate, reason}
    end
  end

  @doc "Upstream `getTaskInputV2` of the `WorkflowTask` inputs for this task ID and `task_def`."
  @spec task_input(t(), TaskDef.t() | nil) :: Codec.json_object()
  def task_input(%__MODULE__{} = context, task_def) do
    Parameters.task_input(
      context.workflow_task.input_parameters,
      context.workflow,
      context.task_id,
      task_def
    )
  end
end
