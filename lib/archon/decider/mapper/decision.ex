# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/DecisionTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; a
# caseExpression runs through the context's evaluate_script (ADR 0015).

defmodule Archon.Decider.Mapper.Decision do
  @moduledoc """
  Upstream `DecisionTaskMapper` (deprecated `DECISION`): an `IN_PROGRESS` `DECISION` task
  followed by the first task of the selected case.

  The case is the task input value named by `caseValueParam`, as a Java string (`"null"` when
  absent). Unlike `SWITCH`, a case with no tasks also falls back to `defaultCase`, and the task
  input is not copied: the `DECISION` input holds only `case` (and `hasChildren`).

  A non-blank `caseExpression` is a script evaluated with the task input as `$` by the context's
  `evaluate_script` (ADR 0015); its result, as a Java string, is the case. A script that fails to
  evaluate terminates the workflow with `Error while evaluating script: <expression>`.
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Decider.Parameters
  alias Archon.Domain.WorkflowTask

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    with {:ok, case_value} <- case_value(wt, context) do
      task = Context.create_task(context)

      decision_task = %{
        task
        | task_type: "DECISION",
          task_def_name: "DECISION",
          input_data: %{"case" => case_value},
          output_data: %{"caseOutput" => [case_value]},
          start_time: context.decider.now,
          status: :in_progress
      }

      case Map.get(wt.decision_cases, case_value) do
        [_ | _] = selected -> schedule_case(selected, decision_task, context)
        _none_or_empty -> schedule_case(wt.default_case, decision_task, context)
      end
    end
  end

  defp case_value(%WorkflowTask{case_expression: expression} = wt, context) do
    if is_binary(expression) and String.trim(expression) != "" do
      case context.decider.evaluate_script.(:eval, expression, context.task_input) do
        {:ok, value} -> {:ok, Parameters.java_string(value)}
        {:error, _error} -> {:terminate, "Error while evaluating script: #{expression}"}
      end
    else
      {:ok, Parameters.java_string(Map.get(context.task_input, wt.case_value_param))}
    end
  end

  defp schedule_case([first | _rest], decision_task, context) do
    with {:ok, case_tasks} <- Context.tasks_to_be_scheduled(context, first, context.retry_task_id) do
      decision_task = put_in(decision_task.input_data["hasChildren"], "true")
      {:ok, [decision_task | case_tasks]}
    end
  end

  defp schedule_case(_empty, decision_task, _context), do: {:ok, [decision_task]}
end
