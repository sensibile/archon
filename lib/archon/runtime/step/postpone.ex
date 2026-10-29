# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/org/conductoross/conductor/core/execution/ExecutorUtils.java
# (computePostpone, isActiveSubWorkflow) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: computed in milliseconds from the step's clock, and the timer is kept
# at least a second ahead (ADR 0018, decision 6).

defmodule Archon.Runtime.Step.Postpone do
  @moduledoc """
  When a running workflow is evaluated next (ADR 0018, decision 6).

  `compute/2` is upstream `ExecutorUtils#computePostpone` in milliseconds: the earliest of one
  candidate per task, each capped at `max_postpone_ms`, else `workflow_offset_timeout_ms`.

    * an active (`SCHEDULED` or `IN_PROGRESS`) `SUB_WORKFLOW`: the workflow offset.
    * an `IN_PROGRESS` `WAIT`: the time left until `waitTimeout`, or the offset without one.
    * an `IN_PROGRESS` `HUMAN`: the offset.
    * another `IN_PROGRESS` task: the response timeout (the task definition's, else the task's)
      left since `startTime`, plus a second, or the offset without one.
    * a `SCHEDULED` task: the poll timeout of its definition left since `scheduledTime`, plus a
      second; else the workflow's `timeoutSeconds` plus a second; else the offset.

  `wake_at/2` adds the end of the delay of each `SCHEDULED` asynchronous system task and keeps
  the result at least a second after `now`.
  """

  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef}
  alias Archon.Runtime.Step.{Async, Env, Schedule}

  @doc "Upstream `ExecutorUtils#computePostpone`, in milliseconds from `env.now`."
  @spec compute(Workflow.t(), Env.t()) :: non_neg_integer()
  def compute(%Workflow{tasks: tasks} = workflow, %Env{} = env) do
    tasks
    |> Enum.map(&candidate(&1, workflow, env))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn ms ->
      ms = max(ms, 0)
      if env.max_postpone_ms > 0, do: min(ms, env.max_postpone_ms), else: ms
    end)
    |> Enum.min(fn -> env.workflow_offset_timeout_ms end)
  end

  defp candidate(%Task{task_type: "SUB_WORKFLOW", status: status}, _workflow, env)
       when status in [:scheduled, :in_progress],
       do: env.workflow_offset_timeout_ms

  defp candidate(%Task{status: :in_progress, task_type: "WAIT", wait_timeout: 0}, _wf, env),
    do: env.workflow_offset_timeout_ms

  defp candidate(%Task{status: :in_progress, task_type: "WAIT"} = task, _workflow, env),
    do: task.wait_timeout - env.now

  defp candidate(%Task{status: :in_progress, task_type: "HUMAN"}, _workflow, env),
    do: env.workflow_offset_timeout_ms

  defp candidate(%Task{status: :in_progress} = task, _workflow, env) do
    case response_timeout_seconds(task) do
      0 -> env.workflow_offset_timeout_ms
      seconds -> seconds * 1000 - max(0, env.now - task.start_time) + 1000
    end
  end

  defp candidate(%Task{status: :scheduled} = task, workflow, env) do
    case {Task.task_definition(task), workflow.workflow_definition} do
      {%TaskDef{poll_timeout_seconds: seconds}, _definition} when seconds not in [nil, 0] ->
        seconds * 1000 - max(0, env.now - task.scheduled_time) + 1000

      {_task_def, %WorkflowDef{timeout_seconds: seconds}} when seconds != 0 ->
        (seconds + 1) * 1000

      _none ->
        env.workflow_offset_timeout_ms
    end
  end

  defp candidate(%Task{}, _workflow, _env), do: nil

  @doc """
  The response timeout upstream applies: the task definition's when not zero, else the task's
  own.
  """
  @spec response_timeout_seconds(Task.t()) :: integer()
  def response_timeout_seconds(%Task{} = task) do
    case Task.task_definition(task) do
      %TaskDef{response_timeout_seconds: seconds} when seconds != 0 -> seconds
      _other -> task.response_timeout_seconds
    end
  end

  @doc """
  The epoch time of the next `:wake`: `compute/2` or the end of a `SCHEDULED` asynchronous system
  task's delay, whichever is earlier, and never less than a second after `now`.
  """
  @spec wake_at(Workflow.t(), Env.t()) :: integer()
  def wake_at(%Workflow{tasks: tasks} = workflow, %Env{now: now} = env) do
    delays =
      for task <- tasks,
          task.status == :scheduled,
          Schedule.async?(task),
          Schedule.delay_ms(task) > 0,
          do: Async.due_time(task) - now

    now + max(earliest(delays, compute(workflow, env)), 1000)
  end

  defp earliest([], ms), do: ms
  defp earliest([delay | delays], ms) when is_integer(delay), do: earliest(delays, min(delay, ms))
end
