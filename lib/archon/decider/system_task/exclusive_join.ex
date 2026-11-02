# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/ExclusiveJoin.java
# and core/.../model/WorkflowModel.java (getTaskByRefName)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the updated task instead of mutating it (ADR 0026, decision 2);
# a joined reference without a task counts as not terminal and is left out of the failure
# reasons, as upstream's Join does, where upstream's ExclusiveJoin throws a NullPointerException.

defmodule Archon.Decider.SystemTask.ExclusiveJoin do
  @moduledoc """
  Upstream `ExclusiveJoin#execute`: decides whether an `EXCLUSIVE_JOIN` task is done from the
  first of its `joinOn` tasks that ran (ADR 0026, decision 3).

  The `joinOn` references (with the `__<iteration>` suffix inside a loop) are looked at in order;
  one without a task or with a `SKIPPED` task is passed over, and the first other one decides. It
  fails the join when it failed and is not permissive, or is permissive and every joined task is
  terminal; the reason is the joined tasks' failure reasons separated by spaces. When it is not
  terminal (or no joined task ran), the `defaultExclusiveJoinTask` references are looked at the
  same way, a failure there failing the join with that task's reason and a space. A terminal
  task that did not fail completes the join with its output; otherwise the join waits (`false`).

  When a joined task failed, upstream reads every joined task without checking that it exists
  (for the permissive check and for the failure reasons), and throws a `NullPointerException`
  when one never ran (the captured `p7_exclusive_join_failed_*`: a 500 to the task update and a
  workflow left `RUNNING`). Here a reference without a task is not terminal and gives no reason,
  as upstream's `Join` treats it: a permissive failure completes the join with the failed task's
  output and the workflow then fails for its permissive task, and any other failure fails the
  join with the existing tasks' reasons (deliberate difference; the decide usually ends the
  workflow on such a failure before the join runs).
  """

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.SystemTask
  alias Archon.Domain.{Task, Workflow, WorkflowTask}

  @impl true
  def execute(%Workflow{} = workflow, %Task{input_data: input} = task, _context) do
    join_on = join_on(task, Map.get(input, "joinOn") || [])

    case by_join_on(workflow, join_on) do
      {false, _failed?, reason, joined} ->
        workflow
        |> by_default(Map.get(input, "defaultExclusiveJoinTask"), reason, joined)
        |> finish(task)

      found ->
        finish(found, task)
    end
  end

  defp finish({_found?, true, reason, _joined}, task),
    do: SystemTask.changed(%{task | reason_for_incompletion: reason, status: :failed})

  defp finish({true, false, _reason, joined}, task),
    do: SystemTask.changed(%{task | output_data: joined.output_data, status: :completed})

  defp finish({false, false, _reason, _joined}, task), do: SystemTask.unchanged(task)

  # {found, failed, reason, the task looked at last}
  defp by_join_on(workflow, join_on) do
    case first_ran(workflow, join_on) do
      {:ran, %Task{status: status} = joined} ->
        failed? =
          not Task.successful?(status) and
            (not permissive?(joined) or all_terminal?(workflow, join_on))

        reason = if failed?, do: failure_reasons(workflow, join_on), else: ""
        {Task.terminal?(status), failed?, reason, joined}

      {:none, last} ->
        {false, false, "", last}
    end
  end

  defp by_default(_workflow, defaults, reason, joined) when defaults in [nil, []],
    do: {false, false, reason, joined}

  defp by_default(workflow, defaults, reason, _joined) do
    case first_ran(workflow, defaults) do
      {:ran, %Task{status: status} = joined} ->
        failed? = not Task.successful?(status)

        reason =
          if failed?, do: reason <> java(joined.reason_for_incompletion) <> " ", else: reason

        {Task.terminal?(status), failed?, reason, joined}

      {:none, last} ->
        {false, false, reason, last}
    end
  end

  # The first reference whose task exists and is not SKIPPED, or the last task looked at (the
  # Java loop variable after the loop).
  defp first_ran(workflow, refs) do
    Enum.reduce_while(refs, {:none, nil}, fn ref, _acc ->
      case task_by_ref_name(workflow, ref) do
        %Task{status: status} = task when status != :skipped -> {:halt, {:ran, task}}
        other -> {:cont, {:none, other}}
      end
    end)
  end

  defp join_on(task, refs) do
    if Task.loop_over_task?(task),
      do: Enum.map(refs, &"#{&1}__#{task.iteration}"),
      else: refs
  end

  defp all_terminal?(workflow, refs) do
    Enum.all?(refs, fn ref ->
      case task_by_ref_name(workflow, ref) do
        %Task{status: status} -> Task.terminal?(status)
        nil -> false
      end
    end)
  end

  # Collectors.joining(" ") over the reasons, a null one printing as "null".
  defp failure_reasons(workflow, refs) do
    refs
    |> Enum.map(&task_by_ref_name(workflow, &1))
    |> Enum.reject(&(&1 == nil or Task.successful?(&1.status)))
    |> Enum.map_join(" ", &java(&1.reason_for_incompletion))
  end

  defp permissive?(%Task{workflow_task: %WorkflowTask{permissive: permissive}}),
    do: permissive == true

  defp permissive?(%Task{}), do: false

  # WorkflowModel#getTaskByRefName: the last task with the reference name.
  defp task_by_ref_name(%Workflow{tasks: tasks}, ref),
    do: tasks |> Enum.filter(&(&1.reference_task_name == ref)) |> List.last()

  defp java(nil), do: "null"
  defp java(value), do: value
end
