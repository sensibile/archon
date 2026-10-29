# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/utils/ParametersUtils.java,
# core/.../core/utils/EnvUtils.java and common/.../common/utils/TaskUtils.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as pure functions over Elixir terms; JsonPath reads use the
# Archon.Decider.JsonPath subset; schema version 1 input, environment/secrets providers and
# server environment variables are not supported (ADR 0014).

defmodule Archon.Decider.Parameters do
  @moduledoc """
  Resolves `${...}` references in task and workflow inputs, as upstream `ParametersUtils`.

  `task_input/4` builds the same reference document as upstream `getTaskInputV2`:

    * `workflow`: `input`, `output`, `status`, `workflowId`, `parentWorkflowId`,
      `parentWorkflowTaskId`, `workflowType`, `version`, `correlationId`,
      `reasonForIncompletion`, `schemaVersion`, `variables`
    * one entry per task reference name with `input`, `output`, `taskType`, `status`,
      `referenceTaskName`, `retryCount`, `correlationId`, `pollCount`, `taskDefName`,
      `scheduledTime`, `startTime`, `endTime`, `workflowInstanceId`, `taskId`,
      `reasonForIncompletion`, `callbackAfterSeconds`, `workerId`, `iteration`. Loop tasks are
      keyed without their `__<iteration>` suffix, and the last task with a reference name wins.

  Expression rules (`replaceVariables`):

    * `$${` is a literal `${`. Nested expressions resolve innermost first, up to 32 levels;
      deeper nesting resolves to `nil`.
    * A value that is exactly one expression keeps the referenced value's type. Otherwise the
      parts are joined as text, with Java's `toString` rendering (`nil` becomes `"null"`).
    * `${}` and blank expressions become `""`.
    * `${workflow.secrets.*}` is left as written: upstream resolves secrets only when a task is
      handed to a worker, and without a secrets provider it never does.
    * `${CPEWF_TASK_ID}` is the task ID. `${NETFLIX_ENV}` and `${NETFLIX_STACK}` stay as
      written, and no other server environment variable or JVM property is visible: this is
      upstream's behaviour on a server where none of them is set (ADR 0014).
    * Everything else is read with `Archon.Decider.JsonPath`; paths that do not resolve are
      `nil`.

  Map values that are rendered as text use sorted keys, since Elixir maps do not keep JSON key
  order (ADR 0002).
  """

  alias Archon.Decider.JsonPath
  alias Archon.Domain.{Codec, Task, TaskDef, Workflow, WorkflowDef}

  @typedoc "Decoded JSON."
  @type json :: Codec.json()

  @max_expression_depth 32
  @secrets_prefix "workflow.secrets."
  @system_parameters ["CPEWF_TASK_ID", "NETFLIX_ENV", "NETFLIX_STACK"]
  @loop_task_delimiter "__"

  @doc """
  Upstream `getTaskInputV2`: resolves `input` against `workflow`.

  `task_def.inputTemplate` fills keys that are missing or `nil` before resolution, and keys that
  resolve to `nil` afterwards.
  """
  @spec task_input(Codec.json_object() | nil, Workflow.t(), String.t() | nil, TaskDef.t() | nil) ::
          Codec.json_object()
  def task_input(input, %Workflow{} = workflow, task_id, task_def) do
    template = template(task_def)

    (input || %{})
    |> put_absent(template)
    |> replace_map(document(workflow), task_id)
    |> Map.new(fn
      {key, nil} -> {key, Map.get(template, key)}
      pair -> pair
    end)
  end

  @doc """
  Upstream `getWorkflowInput`: fills keys of `input` that are missing or `nil` from the
  definition's `inputTemplate`. No references are resolved.
  """
  @spec workflow_input(WorkflowDef.t() | nil, Codec.json_object()) :: Codec.json_object()
  def workflow_input(%WorkflowDef{input_template: template}, input) when is_map(template),
    do: put_absent(input, template)

  def workflow_input(_definition, input), do: input

  @doc """
  Upstream `replace(Map, Object)`: resolves `input` against an arbitrary JSON document.

  A string document is parsed as JSON text first, as upstream does with `JsonPath.parse(String)`;
  text that is not JSON raises `ArgumentError`, where upstream throws `InvalidJsonException`.
  """
  @spec replace(Codec.json_object(), json()) :: Codec.json_object()
  def replace(input, document) when is_binary(document) do
    case JSON.decode(document) do
      {:ok, decoded} -> replace_map(input, decoded, nil)
      {:error, reason} -> raise ArgumentError, "invalid JSON document: #{inspect(reason)}"
    end
  end

  def replace(input, document), do: replace_map(input, document, nil)

  @doc """
  Upstream `findExpressions`: the `{start, end}` byte ranges of the top-level `${...}`
  expressions in `value`.

  An expression starts at a `${` not preceded by `$` and ends at its matching `}`; expressions
  nested in it belong to it. An expression that is never closed hides everything after it. The
  scan is linear in the length of `value`. Ranges are byte offsets, which equal upstream's
  character offsets for ASCII text.
  """
  @spec find_expressions(String.t()) :: [{non_neg_integer(), non_neg_integer()}]
  def find_expressions(value), do: find_expressions(value, 0, [])

  defp find_expressions(value, from, acc) do
    case :binary.match(value, "${", scope: {from, byte_size(value) - from}) do
      :nomatch ->
        Enum.reverse(acc)

      {start, 2} when start > 0 ->
        if :binary.at(value, start - 1) == ?$,
          do: find_expressions(value, start + 1, acc),
          else: close_expression(value, start, acc)

      {start, 2} ->
        close_expression(value, start, acc)
    end
  end

  defp close_expression(value, start, acc) do
    open = start + 1

    case closing_brace(binary_part(value, open, byte_size(value) - open), open, 0) do
      nil -> Enum.reverse(acc)
      close -> find_expressions(value, close + 1, [{start, close + 1} | acc])
    end
  end

  defp closing_brace(<<?{, rest::binary>>, index, depth),
    do: closing_brace(rest, index + 1, depth + 1)

  defp closing_brace(<<?}, _rest::binary>>, index, 1), do: index

  defp closing_brace(<<?}, rest::binary>>, index, depth),
    do: closing_brace(rest, index + 1, depth - 1)

  defp closing_brace(<<_char, rest::binary>>, index, depth),
    do: closing_brace(rest, index + 1, depth)

  defp closing_brace(<<>>, _index, _depth), do: nil

  # getTaskInputV2's reference document.
  defp document(%Workflow{} = workflow) do
    definition = workflow.workflow_definition || %WorkflowDef{name: nil, version: nil}

    workflow_params = %{
      "input" => workflow.input,
      "output" => workflow.output,
      "status" => enum_string(workflow.status),
      "workflowId" => workflow.workflow_id,
      "parentWorkflowId" => workflow.parent_workflow_id,
      "parentWorkflowTaskId" => workflow.parent_workflow_task_id,
      "workflowType" => definition.name,
      "version" => definition.version,
      "correlationId" => workflow.correlation_id,
      "reasonForIncompletion" => workflow.reason_for_incompletion,
      "schemaVersion" => workflow.workflow_definition && definition.schema_version,
      "variables" => workflow.variables
    }

    tasks = Enum.reject(workflow.tasks || [], &is_nil/1)
    latest = Map.new(tasks, &{&1.reference_task_name, &1})

    Enum.reduce(tasks, %{"workflow" => workflow_params}, fn %Task{reference_task_name: ref},
                                                            doc ->
      task = Map.fetch!(latest, ref)
      Map.put(doc, task_key(task), task_params(task))
    end)
  end

  defp task_key(%Task{reference_task_name: ref} = task) do
    if Task.loop_over_task?(task), do: remove_iteration(ref), else: ref
  end

  # TaskUtils.removeIterationFromTaskRefName: Java's String#split drops trailing empty tokens.
  defp remove_iteration(ref) do
    case ref
         |> String.split(@loop_task_delimiter)
         |> Enum.reverse()
         |> Enum.drop_while(&(&1 == "")) do
      [] -> ref
      tokens -> List.last(tokens)
    end
  end

  defp task_params(%Task{} = task) do
    params = %{
      "input" => task.input_data,
      "output" => task.output_data,
      "taskType" => task.task_type,
      "referenceTaskName" => task.reference_task_name,
      "retryCount" => task.retry_count,
      "correlationId" => task.correlation_id,
      "pollCount" => task.poll_count,
      "taskDefName" => task_def_name(task),
      "scheduledTime" => task.scheduled_time,
      "startTime" => task.start_time,
      "endTime" => task.end_time,
      "workflowInstanceId" => task.workflow_instance_id,
      "taskId" => task.task_id,
      "reasonForIncompletion" => task.reason_for_incompletion,
      "callbackAfterSeconds" => task.callback_after_seconds,
      "workerId" => task.worker_id,
      "iteration" => task.iteration
    }

    if task.status, do: Map.put(params, "status", enum_string(task.status)), else: params
  end

  # TaskModel#getTaskDefName falls back to the task type when the name is null or empty.
  defp task_def_name(%Task{task_def_name: name, task_type: type}) when name in [nil, ""], do: type
  defp task_def_name(%Task{task_def_name: name}), do: name

  defp enum_string(nil), do: nil
  defp enum_string(status), do: Codec.enum_name(status)

  defp template(%TaskDef{input_template: template}) when is_map(template), do: template
  defp template(_task_def), do: %{}

  # Map#putIfAbsent: also replaces keys mapped to null.
  defp put_absent(input, template) do
    Enum.reduce(template, input, fn {key, value}, acc ->
      if Map.get(acc, key) == nil, do: Map.put(acc, key, value), else: acc
    end)
  end

  defp replace_map(input, doc, task_id) do
    Map.new(input, fn {key, value} -> {key, replace_value(value, doc, task_id)} end)
  end

  defp replace_value(value, doc, task_id) when is_binary(value),
    do: replace_variables(value, doc, task_id, 0)

  defp replace_value(value, doc, task_id) when is_map(value), do: replace_map(value, doc, task_id)

  defp replace_value(value, doc, task_id) when is_list(value),
    do: Enum.map(value, &replace_value(&1, doc, task_id))

  defp replace_value(value, _doc, _task_id), do: value

  defp replace_variables(_value, _doc, _task_id, depth) when depth >= @max_expression_depth,
    do: nil

  defp replace_variables(value, doc, task_id, depth) do
    replacements =
      value
      |> find_expressions()
      |> Enum.flat_map(fn {start, stop} ->
        match = binary_part(value, start, stop - start)
        path = binary_part(match, 2, byte_size(match) - 3)

        case resolve(match, path, doc, task_id, depth) do
          :keep -> []
          {:value, replacement} -> [{start, stop, replacement}]
        end
      end)

    case replacements do
      [{0, stop, replacement}] when stop == byte_size(value) and depth == 0 -> replacement
      _other -> value |> splice(replacements) |> String.replace("$${", "${")
    end
  end

  defp resolve(match, path, doc, task_id, depth) do
    case replace_variables(path, doc, task_id, depth + 1) do
      nil -> {:value, nil}
      path -> resolve_path(match, path, doc, task_id)
    end
  end

  defp resolve_path(match, path, doc, task_id) do
    cond do
      String.trim(path) == "" -> {:value, ""}
      String.starts_with?(path, @secrets_prefix) -> {:value, match}
      path in @system_parameters -> system_parameter(path, task_id)
      true -> {:value, JsonPath.read(doc, path)}
    end
  end

  # EnvUtils.getSystemParametersValue: an unset value leaves the expression as written.
  defp system_parameter("CPEWF_TASK_ID", task_id) when is_binary(task_id), do: {:value, task_id}
  defp system_parameter(_name, _task_id), do: :keep

  defp splice(value, replacements) do
    {parts, last} =
      Enum.reduce(replacements, {[], 0}, fn {start, stop, replacement}, {parts, from} ->
        {[parts, binary_part(value, from, start - from), java_string(replacement)], stop}
      end)

    IO.iodata_to_binary([parts, binary_part(value, last, byte_size(value) - last)])
  end

  @doc """
  Java's `Objects.toString` of a decoded JSON value: `null`, `{k=v, ...}` for maps (keys sorted),
  `[a, b]` for lists and `Double#toString` for floats.
  """
  @spec java_string(json()) :: String.t()
  def java_string(nil), do: "null"
  def java_string(value) when is_binary(value), do: value
  def java_string(value) when is_boolean(value), do: Atom.to_string(value)
  def java_string(value) when is_integer(value), do: Integer.to_string(value)
  def java_string(value) when is_float(value), do: java_double(value)

  def java_string(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &java_string/1) <> "]"

  def java_string(value) when is_map(value) do
    "{" <>
      (value |> Enum.sort() |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{java_string(v)}" end)) <>
      "}"
  end

  # Double#toString: plain notation for 1e-3 <= |d| < 1e7, otherwise d.dddE<n>, always with
  # at least one fractional digit.
  defp java_double(value) when value == 0 do
    <<sign::1, _rest::63>> = <<value::float>>
    if sign == 1, do: "-0.0", else: "0.0"
  end

  defp java_double(value) do
    sign = if value < 0, do: "-", else: ""
    magnitude = abs(value)
    {digits, exponent} = decimal_digits(magnitude)

    body =
      if magnitude >= 1.0e-3 and magnitude < 1.0e7,
        do: plain(digits, exponent),
        else: scientific(digits, exponent)

    sign <> body
  end

  # Digits and exponent such that value = 0.<digits> * 10^exponent: the shortest round-trip
  # digits, except that Java always writes at least two significant digits (d.d), choosing the
  # two-digit decimal closest to the value. That only differs from "<d>.0" for subnormals such
  # as Double.MIN_VALUE (4.9E-324).
  defp decimal_digits(value) do
    case shortest_digits(value) do
      {<<_digit>>, _exponent} -> two_digits(value)
      digits -> digits
    end
  end

  defp two_digits(value) do
    [mantissa, exponent] = value |> :erlang.float_to_binary(scientific: 1) |> String.split("e")
    <<first, ?., second>> = mantissa
    digits = String.trim_trailing(<<first, second>>, "0")
    {digits, String.to_integer(exponent) + 1}
  end

  defp shortest_digits(value) do
    {mantissa, exponent} =
      case value |> :erlang.float_to_binary([:short]) |> String.split("e") do
        [mantissa] -> {mantissa, 0}
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
      end

    {integer, fraction} =
      case String.split(mantissa, ".") do
        [integer] -> {integer, ""}
        [integer, fraction] -> {integer, fraction}
      end

    all = integer <> fraction
    trimmed = String.trim_leading(all, "0")
    leading_zeros = byte_size(all) - byte_size(trimmed)

    {String.trim_trailing(trimmed, "0"), byte_size(integer) + exponent - leading_zeros}
  end

  defp plain(digits, exponent) when exponent <= 0,
    do: "0." <> String.duplicate("0", -exponent) <> digits

  defp plain(digits, exponent) when exponent >= byte_size(digits),
    do: digits <> String.duplicate("0", exponent - byte_size(digits)) <> ".0"

  defp plain(digits, exponent) do
    binary_part(digits, 0, exponent) <>
      "." <> binary_part(digits, exponent, byte_size(digits) - exponent)
  end

  defp scientific(<<first::binary-size(1), rest::binary>>, exponent) do
    fraction = if rest == "", do: "0", else: rest
    first <> "." <> fraction <> "E" <> Integer.to_string(exponent - 1)
  end
end
