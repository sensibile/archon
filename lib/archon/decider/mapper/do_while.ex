# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/DoWhileTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; reads the
# clock and task definitions from the Decider context.

defmodule Archon.Decider.Mapper.DoWhile do
  @moduledoc """
  Upstream `DoWhileTaskMapper`: one `IN_PROGRESS` `DO_WHILE` task, or nothing when the workflow
  already has a terminal task with its reference name.

  The loop body is not scheduled here. Executing the task
  (`Archon.Decider.SystemTask.DoWhile.execute/3`) starts the first iteration. The task definition
  is the embedded one, else the context's `task_defs`, else `TaskDef` defaults.
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.{Task, TaskDef, WorkflowTask}

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    if completed?(context.workflow.tasks, wt.task_reference_name) do
      {:ok, []}
    else
      task_def =
        context.task_definition || Map.get(context.decider.task_defs, wt.name) || %TaskDef{}

      task = Context.create_task(context)

      {:ok,
       [
         %{
           task
           | task_type: "DO_WHILE",
             status: :in_progress,
             start_time: context.decider.now,
             rate_limit_per_frequency: task_def.rate_limit_per_frequency,
             rate_limit_frequency_in_seconds: task_def.rate_limit_frequency_in_seconds,
             retry_count: context.retry_count,
             input_data: Context.task_input(context, task_def)
         }
       ]}
    end
  end

  # WorkflowModel#getTaskByRefName: the last task with the reference name.
  defp completed?(tasks, ref) do
    case tasks |> Enum.filter(&(&1.reference_task_name == ref)) |> List.last() do
      %Task{status: status} -> Task.terminal?(status)
      nil -> false
    end
  end
end
