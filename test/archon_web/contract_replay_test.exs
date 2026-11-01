# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.ContractReplayTest do
  @moduledoc """
  The whole capture scenario (`ArchonWeb.ContractCase.scenario/0`) replayed in one run through
  REST, the `metadata_*` registrations included (ADR 0023, decision 6, slice 5f). The slices'
  own replays leave parts out; this one starts from the store the capture started from: the
  fixtures' definitions other tests registered are removed first and put back afterwards. The
  Phase 6 steps whose actions are not implemented yet are skipped (ADR 0025, decision 7).

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
            archon_ops_top archon_ops_parent archon_ops_signal_parent)

  @queues ~w(archon_task_a archon_task_b archon_task_c archon_ops_a archon_ops_b archon_ops_c
             archon_ops_cb archon_ops_idle)

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
    replay(scenario())
  end
end
