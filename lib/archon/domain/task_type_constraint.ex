# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/validations/WorkflowTaskTypeConstraint.java
# and core/src/main/java/com/netflix/conductor/core/utils/DateTimeUtils.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the class-level constraint became a function returning error tuples;
# rules that need a MetadataDAO lookup are not ported yet (ADR 0014); the script syntax check
# runs through Archon.Script (ADR 0015).

defmodule Archon.Domain.TaskTypeConstraint do
  @moduledoc """
  Upstream `WorkflowTaskTypeConstraint`: the fields each task type requires.

  Upstream registers it on `WorkflowTask` in `core/.../META-INF/validation/constraints.xml`, so
  it runs for every task wherever a `WorkflowTask` is validated. The violations are class-level:
  their path is the task's own path (`tasks[0]`), represented here by `""`.

  Not ported yet (ADR 0014): `HTTP`, `KAFKA_PUBLISH` and `JSON_JQ_TRANSFORM`, which fall back to
  a `MetadataDAO` lookup of the task definition.

  `DECISION.caseExpression` and `SWITCH.expression` with the `javascript` evaluator (not
  `graaljs`, as upstream) are parsed without running (`Archon.Script.validate_syntax/1`, ADR
  0015). A syntax error is reported as
  `Expression is not well formatted: <engine message>, taskType: <type> taskName <name>`; the
  engine message is QuickJS-ng's, not GraalJS's.

  `WAIT.until` is checked against upstream's date patterns (`yyyy-MM-dd HH:mm`,
  `yyyy-MM-dd HH:mm z`, `yyyy-MM-dd`) by shape only; lenient `SimpleDateFormat` parsing of
  out-of-range values is not reproduced.
  """

  alias Archon.Domain.{Codec, DateTimeUtils, WorkflowTask}
  alias Archon.Script

  @date ~r/^\d+-\d+-\d+(?: \d+:\d+(?: \S+)?)?\z/

  @termination_statuses ["COMPLETED", "FAILED", "TERMINATED"]

  @doc "Violations of the type rules for `task`, each with the task's own path `\"\"`."
  @spec errors(WorkflowTask.t()) :: [Codec.error()]
  def errors(%WorkflowTask{} = task), do: task |> messages() |> Enum.map(&{"", &1})

  defp messages(%WorkflowTask{type: "EVENT"} = task) do
    required(is_nil(task.sink), "sink", "EVENT", task)
  end

  defp messages(%WorkflowTask{type: "DECISION"} = task) do
    required(
      is_nil(task.case_value_param) and is_nil(task.case_expression),
      "caseValueParam or caseExpression",
      "DECISION",
      task
    ) ++ decision_cases(task, "DECISION") ++ script_syntax(task.case_expression, "DECISION", task)
  end

  defp messages(%WorkflowTask{type: "SWITCH"} = task) do
    evaluator =
      cond do
        is_nil(task.evaluator_type) -> required(true, "evaluatorType", "SWITCH", task)
        is_nil(task.expression) -> required(true, "expression", "SWITCH", task)
        true -> []
      end

    script =
      if task.evaluator_type == "javascript",
        do: script_syntax(task.expression, "SWITCH", task),
        else: []

    evaluator ++ decision_cases(task, "SWITCH") ++ script
  end

  defp messages(%WorkflowTask{type: "DYNAMIC"} = task) do
    required(is_nil(task.dynamic_task_name_param), "dynamicTaskNameParam", "DYNAMIC", task)
  end

  defp messages(%WorkflowTask{type: "FORK_JOIN_DYNAMIC"} = task) do
    legacy = task.dynamic_fork_join_tasks_param
    tasks_param = task.dynamic_fork_tasks_param
    input_param = task.dynamic_fork_tasks_input_param_name

    cond do
      Map.has_key?(task.input_parameters || %{}, "forkTaskInputs") ->
        []

      legacy != nil and (tasks_param != nil or input_param != nil) ->
        [
          "dynamicForkJoinTasksParam or combination of dynamicForkTasksInputParamName and " <>
            "dynamicForkTasksParam cam be used for taskType: FORK_JOIN_DYNAMIC " <>
            "taskName: #{task.name}"
        ]

      legacy != nil ->
        []

      true ->
        required(is_nil(tasks_param), "dynamicForkTasksParam", "FORK_JOIN_DYNAMIC", task) ++
          required(
            is_nil(input_param),
            "dynamicForkTasksInputParamName",
            "FORK_JOIN_DYNAMIC",
            task
          )
    end
  end

  defp messages(%WorkflowTask{type: "FORK_JOIN", fork_tasks: []} = task) do
    ["forkTasks should have atleast one task for taskType: FORK_JOIN taskName: #{task.name}"]
  end

  defp messages(%WorkflowTask{type: "TERMINATE"} = task) do
    status = Map.get(task.input_parameters || %{}, "terminationStatus")

    optional =
      if task.optional,
        do: ["terminate task cannot be optional, taskName: #{task.name}"],
        else: []

    status_errors =
      if is_nil(status) or java_string(status) not in @termination_statuses do
        [
          "terminate task must have an terminationStatus parameter and must be set to " <>
            "COMPLETED or FAILED, taskName: #{task.name}"
        ]
      else
        []
      end

    optional ++ status_errors
  end

  defp messages(%WorkflowTask{type: "DO_WHILE"} = task) do
    required(is_nil(task.loop_condition), "loopCondition", "DO_WHILE", task) ++
      required(task.loop_over in [nil, []], "loopOver", "DO_WHILE", task)
  end

  defp messages(%WorkflowTask{type: "SUB_WORKFLOW"} = task) do
    required(is_nil(task.sub_workflow_param), "subWorkflowParam", "SUB_WORKFLOW", task)
  end

  defp messages(%WorkflowTask{type: "WAIT"} = task) do
    input = task.input_parameters || %{}
    duration = input |> Map.get("duration") |> wait_input()
    until = input |> Map.get("until") |> wait_input()

    both =
      if blank?(duration) or blank?(until),
        do: [],
        else: ["Both 'duration' and 'until' specified. Please provide only one input"]

    both ++ wait_parse_errors(duration, until)
  end

  defp messages(%WorkflowTask{}), do: []

  # isWaitTaskValid: only the first non-blank, non-expression input is parsed.
  defp wait_parse_errors(duration, until) do
    cond do
      not blank?(duration) and not String.starts_with?(duration, "${") ->
        if DateTimeUtils.parse_duration(duration) != :error,
          do: [],
          else: ["Either date or duration is passed as null "]

      not blank?(until) and not String.starts_with?(until, "${") ->
        if Regex.match?(@date, until), do: [], else: ["Unable to parse date "]

      true ->
        []
    end
  end

  defp decision_cases(%WorkflowTask{decision_cases: nil} = task, type),
    do: required(true, "decisionCases", type, task)

  defp decision_cases(%WorkflowTask{decision_cases: cases} = task, type)
       when map_size(cases) == 0,
       do: [
         "decisionCases should have atleast one task for taskType: #{type} taskName: #{task.name}"
       ]

  defp decision_cases(%WorkflowTask{}, _type), do: []

  defp script_syntax(nil, _type, _task), do: []

  defp script_syntax(expression, type, task) do
    case Script.validate_syntax(expression) do
      :ok ->
        []

      {:error, reason} ->
        ["Expression is not well formatted: #{reason}, taskType: #{type} taskName #{task.name}"]
    end
  end

  # PARAM_REQUIRED_STRING_FORMAT
  defp required(false, _field, _type, _task), do: []

  defp required(true, field, type, task),
    do: ["#{field} field is required for taskType: #{type} taskName: #{task.name}"]

  defp wait_input(nil), do: ""
  defp wait_input(value), do: java_string(value)

  # Object#toString for the JSON scalars upstream sees; other values cannot match a pattern.
  defp java_string(value) when is_binary(value), do: value
  defp java_string(value) when is_integer(value), do: Integer.to_string(value)
  defp java_string(value) when is_float(value), do: Float.to_string(value)
  defp java_string(value) when is_boolean(value), do: Atom.to_string(value)
  defp java_string(value), do: inspect(value)

  # StringUtils.isBlank
  defp blank?(value), do: String.trim(value) == ""
end
