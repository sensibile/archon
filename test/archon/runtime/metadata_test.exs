# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.MetadataTest do
  use ExUnit.Case, async: true
  use Archon.Runtime.MetadataContract

  alias Archon.Runtime.Metadata.Memory

  setup do
    %{impl: Memory, server: start_supervised!({Memory, name: nil})}
  end

  test "the behaviour arities use the server named after the module" do
    start_supervised!(Memory, id: :named)
    definition = %WorkflowDef{name: "named", version: 1}

    assert Memory.create_workflow_def(definition) == :ok
    assert Memory.update_workflow_def(definition) == :ok
    assert Memory.get_workflow_def("named", 1) == {:ok, definition}
    assert Memory.get_latest_workflow_def("named") == {:ok, definition}
    assert Memory.create_task_def(%TaskDef{name: "t"}) == :ok
    assert Memory.update_task_def(%TaskDef{name: "t"}) == :ok
    assert Memory.get_task_def("t") == {:ok, %TaskDef{name: "t"}}
  end
end
