# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/Join.java
# (execute, isAgentExecution, prepareAgentOutput) and core/.../model/WorkflowModel.java
# (getTaskByRefName) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the updated join task instead of mutating it; the evaluation
# offset (queue postponement) is left to the runtime.

defmodule Archon.Decider.SystemTask.Join do
  @moduledoc """
  Upstream `Join#execute`: decides whether a `JOIN` task is done from the tasks it joins on.

  For each `joinOn` reference (with the `__<iteration>` suffix inside a loop), the latest task of
  that name contributes its non-empty output under the reference name. The join fails as soon as
  a joined task failed and is neither optional nor permissive (a permissive failure counts once
  every joined task is terminal): `FAILED`, or `CANCELED` when every such failure is a
  cancellation, with the joined reasons. Once every joined task is terminal the join is
  `COMPLETED`, or `COMPLETED_WITH_ERRORS` when optional tasks completed with errors. Otherwise it
  waits (`false`).

  For agent workflows (definition `metadata` with `agent_sdk` or `agentDef`) branch outputs are
  shaped as upstream does for Conductor-Agents.
  """

  alias Archon.Domain.{Task, Workflow, WorkflowDef, WorkflowTask}

  @agent_keys ["_state_updates", "state"]

  @doc "Upstream `Join#execute`."
  @spec execute(Workflow.t(), Task.t()) :: {boolean(), Task.t()}
  def execute(%Workflow{} = workflow, %Task{} = task) do
    join_on = join_on(task)
    joined = Enum.map(join_on, &{&1, task_by_ref_name(workflow, &1)})
    all_terminal? = Enum.all?(joined, fn {_ref, t} -> t != nil and Task.terminal?(t.status) end)
    agent? = agent_execution?(workflow)

    joined
    |> Enum.reject(fn {_ref, forked} -> forked == nil end)
    |> Enum.reduce_while({task, []}, fn {ref, forked}, {task, optional_failures} ->
      task = add_output(task, ref, forked, agent?)

      cond do
        join_failure?(forked, all_terminal?) ->
          {:halt, {:done, fail(task, joined)}}

        optional?(forked) and forked.status == :completed_with_errors ->
          {:cont,
           {task, optional_failures ++ ["#{java(forked.task_def_name)}/#{java(forked.task_id)}"]}}

        true ->
          {:cont, {task, optional_failures}}
      end
    end)
    |> finish(all_terminal?)
  end

  defp finish({:done, task}, _all_terminal?), do: {true, task}
  defp finish({task, []}, true), do: {true, %{task | status: :completed}}

  defp finish({task, failures}, true) do
    reason = Enum.map_join(failures, "", &(&1 <> " ")) <> "completed with errors"
    {true, %{task | status: :completed_with_errors, reason_for_incompletion: reason}}
  end

  defp finish({task, _failures}, false), do: {false, task}

  defp join_on(%Task{input_data: input} = task) do
    refs = Map.get(input, "joinOn") || []

    if Task.loop_over_task?(task),
      do: Enum.map(refs, &"#{&1}__#{task.iteration}"),
      else: refs
  end

  defp add_output(task, _ref, %Task{output_data: output}, _agent?)
       when output == %{} or output == nil,
       do: task

  defp add_output(task, ref, forked, agent?) do
    output = if agent?, do: agent_output(forked), else: forked.output_data
    %{task | output_data: Map.put(task.output_data || %{}, ref, output)}
  end

  defp join_failure?(forked, all_terminal?) do
    not Task.successful?(forked.status) and not optional?(forked) and
      (not permissive?(forked) or all_terminal?)
  end

  defp fail(task, joined) do
    forked = for {_ref, t} <- joined, t != nil, do: t

    reason =
      forked
      |> Enum.filter(&(not Task.successful?(&1.status) and &1.reason_for_incompletion != nil))
      |> Enum.map_join(" ", & &1.reason_for_incompletion)

    non_canceled_failure? =
      Enum.any?(forked, fn t ->
        Task.terminal?(t.status) and not Task.successful?(t.status) and not optional?(t) and
          t.status != :canceled
      end)

    %{
      task
      | reason_for_incompletion: reason,
        status: if(non_canceled_failure?, do: :failed, else: :canceled)
    }
  end

  defp optional?(%Task{workflow_task: %WorkflowTask{optional: optional}}), do: optional == true
  defp optional?(%Task{}), do: false

  defp permissive?(%Task{workflow_task: %WorkflowTask{permissive: permissive}}),
    do: permissive == true

  defp permissive?(%Task{}), do: false

  # WorkflowModel#getTaskByRefName: the last task with the reference name.
  defp task_by_ref_name(%Workflow{tasks: tasks}, ref),
    do: tasks |> Enum.filter(&(&1.reference_task_name == ref)) |> List.last()

  defp agent_execution?(%Workflow{workflow_definition: %WorkflowDef{metadata: metadata}})
       when is_map(metadata),
       do: Map.get(metadata, "agent_sdk") != nil or Map.get(metadata, "agentDef") != nil

  defp agent_execution?(%Workflow{}), do: false

  defp agent_output(%Task{output_data: output, input_data: input}) do
    case Map.get(input || %{}, "_agent_tool_name") do
      nil ->
        if Enum.any?(@agent_keys, &Map.has_key?(output, &1)),
          do: Map.take(output, @agent_keys),
          else: output

      name ->
        %{"_agent_tool_name" => name, "_agent_tool_output" => output}
    end
  end

  defp java(nil), do: "null"
  defp java(value), do: value
end
