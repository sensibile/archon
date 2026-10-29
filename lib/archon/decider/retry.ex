# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/DeciderService.java
# (retry, resetRetriedTaskRuntimeState, applyMaxRetryDelayCap, updateWorkflowOutput)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the retried task, the updated original and the workflow instead
# of mutating them and throwing; the clock, ID generator, jitter source and MetadataDAO come
# from the Decider context; external payload storage is not supported (ADR 0014).

defmodule Archon.Decider.Retry do
  @moduledoc """
  Upstream `DeciderService#retry`: decides whether a failed task runs again.

  Results:

    * `{:retry, rescheduled, original}` - `rescheduled` is the next attempt and `original` the
      failed task marked `retried`.
    * `:no_retry` - the task is out of retries but optional or permissive, so the workflow goes
      on.
    * `{:terminate, termination, workflow}` - the workflow ends. `workflow` has its `output`
      updated from the failed task, as upstream does before throwing.

  The retry delay follows `TaskDef.retryLogic` (`FIXED`, `LINEAR_BACKOFF`,
  `EXPONENTIAL_BACKOFF`) with Java `int` arithmetic: a product that overflows to a negative value
  becomes `Integer.MAX_VALUE`. `maxRetryDelaySeconds` caps the delay when positive, and up to
  `backoffJitterMs` of jitter is added to `callback_after_ms` only.
  """

  alias Archon.Decider.{Context, Parameters, Termination}
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}

  @int_max 2_147_483_647

  # TaskType.isBuiltIn
  @built_in ~w(DECISION SWITCH FORK JOIN EXCLUSIVE_JOIN DO_WHILE)

  @type result ::
          {:retry, Task.t(), Task.t()}
          | :no_retry
          | {:terminate, Termination.t(), Workflow.t()}

  @doc """
  Retries `task` of `workflow`. `task_def` is the task's definition, looked up by task definition
  name in `context.task_defs` when `nil`; `workflow_task` is its `WorkflowTask`, which may be
  `nil`.
  """
  @spec retry(TaskDef.t() | nil, WorkflowTask.t() | nil, Task.t(), Workflow.t(), Context.t()) ::
          result()
  def retry(task_def, workflow_task, %Task{} = task, %Workflow{} = workflow, %Context{} = context) do
    task_def = task_def || Map.get(context.task_defs, Task.task_def_name(task))

    cond do
      exhausted?(task_def, workflow_task, task) ->
        exhausted(workflow_task, task, workflow)

      total_timeout_exceeded?(task_def, task, context.now) ->
        total_timeout(task_def, task, workflow, context.now)

      true ->
        reschedule(task_def, workflow_task, task, workflow, context)
    end
  end

  defp exhausted?(task_def, workflow_task, task) do
    not Task.retriable?(task.status) or task.task_type in @built_in or
      expected_retries(task_def, workflow_task) <= task.retry_count
  end

  defp expected_retries(nil, _workflow_task), do: 0
  defp expected_retries(_task_def, %WorkflowTask{retry_count: count}) when count != nil, do: count
  defp expected_retries(%TaskDef{retry_count: count}, _workflow_task), do: count

  defp exhausted(%WorkflowTask{optional: optional, permissive: permissive}, _task, _workflow)
       when optional or permissive,
       do: :no_retry

  defp exhausted(_workflow_task, task, workflow) do
    status =
      case task.status do
        :canceled -> :terminated
        :timed_out -> :timed_out
        _other -> :failed
      end

    reason =
      "Task #{java_string(task.task_id)} failed with status: #{status_name(status)} and reason: " <>
        "'#{java_string(task.reason_for_incompletion)}'"

    {:terminate, Termination.new(reason, status, task), update_output(workflow, task)}
  end

  defp total_timeout_exceeded?(%TaskDef{total_timeout_seconds: total}, task, now) do
    total > 0 and task.first_scheduled_time > 0 and
      div(now - task.first_scheduled_time, 1000) >= total
  end

  defp total_timeout(task_def, task, workflow, now) do
    elapsed = div(now - task.first_scheduled_time, 1000)

    reason =
      "Task #{java_string(task.task_id)}/#{java_string(Task.task_def_name(task))} exceeded total " <>
        "timeout of #{task_def.total_timeout_seconds} seconds (elapsed #{elapsed} seconds across " <>
        "all attempts). No further retries will be attempted."

    status = if task.status == :timed_out, do: :timed_out, else: :failed
    {:terminate, Termination.new(reason, status, task), update_output(workflow, task)}
  end

  defp reschedule(task_def, workflow_task, task, workflow, context) do
    delay = task_def |> base_delay(task.retry_count) |> cap(task_def.max_retry_delay_seconds)

    jitter =
      if task_def.backoff_jitter_ms > 0, do: context.jitter.(task_def.backoff_jitter_ms), else: 0

    # TaskModel.copy() shares inputData with the original, so removing `subWorkflowId` from the
    # copy removes it from the failed task too.
    input = Map.delete(task.input_data, "subWorkflowId")
    original = %{task | retried: true, input_data: input}
    task_id = context.new_id.()

    rescheduled = %{
      original
      | update_time: 0,
        scheduled_time: 0,
        start_time: 0,
        end_time: 0,
        worker_id: nil,
        output_data: %{},
        external_output_payload_storage_path: nil,
        start_delay_in_seconds: delay,
        callback_after_seconds: delay,
        callback_after_ms: delay * 1000 + jitter,
        retry_count: task.retry_count + 1,
        retried: false,
        task_id: task_id,
        retried_task_id: task.task_id,
        status: :scheduled,
        poll_count: 0,
        sub_workflow_id: nil,
        seq: 0
    }

    rescheduled =
      case {workflow_task, workflow.workflow_definition} do
        {%WorkflowTask{} = wt, %WorkflowDef{schema_version: version}} when version > 1 ->
          resolved = Parameters.task_input(wt.input_parameters, workflow, task_id, task_def)
          %{rescheduled | input_data: Map.merge(rescheduled.input_data, resolved)}

        _other ->
          rescheduled
      end

    {:retry, rescheduled, original}
  end

  defp base_delay(%TaskDef{retry_logic: :fixed} = task_def, _retry_count),
    do: task_def.retry_delay_seconds

  defp base_delay(%TaskDef{retry_logic: :linear_backoff} = task_def, retry_count) do
    task_def.retry_delay_seconds
    |> int_mul(task_def.backoff_scale_factor)
    |> int_mul(retry_count + 1)
    |> overflow_to_max()
  end

  defp base_delay(%TaskDef{retry_logic: :exponential_backoff} = task_def, retry_count) do
    task_def.retry_delay_seconds |> int_mul(pow2_int(retry_count)) |> overflow_to_max()
  end

  # applyMaxRetryDelayCap
  defp cap(delay, max) when max > 0 and delay > max, do: max
  defp cap(delay, _max), do: delay

  # Java `int` multiplication: the product wraps to 32 bits.
  defp int_mul(a, b) do
    <<wrapped::signed-32>> = <<a * b::signed-32>>
    wrapped
  end

  defp overflow_to_max(value) when value < 0, do: @int_max
  defp overflow_to_max(value), do: value

  # `(int) Math.pow(2, n)`: the double saturates to Integer.MAX_VALUE from n = 31.
  defp pow2_int(n) when n >= 31, do: @int_max
  defp pow2_int(n) when n >= 0, do: Bitwise.bsl(1, n)

  @doc """
  Upstream `updateWorkflowOutput`: the workflow output once it ends.

  A successful `TERMINATE` task's non-empty output wins. Otherwise the definition's
  `outputParameters` are resolved against the workflow; without them the output of `task`, or of
  the last task when `task` is `nil`, is copied. A workflow without tasks keeps its output.
  """
  @spec update_output(Workflow.t(), Task.t() | nil) :: Workflow.t()
  def update_output(%Workflow{tasks: tasks} = workflow, _task) when tasks in [nil, []],
    do: workflow

  def update_output(%Workflow{tasks: tasks} = workflow, task) do
    output =
      case Enum.find(tasks, &successful_terminate?/1) do
        %Task{output_data: data} when map_size(data) > 0 -> data
        %Task{} -> %{}
        nil -> last_output(workflow, task || List.last(tasks))
      end

    %{workflow | output: output}
  end

  defp last_output(%Workflow{workflow_definition: definition} = workflow, last) do
    case definition do
      %WorkflowDef{output_parameters: params} when is_map(params) and map_size(params) > 0 ->
        Parameters.task_input(params, workflow, nil, nil)

      _other ->
        last.output_data
    end
  end

  @doc false
  @spec successful_terminate?(Task.t()) :: boolean()
  def successful_terminate?(%Task{task_type: "TERMINATE", status: status}),
    do: Task.terminal?(status) and Task.successful?(status)

  def successful_terminate?(%Task{}), do: false

  defp status_name(status), do: status |> Atom.to_string() |> String.upcase()

  defp java_string(nil), do: "null"
  defp java_string(value), do: value
end
