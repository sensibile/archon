# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/workflow/WorkflowDef.java,
# common/.../constraints/TaskReferenceNameUniqueConstraint.java,
# common/.../utils/ConstraintParamUtil.java and common/.../utils/EnvUtils.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; bean validation
# ported to validate/2, with the JsonPath syntax check approximated (see input_path_valid?/1).

defmodule Archon.Domain.WorkflowDef do
  @moduledoc """
  Workflow definition (`POST /api/metadata/workflow`, `Workflow.workflowDefinition`).

  Besides `priv/contract/WorkflowDef.json`, upstream also writes `failureWorkflowVersion`, which
  is modelled too.
  """

  alias Archon.Domain.{
    CacheConfig,
    Codec,
    RateLimitConfig,
    SchemaDef,
    Validation,
    WorkflowTask
  }

  @type timeout_policy :: :time_out_wf | :alert_only

  @fields [
    {:owner_app, "ownerApp", :string, []},
    {:create_time, "createTime", :int, []},
    {:update_time, "updateTime", :int, []},
    {:created_by, "createdBy", :string, []},
    {:updated_by, "updatedBy", :string, []},
    {:name, "name", :string, []},
    {:description, "description", :string, []},
    {:version, "version", :int, default: 1},
    {:tasks, "tasks", {:list, {:struct, WorkflowTask}}, default: []},
    {:input_parameters, "inputParameters", {:list, :string}, default: []},
    {:output_parameters, "outputParameters", :object, default: %{}},
    {:failure_workflow, "failureWorkflow", :string, []},
    {:schema_version, "schemaVersion", :int, default: 2},
    {:restartable, "restartable", :bool, default: true},
    {:workflow_status_listener_enabled, "workflowStatusListenerEnabled", :bool, []},
    {:owner_email, "ownerEmail", :string, []},
    {:timeout_policy, "timeoutPolicy", {:enum, [:time_out_wf, :alert_only]},
     default: :alert_only},
    {:timeout_seconds, "timeoutSeconds", :int, []},
    {:variables, "variables", :object, default: %{}},
    {:input_template, "inputTemplate", :object, default: %{}},
    {:failure_workflow_version, "failureWorkflowVersion", :integer, []},
    {:workflow_status_listener_sink, "workflowStatusListenerSink", :string, []},
    {:rate_limit_config, "rateLimitConfig", {:struct, RateLimitConfig}, []},
    {:input_schema, "inputSchema", {:struct, SchemaDef}, []},
    {:output_schema, "outputSchema", {:struct, SchemaDef}, []},
    {:enforce_schema, "enforceSchema", :bool, default: true},
    {:metadata, "metadata", :object, default: %{}},
    {:cache_config, "cacheConfig", {:struct, CacheConfig}, []},
    {:masked_fields, "maskedFields", {:list, :string}, default: []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          owner_app: String.t() | nil,
          create_time: integer(),
          update_time: integer(),
          created_by: String.t() | nil,
          updated_by: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          version: integer(),
          tasks: [WorkflowTask.t() | nil] | nil,
          input_parameters: [String.t() | nil] | nil,
          output_parameters: Codec.json_object() | nil,
          failure_workflow: String.t() | nil,
          schema_version: integer(),
          restartable: boolean(),
          workflow_status_listener_enabled: boolean(),
          owner_email: String.t() | nil,
          timeout_policy: timeout_policy() | nil,
          timeout_seconds: integer(),
          variables: Codec.json_object() | nil,
          input_template: Codec.json_object() | nil,
          failure_workflow_version: integer() | nil,
          workflow_status_listener_sink: String.t() | nil,
          rate_limit_config: RateLimitConfig.t() | nil,
          input_schema: SchemaDef.t() | nil,
          output_schema: SchemaDef.t() | nil,
          enforce_schema: boolean(),
          metadata: Codec.json_object() | nil,
          cache_config: CacheConfig.t() | nil,
          masked_fields: [String.t() | nil] | nil
        }

  # EnvUtils.SystemParameters: always accepted as `${NAME}` input references.
  @system_parameters ~w(CPEWF_TASK_ID NETFLIX_ENV NETFLIX_STACK)

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = definition), do: Codec.encode(__MODULE__, @fields, definition)

  @doc "Upstream `WorkflowDef.getKey/2`: `name.version`."
  @spec key(String.t(), integer()) :: String.t()
  def key(name, version), do: "#{name}.#{version}"

  @doc "Upstream `collectTasks`: every task of the definition, nested ones included."
  @spec collect_tasks(t()) :: [WorkflowTask.t()]
  def collect_tasks(%__MODULE__{tasks: tasks}) do
    (tasks || []) |> Enum.reject(&is_nil/1) |> Enum.flat_map(&WorkflowTask.collect_tasks/1)
  end

  @doc "Upstream `getTaskByRefName`: the first task with this reference name, nested included."
  @spec task_by_ref_name(t(), String.t()) :: WorkflowTask.t() | nil
  def task_by_ref_name(%__MODULE__{} = definition, ref_name) do
    definition |> collect_tasks() |> Enum.find(&(&1.task_reference_name == ref_name))
  end

  @doc """
  Bean validation of a workflow definition. See `Archon.Domain.Validation` for `opts`.

  Ports the field annotations of `WorkflowDef` (`name` `@NotEmpty` and `@ValidNameConstraint`,
  `tasks` `@NotNull @NotEmpty` with `@Valid` elements, `schemaVersion` `@Min(2) @Max(2)`,
  `ownerEmail` `@OwnerEmailMandatoryConstraint`) and the class-level
  `@TaskReferenceNameUniqueConstraint`, which also checks `${...}` references in the top-level
  tasks' `inputParameters`.
  """
  @spec validate(t(), Validation.opts()) :: Validation.result()
  def validate(%__MODULE__{} = d, opts \\ []) do
    Validation.result(
      Validation.not_empty("name", d.name, "WorkflowDef name cannot be null or empty") ++
        Validation.valid_name("name", d.name, opts) ++
        tasks_errors(d.tasks) ++
        Validation.min(
          "schemaVersion",
          d.schema_version,
          2,
          "workflowDef schemaVersion: 2 is only supported"
        ) ++
        Validation.max(
          "schemaVersion",
          d.schema_version,
          2,
          "workflowDef schemaVersion: 2 is only supported"
        ) ++
        Validation.owner_email(d.owner_email, opts) ++
        unique_ref_name_errors(d) ++
        input_parameter_errors(d)
    )
  end

  defp tasks_errors(nil),
    do: [{"tasks", "must not be null"}, {"tasks", "WorkflowTask list cannot be empty"}]

  defp tasks_errors([]), do: [{"tasks", "WorkflowTask list cannot be empty"}]

  defp tasks_errors(tasks) do
    tasks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {nil, _index} -> []
      {task, index} -> task |> WorkflowTask.errors() |> Validation.nest("tasks[#{index}]")
    end)
  end

  defp unique_ref_name_errors(d) do
    d
    |> collect_tasks()
    |> Enum.reduce({MapSet.new(), []}, fn %WorkflowTask{task_reference_name: ref},
                                          {seen, errors} ->
      if MapSet.member?(seen, ref) do
        message =
          "taskReferenceName: #{ref} should be unique across tasks for a given " <>
            "workflowDefinition: #{d.name}"

        {seen, [{"", message} | errors]}
      else
        {MapSet.put(seen, ref), errors}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # TaskReferenceNameUniqueValidator#verifyTaskInputParameters: only top-level tasks are checked.
  defp input_parameter_errors(%__MODULE__{tasks: tasks} = d) do
    (tasks || [])
    |> Enum.reject(&(is_nil(&1) or is_nil(&1.input_parameters)))
    |> Enum.flat_map(fn task -> input_map_errors(task.input_parameters, task.name, d) end)
    |> Enum.map(&{"", &1})
  end

  # ConstraintParamUtil#validateInputParam
  defp input_map_errors(input, task_name, d) do
    input
    |> Enum.sort()
    |> Enum.flat_map(fn {key, value} -> input_value_errors(key, value, task_name, d) end)
  end

  defp input_value_errors(key, value, task_name, d) when is_binary(value),
    do: reference_errors(key, value, task_name, d)

  defp input_value_errors(_key, value, task_name, d) when is_map(value),
    do: input_map_errors(value, task_name, d)

  defp input_value_errors(key, values, task_name, d) when is_list(values),
    do: Enum.flat_map(values, &input_value_errors(key, &1, task_name, d))

  defp input_value_errors(_key, _value, _task_name, _d), do: []

  # ConstraintParamUtil#extractParamPathComponentsFromString
  defp reference_errors(key, value, task_name, d) do
    value
    |> references()
    |> Enum.flat_map(fn path ->
      cond do
        not input_path_valid?(path) ->
          ["key: #{key} input parameter value: #{path} is not valid"]

        environment_variable?(path) ->
          # Accepted as an environment reference. Upstream re-reads the value with
          # getenv/getProperty fallbacks that cannot come back empty at this point.
          []

        true ->
          undefined_ref_errors(path, key, value, task_name, d)
      end
    end)
  end

  defp undefined_ref_errors(path, key, value, task_name, d) do
    ref = path |> String.split(".") |> hd()

    if ref == "workflow" or task_by_ref_name(d, ref) != nil do
      []
    else
      [
        "taskReferenceName: #{ref} for given task: #{task_name} input value: #{key} " <>
          "of input parameter: #{value} is not defined in workflow definition."
      ]
    end
  end

  # Upstream splits on `(?=(?<!\$)\$\{)|(?<=\})` and keeps the pieces shaped `${...}`.
  defp references(value) do
    ~r/(?=(?<!\$)\$\{)|(?<=\})/
    |> Regex.split(value)
    |> Enum.filter(&(String.starts_with?(&1, "${") and String.ends_with?(&1, "}")))
    |> Enum.map(&binary_part(&1, 2, byte_size(&1) - 3))
  end

  @doc """
  Approximates upstream's `JsonPath.compile(path)` success check used for `${...}` input
  references.

  Rejects what Jayway JsonPath rejects in the paths Conductor uses: a blank path, whitespace
  outside bracket notation (`workflow.input.Space Value`), a trailing `.`, and unbalanced
  brackets or quotes. Full JsonPath grammar (filters, functions) is not checked.
  """
  @spec input_path_valid?(String.t()) :: boolean()
  def input_path_valid?(path) do
    trimmed = String.trim(path)

    trimmed != "" and not String.ends_with?(trimmed, ".") and
      balanced_without_bare_space?(String.to_charlist(trimmed), 0, nil)
  end

  defp balanced_without_bare_space?([], depth, quote), do: depth == 0 and quote == nil

  defp balanced_without_bare_space?([q | rest], depth, q),
    do: balanced_without_bare_space?(rest, depth, nil)

  defp balanced_without_bare_space?([_c | rest], depth, quote) when quote != nil,
    do: balanced_without_bare_space?(rest, depth, quote)

  defp balanced_without_bare_space?([q | rest], depth, nil) when q in [?', ?"] and depth > 0,
    do: balanced_without_bare_space?(rest, depth, q)

  defp balanced_without_bare_space?([?[ | rest], depth, nil),
    do: balanced_without_bare_space?(rest, depth + 1, nil)

  defp balanced_without_bare_space?([?] | _rest], 0, nil), do: false

  defp balanced_without_bare_space?([?] | rest], depth, nil),
    do: balanced_without_bare_space?(rest, depth - 1, nil)

  defp balanced_without_bare_space?([c | rest], depth, nil) do
    if depth == 0 and c in [?\s, ?\t, ?\n, ?\r] do
      false
    else
      balanced_without_bare_space?(rest, depth, nil)
    end
  end

  # EnvUtils#isEnvironmentVariable
  defp environment_variable?(path), do: path in @system_parameters or System.get_env(path) != nil
end
