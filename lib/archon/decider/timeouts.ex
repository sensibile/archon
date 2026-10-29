# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/DeciderService.java
# (checkWorkflowTimeout, checkTotalTimeout, checkTaskTimeout, checkTaskPollTimeout,
# timeoutTaskWithTimeoutPolicy, isResponseTimedOut, timeoutTask)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: pure functions over a clock value that return the updated task or a
# termination instead of mutating it and throwing; logging and metrics are not ported.

defmodule Archon.Decider.Timeouts do
  @moduledoc """
  Workflow and task timeout checks of upstream `DeciderService`.

  Task checks return `{:ok, task}` with the task unchanged or marked `TIMED_OUT`, or
  `{:terminate, termination, task}` when the timeout policy is `TIME_OUT_WF` (the task is marked
  `TIMED_OUT` first, as upstream does before throwing). `ALERT_ONLY` only logs upstream, so it
  changes nothing here. Messages are upstream's.
  """

  alias Archon.Decider.{SystemTasks, Termination}
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef}

  @type task_result :: {:ok, Task.t()} | {:terminate, Termination.t(), Task.t()}

  @doc """
  Upstream `checkWorkflowTimeout`. Elapsed time counts from `lastRetriedTime` when set, else from
  `createTime`. Only `TIME_OUT_WF` terminates (with `TIMED_OUT`).
  """
  @spec check_workflow(Workflow.t(), integer()) :: :ok | {:terminate, Termination.t()}
  def check_workflow(%Workflow{workflow_definition: nil}, _now), do: :ok

  def check_workflow(%Workflow{workflow_definition: %WorkflowDef{} = definition} = workflow, now) do
    if Workflow.terminal?(workflow.status) or definition.timeout_seconds <= 0 do
      :ok
    else
      timeout = 1000 * definition.timeout_seconds

      elapsed =
        if workflow.last_retried_time > 0,
          do: now - workflow.last_retried_time,
          else: now - workflow.create_time

      cond do
        elapsed < timeout ->
          :ok

        definition.timeout_policy == :time_out_wf ->
          {:terminate,
           Termination.new(
             "Workflow timed out after #{div(elapsed, 1000)} seconds. Timeout configured as " <>
               "#{definition.timeout_seconds} seconds. Timeout policy configured to " <>
               policy_name(definition.timeout_policy),
             :timed_out
           )}

        definition.timeout_policy == :alert_only ->
          :ok
      end
    end
  end

  @doc """
  Upstream `checkTotalTimeout`: the budget of `totalTimeoutSeconds` across all attempts, counted
  from `first_scheduled_time`. Tasks without a first scheduled time are skipped.
  """
  @spec check_total(TaskDef.t() | nil, Task.t(), integer()) :: task_result()
  def check_total(%TaskDef{total_timeout_seconds: total} = task_def, %Task{} = task, now)
      when total > 0 do
    elapsed = div(now - task.first_scheduled_time, 1000)

    if Task.terminal?(task.status) or task.first_scheduled_time <= 0 or elapsed < total do
      {:ok, task}
    else
      reason =
        "Task #{java_string(Task.task_def_name(task))}/#{java_string(task.task_id)} exceeded " <>
          "total timeout of #{total} seconds (elapsed #{elapsed} seconds across all attempts " <>
          "including retry delays). Timeout policy: #{policy_name(task_def.timeout_policy)}"

      apply_policy(reason, task_def, task)
    end
  end

  def check_total(_task_def, %Task{} = task, _now), do: {:ok, task}

  @doc """
  Upstream `checkTaskTimeout`: `timeoutSeconds` since `startTime + startDelayInSeconds`, for a
  started task that is not terminal.
  """
  @spec check_task(TaskDef.t() | nil, Task.t(), integer()) :: task_result()
  def check_task(nil, %Task{} = task, _now), do: {:ok, task}

  def check_task(%TaskDef{timeout_seconds: seconds} = task_def, %Task{} = task, now) do
    if Task.terminal?(task.status) or seconds <= 0 or task.start_time <= 0 do
      {:ok, task}
    else
      elapsed = now - (task.start_time + task.start_delay_in_seconds * 1000)

      if elapsed < 1000 * seconds do
        {:ok, task}
      else
        reason =
          "Task timed out after #{div(elapsed, 1000)} seconds. Timeout configured as " <>
            "#{seconds} seconds. Timeout policy configured to #{policy_name(task_def.timeout_policy)}"

        apply_policy(reason, task_def, task)
      end
    end
  end

  @doc """
  Upstream `checkTaskPollTimeout`: a `SCHEDULED` task not polled within `pollTimeoutSeconds`
  (plus `callbackAfterSeconds`) of `scheduledTime + startDelayInSeconds`.
  """
  @spec check_poll(TaskDef.t() | nil, Task.t(), integer()) :: task_result()
  def check_poll(
        %TaskDef{poll_timeout_seconds: seconds} = task_def,
        %Task{status: :scheduled} = task,
        now
      )
      when is_integer(seconds) and seconds > 0 do
    poll_timeout = 1000 * seconds
    elapsed = now - (task.scheduled_time + task.start_delay_in_seconds * 1000)

    if elapsed < poll_timeout + task.callback_after_seconds * 1000 do
      {:ok, task}
    else
      reason =
        "Task poll timed out after #{div(elapsed, 1000)} seconds. Poll timeout configured as " <>
          "#{seconds} seconds. Timeout policy configured to #{policy_name(task_def.timeout_policy)}"

      apply_policy(reason, task_def, task)
    end
  end

  def check_poll(_task_def, %Task{} = task, _now), do: {:ok, task}

  @doc """
  Upstream `isResponseTimedOut`: an `IN_PROGRESS` task not updated within
  `responseTimeoutSeconds` (plus `callbackAfterSeconds`). Asynchronously completed system tasks
  never time out this way, and `responseTimeoutSeconds` 0 disables the check.
  """
  @spec response_timed_out?(TaskDef.t() | nil, Task.t(), integer(), SystemTasks.t()) :: boolean()
  def response_timed_out?(nil, %Task{}, _now, _system_tasks), do: false

  def response_timed_out?(%TaskDef{} = task_def, %Task{} = task, now, system_tasks) do
    cond do
      Task.terminal?(task.status) or SystemTasks.async_complete?(system_tasks, task) ->
        false

      task.status != :in_progress or task_def.response_timeout_seconds == 0 ->
        false

      true ->
        now - task.update_time >=
          1000 * task_def.response_timeout_seconds + 1000 * task.callback_after_seconds
    end
  end

  @doc "Upstream `timeoutTask`: marks a task `TIMED_OUT` after a response timeout."
  @spec timeout_response(TaskDef.t(), Task.t()) :: Task.t()
  def timeout_response(%TaskDef{} = task_def, %Task{} = task) do
    reason =
      "responseTimeout: #{task_def.response_timeout_seconds} exceeded for the taskId: " <>
        "#{java_string(task.task_id)} with Task Definition: #{java_string(Task.task_def_name(task))}"

    %{task | status: :timed_out, reason_for_incompletion: reason}
  end

  # timeoutTaskWithTimeoutPolicy
  defp apply_policy(reason, %TaskDef{timeout_policy: policy}, task) do
    timed_out = %{task | status: :timed_out, reason_for_incompletion: reason}

    case policy do
      :alert_only -> {:ok, task}
      :retry -> {:ok, timed_out}
      :time_out_wf -> {:terminate, Termination.new(reason, :timed_out, timed_out), timed_out}
    end
  end

  defp policy_name(policy) when is_atom(policy) and not is_nil(policy),
    do: policy |> Atom.to_string() |> String.upcase()

  defp java_string(nil), do: "null"
  defp java_string(value), do: value
end
