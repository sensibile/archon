# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/org/conductoross/conductor/model/SignalResponse.java,
# WorkflowSignalReturnStrategy.java and core/src/main/java/com/netflix/conductor/core/execution/NotificationResult.java
# (toResponse, getWorkflowRun, toWorkflowRun, toTaskRun) at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the abstract class is a union of `Archon.Domain.WorkflowRun` and
# `Archon.Domain.TaskRun`; the missing answer of a `BLOCKING_TASK*` strategy without a blocking
# task is `nil` here, as upstream's `null`.

defmodule Archon.Domain.SignalResponse do
  @moduledoc """
  The answer of the synchronous start and signal (ADR 0025, decision 5): an
  `Archon.Domain.WorkflowRun` or an `Archon.Domain.TaskRun`, chosen by the return strategy
  (upstream `WorkflowSignalReturnStrategy`):

    * `:target_workflow` - the workflow the request named.
    * `:blocking_workflow` - the workflow the blocking task is in, which may be a child.
    * `:blocking_task`, `:blocking_task_input` - the first blocking task. Upstream builds the
      same `TaskRun` for both.
  """

  alias Archon.Domain.{Codec, Task, TaskRun, Workflow, WorkflowRun}

  @type strategy :: :target_workflow | :blocking_workflow | :blocking_task | :blocking_task_input
  @type t :: WorkflowRun.t() | TaskRun.t()

  @strategies [:target_workflow, :blocking_workflow, :blocking_task, :blocking_task_input]

  @doc "The return strategies, in upstream declaration order."
  @spec strategies() :: [strategy(), ...]
  def strategies, do: @strategies

  @doc "Decodes upstream JSON by its `responseType`: a `TaskRun` for `BLOCKING_TASK*`."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ [])

  def from_json(%{"responseType" => type} = json, path)
      when type in ["BLOCKING_TASK", "BLOCKING_TASK_INPUT"],
      do: TaskRun.from_json(json, path)

  def from_json(json, path), do: WorkflowRun.from_json(json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%WorkflowRun{} = run), do: WorkflowRun.to_json(run)
  def to_json(%TaskRun{} = run), do: TaskRun.to_json(run)

  @doc """
  Upstream `NotificationResult#toResponse`: the answer for the target workflow, the workflow
  of the first blocking task and the blocking tasks. Without a blocking task, `:target_workflow`
  and `:blocking_workflow` answer the target workflow, and the `BLOCKING_TASK*` strategies have
  no answer (`nil`).
  """
  @spec new(Workflow.t(), Workflow.t(), [Task.t()], boolean(), strategy(), String.t()) ::
          t() | nil
  def new(%Workflow{} = target, %Workflow{} = blocking, tasks, timeout?, strategy, request_id)
      when strategy in @strategies do
    case {tasks, strategy} do
      {_tasks, :target_workflow} ->
        workflow_run(target, target, timeout?, strategy, request_id)

      {[], :blocking_workflow} ->
        workflow_run(target, target, timeout?, strategy, request_id)

      {_tasks, :blocking_workflow} ->
        workflow_run(blocking, target, timeout?, strategy, request_id)

      {[], _blocking_task} ->
        nil

      {[task | _rest], _blocking_task} ->
        task_run(task, target, timeout?, strategy, request_id)
    end
  end

  # getWorkflowRun and toWorkflowRun
  defp workflow_run(%Workflow{} = workflow, target, timeout?, strategy, request_id) do
    %WorkflowRun{
      response_type: strategy,
      target_workflow_id: target.workflow_id,
      target_workflow_status: Codec.enum_name(target.status),
      request_id: request_id,
      workflow_id: workflow.workflow_id,
      correlation_id: workflow.correlation_id,
      input: workflow.input,
      output: workflow.output,
      signal_timeout: timeout?,
      priority: workflow.priority,
      variables: workflow.variables,
      tasks: workflow.tasks,
      created_by: workflow.created_by,
      create_time: workflow.create_time,
      status: workflow.status,
      update_time: workflow.update_time || 0
    }
  end

  # toTaskRun: the task's start time is the run's create time and its worker the creator.
  defp task_run(%Task{} = task, target, timeout?, strategy, request_id) do
    %TaskRun{
      response_type: strategy,
      target_workflow_id: target.workflow_id,
      target_workflow_status: Codec.enum_name(target.status),
      request_id: request_id,
      workflow_id: task.workflow_instance_id,
      correlation_id: task.correlation_id,
      input: task.input_data,
      output: task.output_data,
      signal_timeout: timeout?,
      task_type: task.task_type,
      task_id: task.task_id,
      reference_task_name: task.reference_task_name,
      retry_count: task.retry_count,
      task_def_name: Task.task_def_name(task),
      retried_task_id: task.retried_task_id,
      workflow_type: task.workflow_type,
      reason_for_incompletion: task.reason_for_incompletion,
      priority: task.workflow_priority,
      created_by: task.worker_id,
      create_time: task.start_time,
      update_time: task.update_time,
      status: task.status
    }
  end
end
