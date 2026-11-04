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
    "workflow_get_options" => {:response, :workflow},
    # Phase 6 (ADR 0025, decision 7).
    "metadata_register_ops_taskdefs" => {:request, {:list, :task_def}},
    "metadata_register_workflow_ops" => {:request, :workflow_def},
    "metadata_register_workflow_ops_v2" => {:request, :workflow_def},
    "metadata_register_workflow_ops_waits" => {:request, :workflow_def},
    "metadata_register_workflow_ops_idle" => {:request, :workflow_def},
    "metadata_register_workflow_ops_callback" => {:request, :workflow_def},
    "metadata_register_workflow_ops_child" => {:request, :workflow_def},
    "metadata_register_workflow_ops_noop" => {:request, :workflow_def},
    "metadata_register_workflow_ops_loop" => {:request, :workflow_def},
    "metadata_register_workflow_ops_mid" => {:request, :workflow_def},
    "metadata_register_workflow_ops_top" => {:request, :workflow_def},
    "metadata_register_workflow_ops_parent" => {:request, :workflow_def},
    "metadata_register_workflow_ops_signal_parent" => {:request, :workflow_def},
    "metadata_list_workflows" => {:response, {:list, :workflow_def}},
    "metadata_list_workflows_classifier" => {:response, {:list, :workflow_def}},
    "metadata_list_workflows_classifier_agent" => {:response, {:list, :workflow_def}},
    "metadata_workflow_latest_versions" => {:response, {:list, :workflow_def}},
    "metadata_validate_workflow" => {:request, :workflow_def},
    "workflow_get_running_not_removed" => {:response, :workflow},
    "workflow_correlated" => {:response, {:list, :workflow}},
    "workflow_correlated_closed" => {:response, {:list, :workflow}},
    "workflow_correlated_closed_tasks" => {:response, {:list, :workflow}},
    "workflow_get_signal" => {:response, :workflow},
    "workflow_get_signal_no_wait" => {:response, :workflow},
    "workflow_get_signaled" => {:response, :workflow},
    "workflow_get_signal_parent" => {:response, :workflow},
    "workflow_get_signal_child" => {:response, :workflow},
    "workflow_get_ref_updated" => {:response, :workflow},
    "task_ref_update_sync" => {:response, :workflow},
    "workflow_get_loop_second" => {:response, :workflow},
    "workflow_get_loop_completed" => {:response, :workflow},
    "workflow_get_life_v2" => {:response, :workflow},
    "workflow_get_paused" => {:response, :workflow},
    "workflow_correlated_paused" => {:response, {:list, :workflow}},
    "workflow_correlated_paused_closed" => {:response, {:list, :workflow}},
    "workflow_get_resumed" => {:response, :workflow},
    "workflow_get_skip" => {:response, :workflow},
    "workflow_get_skipped" => {:response, :workflow},
    "workflow_get_skip_completed" => {:response, :workflow},
    "task_poll_callback" => {:response, :task},
    "workflow_get_callback" => {:response, :workflow},
    "workflow_get_callback_reset" => {:response, :workflow},
    "task_poll_callback_reset" => {:response, :task},
    "workflow_get_retry" => {:response, :workflow},
    "workflow_get_retry_failed" => {:response, :workflow},
    "workflow_get_retried" => {:response, :workflow},
    "workflow_get_restarted" => {:response, :workflow},
    "workflow_get_restarted_latest" => {:response, :workflow},
    "workflow_get_rerun" => {:response, :workflow},
    "workflow_get_rerun_b" => {:response, :workflow},
    "workflow_get_rerun_from_task" => {:response, :workflow},
    "workflow_get_rerun_whole" => {:response, :workflow},
    "workflow_get_parent" => {:response, :workflow},
    "workflow_get_parent_child" => {:response, :workflow},
    "workflow_get_rerun_sub_workflow" => {:response, :workflow},
    "workflow_get_rerun_new_child" => {:response, :workflow},
    "workflow_get_rerun_child_parent" => {:response, :workflow},
    "workflow_get_rerun_child" => {:response, :workflow},
    "workflow_get_top" => {:response, :workflow},
    "workflow_get_mid" => {:response, :workflow},
    "workflow_get_child_first" => {:response, :workflow},
    "workflow_get_mid_retried" => {:response, :workflow},
    "workflow_get_child_second" => {:response, :workflow},
    "workflow_get_mid_failed" => {:response, :workflow},
    "workflow_get_top_failed" => {:response, :workflow},
    "workflow_get_rerun_top" => {:response, :workflow},
    "workflow_get_rerun_mid" => {:response, :workflow},
    "workflow_get_rerun_child_first" => {:response, :workflow},
    "workflow_get_remove" => {:response, :workflow},
    "workflow_get_bulk_restarted" => {:response, :workflow},
    "workflow_get_bulk_terminate_remove" => {:response, :workflow},
    "metadata_get_workflow_after_delete" => {:response, :workflow_def},
    # Phase 7 (ADR 0026, decision 8).
    "p7_register_taskdefs" => {:request, {:list, :task_def}},
    "p7_terminate_register_completed" => {:request, :workflow_def},
    "p7_terminate_register_failed" => {:request, :workflow_def},
    "p7_terminate_register_terminated" => {:request, :workflow_def},
    "p7_terminate_completed_get" => {:response, :workflow},
    "p7_terminate_failed_get" => {:response, :workflow},
    "p7_terminate_terminated_get" => {:response, :workflow},
    "p7_set_variable_register" => {:request, :workflow_def},
    "p7_set_variable_get" => {:response, :workflow},
    "p7_set_variable_register_big" => {:request, :workflow_def},
    "p7_set_variable_big_get" => {:response, :workflow},
    "p7_set_variable_register_fork" => {:request, :workflow_def},
    "p7_set_variable_fork_get" => {:response, :workflow},
    "p7_noop_register" => {:request, :workflow_def},
    "p7_noop_get" => {:response, :workflow},
    "p7_human_register" => {:request, :workflow_def},
    "p7_human_get" => {:response, :workflow},
    "p7_human_get_completed" => {:response, :workflow},
    "p7_exclusive_join_register" => {:request, :workflow_def},
    "p7_exclusive_join_case_get" => {:response, :workflow},
    "p7_exclusive_join_case_get_ended" => {:response, :workflow},
    "p7_exclusive_join_default_get" => {:response, :workflow},
    "p7_exclusive_join_default_get_ended" => {:response, :workflow},
    "p7_exclusive_join_failed_get" => {:response, :workflow},
    "p7_exclusive_join_failed_get_ended" => {:response, :workflow},
    "p7_dynamic_register" => {:request, :workflow_def},
    "p7_dynamic_get" => {:response, :workflow},
    "p7_dynamic_get_completed" => {:response, :workflow},
    "p7_dynamic_missing_get" => {:response, :workflow},
    "p7_dynamic_no_name_get" => {:response, :workflow},
    "p7_dynamic_system_get" => {:response, :workflow},
    "p7_fjd_register_simple" => {:request, :workflow_def},
    "p7_fjd_simple_get" => {:response, :workflow},
    "p7_fjd_simple_get_completed" => {:response, :workflow},
    "p7_fjd_register_param" => {:request, :workflow_def},
    "p7_fjd_param_get" => {:response, :workflow},
    "p7_fjd_param_get_completed" => {:response, :workflow},
    "p7_fjd_register_legacy" => {:request, :workflow_def},
    "p7_fjd_legacy_get" => {:response, :workflow},
    "p7_fjd_legacy_get_completed" => {:response, :workflow},
    "p7_fjd_register_no_join" => {:request, :workflow_def},
    "p7_fjd_no_join_get" => {:response, :workflow},
    "p7_fjd_retry_get" => {:response, :workflow},
    "p7_fjd_retry_get_failed" => {:response, :workflow},
    "p7_fjd_retried_get" => {:response, :workflow},
    "p7_fjd_retried_get_completed" => {:response, :workflow},
    "p7_fjd_rerun_branch_get" => {:response, :workflow},
    "p7_fjd_rerun_fork_get" => {:response, :workflow},
    "p7_inline_register" => {:request, :workflow_def},
    "p7_inline_javascript_get" => {:response, :workflow},
    "p7_inline_value_param_get" => {:response, :workflow},
    "p7_inline_unknown_get" => {:response, :workflow},
    "p7_inline_script_error_get" => {:response, :workflow},
    "p7_lambda_register" => {:request, :workflow_def},
    "p7_lambda_get" => {:response, :workflow},
    "p7_lambda_error_get" => {:response, :workflow},
    "p7_lambda_empty_get" => {:response, :workflow},
    "p7_jq_register" => {:request, :workflow_def},
    "p7_jq_get" => {:response, :workflow},
    "p7_jq_null_get" => {:response, :workflow},
    "p7_jq_syntax_get" => {:response, :workflow},
    "p7_jq_missing_get" => {:response, :workflow},
    "p7_jq_not_string_get" => {:response, :workflow},
    "p7_start_workflow_register" => {:request, :workflow_def},
    "p7_start_workflow_get" => {:response, :workflow},
    "p7_start_workflow_get_started" => {:response, :workflow},
    "p7_start_workflow_invalid_get" => {:response, :workflow},
    "p7_start_workflow_missing_get" => {:response, :workflow},
    "p7_http_register" => {:request, :workflow_def},
    "p7_http_json_get" => {:response, :workflow},
    "p7_http_post_get" => {:response, :workflow},
    "p7_http_text_get" => {:response, :workflow},
    "p7_http_number_get" => {:response, :workflow},
    "p7_http_status_299_get" => {:response, :workflow},
    "p7_http_short_404_get" => {:response, :workflow},
    "p7_http_long_400_get" => {:response, :workflow},
    "p7_http_empty_404_get" => {:response, :workflow},
    "p7_http_short_503_get" => {:response, :workflow},
    "p7_http_refused_get" => {:response, :workflow},
    "p7_http_no_uri_get" => {:response, :workflow},
    "p7_http_no_method_get" => {:response, :workflow},
    "p7_http_redirect_302_get" => {:response, :workflow},
    "p7_http_redirect_307_get" => {:response, :workflow},
    "p7_http_register_async" => {:request, :workflow_def},
    "p7_http_async_get" => {:response, :workflow},
    "p7_http_async_get_completed" => {:response, :workflow},
    "p7_http_register_async_input" => {:request, :workflow_def},
    "p7_http_async_input_get" => {:response, :workflow},
    # Phase 8 (ADR 0027, decision 7).
    "p8_register_taskdefs" => {:request, {:list, :task_def}},
    "p8_search_register" => {:request, :workflow_def},
    "p8_search_get_1" => {:response, :workflow},
    "p8_search_get_2" => {:response, :workflow},
    "p8_search_get_3" => {:response, :workflow},
    "p8_search_get_1_completed" => {:response, :workflow},
    "p8_search_get_2_failed" => {:response, :workflow},
    "p8_classified_register" => {:request, :workflow_def},
    "p8_classified_get" => {:response, :workflow},
    "p8_index_register" => {:request, :workflow_def},
    "p8_index_get" => {:response, :workflow},
    "p8_index_poll" => {:response, :task},
    "p8_index_get_extended" => {:response, :workflow},
    "p8_index_get_completed" => {:response, :workflow},
    "p8_sys_register" => {:request, :workflow_def},
    "p8_sys_get" => {:response, :workflow},
    "p8_sys_get_forked" => {:response, :workflow},
    "p8_skip_register" => {:request, :workflow_def},
    "p8_skip_get" => {:response, :workflow},
    "p8_skip_get_skipped" => {:response, :workflow},
    "p8_skip_get_completed" => {:response, :workflow},
    "p8_remove_register" => {:request, :workflow_def},
    "p8_remove_archive_get" => {:response, :workflow},
    "p8_remove_archive_get_completed" => {:response, :workflow},
    "p8_remove_delete_get" => {:response, :workflow},
    "p8_remove_delete_get_completed" => {:response, :workflow},
    "p8_child_register" => {:request, :workflow_def},
    "p8_parent_register" => {:request, :workflow_def},
    "p8_parent_get" => {:response, :workflow},
    "p8_child_get" => {:response, :workflow},
    "p8_parent_get_failed" => {:response, :workflow},
    "p8_parent_get_retried" => {:response, :workflow},
    "p8_parent_get_terminated" => {:response, :workflow},
    "p8_parent_get_restarted" => {:response, :workflow},
    "p8_child_get_restarted" => {:response, :workflow},
    "p8_parent_get_completed" => {:response, :workflow},
    "p8_parent_get_reran" => {:response, :workflow}
  }

  # Keys holding wall-clock timestamps or durations derived from them. Generated IDs are UUIDs and
  # are handled by uuid_regex/0 instead, which also covers IDs embedded in paths and text/plain bodies.
  # The search summaries (ADR 0027, decision 3) hold the same keys as text in GMT, a task log its
  # createdTime, and bulk/search's WorkflowModel and TaskModel (decision 5) updatedTime and
  # firstScheduledTime.
  @volatile_keys ~w(
    createTime updateTime startTime endTime scheduledTime firstStartTime lastUpdated
    lastPollTime lastRetriedTime queueWaitTime executionTime createdTime updatedTime
    firstScheduledTime
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

  # A summary's text for a timestamp of 0 (TaskSummary formats every time, ADR 0027 decision 3).
  @epoch_text "1970-01-01T00:00:00.000Z"

  @doc """
  Like `normalize/1` but for comparisons that check IDs too (the replay of
  `ArchonWeb.ContractCase`): UUIDs are kept, and a timestamp of `0` (upstream's "not set") is kept
  as well, so a time written where upstream has none still differs; so is a summary's text for it,
  `"1970-01-01T00:00:00.000Z"`. Other timestamps and every duration become `"<volatile>"`.
  """
  @spec mask_times(json()) :: json()
  def mask_times(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when key in @duration_keys and not is_nil(value) ->
        {key, "<volatile>"}

      {key, value} when key in @volatile_keys and value not in [nil, 0, @epoch_text] ->
        {key, "<volatile>"}

      {key, value} ->
        {key, mask_times(value)}
    end)
  end

  def mask_times(list) when is_list(list), do: Enum.map(list, &mask_times/1)
  def mask_times(other), do: other

  @doc "Matches a generated ID (a lowercase UUID) anywhere in a string."
  @spec uuid_regex() :: Regex.t()
  def uuid_regex, do: ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
end
