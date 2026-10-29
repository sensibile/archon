# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/WaitTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; reads the
# clock from the Decider context; an invalid duration fails the task instead of throwing.

defmodule Archon.Decider.Mapper.Wait do
  @moduledoc """
  Upstream `WaitTaskMapper`: one `IN_PROGRESS` `WAIT` task that waits for its `duration`, until
  its `until` time, or forever.

  `wait_timeout` is when the wait ends (`Archon.Decider.SystemTask.execute/3` completes the task
  after it) and `callback_after_seconds` how long until then. Both inputs, or an `until` that does
  not parse, fail the task with `FAILED_WITH_TERMINAL_ERROR`. A `duration` that does not parse
  does the same with `Not valid duration: <duration>`, where upstream throws out of the decide
  (ADR 0014).
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Decider.Parameters
  alias Archon.Domain.{DateTimeUtils, Task, TaskDef, WorkflowTask}

  # Integer.MAX_VALUE: no duration waits forever.
  @forever 2_147_483_647

  @impl true
  def map(%WorkflowTask{}, %Context{} = context) do
    task = Context.create_task(context)
    now = context.decider.now

    task = %{
      task
      | task_type: "WAIT",
        input_data: Context.task_input(context, nil),
        start_time: now,
        status: :in_progress,
        isolation_group_id: isolation_group_id(context.task_definition)
    }

    {:ok, [callback_after(task, now)]}
  end

  defp callback_after(%Task{input_data: input} = task, now) do
    duration = wait_input(input["duration"])
    until = wait_input(input["until"])

    cond do
      not blank?(duration) and not blank?(until) ->
        failed(task, "Both 'duration' and 'until' specified. Please provide only one input")

      not blank?(duration) ->
        wait_for(task, duration, now)

      not blank?(until) ->
        wait_until(task, until, now)

      true ->
        %{task | callback_after_seconds: @forever}
    end
  end

  defp wait_for(task, duration, now) do
    case DateTimeUtils.parse_duration(duration) do
      {:ok, seconds} ->
        %{task | wait_timeout: now + seconds * 1000, callback_after_seconds: seconds}

      :error ->
        failed(task, "Not valid duration: #{duration}")
    end
  end

  defp wait_until(task, until, now) do
    case DateTimeUtils.parse_date(until) do
      {:ok, ms} -> %{task | callback_after_seconds: max(div(ms - now, 1000), 0), wait_timeout: ms}
      :error -> failed(task, "Invalid/Unsupported Wait Until format.  Provided: #{until}")
    end
  end

  defp failed(task, reason),
    do: %{task | reason_for_incompletion: reason, status: :failed_with_terminal_error}

  # Optional.ofNullable(value).orElse("").toString()
  defp wait_input(nil), do: ""
  defp wait_input(value), do: Parameters.java_string(value)

  defp blank?(value), do: String.trim(value) == ""

  defp isolation_group_id(%TaskDef{isolation_group_id: id}), do: id
  defp isolation_group_id(nil), do: nil
end
