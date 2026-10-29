# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/SubWorkflow.java
# (execute, updateTaskStatus) and core/.../model/WorkflowModel.java (toShortString)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: takes the child workflow the runtime loaded and returns the updated
# task instead of mutating it; starting the child (start, the SCHEDULED recovery in execute)
# and cancel are left to the runtime.

defmodule Archon.Decider.SystemTask.SubWorkflow do
  @moduledoc """
  The state-deciding part of upstream `SubWorkflow`: the `SUB_WORKFLOW` task follows its child
  workflow's status.

  The runtime loads the child by `Archon.Domain.Task.sub_workflow_id/1` and passes it, or `nil`
  when the task has no child yet or the child is gone. Starting the child, including upstream's
  retry of a `SCHEDULED` task without one, is the runtime's (Phase 3).
  """

  alias Archon.Decider.Parameters
  alias Archon.Domain.{Task, Workflow}

  @doc """
  Upstream `execute` once the child is loaded: `{false, task}` while there is no child or it is
  still running, else the task takes the child's terminal status.
  """
  @spec execute(Task.t(), Workflow.t() | nil) :: {boolean(), Task.t()}
  def execute(%Task{} = task, nil), do: {false, task}

  def execute(%Task{} = task, %Workflow{status: status} = child) do
    if Workflow.terminal?(status),
      do: {true, update_task_status(child, task)},
      else: {false, task}
  end

  @doc """
  Upstream `updateTaskStatus`: the task status for the child's status and, once the child is
  terminal, its output and, unless it succeeded, the reason.
  """
  @spec update_task_status(Workflow.t(), Task.t()) :: Task.t()
  def update_task_status(%Workflow{status: status} = child, %Task{} = task) do
    task = %{task | status: task_status(status)}

    cond do
      not Workflow.terminal?(status) ->
        task

      Workflow.successful?(status) ->
        add_output(task, child)

      true ->
        %{
          add_output(task, child)
          | reason_for_incompletion:
              "Sub workflow #{short_string(child)} failure reason: " <>
                Parameters.java_string(child.reason_for_incompletion)
        }
    end
  end

  defp task_status(status) when status in [:running, :paused], do: :in_progress
  defp task_status(:completed), do: :completed
  defp task_status(:failed), do: :failed
  defp task_status(:terminated), do: :canceled
  defp task_status(:timed_out), do: :timed_out

  defp add_output(task, child),
    do: %{task | output_data: Map.merge(task.output_data || %{}, child.output || %{})}

  # WorkflowModel#toShortString
  defp short_string(%Workflow{} = workflow) do
    [Workflow.workflow_name(workflow), Workflow.workflow_version(workflow), workflow.workflow_id]
    |> Enum.map(&Parameters.java_string/1)
    |> then(fn [name, version, id] -> "#{name}.#{version}/#{id}" end)
  end
end
