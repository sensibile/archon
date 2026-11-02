# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.ContractCase do
  @moduledoc """
  Replays the golden fixtures (`test/fixtures/contract/`) against `ArchonWeb.Endpoint` through
  `Phoenix.ConnTest` and compares Archon's answers with upstream's (ADR 0023, decision 6).

  ## Scenario

  The fixture files carry no order, and the capture script waits and repeats requests it does
  not save. `scenario/0` is that order in code, step for step with
  `scripts/contract/capture_fixtures.sh`:

    * `{:exchange, name}` or `{:exchange, name, opts}` - send the fixture's request, compare the
      response.
    * `{:poll_until, name}` - repeat the request until it answers 200 (a task arrived), then
      compare the last answer.
    * `{:batch_poll_until, name}` - repeat until the answer is a non-empty list.
    * `{:wait_status, name, status}` - wait until the
      workflow whose ID fixture `name` answered (a start's text body) reaches `status`. It reads
      `Archon.Runtime` directly, as the script's wait is not a fixture.

  A fixture request body is sent as JSON, except a string, which is sent as the raw text it holds
  (the capture script stores a body that is not a JSON object, array, number or boolean as a
  string: an empty body, `null`, text that is not JSON).

  Exchange options record the deliberate differences from upstream:

    * `expect: :no_route` - Archon answers the 404 of a path without a handler instead of the
      fixture's response (Later routes, and an MVP path with another method, where upstream
      answers 405; ADR 0023, decision 2).
    * `expect: {:archon, status, conditions}` - Archon answers `status` with a body that meets
      `conditions` (as `until:` has them) instead of the fixture's response, for a deliberate
      difference where upstream fails (ADR 0026, decision 3). No ID is bound from it.
    * `ignore: [path]` - leave out these paths (lists of keys and list indexes) of both bodies,
      for a message Archon cannot reproduce (Jackson's parse errors) or a value upstream's timing
      decides.
    * `only: :expected_names` - keep only the elements of Archon's body whose name is a name in
      the fixture's body: the `name` of a list of definitions, the strings of a list of names,
      the keys of a map keyed by name. For lists the shared runtime also holds other tests'
      definitions in (`metadata_list_taskdefs`).
    * `only: :bound_ids` - keep only the workflow IDs of Archon's list body (strings, or objects
      by `workflowId`; in a map of lists, each list) that this replay bound, for queries the
      shared runtime also holds other tests' workflows in (`workflow_running`).
    * `unordered: true` - compare a list body, or each list of a map body, without order, for
      answers upstream gives in no defined order. No ID is bound from such a body, so every ID
      in it has to be bound by an earlier step.
    * `until: [{path, condition}]` - repeat the request until every condition holds on Archon's
      body, then compare the last answer, for a state the capture waited for (a child started).
      `path` is a list of keys and list indexes; `condition` is `:present` (not `nil`),
      `{:length, n}` or the value itself. `until: :settled` waits for the workflow GET to show
      the fixture's workflow status, number of tasks and status of each task.
    * `types: [type]` - the workflow task types of Phase 7 the step needs (ADR 0026, decision 8).
      The step is skipped while one of them has no mapper of its own
      (`Archon.Decider.Mapper.mapped?/1`); a step that needs an earlier one names its types too.
      Each Phase 7 slice turns its steps on by adding its type to the mapper table.

  ## HTTP stub

  The `HTTP` task fixtures call `Archon.HttpStub`, which the capture ran at `captured_http_stub/0`.
  A replay started with `new_state(http_stub: url)` puts `url` (its own stub) in place of that
  address in the requests it sends and the bodies it expects.

  `steps/2` cuts a part of the scenario. Run them with `replay/2`, threading the state from one
  call to the next.

  ## Generated IDs

  The state maps each captured UUID to the value Archon generated. A captured UUID is bound the
  first time it shows up in a response, to the value at the same place in Archon's response. A
  captured UUID that shows up in a request first (an unknown ID such as `00000000-...`) is sent
  unchanged and bound to itself. The mapping is one-to-one: a step fails when a captured UUID
  would be bound to a value already bound to another one. Requests are sent with the bound
  values, and expected bodies are compared after replacing the captured UUIDs with them.

  Prerequisites a slice sets up without replaying (a workflow started through `Archon.Runtime`)
  are bound with `bind/3`.

  ## Comparison

  Status, `Content-Type` and body are compared after masking only the timestamp keys
  (`Archon.Contract.mask_times/1`, not `normalize/1`, which masks UUIDs too; a `0` timestamp is
  kept), so an ID that does not match its binding fails. `instance` (the host) is compared as present or absent, and
  `validationErrors` without order (Hibernate reports violations in no defined order). A response
  of a fixture listed in `Archon.Contract.fixture_schemas/0` is also checked against its schema.

  Fixtures depend on the state earlier steps left, as the capture ran on an empty server. The
  runtime under test is shared with other tests, so a test replaying a list response (such as
  `metadata_list_taskdefs`) has to keep other tests' definitions out of it (`only:`), and a test
  replaying registrations has to remove the fixtures' definitions other tests stored first
  (`remove_definitions/1`).
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Archon.Contract
  alias Archon.Decider.Mapper
  alias Archon.Domain.Codec

  @endpoint ArchonWeb.Endpoint

  # Polls and waits give up after 10 s.
  @deadline_ms 10_000
  @attempts 400
  @attempt_ms 25

  @type condition :: :present | {:length, non_neg_integer()} | term()
  @type exchange_opts :: [
          expect:
            :no_route
            | {:archon, pos_integer(), [{[String.t() | non_neg_integer()], condition()}]},
          ignore: [[String.t() | non_neg_integer()]],
          only: :expected_names | :bound_ids,
          unordered: boolean(),
          until: [{[String.t() | non_neg_integer()], condition()}] | :settled,
          types: [String.t()]
        ]
  @type step ::
          {:exchange, String.t()}
          | {:exchange, String.t(), exchange_opts()}
          | {:poll_until, String.t()}
          | {:batch_poll_until, String.t()}
          | {:wait_status, String.t(), String.t()}

  @type state :: %{
          :ids => %{String.t() => String.t()},
          :actuals => %{String.t() => String.t()},
          optional(:http_stub) => String.t() | nil
        }

  # Where the capture ran Archon.HttpStub (scripts/contract/capture_fixtures.sh).
  @captured_http_stub "http://127.0.0.1:18299"

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import ArchonWeb.ContractCase

      @endpoint ArchonWeb.Endpoint
    end
  end

  # Deliberate differences from the captured responses (see the moduledoc).
  @no_route [expect: :no_route]
  @jackson_message [ignore: [["message"]]]
  @expected_names [only: :expected_names]

  # Phase 6 (ADR 0025, decision 7): lists in no defined order.
  @names_unordered [only: :expected_names, unordered: true]
  @ids_unordered [only: :bound_ids, unordered: true]
  @child_started [until: [{["tasks", 0, "subWorkflowId"], :present}]]
  @one_task [until: [{["tasks"], {:length, 1}}]]
  @two_tasks [until: [{["tasks"], {:length, 2}}]]
  @first_in_progress [until: [{["tasks", 0, "status"], "IN_PROGRESS"}]]

  # Phase 7 (ADR 0026, decision 8): the types a step needs, and the workflow GETs the capture
  # waited on.
  @terminate [types: ["TERMINATE"]]
  @set_variable [types: ["SET_VARIABLE"]]
  @noop [types: ["NOOP"]]
  @human [types: ["HUMAN"]]
  @exclusive_join [types: ["EXCLUSIVE_JOIN"]]
  @dynamic [types: ["DYNAMIC"]]
  @dynamic_noop [types: ["DYNAMIC", "NOOP"]]
  @fork_join_dynamic [types: ["FORK_JOIN_DYNAMIC"]]
  @inline [types: ["INLINE"]]
  @lambda [types: ["LAMBDA"]]
  @jq [types: ["JSON_JQ_TRANSFORM"]]
  @start_workflow [types: ["START_WORKFLOW", "NOOP"]]
  @http [types: ["HTTP"]]
  @settled [until: :settled]
  # ADR 0026, decision 3: a permissive joined task that failed while another joined reference
  # never ran. Upstream's ExclusiveJoin throws a NullPointerException (a 500 to the update, the
  # workflow left RUNNING); here the join completes with the failed task's output and the
  # workflow fails for its permissive task.
  @permissive_join_update [expect: {:archon, 200, []}]
  @permissive_join_failed [
    {["status"], "FAILED"},
    {["tasks", 1, "status"], "FAILED"},
    {["tasks", 2, "status"], "COMPLETED"},
    {["tasks", 2, "outputData"], %{"from" => "b_ref"}}
  ]
  @permissive_join_ended [
    until: @permissive_join_failed,
    expect: {:archon, 200, @permissive_join_failed}
  ]
  # The server's host name as the HTTP task's workerId, and the stub's Date header.
  @http_volatile [
    ignore: [
      ["tasks", 0, "workerId"],
      ["tasks", 0, "outputData", "response", "headers", "date"],
      ["output", "response", "headers", "date"]
    ]
  ]

  @scenario [
    # metadata
    {:exchange, "metadata_register_taskdefs"},
    {:exchange, "metadata_get_taskdef"},
    {:exchange, "metadata_get_taskdef_not_found"},
    {:exchange, "metadata_register_workflow_simple"},
    {:exchange, "metadata_register_workflow_switch"},
    {:exchange, "metadata_register_workflow_fork"},
    {:exchange, "metadata_register_workflow_conflict"},
    {:exchange, "metadata_get_workflow"},
    {:exchange, "metadata_get_workflow_switch"},
    {:exchange, "metadata_get_workflow_fork"},
    {:exchange, "metadata_get_workflow_not_found"},
    # SIMPLE: start, poll, update, complete
    {:exchange, "workflow_start_simple"},
    {:poll_until, "task_poll_simple_a"},
    {:exchange, "workflow_get_running"},
    {:exchange, "task_update_simple_a"},
    {:poll_until, "task_poll_simple_b"},
    {:exchange, "task_update_v2_simple_b"},
    {:wait_status, "workflow_start_simple", "COMPLETED"},
    {:exchange, "workflow_get_completed_simple"},
    {:exchange, "workflow_get_without_tasks"},
    {:exchange, "workflow_get_status"},
    {:exchange, "task_get"},
    {:exchange, "task_poll_empty"},
    # SWITCH: start with StartWorkflowRequest
    {:exchange, "workflow_start_request_switch"},
    {:poll_until, "task_poll_switch_b"},
    {:exchange, "task_update_switch_b"},
    {:wait_status, "workflow_start_request_switch", "COMPLETED"},
    {:exchange, "workflow_get_completed_switch"},
    # FORK_JOIN / JOIN
    {:exchange, "workflow_start_fork"},
    {:batch_poll_until, "task_batch_poll_fork_a"},
    {:exchange, "task_update_fork_a"},
    {:poll_until, "task_poll_fork_b"},
    {:exchange, "task_update_fork_b"},
    {:wait_status, "workflow_start_fork", "COMPLETED"},
    {:exchange, "workflow_get_completed_fork"},
    # terminate
    {:exchange, "workflow_start_to_terminate"},
    {:exchange, "workflow_terminate"},
    {:exchange, "workflow_get_terminated"},
    {:exchange, "workflow_get_not_found"},
    # health
    {:exchange, "health"},
    {:exchange, "health_api"},
    # metadata: list, single update, overwrite, bulk update, validation
    {:exchange, "metadata_list_taskdefs", @expected_names},
    {:exchange, "metadata_register_taskdefs_single"},
    {:exchange, "metadata_update_taskdef"},
    {:exchange, "metadata_get_taskdef_updated"},
    {:exchange, "metadata_update_taskdef_not_found"},
    {:exchange, "metadata_register_taskdefs_empty"},
    {:exchange, "metadata_register_taskdefs_no_name"},
    {:exchange, "metadata_register_taskdefs_blank_name"},
    {:exchange, "metadata_register_taskdefs_coerced"},
    {:exchange, "metadata_register_workflow_no_tasks"},
    {:exchange, "metadata_register_workflow_overwrite"},
    {:exchange, "metadata_get_workflow_overwritten"},
    {:exchange, "metadata_get_workflow_version_not_found"},
    {:exchange, "metadata_update_workflows"},
    {:exchange, "metadata_get_workflow_bulk_latest"},
    {:exchange, "metadata_update_workflows_invalid"},
    {:exchange, "metadata_get_workflow_bulk_rejected"},
    {:exchange, "metadata_update_workflows_empty"},
    # workflow: start errors, inline definition, fetch options, terminate errors
    {:exchange, "workflow_start_not_found"},
    {:exchange, "workflow_start_request_not_found"},
    {:exchange, "workflow_start_inline"},
    {:exchange, "workflow_get_running_without_tasks"},
    {:exchange, "workflow_get_status_default"},
    {:exchange, "workflow_get_status_all"},
    {:exchange, "workflow_get_status_not_found"},
    {:exchange, "workflow_start_inline_second"},
    {:poll_until, "task_poll_inline_c"},
    {:exchange, "workflow_get_inline"},
    {:exchange, "task_update_v2_next"},
    {:wait_status, "workflow_start_inline", "COMPLETED"},
    {:exchange, "workflow_terminate_completed"},
    {:exchange, "workflow_terminate_not_found"},
    # task: empty batch, unknown task, validation
    {:exchange, "task_batch_poll_empty"},
    {:exchange, "task_get_not_found"},
    {:exchange, "task_update_not_found"},
    {:exchange, "task_update_workflow_not_found"},
    {:exchange, "task_update_v2_not_found"},
    {:exchange, "task_update_invalid"},
    {:exchange, "task_update_v2_invalid"},
    # routing: unknown path, Later paths shaped like MVP parameter paths, other methods, bad input
    {:exchange, "route_not_found"},
    {:exchange, "route_later_workflow_search", @no_route},
    {:exchange, "route_later_workflow_running", @ids_unordered},
    {:exchange, "route_later_workflow_test", @no_route},
    {:exchange, "route_later_metadata_names", @expected_names},
    {:exchange, "route_later_tasks_search", @no_route},
    {:exchange, "route_method_patch_workflow", @no_route},
    {:exchange, "route_method_put_task", @no_route},
    {:exchange, "request_body_not_json", @jackson_message},
    {:exchange, "request_query_not_number"},
    {:exchange, "request_query_not_boolean"},
    # slice 5f: missing and null bodies, one route each
    {:exchange, "metadata_register_taskdefs_missing_body"},
    {:exchange, "metadata_update_taskdef_null_body"},
    {:exchange, "metadata_register_workflow_missing_body"},
    {:exchange, "metadata_update_workflows_null_body"},
    {:exchange, "workflow_start_request_missing_body"},
    {:exchange, "workflow_start_null_body"},
    {:exchange, "task_update_missing_body"},
    {:exchange, "task_update_v2_null_body"},
    # metadata validation prefixes and null elements
    {:exchange, "metadata_register_workflow_no_name"},
    {:exchange, "metadata_register_workflow_overwrite_invalid"},
    {:exchange, "metadata_update_taskdef_invalid"},
    {:exchange, "metadata_update_workflows_null_element"},
    {:exchange, "metadata_register_taskdefs_null_element"},
    # values Jackson cannot convert
    {:exchange, "metadata_register_taskdefs_wrong_type", @jackson_message},
    {:exchange, "task_update_wrong_type", @jackson_message},
    {:exchange, "workflow_start_request_wrong_type", @jackson_message},
    {:exchange, "workflow_start_not_object", @jackson_message},
    # query values that do not convert
    {:exchange, "metadata_register_workflow_query_not_boolean"},
    {:exchange, "metadata_get_workflow_query_not_number"},
    {:exchange, "workflow_start_query_not_number"},
    {:exchange, "workflow_get_status_query_not_boolean"},
    # task routes
    {:exchange, "task_update_v2_invalid_both"},
    {:exchange, "task_batch_poll_timeout_too_long"},
    {:exchange, "task_batch_poll_count_zero"},
    {:exchange, "task_poll_domain_empty"},
    # start errors
    {:exchange, "workflow_start_request_no_name"},
    {:exchange, "workflow_start_request_priority_too_high"},
    {:exchange, "workflow_start_request_invalid_definition"},
    {:exchange, "workflow_start_request_blank_name"},
    {:exchange, "workflow_start_request_null_input"},
    {:exchange, "workflow_start_request_external_input"},
    {:exchange, "workflow_start_priority_too_low"},
    {:exchange, "workflow_start_version_not_found"},
    # status without a correlation ID, terminating a TERMINATED workflow
    {:exchange, "workflow_get_status_no_correlation"},
    {:exchange, "workflow_terminate_terminated"},
    # starts with defaults, an inline definition under another name, the query options
    {:exchange, "workflow_start_request_defaults"},
    {:exchange, "workflow_get_request_defaults"},
    {:exchange, "workflow_start_request_inline_other_name"},
    {:exchange, "workflow_start_options"},
    {:exchange, "workflow_get_options"},
    # Phase 6 (ADR 0025, decision 7): definitions
    {:exchange, "metadata_register_ops_taskdefs"},
    {:exchange, "metadata_register_workflow_ops"},
    {:exchange, "metadata_register_workflow_ops_v2"},
    {:exchange, "metadata_register_workflow_ops_waits"},
    {:exchange, "metadata_register_workflow_ops_idle"},
    {:exchange, "metadata_register_workflow_ops_callback"},
    {:exchange, "metadata_register_workflow_ops_child"},
    {:exchange, "metadata_register_workflow_ops_noop"},
    {:exchange, "metadata_register_workflow_ops_loop"},
    {:exchange, "metadata_register_workflow_ops_mid"},
    {:exchange, "metadata_register_workflow_ops_top"},
    {:exchange, "metadata_register_workflow_ops_parent"},
    {:exchange, "metadata_register_workflow_ops_signal_parent"},
    # metadata: lists, validation, deleting what is not there
    {:exchange, "metadata_list_workflows", @names_unordered},
    {:exchange, "metadata_list_workflows_classifier", @names_unordered},
    {:exchange, "metadata_list_workflows_classifier_agent"},
    {:exchange, "metadata_workflow_names_and_versions", @names_unordered},
    {:exchange, "metadata_workflow_names", @expected_names},
    {:exchange, "metadata_workflow_latest_versions", @names_unordered},
    {:exchange, "metadata_workflow_versions"},
    {:exchange, "metadata_workflow_versions_missing"},
    {:exchange, "metadata_validate_workflow"},
    {:exchange, "metadata_validate_workflow_invalid"},
    {:exchange, "metadata_get_workflow_not_validated"},
    {:exchange, "metadata_delete_workflow_not_found"},
    {:exchange, "metadata_delete_workflow_version_not_number"},
    {:exchange, "metadata_delete_taskdef_not_found"},
    # lifecycle errors: unknown, finished and running workflows
    {:exchange, "workflow_pause_not_found"},
    {:exchange, "workflow_resume_not_found"},
    {:exchange, "workflow_retry_not_found"},
    {:exchange, "workflow_restart_not_found"},
    {:exchange, "workflow_rerun_not_found"},
    {:exchange, "workflow_skiptask_not_found"},
    {:exchange, "workflow_resetcallbacks_not_found"},
    {:exchange, "workflow_remove_not_found"},
    {:exchange, "workflow_terminate_remove_not_found"},
    {:exchange, "workflow_pause_completed"},
    {:exchange, "workflow_resume_completed"},
    {:exchange, "workflow_retry_completed"},
    {:exchange, "workflow_rerun_task_not_found"},
    {:exchange, "workflow_skiptask_completed"},
    {:exchange, "workflow_resetcallbacks_completed"},
    {:exchange, "workflow_terminate_remove_completed"},
    {:exchange, "workflow_resume_running"},
    {:exchange, "workflow_retry_running"},
    {:exchange, "workflow_restart_running"},
    {:exchange, "workflow_rerun_running"},
    {:exchange, "workflow_skiptask_unknown_ref"},
    {:exchange, "workflow_skiptask_existing_ref"},
    {:exchange, "workflow_remove_running"},
    {:exchange, "workflow_get_running_not_removed"},
    # queries on the MVP scenario's workflows
    {:exchange, "workflow_tasks"},
    {:exchange, "workflow_tasks_status"},
    {:exchange, "workflow_tasks_status_list"},
    {:exchange, "workflow_tasks_status_comma"},
    {:exchange, "workflow_tasks_status_none"},
    {:exchange, "workflow_tasks_page"},
    {:exchange, "workflow_tasks_count_negative"},
    {:exchange, "workflow_tasks_start_negative"},
    {:exchange, "workflow_tasks_start_past_end"},
    {:exchange, "workflow_tasks_not_found"},
    {:exchange, "workflow_correlated", @ids_unordered},
    {:exchange, "workflow_correlated_closed", @ids_unordered},
    {:exchange, "workflow_correlated_closed_tasks", @ids_unordered},
    {:exchange, "workflow_correlated_post", @ids_unordered},
    {:exchange, "workflow_correlated_post_closed", @ids_unordered},
    {:exchange, "workflow_correlated_post_empty"},
    {:exchange, "workflow_running", @ids_unordered},
    {:exchange, "workflow_running_other_version", @ids_unordered},
    {:exchange, "workflow_running_time", @ids_unordered},
    {:exchange, "workflow_running_time_other_version", @ids_unordered},
    {:exchange, "workflow_running_unknown", @ids_unordered},
    # task updates by reference and signals that find no task
    {:exchange, "task_ref_update_workflow_not_found"},
    {:exchange, "task_ref_update_sync_workflow_not_found"},
    {:exchange, "task_ref_update_no_task"},
    {:exchange, "task_ref_update_sync_no_task"},
    {:exchange, "task_ref_update_status_invalid"},
    {:exchange, "task_signal_workflow_not_found"},
    {:exchange, "task_signal_sync_workflow_not_found"},
    {:exchange, "task_signal_no_task"},
    {:exchange, "task_signal_sync_no_task"},
    # Later and Unsupported routes shaped like the new parameter routes
    {:exchange, "route_unsupported_workflow_decide", @no_route},
    {:exchange, "route_later_tasks_requeue", @no_route},
    {:exchange, "route_later_workflow_bulk_search", @no_route},
    {:exchange, "route_later_task_log", @no_route},
    # execute
    {:exchange, "workflow_execute_not_found"},
    {:exchange, "workflow_execute"},
    {:exchange, "workflow_execute_blocking_workflow"},
    {:exchange, "workflow_execute_blocking_task"},
    {:exchange, "workflow_execute_blocking_task_input"},
    {:exchange, "workflow_execute_latest"},
    # The message names a JVM lambda class.
    {:exchange, "workflow_execute_completed_blocking_task", ignore: [["message"]]},
    {:exchange, "workflow_execute_wait_until_task"},
    {:exchange, "workflow_execute_timeout"},
    {:exchange, "workflow_execute_timeout_blocking_task"},
    {:exchange, "workflow_execute_inline"},
    # signal
    {:exchange, "workflow_start_signal"},
    {:exchange, "workflow_get_signal", @first_in_progress},
    {:exchange, "task_signal_sync"},
    {:exchange, "task_signal_sync_blocking_workflow"},
    {:exchange, "task_signal_sync_blocking_task"},
    {:exchange, "task_signal_sync_blocking_task_input"},
    {:exchange, "task_signal_sync_timeout"},
    {:exchange, "task_signal_sync_no_wait"},
    {:exchange, "task_signal_no_wait"},
    {:exchange, "workflow_get_signal_no_wait"},
    {:exchange, "task_signal"},
    {:exchange, "workflow_get_signaled", until: [{["tasks", 1, "status"], "IN_PROGRESS"}]},
    {:exchange, "workflow_start_signal_parent"},
    {:exchange, "workflow_get_signal_parent", @child_started},
    {:exchange, "workflow_get_signal_child", @first_in_progress},
    {:exchange, "task_signal_sync_child"},
    # task updates by reference
    {:exchange, "workflow_start_ref"},
    {:exchange, "task_ref_update"},
    {:exchange, "workflow_get_ref_updated", @two_tasks},
    {:exchange, "task_ref_update_sync"},
    {:exchange, "task_ref_update_done"},
    {:exchange, "workflow_start_loop"},
    {:exchange, "task_ref_update_loop"},
    {:exchange, "workflow_get_loop_second", [until: [{["tasks"], {:length, 3}}]]},
    {:exchange, "task_ref_update_loop_second"},
    {:wait_status, "workflow_start_loop", "COMPLETED"},
    {:exchange, "workflow_get_loop_completed"},
    # pause and resume
    {:exchange, "workflow_start_life"},
    {:exchange, "workflow_start_life_v2"},
    {:exchange, "workflow_get_life_v2"},
    {:exchange, "workflow_pause"},
    {:exchange, "workflow_get_paused"},
    {:exchange, "workflow_pause_paused"},
    {:exchange, "workflow_skiptask_paused"},
    {:exchange, "workflow_running_ops", @ids_unordered},
    {:exchange, "workflow_running_ops_time", @ids_unordered},
    {:exchange, "workflow_correlated_paused", @ids_unordered},
    {:exchange, "workflow_correlated_paused_closed", @ids_unordered},
    {:exchange, "workflow_resume"},
    {:exchange, "workflow_get_resumed"},
    # skiptask
    {:exchange, "workflow_start_skip"},
    {:exchange, "workflow_get_skip"},
    {:exchange, "workflow_skiptask"},
    {:exchange, "workflow_get_skipped"},
    {:exchange, "workflow_skiptask_again"},
    {:exchange, "workflow_tasks_skipped"},
    {:exchange, "task_update_skip_a"},
    {:wait_status, "workflow_start_skip", "COMPLETED"},
    {:exchange, "workflow_get_skip_completed"},
    # resetcallbacks
    {:exchange, "workflow_start_callback"},
    {:poll_until, "task_poll_callback"},
    {:exchange, "task_update_callback"},
    {:exchange, "workflow_get_callback"},
    {:exchange, "task_poll_callback_postponed"},
    {:exchange, "workflow_resetcallbacks"},
    {:exchange, "workflow_get_callback_reset"},
    {:exchange, "task_poll_callback_reset"},
    # retry and restart
    {:exchange, "workflow_start_retry"},
    {:exchange, "workflow_get_retry"},
    {:exchange, "task_update_retry_a"},
    {:wait_status, "workflow_start_retry", "FAILED"},
    {:exchange, "workflow_get_retry_failed"},
    {:exchange, "workflow_retry"},
    {:exchange, "workflow_get_retried"},
    {:exchange, "workflow_start_restart"},
    {:exchange, "workflow_terminate_restart"},
    {:exchange, "workflow_restart"},
    {:exchange, "workflow_get_restarted"},
    {:exchange, "workflow_terminate_restarted"},
    {:exchange, "workflow_restart_latest"},
    {:exchange, "workflow_get_restarted_latest"},
    # rerun: from a task, from the start, from a SUB_WORKFLOW, from a child's task
    {:exchange, "workflow_start_rerun"},
    {:exchange, "workflow_get_rerun"},
    {:exchange, "task_update_rerun_a"},
    {:exchange, "workflow_get_rerun_b", @two_tasks},
    {:exchange, "task_update_rerun_b"},
    {:wait_status, "workflow_start_rerun", "COMPLETED"},
    {:exchange, "workflow_rerun_from_task"},
    {:exchange, "workflow_get_rerun_from_task"},
    {:exchange, "workflow_terminate_rerun"},
    {:exchange, "workflow_rerun"},
    {:exchange, "workflow_get_rerun_whole"},
    {:exchange, "workflow_start_parent"},
    {:exchange, "workflow_get_parent", @child_started},
    {:exchange, "workflow_get_parent_child", @one_task},
    {:exchange, "task_update_parent_child"},
    {:wait_status, "workflow_start_parent", "FAILED"},
    {:exchange, "workflow_rerun_sub_workflow"},
    {:exchange, "workflow_get_rerun_sub_workflow", @child_started},
    {:exchange, "workflow_get_rerun_new_child", @one_task},
    {:exchange, "task_update_rerun_new_child"},
    {:wait_status, "workflow_start_parent", "FAILED"},
    {:exchange, "workflow_rerun_child_task"},
    {:exchange, "workflow_get_rerun_child_parent"},
    {:exchange, "workflow_get_rerun_child"},
    # a task in the first child of a retried SUB_WORKFLOW (top, mid, child)
    {:exchange, "workflow_start_top"},
    {:exchange, "workflow_get_top", @child_started},
    {:exchange, "workflow_get_mid", @child_started},
    {:exchange, "workflow_get_child_first", @one_task},
    {:exchange, "task_update_child_first"},
    {:exchange, "workflow_get_mid_retried",
     until: [{["tasks"], {:length, 2}}, {["tasks", 1, "subWorkflowId"], :present}]},
    {:exchange, "workflow_get_child_second", @one_task},
    {:exchange, "task_update_child_second"},
    {:wait_status, "workflow_start_top", "FAILED"},
    {:exchange, "workflow_get_mid_failed"},
    {:exchange, "workflow_get_top_failed"},
    {:exchange, "workflow_rerun_retried_child"},
    {:exchange, "workflow_get_rerun_top"},
    {:exchange, "workflow_get_rerun_mid", [until: [{["status"], "FAILED"}]]},
    {:exchange, "workflow_get_rerun_child_first", [until: [{["status"], "TERMINATED"}]]},
    # remove and terminate-remove
    {:exchange, "workflow_start_remove"},
    {:exchange, "workflow_get_remove"},
    {:exchange, "task_update_remove_a"},
    {:wait_status, "workflow_start_remove", "FAILED"},
    {:exchange, "workflow_remove"},
    {:exchange, "workflow_get_removed"},
    {:exchange, "workflow_remove_removed"},
    {:exchange, "workflow_start_remove_running"},
    {:exchange, "workflow_remove_no_archive"},
    {:exchange, "workflow_get_removed_running"},
    {:exchange, "workflow_start_terminate_remove"},
    {:exchange, "workflow_terminate_remove"},
    {:exchange, "workflow_get_terminate_removed"},
    # bulk: each step after the first mixed one needs the ones before it
    {:exchange, "workflow_bulk_pause_empty"},
    {:exchange, "workflow_bulk_pause_too_many"},
    {:exchange, "workflow_bulk_pause_null_body"},
    {:exchange, "workflow_start_bulk_1"},
    {:exchange, "workflow_start_bulk_2"},
    {:exchange, "workflow_bulk_pause"},
    {:exchange, "workflow_bulk_pause_single"},
    {:exchange, "workflow_bulk_resume"},
    {:exchange, "workflow_bulk_terminate"},
    {:exchange, "workflow_bulk_retry"},
    {:exchange, "workflow_bulk_restart"},
    {:exchange, "workflow_get_bulk_restarted"},
    {:exchange, "workflow_bulk_remove"},
    {:exchange, "workflow_get_bulk_removed"},
    {:exchange, "workflow_get_bulk_terminate_remove"},
    {:exchange, "workflow_bulk_terminate_remove"},
    {:exchange, "workflow_get_bulk_terminate_removed"},
    # deleting definitions
    {:exchange, "metadata_delete_workflow"},
    {:exchange, "metadata_get_workflow_deleted"},
    {:exchange, "metadata_get_workflow_after_delete"},
    {:exchange, "metadata_delete_taskdef"},
    {:exchange, "metadata_get_taskdef_deleted"},
    # Phase 7 system task types (ADR 0026, decision 8): each step names the types it needs
    {:exchange, "p7_register_taskdefs"},
    # TERMINATE
    {:exchange, "p7_terminate_register_completed", @terminate},
    {:exchange, "p7_terminate_register_failed", @terminate},
    {:exchange, "p7_terminate_register_terminated", @terminate},
    {:exchange, "p7_terminate_register_not_string", @terminate},
    {:exchange, "p7_terminate_register_expression", @terminate},
    {:exchange, "p7_terminate_completed_start", @terminate},
    {:exchange, "p7_terminate_completed_get", @terminate ++ @settled},
    {:exchange, "p7_terminate_failed_start", @terminate},
    {:exchange, "p7_terminate_failed_get", @terminate ++ @settled},
    {:exchange, "p7_terminate_terminated_start", @terminate},
    {:exchange, "p7_terminate_terminated_get", @terminate ++ @settled},
    # SET_VARIABLE
    {:exchange, "p7_set_variable_register", @set_variable},
    {:exchange, "p7_set_variable_start", @set_variable},
    {:exchange, "p7_set_variable_get", @set_variable ++ @settled},
    {:exchange, "p7_set_variable_register_big", @set_variable},
    {:exchange, "p7_set_variable_big_start", @set_variable},
    {:exchange, "p7_set_variable_big_get", @set_variable ++ @settled},
    {:exchange, "p7_set_variable_register_fork", @set_variable},
    {:exchange, "p7_set_variable_fork_start", @set_variable},
    {:exchange, "p7_set_variable_fork_get", @set_variable ++ @settled},
    # NOOP
    {:exchange, "p7_noop_register", @noop},
    {:exchange, "p7_noop_start", @noop},
    {:exchange, "p7_noop_get", @noop ++ @settled},
    # HUMAN
    {:exchange, "p7_human_register", @human},
    {:exchange, "p7_human_start", @human},
    {:exchange, "p7_human_get", @human ++ @settled},
    {:exchange, "p7_human_update", @human},
    {:exchange, "p7_human_get_completed", @human ++ @settled},
    # EXCLUSIVE_JOIN
    {:exchange, "p7_exclusive_join_register", @exclusive_join},
    {:exchange, "p7_exclusive_join_case_start", @exclusive_join},
    {:exchange, "p7_exclusive_join_case_get", @exclusive_join ++ @settled},
    {:exchange, "p7_exclusive_join_case_update", @exclusive_join},
    {:exchange, "p7_exclusive_join_case_get_ended", @exclusive_join ++ @settled},
    {:exchange, "p7_exclusive_join_default_start", @exclusive_join},
    {:exchange, "p7_exclusive_join_default_get", @exclusive_join ++ @settled},
    {:exchange, "p7_exclusive_join_default_update", @exclusive_join},
    {:exchange, "p7_exclusive_join_default_get_ended", @exclusive_join ++ @settled},
    {:exchange, "p7_exclusive_join_failed_start", @exclusive_join},
    {:exchange, "p7_exclusive_join_failed_get", @exclusive_join ++ @settled},
    {:exchange, "p7_exclusive_join_failed_update", @exclusive_join ++ @permissive_join_update},
    {:exchange, "p7_exclusive_join_failed_get_ended", @exclusive_join ++ @permissive_join_ended},
    # DYNAMIC
    {:exchange, "p7_dynamic_register", @dynamic},
    {:exchange, "p7_dynamic_start", @dynamic},
    {:exchange, "p7_dynamic_get", @dynamic ++ @settled},
    {:exchange, "p7_dynamic_update", @dynamic},
    {:exchange, "p7_dynamic_get_completed", @dynamic ++ @settled},
    {:exchange, "p7_dynamic_missing_start", @dynamic},
    {:exchange, "p7_dynamic_missing_get", @dynamic ++ @settled},
    {:exchange, "p7_dynamic_no_name_start", @dynamic},
    {:exchange, "p7_dynamic_no_name_get", @dynamic ++ @settled},
    {:exchange, "p7_dynamic_system_start", @dynamic_noop},
    {:exchange, "p7_dynamic_system_get", @dynamic_noop ++ @settled},
    # FORK_JOIN_DYNAMIC
    {:exchange, "p7_fjd_register_simple", @fork_join_dynamic},
    {:exchange, "p7_fjd_simple_start", @fork_join_dynamic},
    {:exchange, "p7_fjd_simple_get", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_simple_update_0", @fork_join_dynamic},
    {:exchange, "p7_fjd_simple_update_1", @fork_join_dynamic},
    {:exchange, "p7_fjd_simple_get_completed", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_register_param", @fork_join_dynamic},
    {:exchange, "p7_fjd_param_start", @fork_join_dynamic},
    {:exchange, "p7_fjd_param_get", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_param_update_0", @fork_join_dynamic},
    {:exchange, "p7_fjd_param_update_1", @fork_join_dynamic},
    {:exchange, "p7_fjd_param_get_completed", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_register_legacy", @fork_join_dynamic},
    {:exchange, "p7_fjd_legacy_start", @fork_join_dynamic},
    {:exchange, "p7_fjd_legacy_get", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_legacy_update_0", @fork_join_dynamic},
    {:exchange, "p7_fjd_legacy_update_1", @fork_join_dynamic},
    {:exchange, "p7_fjd_legacy_get_completed", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_register_no_join", @fork_join_dynamic},
    {:exchange, "p7_fjd_no_join_start", @fork_join_dynamic},
    {:exchange, "p7_fjd_no_join_get", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_retry_start", @fork_join_dynamic},
    {:exchange, "p7_fjd_retry_get", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_retry_fail", @fork_join_dynamic},
    {:exchange, "p7_fjd_retry_get_failed", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_retry", @fork_join_dynamic},
    {:exchange, "p7_fjd_retried_get", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_retried_update_0", @fork_join_dynamic},
    {:exchange, "p7_fjd_retried_update_1", @fork_join_dynamic},
    {:exchange, "p7_fjd_retried_get_completed", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_rerun_branch", @fork_join_dynamic},
    {:exchange, "p7_fjd_rerun_branch_get", @fork_join_dynamic ++ @settled},
    {:exchange, "p7_fjd_rerun_terminate", @fork_join_dynamic},
    {:exchange, "p7_fjd_rerun_fork", @fork_join_dynamic},
    {:exchange, "p7_fjd_rerun_fork_get", @fork_join_dynamic ++ @settled},
    # INLINE
    {:exchange, "p7_inline_register", @inline},
    {:exchange, "p7_inline_javascript_start", @inline},
    {:exchange, "p7_inline_javascript_get", @inline ++ @settled},
    {:exchange, "p7_inline_value_param_start", @inline},
    {:exchange, "p7_inline_value_param_get", @inline ++ @settled},
    {:exchange, "p7_inline_unknown_start", @inline},
    {:exchange, "p7_inline_unknown_get", @inline ++ @settled},
    {:exchange, "p7_inline_script_error_start", @inline},
    {:exchange, "p7_inline_script_error_get", @inline ++ @settled},
    {:exchange, "p7_inline_evaluator_not_string_start", @inline},
    {:exchange, "p7_inline_expression_not_string_start", @inline},
    # LAMBDA
    {:exchange, "p7_lambda_register", @lambda},
    {:exchange, "p7_lambda_start", @lambda},
    {:exchange, "p7_lambda_get", @lambda ++ @settled},
    {:exchange, "p7_lambda_error_start", @lambda},
    {:exchange, "p7_lambda_error_get", @lambda ++ @settled},
    {:exchange, "p7_lambda_empty_start", @lambda},
    {:exchange, "p7_lambda_empty_get", @lambda ++ @settled},
    # JSON_JQ_TRANSFORM
    {:exchange, "p7_jq_register", @jq},
    {:exchange, "p7_jq_start", @jq},
    {:exchange, "p7_jq_get", @jq ++ @settled},
    {:exchange, "p7_jq_null_start", @jq},
    {:exchange, "p7_jq_null_get", @jq ++ @settled},
    {:exchange, "p7_jq_syntax_start", @jq},
    {:exchange, "p7_jq_syntax_get", @jq ++ @settled},
    {:exchange, "p7_jq_missing_start", @jq},
    {:exchange, "p7_jq_missing_get", @jq ++ @settled},
    {:exchange, "p7_jq_not_string_start", @jq},
    {:exchange, "p7_jq_not_string_get", @jq ++ @settled},
    {:exchange, "p7_jq_register_invalid", @jq},
    # START_WORKFLOW
    {:exchange, "p7_start_workflow_register", @start_workflow},
    {:exchange, "p7_start_workflow_start", @start_workflow},
    {:exchange, "p7_start_workflow_get", @start_workflow ++ @settled},
    {:exchange, "p7_start_workflow_get_started", @start_workflow ++ @settled},
    {:exchange, "p7_start_workflow_invalid_start", @start_workflow},
    {:exchange, "p7_start_workflow_invalid_get", @start_workflow ++ @settled},
    {:exchange, "p7_start_workflow_missing_start", @start_workflow},
    {:exchange, "p7_start_workflow_missing_get", @start_workflow ++ @settled},
    # HTTP
    {:exchange, "p7_http_register", @http},
    {:exchange, "p7_http_json_start", @http},
    {:exchange, "p7_http_json_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_post_start", @http},
    {:exchange, "p7_http_post_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_text_start", @http},
    {:exchange, "p7_http_text_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_number_start", @http},
    {:exchange, "p7_http_number_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_status_299_start", @http},
    {:exchange, "p7_http_status_299_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_short_404_start", @http},
    {:exchange, "p7_http_short_404_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_long_400_start", @http},
    {:exchange, "p7_http_long_400_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_empty_404_start", @http},
    {:exchange, "p7_http_empty_404_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_short_503_start", @http},
    {:exchange, "p7_http_short_503_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_refused_start", @http},
    {:exchange, "p7_http_refused_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_no_uri_start", @http},
    {:exchange, "p7_http_no_uri_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_no_method_start", @http},
    {:exchange, "p7_http_no_method_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_register_async", @http},
    {:exchange, "p7_http_async_start", @http},
    {:exchange, "p7_http_async_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_async_update", @http},
    {:exchange, "p7_http_async_get_completed", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_register_async_input", @http},
    {:exchange, "p7_http_async_input_start", @http},
    {:exchange, "p7_http_async_input_get", @http ++ @settled ++ @http_volatile},
    {:exchange, "p7_http_register_invalid", @http}
  ]

  @doc "Every captured exchange in capture order, with the waits between them."
  @spec scenario() :: [step()]
  def scenario, do: @scenario

  @doc """
  The steps of `scenario/0` from fixture `first` through fixture `last`, both included (a
  `:wait_status` step is found by the start fixture it names).
  """
  @spec steps(String.t(), String.t()) :: [step()]
  def steps(first, last) do
    from = index!(first)
    through = index!(last)
    true = from <= through
    Enum.slice(@scenario, from..through)
  end

  defp index!(name) do
    Enum.find_index(@scenario, &(elem(&1, 1) == name)) ||
      raise ArgumentError, "no step for fixture #{inspect(name)}"
  end

  @doc """
  An empty ID mapping. `http_stub:` is the base URL of the replay's `Archon.HttpStub`, put in
  place of `captured_http_stub/0`.
  """
  @spec new_state(keyword()) :: state()
  def new_state(opts \\ []), do: %{ids: %{}, actuals: %{}, http_stub: opts[:http_stub]}

  @doc "The base URL the capture ran `Archon.HttpStub` at."
  @spec captured_http_stub() :: String.t()
  def captured_http_stub, do: @captured_http_stub

  @doc """
  Whether a step runs: its `types:` all have a mapper of their own (ADR 0026, decision 8).
  """
  @spec runs?(step()) :: boolean()
  def runs?({:exchange, _name, opts}),
    do: opts |> Keyword.get(:types, []) |> Enum.all?(&Mapper.mapped?/1)

  def runs?(_step), do: true

  @doc "Binds captured UUID `captured` to `actual`, one-to-one (see the moduledoc)."
  @spec bind(state(), String.t(), String.t()) :: state()
  def bind(state, captured, actual) do
    case state.ids do
      %{^captured => ^actual} ->
        state

      %{^captured => bound} ->
        flunk("captured ID #{captured} is bound to #{bound}, not #{actual}")

      _unbound ->
        case state.actuals do
          %{^actual => other} ->
            flunk("#{actual} is already bound to captured ID #{other}, not to #{captured}")

          _free ->
            %{
              state
              | ids: Map.put(state.ids, captured, actual),
                actuals: Map.put(state.actuals, actual, captured)
            }
        end
    end
  end

  @doc """
  Removes the definitions named `names` from the runtime's store, whichever backend it is (there
  is no remove operation in `Archon.Runtime.Metadata`, as the MVP has no delete route). A test
  replaying registrations calls it first: the capture ran on an empty server.
  """
  @spec remove_definitions([String.t()]) :: :ok
  def remove_definitions(names) do
    case Archon.Runtime.metadata() do
      Archon.Runtime.Metadata.Memory ->
        :sys.replace_state(Archon.Runtime.Metadata.Memory, fn state ->
          %{
            state
            | task_defs: Map.drop(state.task_defs, names),
              workflow_defs:
                Map.reject(state.workflow_defs, fn {{name, _version}, _def} -> name in names end)
          }
        end)

      Archon.Runtime.Metadata.Postgres ->
        instance = Archon.Runtime.Postgres.runtime()

        for table <- ["meta_task_def", "meta_workflow_def"] do
          Archon.Repo.query!(
            "DELETE FROM #{Archon.Runtime.Postgres.table(instance, table)} WHERE name = ANY($1)",
            [names]
          )
        end
    end

    :ok
  end

  @doc "Replays `steps`, asserting every response; returns the ID mapping for the next steps."
  @spec replay([step()], state()) :: state()
  def replay(steps, state \\ new_state()) do
    steps |> Enum.filter(&runs?/1) |> Enum.reduce(state, &run/2)
  end

  defp run({:exchange, name}, state), do: run({:exchange, name, []}, state)

  defp run({:exchange, name, opts}, state) do
    case Keyword.fetch(opts, :until) do
      {:ok, :settled} ->
        conditions = settled(Contract.fixture(name)["response"]["body"])
        repeat(name, state, &holds?(&1.body, conditions), opts)

      {:ok, conditions} ->
        repeat(name, state, &holds?(&1.body, conditions), opts)

      :error ->
        fixture = Contract.fixture(name)
        {state, actual} = send_fixture(fixture, state)
        check(name, fixture, actual, state, opts)
    end
  end

  defp run({:poll_until, name}, state),
    do: repeat(name, state, fn actual -> actual.status == 200 end, [])

  defp run({:batch_poll_until, name}, state),
    do: repeat(name, state, fn actual -> match?([_ | _], actual.body) end, [])

  defp run({:wait_status, name, status}, state) do
    %{"response" => %{"body" => captured}} = Contract.fixture(name)

    case Map.fetch(state.ids, captured) do
      {:ok, id} -> wait_status(name, id, status, @attempts)
      :error -> flunk("#{name}: the started workflow's ID #{captured} was never bound")
    end

    state
  end

  defp repeat(name, state, done?, opts) do
    fixture = Contract.fixture(name)

    actual =
      repeat_until(fixture, state, done?, System.monotonic_time(:millisecond) + @deadline_ms)

    {state, _actual} = prepare_request(fixture["request"], state)
    check(name, fixture, actual, state, opts)
  end

  # The workflow status, the number of tasks and each task's status of a workflow GET.
  defp settled(%{"status" => status, "tasks" => tasks}) do
    [{["status"], status}, {["tasks"], {:length, length(tasks)}}] ++
      for {%{"status" => task_status}, index} <- Enum.with_index(tasks),
          do: {["tasks", index, "status"], task_status}
  end

  defp holds?(body, conditions) do
    Enum.all?(conditions, fn {path, condition} -> holds_at?(at(body, path), condition) end)
  end

  defp holds_at?(value, :present), do: value != nil
  defp holds_at?(value, {:length, n}), do: is_list(value) and length(value) == n
  defp holds_at?(value, expected), do: value == expected

  defp at(value, []), do: value
  defp at(map, [key | path]) when is_map(map) and is_binary(key), do: at(Map.get(map, key), path)

  defp at(list, [index | path]) when is_list(list) and is_integer(index),
    do: at(Enum.at(list, index), path)

  defp at(_other, _path), do: nil

  # The deadline counts the requests' own time (a poll can wait for its timeout).
  defp repeat_until(fixture, state, done?, deadline) do
    {_state, actual} = send_fixture(fixture, state)

    if done?.(actual) or System.monotonic_time(:millisecond) >= deadline do
      actual
    else
      Process.sleep(@attempt_ms)
      repeat_until(fixture, state, done?, deadline)
    end
  end

  defp wait_status(name, id, status, 0),
    do: flunk("#{name}: workflow #{id} did not reach #{status}")

  defp wait_status(name, id, status, attempts) do
    case Archon.Runtime.get_workflow(id, false) do
      {:ok, workflow} ->
        if Codec.enum_name(workflow.status) == status do
          :ok
        else
          Process.sleep(@attempt_ms)
          wait_status(name, id, status, attempts - 1)
        end

      {:error, reason} ->
        flunk("#{name}: workflow #{id} cannot be read: #{inspect(reason)}")
    end
  end

  # --- request ---------------------------------------------------------------------------------

  @doc false
  # Sends a fixture's request with the bound IDs (public for the helper's own tests).
  @spec send_fixture(map(), state()) :: {state(), map()}
  def send_fixture(fixture, state) do
    {state, request} = prepare_request(fixture["request"], state)
    {state, dispatch(request)}
  end

  defp prepare_request(%{"method" => method, "path" => path, "body" => body}, state) do
    {state, path} = request_ids(path, state)
    {state, body} = request_ids(body, state)
    {state, %{method: method, path: path, body: body}}
  end

  # A captured ID that is not bound yet appears first in a request: it is sent as it is.
  defp request_ids(string, state) when is_binary(string) do
    state =
      Contract.uuid_regex()
      |> Regex.scan(string)
      |> List.flatten()
      |> Enum.reduce(state, fn id, state ->
        if Map.has_key?(state.ids, id), do: state, else: bind(state, id, id)
      end)

    {state, substitute(string, state)}
  end

  defp request_ids(list, state) when is_list(list) do
    {items, state} =
      Enum.map_reduce(list, state, fn item, state -> swap(request_ids(item, state)) end)

    {state, items}
  end

  defp request_ids(map, state) when is_map(map) do
    {pairs, state} =
      Enum.map_reduce(map, state, fn {key, value}, state ->
        {state, value} = request_ids(value, state)
        {{key, value}, state}
      end)

    {state, Map.new(pairs)}
  end

  defp request_ids(other, state), do: {state, other}

  defp swap({state, value}), do: {value, state}

  defp dispatch(%{method: method, path: path, body: body}) do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      case body do
        nil ->
          Phoenix.ConnTest.dispatch(conn, @endpoint, method, path, nil)

        body ->
          raw = if is_binary(body), do: body, else: JSON.encode!(body)

          conn
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(@endpoint, method, path, raw)
      end

    content_type = conn |> Plug.Conn.get_resp_header("content-type") |> List.first()
    body = response_body(conn.resp_body, content_type)

    %{status: conn.status, content_type: content_type, body: body, path: path}
  end

  defp response_body(body, _content_type) when body in [nil, ""], do: nil

  defp response_body(body, content_type) do
    if String.starts_with?(content_type || "", "application/json"),
      do: JSON.decode!(body),
      else: body
  end

  # --- response --------------------------------------------------------------------------------

  @doc false
  # Compares one response with a fixture (public for the helper's own tests): `actual` is
  # `%{status:, content_type:, body:, path:}`.
  @spec check(String.t(), map(), map(), state(), exchange_opts()) :: state()
  def check(name, fixture, actual, state, opts \\ []) do
    expected = fixture["response"]

    case Keyword.get(opts, :expect) do
      # Upstream's answer has nothing to do with Archon's 404: no ID is bound from it.
      :no_route ->
        assert_no_route(name, actual)
        state

      # A deliberate difference where upstream fails: Archon's own answer, nothing bound.
      {:archon, status, conditions} ->
        assert actual.status == status and holds?(actual.body, conditions),
               "#{name}: Archon's answer is not the expected #{status} with " <>
                 "#{inspect(conditions)}\nArchon: #{inspect(actual)}"

        state

      nil ->
        actual = only(actual, expected["body"], Keyword.get(opts, :only), state)

        # A body in no defined order binds nothing: its elements cannot be paired by position.
        state =
          if opts[:unordered],
            do: state,
            else: bind_response(expected["body"], actual.body, state)

        assert_same(name, expected, actual, state, opts)
        state
    end
  end

  defp only(actual, expected, :expected_names, _state)
       when is_list(expected) and is_list(actual.body) do
    names = MapSet.new(expected, &name/1)
    %{actual | body: Enum.filter(actual.body, &(name(&1) in names))}
  end

  defp only(actual, expected, :expected_names, _state)
       when is_map(expected) and is_map(actual.body) and not is_map_key(expected, "status") do
    %{actual | body: Map.take(actual.body, Map.keys(expected))}
  end

  defp only(actual, _expected, :bound_ids, state) when is_list(actual.body),
    do: %{actual | body: bound(actual.body, state)}

  defp only(actual, expected, :bound_ids, state)
       when is_map(actual.body) and not is_map_key(expected, "status") do
    %{actual | body: Map.new(actual.body, fn {key, list} -> {key, bound(list, state)} end)}
  end

  # Not the expected shape (an error): left for the comparison to report.
  defp only(actual, _expected, _only, _state), do: actual

  defp name(%{"name" => name}), do: name
  defp name(name), do: name

  defp bound(list, state) when is_list(list),
    do: Enum.filter(list, &Map.has_key?(state.actuals, workflow_id(&1)))

  defp bound(other, _state), do: other

  defp workflow_id(%{"workflowId" => id}), do: id
  defp workflow_id(id), do: id

  defp assert_no_route(name, actual) do
    "/" <> path = actual.path |> URI.parse() |> Map.fetch!(:path)

    assert %{status: 404, content_type: "application/json"} = actual, "#{name}: not a 404"

    assert %{
             "status" => 404,
             "message" => "No static resource " <> ^path <> ".",
             "instance" => instance,
             "retryable" => false
           } = actual.body,
           "#{name}: #{inspect(actual.body)}"

    assert is_binary(instance)
  end

  defp assert_same(name, expected, actual, state, opts) do
    want = %{
      status: expected["status"],
      content_type: expected["content_type"],
      body: comparable(substitute(expected["body"], state), opts)
    }

    got = %{
      status: actual.status,
      content_type: actual.content_type,
      body: comparable(actual.body, opts)
    }

    assert got == want,
           "#{name}: Archon's response differs from the fixture\n" <>
             "Archon:  #{inspect(got)}\nfixture: #{inspect(want)}"

    case Contract.fixture_schemas() do
      %{^name => {:response, schema}} ->
        assert Contract.validate_schema(schema, actual.body) == :ok, "#{name}: schema"

      _other ->
        :ok
    end
  end

  defp comparable(body, opts) do
    body
    |> Contract.mask_times()
    |> drop_paths(Keyword.get(opts, :ignore, []))
    |> mask_error()
    |> sort(opts[:unordered])
  end

  defp sort(list, true) when is_list(list), do: Enum.sort(list)

  defp sort(map, true) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, sort(value, true)} end)

  defp sort(body, _unordered), do: body

  defp drop_paths(body, paths) when is_map(body) do
    Enum.reduce(paths, body, fn path, body ->
      # A path through a value that is not there (an error body) is left for the comparison.
      if container?(at(body, Enum.drop(path, -1)), List.last(path)) do
        {_value, body} = pop_in(body, Enum.map(path, &access/1))
        body
      else
        body
      end
    end)
  end

  defp drop_paths(body, _paths), do: body

  defp container?(list, index) when is_integer(index), do: is_list(list)
  defp container?(map, _key), do: is_map(map)

  defp access(index) when is_integer(index), do: Access.at(index)
  defp access(key), do: Access.key(key)

  defp mask_error(body) when is_map(body) do
    body = if Map.has_key?(body, "instance"), do: %{body | "instance" => "<host>"}, else: body

    case body do
      %{"validationErrors" => errors} when is_list(errors) ->
        %{body | "validationErrors" => Enum.sort(errors)}

      body ->
        body
    end
  end

  defp mask_error(body), do: body

  defp bind_response(expected, actual, state) when is_binary(expected) and is_binary(actual) do
    captured = expected |> scan_ids()
    produced = actual |> scan_ids()

    if length(captured) == length(produced) do
      captured |> Enum.zip(produced) |> Enum.reduce(state, &bind_new/2)
    else
      state
    end
  end

  defp bind_response(expected, actual, state) when is_list(expected) and is_list(actual) do
    expected
    |> Enum.zip(actual)
    |> Enum.reduce(state, fn {expected, actual}, state ->
      bind_response(expected, actual, state)
    end)
  end

  defp bind_response(expected, actual, state) when is_map(expected) and is_map(actual) do
    Enum.reduce(expected, state, fn {key, value}, state ->
      case actual do
        %{^key => produced} -> bind_response(value, produced, state)
        _missing -> state
      end
    end)
  end

  defp bind_response(_expected, _actual, state), do: state

  # Only the first appearance binds; a later mismatch is the comparison's to report.
  defp bind_new({captured, produced}, state) do
    if Map.has_key?(state.ids, captured), do: state, else: bind(state, captured, produced)
  end

  defp scan_ids(string), do: Contract.uuid_regex() |> Regex.scan(string) |> List.flatten()

  defp substitute(string, state) when is_binary(string) do
    string = Regex.replace(Contract.uuid_regex(), string, &Map.get(state.ids, &1, &1))

    case Map.get(state, :http_stub) do
      nil -> string
      url -> String.replace(string, @captured_http_stub, url)
    end
  end

  defp substitute(list, state) when is_list(list), do: Enum.map(list, &substitute(&1, state))

  # Keys too: a BulkResponse's errors are keyed by workflow ID.
  defp substitute(map, state) when is_map(map),
    do: Map.new(map, fn {key, value} -> {substitute(key, state), substitute(value, state)} end)

  defp substitute(other, _state), do: other
end
