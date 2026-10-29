# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/SwitchTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; the
# evaluator comes from Archon.Decider.Evaluator.

defmodule Archon.Decider.Mapper.Switch do
  @moduledoc """
  Upstream `SwitchTaskMapper`: an `IN_PROGRESS` `SWITCH` task followed by the first task of the
  selected case.

  The expression is evaluated here, at scheduling time. The result, as a Java string, picks the
  case; an evaluator result that is a map with `selectedCase` routes by that key and its entries
  are copied into the output. Only a case name that is absent falls back to `defaultCase`; a case
  with no tasks schedules nothing. When a case task is scheduled the `SWITCH` input gets
  `hasChildren: "true"`, which `Archon.Decider.next_tasks/3` reads. An evaluator that is not
  registered terminates the workflow.
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.{Evaluator, Parameters}
  alias Archon.Decider.Mapper.Context
  alias Archon.Domain.WorkflowTask

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    case Evaluator.evaluate(wt.evaluator_type, wt.expression, context.task_input) do
      :unregistered ->
        {:terminate,
         "No evaluator registered for type: #{Parameters.java_string(wt.evaluator_type)}"}

      {:ok, result} ->
        {output, case_name} = routing(result)
        task = Context.create_task(context)

        switch_task = %{
          task
          | task_type: "SWITCH",
            task_def_name: "SWITCH",
            input_data: Map.put(context.task_input, "case", case_name),
            output_data:
              Map.merge(output, %{"evaluationResult" => [case_name], "selectedCase" => case_name}),
            start_time: context.decider.now,
            status: :in_progress
        }

        wt.decision_cases
        |> Map.get(case_name, wt.default_case)
        |> schedule_case(switch_task, context)
    end
  end

  defp routing(%{"selectedCase" => selected} = output),
    do: {output, Parameters.java_string(selected)}

  defp routing(result), do: {%{}, Parameters.java_string(result)}

  defp schedule_case([first | _rest], switch_task, context) do
    with {:ok, case_tasks} <- Context.tasks_to_be_scheduled(context, first, context.retry_task_id) do
      switch_task = put_in(switch_task.input_data["hasChildren"], "true")
      {:ok, [switch_task | case_tasks]}
    end
  end

  defp schedule_case(_empty, switch_task, _context), do: {:ok, [switch_task]}
end
