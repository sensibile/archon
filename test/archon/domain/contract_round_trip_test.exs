defmodule Archon.Domain.ContractRoundTripTest do
  @moduledoc """
  Every golden fixture body that is a domain object must decode, encode back to the same JSON
  (after `Archon.Contract.normalize/1`) and pass the upstream JSON schema.
  """

  use ExUnit.Case, async: true

  alias Archon.Contract

  alias Archon.Domain.{
    BulkResponse,
    ErrorResponse,
    Task,
    TaskDef,
    TaskResult,
    Workflow,
    WorkflowDef
  }

  # Which domain model each fixture body decodes to. Every fixture is listed so that a newly
  # captured one cannot be skipped silently; [] means the exchange carries no domain object.
  @models %{
    "metadata_get_taskdef" => [response: TaskDef],
    "metadata_get_workflow" => [response: WorkflowDef],
    "metadata_get_workflow_fork" => [response: WorkflowDef],
    "metadata_get_workflow_switch" => [response: WorkflowDef],
    "metadata_register_taskdefs" => [request: {:list, TaskDef}],
    "metadata_register_workflow_conflict" => [request: WorkflowDef],
    "metadata_register_workflow_fork" => [request: WorkflowDef],
    "metadata_register_workflow_simple" => [request: WorkflowDef],
    "metadata_register_workflow_switch" => [request: WorkflowDef],
    "task_batch_poll_fork_a" => [response: {:list, Task}],
    "task_get" => [response: Task],
    "task_poll_fork_b" => [response: Task],
    "task_poll_simple_a" => [response: Task],
    "task_poll_simple_b" => [response: Task],
    "task_poll_switch_b" => [response: Task],
    "task_update_fork_a" => [request: TaskResult],
    "task_update_fork_b" => [request: TaskResult],
    "task_update_simple_a" => [request: TaskResult],
    "task_update_switch_b" => [request: TaskResult],
    "task_update_v2_simple_b" => [request: TaskResult],
    "workflow_get_completed_fork" => [response: Workflow],
    "workflow_get_completed_simple" => [response: Workflow],
    "workflow_get_completed_switch" => [response: Workflow],
    "workflow_get_running" => [response: Workflow],
    "workflow_get_terminated" => [response: Workflow],
    "workflow_get_without_tasks" => [response: Workflow],
    # Error bodies, text/plain IDs, empty bodies, raw workflow input maps, the
    # StartWorkflowRequest (outside Phase 1) and the status-only workflow summary.
    "metadata_get_taskdef_not_found" => [],
    "metadata_get_workflow_not_found" => [],
    "task_poll_empty" => [],
    "workflow_get_not_found" => [response: ErrorResponse],
    "workflow_get_status" => [],
    "workflow_start_fork" => [],
    "workflow_start_request_switch" => [],
    "workflow_start_simple" => [],
    "workflow_start_to_terminate" => [],
    "workflow_terminate" => [],
    # Added for Phase 5 (ADR 0023, decision 6). Requests rejected for their values (a null
    # primitive, a fraction, a missing name) are not round-tripped: decoding changes them.
    "metadata_list_taskdefs" => [response: {:list, TaskDef}],
    "metadata_register_taskdefs_single" => [request: TaskDef],
    "metadata_update_taskdef" => [request: TaskDef],
    "metadata_get_taskdef_updated" => [response: TaskDef],
    "metadata_update_taskdef_not_found" => [request: TaskDef],
    "metadata_register_workflow_overwrite" => [request: WorkflowDef],
    "metadata_get_workflow_overwritten" => [response: WorkflowDef],
    "metadata_update_workflows" => [request: {:list, WorkflowDef}],
    "metadata_get_workflow_bulk_latest" => [response: WorkflowDef],
    "workflow_get_running_without_tasks" => [response: Workflow],
    "workflow_get_inline" => [response: Workflow],
    "task_poll_inline_c" => [response: Task],
    "task_update_v2_next" => [request: TaskResult, response: Task],
    "task_batch_poll_empty" => [response: {:list, Task}],
    "task_update_not_found" => [request: TaskResult],
    "task_update_workflow_not_found" => [request: TaskResult],
    "task_update_v2_not_found" => [request: TaskResult],
    "health" => [],
    "health_api" => [],
    "metadata_register_taskdefs_empty" => [],
    "metadata_register_taskdefs_no_name" => [],
    "metadata_register_taskdefs_blank_name" => [],
    "metadata_register_taskdefs_coerced" => [response: ErrorResponse],
    "metadata_register_workflow_no_tasks" => [],
    "metadata_get_workflow_version_not_found" => [],
    "metadata_update_workflows_invalid" => [],
    "metadata_get_workflow_bulk_rejected" => [],
    "metadata_update_workflows_empty" => [],
    "workflow_start_not_found" => [],
    "workflow_start_request_not_found" => [],
    "workflow_start_inline" => [],
    "workflow_start_inline_second" => [],
    "workflow_get_status_default" => [],
    "workflow_get_status_all" => [],
    "workflow_get_status_not_found" => [],
    "workflow_terminate_completed" => [],
    "workflow_terminate_not_found" => [],
    "task_get_not_found" => [],
    "task_update_invalid" => [response: ErrorResponse],
    "task_update_v2_invalid" => [response: ErrorResponse],
    "route_not_found" => [response: ErrorResponse],
    "route_later_workflow_search" => [],
    "route_later_workflow_running" => [],
    "route_later_workflow_test" => [],
    "route_later_metadata_names" => [],
    "route_later_tasks_search" => [],
    "route_method_patch_workflow" => [],
    "route_method_put_task" => [],
    "request_body_not_json" => [],
    "request_query_not_number" => [],
    "request_query_not_boolean" => [],
    # Added in slice 5f. Bodies the codec refuses (wrong types, null elements, missing names)
    # are not round-tripped.
    "metadata_register_taskdefs_missing_body" => [],
    "metadata_update_taskdef_null_body" => [],
    "metadata_register_workflow_missing_body" => [],
    "metadata_update_workflows_null_body" => [],
    "workflow_start_request_missing_body" => [],
    "workflow_start_null_body" => [],
    "task_update_missing_body" => [],
    "task_update_v2_null_body" => [],
    "metadata_register_workflow_no_name" => [],
    "metadata_register_workflow_overwrite_invalid" => [],
    "metadata_update_taskdef_invalid" => [],
    "metadata_update_workflows_null_element" => [],
    "metadata_register_taskdefs_null_element" => [],
    "metadata_register_taskdefs_wrong_type" => [],
    "task_update_wrong_type" => [],
    "workflow_start_request_wrong_type" => [],
    "workflow_start_not_object" => [],
    "metadata_register_workflow_query_not_boolean" => [request: WorkflowDef],
    "metadata_get_workflow_query_not_number" => [],
    "workflow_start_query_not_number" => [],
    "workflow_get_status_query_not_boolean" => [],
    "task_update_v2_invalid_both" => [response: ErrorResponse],
    "task_batch_poll_timeout_too_long" => [],
    "task_batch_poll_count_zero" => [response: {:list, Task}],
    "task_poll_domain_empty" => [],
    "workflow_start_request_no_name" => [],
    "workflow_start_request_priority_too_high" => [],
    "workflow_start_request_invalid_definition" => [],
    "workflow_start_request_blank_name" => [],
    "workflow_start_request_null_input" => [],
    "workflow_start_request_external_input" => [],
    "workflow_start_priority_too_low" => [],
    "workflow_start_version_not_found" => [],
    "workflow_get_status_no_correlation" => [],
    "workflow_terminate_terminated" => [],
    "workflow_start_request_defaults" => [],
    "workflow_get_request_defaults" => [response: Workflow],
    "workflow_start_request_inline_other_name" => [],
    "workflow_start_options" => [],
    "workflow_get_options" => [response: Workflow],
    # Phase 6 (ADR 0025, decision 7). Bodies of the models the later slices add
    # (SearchResult, WorkflowDefSummary, SignalResponse, RerunWorkflowRequest) are [] until
    # slice 6h classifies them.
    "metadata_register_ops_taskdefs" => [request: {:list, TaskDef}],
    "metadata_register_workflow_ops" => [request: WorkflowDef],
    "metadata_register_workflow_ops_v2" => [request: WorkflowDef],
    "metadata_register_workflow_ops_waits" => [request: WorkflowDef],
    "metadata_register_workflow_ops_idle" => [request: WorkflowDef],
    "metadata_register_workflow_ops_callback" => [request: WorkflowDef],
    "metadata_register_workflow_ops_child" => [request: WorkflowDef],
    "metadata_register_workflow_ops_noop" => [request: WorkflowDef],
    "metadata_register_workflow_ops_loop" => [request: WorkflowDef],
    "metadata_register_workflow_ops_mid" => [request: WorkflowDef],
    "metadata_register_workflow_ops_top" => [request: WorkflowDef],
    "metadata_register_workflow_ops_parent" => [request: WorkflowDef],
    "metadata_register_workflow_ops_signal_parent" => [request: WorkflowDef],
    "metadata_list_workflows" => [response: {:list, WorkflowDef}],
    "metadata_list_workflows_classifier" => [response: {:list, WorkflowDef}],
    "metadata_list_workflows_classifier_agent" => [response: {:list, WorkflowDef}],
    "metadata_workflow_names_and_versions" => [],
    "metadata_workflow_names" => [],
    "metadata_workflow_latest_versions" => [response: {:list, WorkflowDef}],
    "metadata_workflow_versions" => [],
    "metadata_workflow_versions_missing" => [],
    "metadata_validate_workflow" => [request: WorkflowDef],
    "metadata_validate_workflow_invalid" => [response: ErrorResponse],
    "metadata_get_workflow_not_validated" => [response: ErrorResponse],
    "metadata_delete_workflow_not_found" => [response: ErrorResponse],
    "metadata_delete_workflow_version_not_number" => [response: ErrorResponse],
    "metadata_delete_taskdef_not_found" => [response: ErrorResponse],
    "workflow_pause_not_found" => [response: ErrorResponse],
    "workflow_resume_not_found" => [response: ErrorResponse],
    "workflow_retry_not_found" => [response: ErrorResponse],
    "workflow_restart_not_found" => [response: ErrorResponse],
    "workflow_rerun_not_found" => [response: ErrorResponse],
    "workflow_skiptask_not_found" => [response: ErrorResponse],
    "workflow_resetcallbacks_not_found" => [response: ErrorResponse],
    "workflow_remove_not_found" => [response: ErrorResponse],
    "workflow_terminate_remove_not_found" => [response: ErrorResponse],
    "workflow_pause_completed" => [response: ErrorResponse],
    "workflow_resume_completed" => [response: ErrorResponse],
    "workflow_retry_completed" => [response: ErrorResponse],
    "workflow_rerun_task_not_found" => [response: ErrorResponse],
    "workflow_skiptask_completed" => [response: ErrorResponse],
    "workflow_resetcallbacks_completed" => [response: ErrorResponse],
    "workflow_terminate_remove_completed" => [response: ErrorResponse],
    "workflow_resume_running" => [],
    "workflow_retry_running" => [response: ErrorResponse],
    "workflow_restart_running" => [response: ErrorResponse],
    "workflow_rerun_running" => [response: ErrorResponse],
    "workflow_skiptask_unknown_ref" => [response: ErrorResponse],
    "workflow_skiptask_existing_ref" => [response: ErrorResponse],
    "workflow_remove_running" => [response: ErrorResponse],
    "workflow_get_running_not_removed" => [response: Workflow],
    "workflow_tasks" => [],
    "workflow_tasks_status" => [],
    "workflow_tasks_status_list" => [],
    "workflow_tasks_status_comma" => [],
    "workflow_tasks_status_none" => [],
    "workflow_tasks_page" => [],
    "workflow_tasks_count_negative" => [response: ErrorResponse],
    "workflow_tasks_start_negative" => [response: ErrorResponse],
    "workflow_tasks_start_past_end" => [],
    "workflow_tasks_not_found" => [response: ErrorResponse],
    "workflow_correlated" => [response: {:list, Workflow}],
    "workflow_correlated_closed" => [response: {:list, Workflow}],
    "workflow_correlated_closed_tasks" => [response: {:list, Workflow}],
    "workflow_correlated_post" => [],
    "workflow_correlated_post_closed" => [],
    "workflow_correlated_post_empty" => [],
    "workflow_running" => [],
    "workflow_running_other_version" => [],
    "workflow_running_time" => [],
    "workflow_running_time_other_version" => [],
    "workflow_running_unknown" => [],
    "task_ref_update_workflow_not_found" => [],
    "task_ref_update_sync_workflow_not_found" => [response: ErrorResponse],
    "task_ref_update_no_task" => [],
    "task_ref_update_sync_no_task" => [response: ErrorResponse],
    "task_ref_update_status_invalid" => [response: ErrorResponse],
    "task_signal_workflow_not_found" => [response: ErrorResponse],
    "task_signal_sync_workflow_not_found" => [response: ErrorResponse],
    "task_signal_no_task" => [],
    "task_signal_sync_no_task" => [response: ErrorResponse],
    "route_unsupported_workflow_decide" => [response: ErrorResponse],
    "route_later_tasks_requeue" => [],
    "route_later_workflow_bulk_search" => [],
    "route_later_task_log" => [],
    "workflow_execute_not_found" => [response: ErrorResponse],
    "workflow_execute" => [],
    "workflow_execute_blocking_workflow" => [],
    "workflow_execute_blocking_task" => [],
    "workflow_execute_blocking_task_input" => [],
    "workflow_execute_latest" => [],
    "workflow_execute_completed_blocking_task" => [response: ErrorResponse],
    "workflow_execute_wait_until_task" => [],
    "workflow_execute_timeout" => [],
    "workflow_execute_timeout_blocking_task" => [response: ErrorResponse],
    "workflow_execute_inline" => [],
    "workflow_start_signal" => [],
    "workflow_get_signal" => [response: Workflow],
    "task_signal_sync" => [],
    "task_signal_sync_blocking_workflow" => [],
    "task_signal_sync_blocking_task" => [],
    "task_signal_sync_blocking_task_input" => [],
    "task_signal_sync_timeout" => [],
    "task_signal_sync_no_wait" => [response: ErrorResponse],
    "task_signal_no_wait" => [],
    "workflow_get_signal_no_wait" => [response: Workflow],
    "task_signal" => [],
    "workflow_get_signaled" => [response: Workflow],
    "workflow_start_signal_parent" => [],
    "workflow_get_signal_parent" => [response: Workflow],
    "workflow_get_signal_child" => [response: Workflow],
    "task_signal_sync_child" => [],
    "workflow_start_ref" => [],
    "task_ref_update" => [],
    "workflow_get_ref_updated" => [response: Workflow],
    "task_ref_update_sync" => [response: Workflow],
    "task_ref_update_done" => [],
    "workflow_start_loop" => [],
    "task_ref_update_loop" => [],
    "workflow_get_loop_second" => [response: Workflow],
    "task_ref_update_loop_second" => [],
    "workflow_get_loop_completed" => [response: Workflow],
    "workflow_start_life" => [],
    "workflow_start_life_v2" => [],
    "workflow_get_life_v2" => [response: Workflow],
    "workflow_pause" => [],
    "workflow_get_paused" => [response: Workflow],
    "workflow_pause_paused" => [],
    "workflow_skiptask_paused" => [response: ErrorResponse],
    "workflow_running_ops" => [],
    "workflow_running_ops_time" => [],
    "workflow_correlated_paused" => [response: {:list, Workflow}],
    "workflow_correlated_paused_closed" => [response: {:list, Workflow}],
    "workflow_resume" => [],
    "workflow_get_resumed" => [response: Workflow],
    "workflow_start_skip" => [],
    "workflow_get_skip" => [response: Workflow],
    "workflow_skiptask" => [],
    "workflow_get_skipped" => [response: Workflow],
    "workflow_skiptask_again" => [response: ErrorResponse],
    "workflow_tasks_skipped" => [],
    "task_update_skip_a" => [request: TaskResult],
    "workflow_get_skip_completed" => [response: Workflow],
    "workflow_start_callback" => [],
    "task_poll_callback" => [response: Task],
    "task_update_callback" => [request: TaskResult],
    "workflow_get_callback" => [response: Workflow],
    "task_poll_callback_postponed" => [],
    "workflow_resetcallbacks" => [],
    "workflow_get_callback_reset" => [response: Workflow],
    "task_poll_callback_reset" => [response: Task],
    "workflow_start_retry" => [],
    "workflow_get_retry" => [response: Workflow],
    "task_update_retry_a" => [request: TaskResult],
    "workflow_get_retry_failed" => [response: Workflow],
    "workflow_retry" => [],
    "workflow_get_retried" => [response: Workflow],
    "workflow_start_restart" => [],
    "workflow_terminate_restart" => [],
    "workflow_restart" => [],
    "workflow_get_restarted" => [response: Workflow],
    "workflow_terminate_restarted" => [],
    "workflow_restart_latest" => [],
    "workflow_get_restarted_latest" => [response: Workflow],
    "workflow_start_rerun" => [],
    "workflow_get_rerun" => [response: Workflow],
    "task_update_rerun_a" => [request: TaskResult],
    "workflow_get_rerun_b" => [response: Workflow],
    "task_update_rerun_b" => [request: TaskResult],
    "workflow_rerun_from_task" => [],
    "workflow_get_rerun_from_task" => [response: Workflow],
    "workflow_terminate_rerun" => [],
    "workflow_rerun" => [],
    "workflow_get_rerun_whole" => [response: Workflow],
    "workflow_start_parent" => [],
    "workflow_get_parent" => [response: Workflow],
    "workflow_get_parent_child" => [response: Workflow],
    "task_update_parent_child" => [request: TaskResult],
    "workflow_rerun_sub_workflow" => [],
    "workflow_get_rerun_sub_workflow" => [response: Workflow],
    "workflow_get_rerun_new_child" => [response: Workflow],
    "task_update_rerun_new_child" => [request: TaskResult],
    "workflow_rerun_child_task" => [],
    "workflow_get_rerun_child_parent" => [response: Workflow],
    "workflow_get_rerun_child" => [response: Workflow],
    "workflow_start_top" => [],
    "workflow_get_top" => [response: Workflow],
    "workflow_get_mid" => [response: Workflow],
    "workflow_get_child_first" => [response: Workflow],
    "task_update_child_first" => [request: TaskResult],
    "workflow_get_mid_retried" => [response: Workflow],
    "workflow_get_child_second" => [response: Workflow],
    "task_update_child_second" => [request: TaskResult],
    "workflow_get_mid_failed" => [response: Workflow],
    "workflow_get_top_failed" => [response: Workflow],
    "workflow_rerun_retried_child" => [],
    "workflow_get_rerun_top" => [response: Workflow],
    "workflow_get_rerun_mid" => [response: Workflow],
    "workflow_get_rerun_child_first" => [response: Workflow],
    "workflow_start_remove" => [],
    "workflow_get_remove" => [response: Workflow],
    "task_update_remove_a" => [request: TaskResult],
    "workflow_remove" => [],
    "workflow_get_removed" => [response: ErrorResponse],
    "workflow_remove_removed" => [response: ErrorResponse],
    "workflow_start_remove_running" => [],
    "workflow_remove_no_archive" => [],
    "workflow_get_removed_running" => [response: ErrorResponse],
    "workflow_start_terminate_remove" => [],
    "workflow_terminate_remove" => [],
    "workflow_get_terminate_removed" => [response: ErrorResponse],
    "workflow_bulk_pause_empty" => [response: ErrorResponse],
    "workflow_bulk_pause_too_many" => [response: ErrorResponse],
    "workflow_bulk_pause_null_body" => [response: ErrorResponse],
    "workflow_start_bulk_1" => [],
    "workflow_start_bulk_2" => [],
    "workflow_bulk_pause" => [response: BulkResponse],
    "workflow_bulk_pause_single" => [response: BulkResponse],
    "workflow_bulk_resume" => [response: BulkResponse],
    "workflow_bulk_terminate" => [response: BulkResponse],
    "workflow_bulk_retry" => [response: BulkResponse],
    "workflow_bulk_restart" => [response: BulkResponse],
    "workflow_get_bulk_restarted" => [response: Workflow],
    "workflow_bulk_remove" => [response: BulkResponse],
    "workflow_get_bulk_removed" => [response: ErrorResponse],
    "workflow_get_bulk_terminate_remove" => [response: Workflow],
    "workflow_bulk_terminate_remove" => [response: BulkResponse],
    "workflow_get_bulk_terminate_removed" => [response: ErrorResponse],
    "metadata_delete_workflow" => [],
    "metadata_get_workflow_deleted" => [response: ErrorResponse],
    "metadata_get_workflow_after_delete" => [response: WorkflowDef],
    "metadata_delete_taskdef" => [],
    "metadata_get_taskdef_deleted" => [response: ErrorResponse]
  }

  @schemas %{
    TaskDef => :task_def,
    WorkflowDef => :workflow_def,
    Task => :task,
    Workflow => :workflow
  }

  # Registration requests and the fixture where upstream returned what it stored.
  # {request fixture, element index of a list body, stored fixture, model}
  @stored [
    {"metadata_register_workflow_simple", nil, "metadata_get_workflow", WorkflowDef},
    {"metadata_register_workflow_switch", nil, "metadata_get_workflow_switch", WorkflowDef},
    {"metadata_register_workflow_fork", nil, "metadata_get_workflow_fork", WorkflowDef},
    {"metadata_register_taskdefs", 0, "metadata_get_taskdef", TaskDef},
    {"metadata_update_taskdef", nil, "metadata_get_taskdef_updated", TaskDef},
    {"metadata_register_workflow_overwrite", nil, "metadata_get_workflow_overwritten",
     WorkflowDef},
    {"metadata_update_workflows", 1, "metadata_get_workflow_bulk_latest", WorkflowDef}
  ]

  # Fields the server fills in on registration (MetadataServiceImpl sets the audit fields).
  @server_fields ~w(createTime updateTime createdBy updatedBy ownerApp)

  test "every fixture is classified" do
    assert MapSet.new(Contract.fixture_names()) == MapSet.new(Map.keys(@models))
  end

  for {name, sides} <- @models, {side, model} <- sides do
    schema_module = with {:list, module} <- model, do: module

    describe "#{name} #{side}" do
      setup do
        body = get_in(Contract.fixture(unquote(name)), [Atom.to_string(unquote(side)), "body"])
        %{items: items(unquote(model), body), module: module(unquote(model))}
      end

      test "decodes and encodes back to the same JSON", %{items: items, module: module} do
        for {item, _index} <- items do
          encoded = round_trip(module, item)

          if unquote(side) == :response do
            # Responses are complete objects as upstream serialized them.
            assert Contract.normalize(encoded) == Contract.normalize(item)
          else
            # Requests are sparse: every field sent survives unchanged, defaults fill the rest,
            # and decoding the result again is a fixed point.
            assert_subset(item, encoded)
            assert round_trip(module, encoded) == encoded
          end
        end
      end

      if schema = Map.get(@schemas, schema_module) do
        test "encoded JSON passes the #{schema} schema", %{items: items, module: module} do
          for {item, _index} <- items do
            assert Contract.validate(unquote(schema), round_trip(module, item)) == :ok
          end
        end
      end
    end
  end

  for {request, index, stored, module} <- @stored do
    test "#{request} decodes to the definition upstream stored (#{stored})" do
      body = element(Contract.fixture(unquote(request))["request"]["body"], unquote(index))
      stored = Contract.fixture(unquote(stored))["response"]["body"]

      assert Map.drop(round_trip(unquote(module), body), @server_fields) ==
               Map.drop(stored, @server_fields)
    end
  end

  defp element(body, nil), do: body
  defp element(body, index), do: Enum.at(body, index)

  defp items({:list, _module}, body) when is_list(body), do: Enum.with_index(body)
  defp items(_module, body), do: [{body, nil}]

  defp module({:list, module}), do: module
  defp module(module), do: module

  # Encodes through the real JSON text, as a REST response would.
  defp round_trip(module, json) do
    assert {:ok, struct} = module.from_json(json)
    struct |> module.to_json() |> JSON.encode!() |> JSON.decode!()
  end

  defp assert_subset(expected, actual) when is_map(expected) do
    assert is_map(actual)
    for {key, value} <- expected, do: assert_subset(value, Map.fetch!(actual, key))
  end

  defp assert_subset(expected, actual) when is_list(expected) do
    assert length(expected) == length(actual)
    Enum.zip_with(expected, actual, &assert_subset/2)
  end

  defp assert_subset(expected, actual), do: assert(expected == actual)
end
