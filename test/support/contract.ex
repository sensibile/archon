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

  defp uuid_regex, do: ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
end
