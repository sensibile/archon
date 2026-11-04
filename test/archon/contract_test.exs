defmodule Archon.ContractTest do
  use ExUnit.Case, async: true

  alias Archon.Contract

  # Which part of each captured exchange is checked against which schema
  # (Archon.Contract.fixture_schemas/0). Every fixture must be listed there or in @unschematized,
  # so a newly captured fixture cannot be skipped silently.
  @schematized Contract.fixture_schemas()

  # Exchanges whose bodies have no upstream JSON schema, with the response shape upstream returned.
  @unschematized %{
    "metadata_get_taskdef_not_found" => :error,
    "metadata_get_workflow_not_found" => :error,
    "metadata_register_workflow_conflict" => :error,
    "workflow_get_not_found" => :error,
    "workflow_start_simple" => :text_id,
    "workflow_start_request_switch" => :text_id,
    "workflow_start_fork" => :text_id,
    "workflow_start_to_terminate" => :text_id,
    "task_update_simple_a" => :text_id,
    "task_update_switch_b" => :text_id,
    "task_update_fork_a" => :text_id,
    "task_update_fork_b" => :text_id,
    "metadata_register_taskdefs" => :empty,
    "metadata_register_workflow_simple" => :empty,
    "metadata_register_workflow_switch" => :empty,
    "metadata_register_workflow_fork" => :empty,
    "workflow_terminate" => :empty,
    "task_poll_empty" => :no_content,
    "task_update_v2_simple_b" => :no_content,
    "workflow_get_status" => :workflow_status,
    # Added for Phase 5 (ADR 0023, decision 6).
    "health" => :health,
    "health_api" => :health,
    "metadata_register_taskdefs_single" => :empty,
    "metadata_update_taskdef" => :empty,
    "metadata_update_taskdef_not_found" => :error,
    "metadata_register_taskdefs_empty" => :validation,
    "metadata_register_taskdefs_no_name" => :validation,
    "metadata_register_taskdefs_blank_name" => :validation,
    "metadata_register_taskdefs_coerced" => :validation,
    "metadata_register_workflow_no_tasks" => :validation,
    "metadata_register_workflow_overwrite" => :empty,
    "metadata_get_workflow_version_not_found" => :error,
    "metadata_update_workflows" => :bulk_response,
    "metadata_update_workflows_invalid" => :validation,
    "metadata_get_workflow_bulk_rejected" => :error,
    "metadata_update_workflows_empty" => :validation,
    "workflow_start_not_found" => :error,
    "workflow_start_request_not_found" => :error,
    "workflow_start_inline" => :text_id,
    "workflow_start_inline_second" => :text_id,
    "workflow_get_status_default" => :workflow_status,
    "workflow_get_status_all" => :workflow_status,
    "workflow_get_status_not_found" => :error,
    "workflow_terminate_completed" => :error,
    "workflow_terminate_not_found" => :error,
    "task_get_not_found" => :error,
    "task_update_not_found" => :error,
    "task_update_workflow_not_found" => :error,
    "task_update_v2_not_found" => :error,
    "task_update_invalid" => :validation,
    "task_update_v2_invalid" => :server_error,
    "route_not_found" => :error,
    "route_later_workflow_running" => :json,
    "route_later_workflow_test" => :validation,
    "route_later_metadata_names" => :json,
    "route_method_patch_workflow" => :error,
    "route_method_put_task" => :error,
    "request_body_not_json" => :server_error,
    "request_query_not_number" => :server_error,
    "request_query_not_boolean" => :server_error,
    # Added in slice 5f (ADR 0023, decision 6).
    "metadata_register_taskdefs_missing_body" => :server_error,
    "metadata_update_taskdef_null_body" => :server_error,
    "metadata_register_workflow_missing_body" => :server_error,
    "metadata_update_workflows_null_body" => :server_error,
    "workflow_start_request_missing_body" => :server_error,
    "workflow_start_null_body" => :server_error,
    "task_update_missing_body" => :server_error,
    "task_update_v2_null_body" => :server_error,
    "metadata_register_workflow_no_name" => :validation,
    "metadata_register_workflow_overwrite_invalid" => :validation,
    "metadata_update_taskdef_invalid" => :validation,
    "metadata_update_workflows_null_element" => :validation,
    "metadata_register_taskdefs_null_element" => :server_error,
    "metadata_register_taskdefs_wrong_type" => :server_error,
    "task_update_wrong_type" => :server_error,
    "workflow_start_request_wrong_type" => :server_error,
    "workflow_start_not_object" => :server_error,
    "metadata_register_workflow_query_not_boolean" => :server_error,
    "metadata_get_workflow_query_not_number" => :server_error,
    "workflow_start_query_not_number" => :server_error,
    "workflow_get_status_query_not_boolean" => :server_error,
    "task_update_v2_invalid_both" => :server_error,
    "task_batch_poll_timeout_too_long" => :error,
    "task_poll_domain_empty" => :no_content,
    "workflow_start_request_no_name" => :validation,
    "workflow_start_request_priority_too_high" => :validation,
    "workflow_start_request_invalid_definition" => :validation,
    "workflow_start_request_blank_name" => :error,
    "workflow_start_request_null_input" => :error,
    "workflow_start_request_external_input" => :server_error,
    "workflow_start_priority_too_low" => :validation,
    "workflow_start_version_not_found" => :error,
    "workflow_get_status_no_correlation" => :workflow_status,
    "workflow_terminate_terminated" => :empty,
    "workflow_start_request_defaults" => :text_id,
    "workflow_start_request_inline_other_name" => :text_id,
    "workflow_start_options" => :text_id,
    # Phase 6 (ADR 0025, decision 7).
    "metadata_workflow_names_and_versions" => :json,
    "metadata_workflow_names" => :json,
    "metadata_workflow_versions" => :json,
    "metadata_workflow_versions_missing" => :json,
    "metadata_validate_workflow_invalid" => :validation,
    "metadata_get_workflow_not_validated" => :error,
    "metadata_delete_workflow_not_found" => :server_error,
    "metadata_delete_workflow_version_not_number" => :server_error,
    "metadata_delete_taskdef_not_found" => :server_error,
    "workflow_pause_not_found" => :error,
    "workflow_resume_not_found" => :error,
    "workflow_retry_not_found" => :error,
    "workflow_restart_not_found" => :error,
    "workflow_rerun_not_found" => :error,
    "workflow_skiptask_not_found" => :error,
    "workflow_resetcallbacks_not_found" => :error,
    "workflow_remove_not_found" => :error,
    "workflow_terminate_remove_not_found" => :error,
    "workflow_pause_completed" => :error,
    "workflow_resume_completed" => :server_error,
    "workflow_retry_completed" => :error,
    "workflow_rerun_task_not_found" => :error,
    "workflow_skiptask_completed" => :server_error,
    "workflow_resetcallbacks_completed" => :error,
    "workflow_terminate_remove_completed" => :error,
    "workflow_resume_running" => :empty,
    "workflow_retry_running" => :error,
    "workflow_restart_running" => :error,
    "workflow_rerun_running" => :error,
    "workflow_skiptask_unknown_ref" => :server_error,
    "workflow_skiptask_existing_ref" => :server_error,
    "workflow_remove_running" => :error,
    "workflow_tasks" => :json,
    "workflow_tasks_status" => :json,
    "workflow_tasks_status_list" => :json,
    "workflow_tasks_status_comma" => :json,
    "workflow_tasks_status_none" => :json,
    "workflow_tasks_page" => :json,
    "workflow_tasks_count_negative" => :error,
    "workflow_tasks_start_negative" => :server_error,
    "workflow_tasks_start_past_end" => :json,
    "workflow_tasks_not_found" => :error,
    "workflow_correlated_post" => :json,
    "workflow_correlated_post_closed" => :json,
    "workflow_correlated_post_empty" => :json,
    "workflow_running" => :json,
    "workflow_running_other_version" => :json,
    "workflow_running_time" => :json,
    "workflow_running_time_other_version" => :json,
    "workflow_running_unknown" => :json,
    "task_ref_update_workflow_not_found" => :empty,
    "task_ref_update_sync_workflow_not_found" => :error,
    "task_ref_update_no_task" => :empty,
    "task_ref_update_sync_no_task" => :error,
    "task_ref_update_status_invalid" => :server_error,
    "task_signal_workflow_not_found" => :error,
    "task_signal_sync_workflow_not_found" => :error,
    "task_signal_no_task" => :empty,
    "task_signal_sync_no_task" => :error,
    "route_unsupported_workflow_decide" => :error,
    "route_later_tasks_requeue" => :text,
    "workflow_execute_not_found" => :error,
    "workflow_execute" => :json,
    "workflow_execute_blocking_workflow" => :json,
    "workflow_execute_blocking_task" => :json,
    "workflow_execute_blocking_task_input" => :json,
    "workflow_execute_latest" => :json,
    "workflow_execute_completed_blocking_task" => :server_error,
    "workflow_execute_wait_until_task" => :json,
    "workflow_execute_timeout" => :json,
    "workflow_execute_timeout_blocking_task" => :server_error,
    "workflow_execute_inline" => :json,
    "workflow_start_signal" => :text_id,
    "task_signal_sync" => :json,
    "task_signal_sync_blocking_workflow" => :json,
    "task_signal_sync_blocking_task" => :json,
    "task_signal_sync_blocking_task_input" => :json,
    "task_signal_sync_timeout" => :json,
    "task_signal_sync_no_wait" => :error,
    "task_signal_no_wait" => :empty,
    "task_signal" => :empty,
    "workflow_start_signal_parent" => :text_id,
    "task_signal_sync_child" => :json,
    "workflow_start_ref" => :text_id,
    "task_ref_update" => :text_id,
    "task_ref_update_done" => :empty,
    "workflow_start_loop" => :text_id,
    "task_ref_update_loop" => :text_id,
    "task_ref_update_loop_second" => :text_id,
    "workflow_start_life" => :text_id,
    "workflow_start_life_v2" => :text_id,
    "workflow_pause" => :empty,
    "workflow_pause_paused" => :empty,
    "workflow_skiptask_paused" => :server_error,
    "workflow_running_ops" => :json,
    "workflow_running_ops_time" => :json,
    "workflow_resume" => :empty,
    "workflow_start_skip" => :text_id,
    "workflow_skiptask" => :empty,
    "workflow_skiptask_again" => :server_error,
    "workflow_tasks_skipped" => :json,
    "task_update_skip_a" => :text_id,
    "workflow_start_callback" => :text_id,
    "task_update_callback" => :text_id,
    "task_poll_callback_postponed" => :no_content,
    "workflow_resetcallbacks" => :no_content,
    "workflow_start_retry" => :text_id,
    "task_update_retry_a" => :text_id,
    "workflow_retry" => :no_content,
    "workflow_start_restart" => :text_id,
    "workflow_terminate_restart" => :empty,
    "workflow_restart" => :no_content,
    "workflow_terminate_restarted" => :empty,
    "workflow_restart_latest" => :no_content,
    "workflow_start_rerun" => :text_id,
    "task_update_rerun_a" => :text_id,
    "task_update_rerun_b" => :text_id,
    "workflow_rerun_from_task" => :text_id,
    "workflow_terminate_rerun" => :empty,
    "workflow_rerun" => :text_id,
    "workflow_start_parent" => :text_id,
    "task_update_parent_child" => :text_id,
    "workflow_rerun_sub_workflow" => :text_id,
    "task_update_rerun_new_child" => :text_id,
    "workflow_rerun_child_task" => :text_id,
    "workflow_start_top" => :text_id,
    "task_update_child_first" => :text_id,
    "task_update_child_second" => :text_id,
    "workflow_rerun_retried_child" => :text_id,
    "workflow_start_remove" => :text_id,
    "task_update_remove_a" => :text_id,
    "workflow_remove" => :empty,
    "workflow_get_removed" => :error,
    "workflow_remove_removed" => :error,
    "workflow_start_remove_running" => :text_id,
    "workflow_remove_no_archive" => :empty,
    "workflow_get_removed_running" => :error,
    "workflow_start_terminate_remove" => :text_id,
    "workflow_terminate_remove" => :empty,
    "workflow_get_terminate_removed" => :error,
    "workflow_bulk_pause_empty" => :validation,
    "workflow_bulk_pause_too_many" => :validation,
    "workflow_bulk_pause_null_body" => :server_error,
    "workflow_start_bulk_1" => :text_id,
    "workflow_start_bulk_2" => :text_id,
    "workflow_bulk_pause" => :json,
    "workflow_bulk_pause_single" => :json,
    "workflow_bulk_resume" => :json,
    "workflow_bulk_terminate" => :json,
    "workflow_bulk_retry" => :json,
    "workflow_bulk_restart" => :json,
    "workflow_bulk_remove" => :json,
    "workflow_get_bulk_removed" => :error,
    "workflow_bulk_terminate_remove" => :json,
    "workflow_get_bulk_terminate_removed" => :error,
    "metadata_delete_workflow" => :empty,
    "metadata_get_workflow_deleted" => :error,
    "metadata_delete_taskdef" => :empty,
    "metadata_get_taskdef_deleted" => :error,
    # Phase 7 (ADR 0026, decision 8).
    "p7_terminate_register_not_string" => :validation,
    "p7_terminate_register_expression" => :validation,
    "p7_terminate_completed_start" => :text_id,
    "p7_terminate_failed_start" => :text_id,
    "p7_terminate_terminated_start" => :text_id,
    "p7_set_variable_start" => :text_id,
    "p7_set_variable_big_start" => :text_id,
    "p7_set_variable_fork_start" => :text_id,
    "p7_noop_start" => :text_id,
    "p7_human_start" => :text_id,
    "p7_human_update" => :text_id,
    "p7_exclusive_join_case_start" => :text_id,
    "p7_exclusive_join_case_update" => :text_id,
    "p7_exclusive_join_default_start" => :text_id,
    "p7_exclusive_join_default_update" => :text_id,
    "p7_exclusive_join_failed_start" => :text_id,
    "p7_exclusive_join_failed_update" => :server_error,
    "p7_dynamic_start" => :text_id,
    "p7_dynamic_update" => :text_id,
    "p7_dynamic_missing_start" => :text_id,
    "p7_dynamic_no_name_start" => :text_id,
    "p7_dynamic_system_start" => :text_id,
    "p7_fjd_simple_start" => :text_id,
    "p7_fjd_simple_update_0" => :text_id,
    "p7_fjd_simple_update_1" => :text_id,
    "p7_fjd_param_start" => :text_id,
    "p7_fjd_param_update_0" => :text_id,
    "p7_fjd_param_update_1" => :text_id,
    "p7_fjd_legacy_start" => :text_id,
    "p7_fjd_legacy_update_0" => :text_id,
    "p7_fjd_legacy_update_1" => :text_id,
    "p7_fjd_no_join_start" => :text_id,
    "p7_fjd_retry_start" => :text_id,
    "p7_fjd_retry_fail" => :text_id,
    "p7_fjd_retry" => :no_content,
    "p7_fjd_retried_update_0" => :text_id,
    "p7_fjd_retried_update_1" => :text_id,
    "p7_fjd_rerun_branch" => :text_id,
    "p7_fjd_rerun_terminate" => :empty,
    "p7_fjd_rerun_fork" => :text_id,
    "p7_inline_javascript_start" => :text_id,
    "p7_inline_value_param_start" => :text_id,
    "p7_inline_unknown_start" => :text_id,
    "p7_inline_script_error_start" => :text_id,
    "p7_inline_evaluator_not_string_start" => :server_error,
    "p7_inline_expression_not_string_start" => :server_error,
    "p7_lambda_start" => :text_id,
    "p7_lambda_error_start" => :text_id,
    "p7_lambda_empty_start" => :text_id,
    "p7_jq_start" => :text_id,
    "p7_jq_null_start" => :text_id,
    "p7_jq_syntax_start" => :text_id,
    "p7_jq_missing_start" => :text_id,
    "p7_jq_not_string_start" => :text_id,
    "p7_jq_register_invalid" => :validation,
    "p7_start_workflow_start" => :text_id,
    "p7_start_workflow_invalid_start" => :text_id,
    "p7_start_workflow_missing_start" => :text_id,
    "p7_http_json_start" => :text_id,
    "p7_http_post_start" => :text_id,
    "p7_http_text_start" => :text_id,
    "p7_http_number_start" => :text_id,
    "p7_http_status_299_start" => :text_id,
    "p7_http_short_404_start" => :text_id,
    "p7_http_long_400_start" => :text_id,
    "p7_http_empty_404_start" => :text_id,
    "p7_http_short_503_start" => :text_id,
    "p7_http_refused_start" => :text_id,
    "p7_http_no_uri_start" => :text_id,
    "p7_http_no_method_start" => :text_id,
    "p7_http_redirect_302_start" => :text_id,
    "p7_http_redirect_307_start" => :text_id,
    "p7_http_async_start" => :text_id,
    "p7_http_async_update" => :text_id,
    "p7_http_async_input_start" => :text_id,
    "p7_http_register_invalid" => :validation,
    # Phase 8 (ADR 0027, decision 7).
    "p8_search_start_1" => :text_id,
    "p8_search_start_2" => :text_id,
    "p8_search_start_3" => :text_id,
    "p8_search_update_1" => :text_id,
    "p8_search_update_2" => :text_id,
    "p8_classified_start" => :text_id,
    "p8_search_all" => :search_result,
    "p8_search_desc" => :search_result,
    "p8_search_sort_many" => :search_result,
    "p8_search_sort_invalid" => :search_result,
    "p8_search_sort_missing_column" => :server_error,
    "p8_search_page" => :search_result,
    "p8_search_size_negative" => :search_result,
    "p8_search_start_negative" => :search_result,
    "p8_search_start_past_end" => :search_result,
    "p8_search_size_limit" => :validation,
    "p8_search_size_limit_v2" => :validation,
    "p8_search_size_zero" => :search_result,
    "p8_search_size_not_number" => :server_error,
    "p8_search_free_text" => :search_result,
    "p8_search_free_text_case" => :search_result,
    "p8_search_free_text_percent" => :search_result,
    "p8_search_free_text_underscore" => :search_result,
    "p8_search_free_text_backslash" => :search_result,
    "p8_search_free_text_backslashes" => :search_result,
    "p8_search_free_text_star" => :search_result,
    "p8_search_free_text_empty" => :search_result,
    "p8_search_free_text_java" => :search_result,
    "p8_search_status" => :search_result,
    "p8_search_in_many" => :search_result,
    "p8_search_in_one" => :search_result,
    "p8_search_in_spaces" => :search_result,
    "p8_search_time_range" => :search_result,
    "p8_search_time_future" => :search_result,
    "p8_search_time_not_number" => :server_error,
    "p8_search_time_in" => :search_result,
    "p8_search_wildcard" => :search_result,
    "p8_search_json_data" => :search_result,
    "p8_search_unknown_field" => :search_result,
    "p8_search_bad_clause" => :error,
    "p8_search_missing_column" => :server_error,
    "p8_search_quoted" => :search_result,
    "p8_search_classifier" => :search_result,
    "p8_search_classifier_workflow" => :search_result,
    "p8_search_classifier_both" => :search_result,
    "p8_search_classifier_only" => :search_result,
    "p8_search_v2" => :search_result,
    "p8_search_v2_page" => :search_result,
    "p8_search_v2_bad_clause" => :error,
    "p8_tasks_search" => :search_result,
    "p8_tasks_search_v2" => :search_result,
    "p8_tasks_search_free_text" => :search_result,
    "p8_tasks_search_page" => :search_result,
    "p8_tasks_search_missing_column" => :server_error,
    "p8_tasks_search_sort_missing_column" => :server_error,
    "p8_tasks_search_bad_clause" => :error,
    "p8_tasks_search_time_not_number" => :server_error,
    "p8_tasks_search_size_negative" => :search_result,
    "p8_tasks_search_size_limit" => :search_result,
    "p8_tasks_search_start_negative" => :search_result,
    "p8_search_by_tasks" => :search_result,
    "p8_search_by_tasks_v2" => :search_result,
    "p8_search_by_tasks_free_text" => :search_result,
    "p8_search_by_tasks_size_limit" => :search_result,
    "p8_search_by_tasks_bad_clause" => :error,
    "p8_index_start" => :text_id,
    "p8_index_tasks_scheduled" => :search_result,
    "p8_index_workflow_scheduled" => :search_result,
    "p8_index_tasks_polled" => :search_result,
    "p8_index_extend_lease" => :text_id,
    "p8_index_tasks_extended" => :search_result,
    "p8_index_update_logs" => :text_id,
    "p8_index_tasks_updated" => :search_result,
    "p8_index_logs" => :task_logs,
    "p8_log_post_text" => :empty,
    "p8_log_post_json" => :empty,
    "p8_log_post_empty" => :server_error,
    "p8_index_logs_posted" => :task_logs,
    "p8_index_complete" => :text_id,
    "p8_index_tasks_completed" => :search_result,
    "p8_index_workflow_completed" => :search_result,
    "p8_log_post_missing" => :empty,
    "p8_log_get_missing" => :task_logs,
    "p8_log_get_none" => :no_content,
    "p8_sys_start" => :text_id,
    "p8_sys_tasks_started" => :search_result,
    "p8_sys_case_update" => :text_id,
    "p8_sys_tasks_forked" => :search_result,
    "p8_sys_search_by_tasks" => :search_result,
    "p8_sys_search_by_tasks_v2" => :search_result,
    "p8_skip_start" => :text_id,
    "p8_skip_skiptask" => :empty,
    "p8_skip_tasks_skipped" => :search_result,
    "p8_skip_complete" => :text_id,
    "p8_skip_tasks_completed" => :search_result,
    "p8_skip_search_by_tasks" => :search_result,
    "p8_remove_archive_start" => :text_id,
    "p8_remove_archive_update" => :text_id,
    "p8_remove_delete_start" => :text_id,
    "p8_remove_delete_get_removed" => :error,
    "p8_remove_delete_update" => :text_id,
    "p8_remove_archive" => :empty,
    "p8_remove_archive_search" => :search_result,
    "p8_remove_archive_search_v2" => :search_result,
    "p8_remove_archive_tasks" => :search_result,
    "p8_remove_archive_tasks_v2" => :search_result,
    "p8_remove_archive_by_tasks" => :search_result,
    "p8_remove_archive_by_tasks_v2" => :search_result,
    "p8_remove_archive_log" => :task_logs,
    "p8_remove_delete" => :empty,
    "p8_remove_delete_search" => :search_result,
    "p8_remove_delete_tasks" => :search_result,
    "p8_remove_delete_search_v2" => :search_result,
    "p8_remove_delete_by_tasks" => :search_result,
    "p8_remove_delete_log" => :no_content,
    "p8_parent_start" => :text_id,
    "p8_child_fail" => :text_id,
    "p8_child_retry" => :no_content,
    "p8_parent_log_retried" => :task_logs,
    "p8_child_terminate" => :empty,
    "p8_child_restart" => :no_content,
    "p8_child_complete" => :text_id,
    "p8_child_rerun" => :text_id,
    "p8_parent_logs" => :task_logs,
    "p8_search_family" => :search_result,
    "p8_search_top_level" => :search_result,
    "p8_search_top_level_v2" => :search_result,
    "p8_search_top_level_only" => :search_result,
    "p8_search_parent_id" => :search_result,
    "p8_bulk_search_empty" => :validation,
    "p8_bulk_search_too_many" => :validation,
    "p8_bulk_search_mixed" => :bulk_response,
    "p8_bulk_search_no_tasks" => :bulk_response,
    "p8_bulk_search_null_body" => :server_error
  }

  test "every fixture is classified" do
    classified = MapSet.new(Map.keys(@schematized) ++ Map.keys(@unschematized))
    assert Contract.fixture_names() != []
    assert MapSet.new(Contract.fixture_names()) == classified
  end

  for {name, {side, schema}} <- @schematized do
    test "#{name} #{side} matches #{inspect(schema)}" do
      exchange = Contract.fixture(unquote(name))
      body = get_in(exchange, [Atom.to_string(unquote(side)), "body"])

      assert Contract.validate_schema(unquote(Macro.escape(schema)), body) == :ok
    end
  end

  for {name, shape} <- @unschematized do
    test "#{name} response is #{shape}" do
      assert_shape(unquote(shape), Contract.fixture(unquote(name))["response"])
    end
  end

  describe "validate/2" do
    test "rejects a task without required fields" do
      assert {:error, errors} = Contract.validate(:task, %{"taskType" => "SIMPLE"})
      assert Enum.any?(errors, fn {_path, msg} -> msg =~ "taskId" end)
    end

    test "rejects an unknown workflow status" do
      workflow = Contract.fixture("workflow_get_running")["response"]["body"]

      assert {:error, [{"#/status", _msg}]} =
               Contract.validate(:workflow, Map.put(workflow, "status", "SLEEPING"))
    end
  end

  describe "normalize/1" do
    test "masks timestamps and UUIDs, keeps everything else" do
      id = "f3e36c49-45f2-4a16-bb2e-8c2898ab44b2"

      input = %{
        "workflowId" => id,
        "path" => "/api/workflow/#{id}",
        "tasks" => [%{"startTime" => 1, "endTime" => nil, "seq" => 1}]
      }

      assert Contract.normalize(input) == %{
               "workflowId" => "<uuid>",
               "path" => "/api/workflow/<uuid>",
               "tasks" => [%{"startTime" => "<volatile>", "endTime" => nil, "seq" => 1}]
             }
    end
  end

  defp assert_shape(:error, response) do
    assert %{"status" => status, "body" => body} = response
    assert status in 400..499
    assert %{"status" => ^status, "message" => message, "retryable" => false} = body
    assert is_binary(message)
    assert Map.has_key?(body, "instance")
  end

  # ValidationExceptionMapper: no instance, one entry per violation.
  defp assert_shape(:validation, response) do
    assert %{"status" => 400, "content_type" => "application/json", "body" => body} = response

    assert %{
             "status" => 400,
             "message" => "Validation failed, check below errors for detail.",
             "retryable" => false,
             "validationErrors" => [_ | _] = errors
           } = body

    refute Map.has_key?(body, "instance")
    assert Enum.all?(errors, &(is_binary(&1["path"]) and is_binary(&1["message"])))
  end

  # An exception class upstream's mapper has no status for.
  defp assert_shape(:server_error, response) do
    assert %{"status" => 500, "body" => body} = response
    assert %{"status" => 500, "message" => message, "retryable" => false} = body
    assert is_binary(message)
  end

  defp assert_shape(:health, response) do
    assert %{"status" => 200, "content_type" => "application/json", "body" => body} = response
    assert body == %{"healthResults" => [], "suppressedHealthResults" => [], "healthy" => true}
  end

  defp assert_shape(:bulk_response, response) do
    assert %{"status" => 200, "content_type" => "application/json", "body" => body} = response
    assert %{"bulkErrorResults" => %{}, "bulkSuccessfulResults" => [_ | _]} = body
  end

  # A Later route's upstream answer, kept to show it is not an MVP parameter route.
  defp assert_shape(:json, response) do
    assert %{"status" => 200, "content_type" => "application/json"} = response
  end

  # SearchResult (ADR 0027, decision 7): its results are summaries, workflows or tasks.
  defp assert_shape(:search_result, response) do
    assert %{"status" => 200, "content_type" => "application/json", "body" => body} = response
    assert %{"totalHits" => hits, "results" => results} = body
    assert is_integer(hits) and is_list(results) and length(results) <= max(hits, 0)
  end

  # GET /api/tasks/{taskId}/log: a list of TaskExecLog.
  defp assert_shape(:task_logs, response) do
    assert %{"status" => 200, "content_type" => "application/json", "body" => [_ | _] = logs} =
             response

    assert Enum.all?(logs, &match?(%{"log" => _, "taskId" => _, "createdTime" => _}, &1))
  end

  defp assert_shape(:text_id, response) do
    assert %{"status" => 200, "content_type" => "text/plain" <> _, "body" => body} = response
    assert body =~ ~r/\A[0-9a-f-]{36}\z/
  end

  # A Later route's upstream answer that is text and not an ID.
  defp assert_shape(:text, response) do
    assert %{"status" => 200, "content_type" => "text/plain" <> _, "body" => body} = response
    assert is_binary(body)
  end

  defp assert_shape(:empty, response) do
    assert %{"status" => 200, "body" => nil} = response
  end

  defp assert_shape(:no_content, response) do
    assert %{"status" => 204, "body" => nil} = response
  end

  defp assert_shape(:workflow_status, response) do
    assert %{"status" => 200, "body" => body} = response
    keys = Map.keys(body)
    assert "workflowId" in keys and "status" in keys
    assert keys -- ~w(correlationId output status variables workflowId) == []
  end
end
