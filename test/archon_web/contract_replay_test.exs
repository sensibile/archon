# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.ContractReplayTest do
  @moduledoc """
  The whole capture scenario (`ArchonWeb.ContractCase.scenario/0`) replayed in one run through
  REST, the `metadata_*` registrations included (ADR 0023, decision 6, slice 5f). The slices'
  own replays leave parts out; this one starts from the store the capture started from: the
  fixtures' definitions other tests registered are removed first and put back afterwards. Every
  Phase 6 step runs (ADR 0025, decision 7; slice 6h removed the skipping of steps not
  implemented yet), and so does every Phase 7 step (ADR 0026, decision 8; slice 7h removed the
  skipping of steps whose task type had no mapper yet). The Phase 8 steps that reach an action
  not implemented yet are skipped until their slice implements it (ADR 0027, decision 7).

  Runs on either backend (`ARCHON_BACKEND`, ADR 0021 decision 9).
  """

  use ArchonWeb.ContractCase, async: false

  @moduletag :capture_log

  alias Archon.RuntimeCase

  # Every definition name the fixtures register or start (inline definitions are not stored).
  @names ~w(archon_task_a archon_task_b archon_task_c archon_coerced archon_missing archon_simple
            archon_switch archon_fork archon_no_tasks archon_bulk archon_bulk_valid
            archon_bulk_invalid archon_ops_a archon_ops_b archon_ops_c archon_ops_cb
            archon_ops_idle archon_ops_sub archon_ops_sub_once archon_ops archon_ops_waits
            archon_ops_callback archon_ops_child archon_ops_noop archon_ops_loop archon_ops_mid
            archon_ops_top archon_ops_parent archon_ops_signal_parent NOOP archon_p7_worker
            archon_p7_terminate_completed archon_p7_terminate_failed archon_p7_terminate_terminated
            archon_p7_terminate_not_string archon_p7_terminate_expression archon_p7_set_variable
            archon_p7_set_variable_big archon_p7_set_variable_fork archon_p7_noop archon_p7_human
            archon_p7_exclusive_join archon_p7_dynamic archon_p7_fjd_simple archon_p7_fjd_param
            archon_p7_fjd_legacy archon_p7_fjd_no_join archon_p7_inline archon_p7_lambda
            archon_p7_jq archon_p7_jq_invalid archon_p7_start_workflow archon_p7_http
            archon_p7_http_async archon_p7_http_async_input archon_p7_http_invalid
            archon_p8_worker archon_p8_poll archon_p8_case archon_p8_fork_a archon_p8_fork_b
            archon_p8_sub archon_p8_search archon_p8_classified archon_p8_index archon_p8_sys
            archon_p8_skip archon_p8_remove archon_p8_child archon_p8_parent)

  @queues ~w(archon_task_a archon_task_b archon_task_c archon_ops_a archon_ops_b archon_ops_c
             archon_ops_cb archon_ops_idle archon_p7_worker archon_p8_worker archon_p8_poll
             archon_p8_case archon_p8_fork_a archon_p8_fork_b)

  setup do
    Archon.RuntimeHooks.reset()
    RuntimeCase.isolate_queues(@queues)
    remove_definitions(@names)

    on_exit(fn ->
      Archon.RuntimeHooks.reset()
      remove_definitions(@names)
      RuntimeCase.register_definitions()
    end)
  end

  test "every fixture in capture order" do
    # The HTTP task target (ADR 0026, decision 8), at the address the replay puts in place of
    # the captured one.
    stub = start_supervised!(Archon.HttpStub)
    replay(scenario(), new_state(http_stub: Archon.HttpStub.url(stub)))
  end
end
