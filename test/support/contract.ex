defmodule Archon.Contract do
  @moduledoc """
  Helpers for checking JSON against the upstream Conductor contract.

  Schemas live in `priv/contract/` and golden fixtures in `test/fixtures/contract/`
  (see the README in each directory). The same helpers are meant to validate Archon's own
  serialized structs once they exist, e.g. `Archon.Contract.validate(:task, encoded_task)`.
  """

  @schemas %{
    workflow_def: "WorkflowDef.json",
    workflow: "Workflow.json",
    task_def: "TaskDef.json",
    task: "Task.json"
  }

  @fixtures_dir Path.expand("../fixtures/contract", __DIR__)

  # Which part of each captured exchange is checked against which schema
  # (test/archon/contract_test.exs; the replay of ArchonWeb.ContractCase checks Archon's responses
  # against the same schemas).
  @fixture_schemas %{
    "metadata_register_taskdefs" => {:request, {:list, :task_def}},
    "metadata_register_taskdefs_single" => {:request, :task_def},
    "metadata_register_workflow_simple" => {:request, :workflow_def},
    "metadata_register_workflow_switch" => {:request, :workflow_def},
    "metadata_register_workflow_fork" => {:request, :workflow_def},
    "metadata_register_workflow_overwrite" => {:request, :workflow_def},
    "metadata_update_taskdef" => {:request, :task_def},
    "metadata_update_workflows" => {:request, {:list, :workflow_def}},
    "metadata_get_taskdef" => {:response, :task_def},
    "metadata_get_taskdef_updated" => {:response, :task_def},
    "metadata_list_taskdefs" => {:response, {:list, :task_def}},
    "metadata_get_workflow" => {:response, :workflow_def},
    "metadata_get_workflow_switch" => {:response, :workflow_def},
    "metadata_get_workflow_fork" => {:response, :workflow_def},
    "metadata_get_workflow_overwritten" => {:response, :workflow_def},
    "metadata_get_workflow_bulk_latest" => {:response, :workflow_def},
    "task_poll_simple_a" => {:response, :task},
    "task_poll_simple_b" => {:response, :task},
    "task_poll_switch_b" => {:response, :task},
    "task_poll_fork_b" => {:response, :task},
    "task_poll_inline_c" => {:response, :task},
    "task_batch_poll_fork_a" => {:response, {:list, :task}},
    "task_batch_poll_empty" => {:response, {:list, :task}},
    "task_get" => {:response, :task},
    "task_update_v2_next" => {:response, :task},
    "workflow_get_running" => {:response, :workflow},
    "workflow_get_running_without_tasks" => {:response, :workflow},
    "workflow_get_inline" => {:response, :workflow},
    "workflow_get_completed_simple" => {:response, :workflow},
    "workflow_get_completed_switch" => {:response, :workflow},
    "workflow_get_completed_fork" => {:response, :workflow},
    "workflow_get_without_tasks" => {:response, :workflow},
    "workflow_get_terminated" => {:response, :workflow},
    "task_batch_poll_count_zero" => {:response, {:list, :task}},
    "workflow_get_request_defaults" => {:response, :workflow},
    "workflow_get_options" => {:response, :workflow}
  }

  # Keys holding wall-clock timestamps or durations derived from them. Generated IDs are UUIDs and
  # are handled by uuid_regex/0 instead, which also covers IDs embedded in paths and text/plain bodies.
  @volatile_keys ~w(
    createTime updateTime startTime endTime scheduledTime firstStartTime lastUpdated
    lastPollTime queueWaitTime executionTime
  )

  @type schema_name :: :workflow_def | :workflow | :task_def | :task
  @type json :: nil | boolean() | number() | String.t() | [json()] | %{String.t() => json()}
  @type error :: {String.t(), String.t()}

  @doc "Names of the available schemas."
  @spec schema_names() :: [schema_name()]
  def schema_names, do: Map.keys(@schemas)

  @doc "Returns the resolved schema, loading and caching it on first use."
  @spec schema(schema_name()) :: ExJsonSchema.Schema.Root.t()
  def schema(name) when is_map_key(@schemas, name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        resolved =
          :archon
          |> Application.app_dir(Path.join("priv/contract", Map.fetch!(@schemas, name)))
          |> File.read!()
          |> JSON.decode!()
          |> ExJsonSchema.Schema.resolve()

        :persistent_term.put(key, resolved)
        resolved

      resolved ->
        resolved
    end
  end

  @doc "Validates decoded JSON against the named schema."
  @spec validate(schema_name(), json()) :: :ok | {:error, [error()]}
  def validate(name, data) do
    case ExJsonSchema.Validator.validate(schema(name), data) do
      :ok -> :ok
      {:error, errors} -> {:error, Enum.map(errors, fn {msg, path} -> {path, msg} end)}
    end
  end

  @doc "Validates every element of a JSON array against the named schema."
  @spec validate_each(schema_name(), [json()]) :: :ok | {:error, [error()]}
  def validate_each(name, items) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> indexed_errors(name, item, index) end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp indexed_errors(name, item, index) do
    case validate(name, item) do
      :ok -> []
      {:error, errors} -> Enum.map(errors, fn {path, msg} -> {"[#{index}]" <> path, msg} end)
    end
  end

  @doc """
  The schema each fixture is checked against: `{:request | :response, schema}`, where `schema` is
  a schema name or `{:list, name}` for an array of them.
  """
  @spec fixture_schemas() :: %{
          String.t() => {:request | :response, schema_name() | {:list, schema_name()}}
        }
  def fixture_schemas, do: @fixture_schemas

  @doc "Validates decoded JSON against a `fixture_schemas/0` entry's schema."
  @spec validate_schema(schema_name() | {:list, schema_name()}, json()) ::
          :ok | {:error, [error()]}
  def validate_schema({:list, name}, items) when is_list(items), do: validate_each(name, items)

  def validate_schema({:list, _name}, _other),
    do: {:error, [{"#", "Type mismatch. Expected Array."}]}

  def validate_schema(name, data), do: validate(name, data)

  @doc "Lists fixture names (file names without `.json`)."
  @spec fixture_names() :: [String.t()]
  def fixture_names do
    @fixtures_dir
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.sort()
  end

  @doc ~S'Loads a captured exchange: `%{"request" => ..., "response" => ...}`.'
  @spec fixture(String.t()) :: %{String.t() => json()}
  def fixture(name) do
    @fixtures_dir |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()
  end

  @doc """
  Replaces volatile values at any depth so two captures, or an Archon response and a fixture,
  can be compared with `==`: timestamp keys become `"<volatile>"` and UUIDs inside any string
  (IDs, request paths, text/plain bodies) become `"<uuid>"`.
  """
  @spec normalize(json()) :: json()
  def normalize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when key in @volatile_keys and not is_nil(value) -> {key, "<volatile>"}
      {key, value} -> {key, normalize(value)}
    end)
  end

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(string) when is_binary(string), do: Regex.replace(uuid_regex(), string, "<uuid>")
  def normalize(other), do: other

  # Durations derived from the clock: any value, 0 included, may differ between runs.
  @duration_keys ~w(queueWaitTime executionTime)

  @doc """
  Like `normalize/1` but for comparisons that check IDs too (the replay of
  `ArchonWeb.ContractCase`): UUIDs are kept, and a timestamp of `0` (upstream's "not set") is kept
  as well, so a time written where upstream has none still differs. Other timestamps and every
  duration become `"<volatile>"`.
  """
  @spec mask_times(json()) :: json()
  def mask_times(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when key in @duration_keys and not is_nil(value) -> {key, "<volatile>"}
      {key, value} when key in @volatile_keys and value not in [nil, 0] -> {key, "<volatile>"}
      {key, value} -> {key, mask_times(value)}
    end)
  end

  def mask_times(list) when is_list(list), do: Enum.map(list, &mask_times/1)
  def mask_times(other), do: other

  @doc "Matches a generated ID (a lowercase UUID) anywhere in a string."
  @spec uuid_regex() :: Regex.t()
  def uuid_regex, do: ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
end
