# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.StoreTest do
  use ExUnit.Case, async: true
  use Archon.Runtime.StoreContract

  alias Archon.Runtime.Store.Memory

  setup do
    %{impl: Memory, server: start_supervised!({Memory, name: nil})}
  end

  test "the behaviour arities use the server named after the module" do
    # 3c starts the named instance under Archon.Runtime.Supervisor; use it when it is there.
    unless Process.whereis(Memory), do: start_supervised!(Memory, id: :named)
    wf = %Workflow{workflow_id: "store-test-named", status: :running}

    assert Memory.commit("store-test-named", %Commit{create: wf}) == :ok
    assert Memory.get_workflow("store-test-named", false) == {:ok, wf}
    assert Memory.get_task("none") == {:error, :not_found}
    assert "store-test-named" in Memory.running_workflow_ids()
    assert Memory.in_progress_count("store-test-task") == 0
    assert Memory.put_poll_data("store-test-task", nil, "w", 1) == :ok
    assert {:ok, %{worker_id: "w"}} = Memory.get_poll_data("store-test-task", nil)
    assert Memory.remove_workflow("store-test-named") == :ok
  end
end
