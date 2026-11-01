# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.MetadataPostgresTest do
  @moduledoc """
  `Archon.Runtime.Metadata.Postgres` against the metadata contract and its Postgres cases (ADR
  0021, decisions 2, 7 and 9).
  """

  use Archon.PostgresCase
  use Archon.Runtime.MetadataContract

  alias Archon.Domain.WorkflowTask
  alias Archon.Runtime.Metadata.Postgres, as: PgMetadata
  alias Archon.Runtime.Postgres.FencedError

  setup %{instance: instance} do
    %{impl: PgMetadata, server: instance}
  end

  test "definitions are stored as their storage encoding", %{server: server} do
    definition = %WorkflowDef{
      name: "stored\u0000text",
      version: 2,
      description: "nul \u0000 inside",
      tasks: [%WorkflowTask{name: "t", task_reference_name: "t", type: "SIMPLE"}]
    }

    # The name is an index column; only json_data may hold NUL.
    assert_raise ArgumentError, ~r/NUL/, fn ->
      PgMetadata.create_workflow_def(server, definition)
    end

    definition = %{definition | name: "stored"}
    assert PgMetadata.create_workflow_def(server, definition) == :ok

    %{rows: [["stored", 2, json]]} =
      Repo.query!("SELECT name, version, json_data FROM #{table(server, "meta_workflow_def")}")

    assert json == definition |> WorkflowDef.to_storage() |> JSON.encode!()
    assert PgMetadata.get_workflow_def(server, "stored", 2) == {:ok, definition}
  end

  test "versions are ordered as numbers", %{server: server} do
    for version <- [2, 10, 9],
        do: PgMetadata.create_workflow_def(server, %WorkflowDef{name: "n", version: version})

    assert {:ok, %WorkflowDef{version: 10}} = PgMetadata.get_latest_workflow_def(server, "n")
  end

  describe "NUL in a name" do
    test "cannot be written", %{server: server} do
      assert_raise ArgumentError, ~r/NUL/, fn ->
        PgMetadata.create_task_def(server, %TaskDef{name: "t\u0000"})
      end

      assert_raise ArgumentError, ~r/NUL/, fn ->
        PgMetadata.update_workflow_def(server, %WorkflowDef{name: "w\u0000", version: 1})
      end

      assert_raise ArgumentError, ~r/UTF-8/, fn ->
        PgMetadata.update_task_def(server, %TaskDef{name: <<0xFF>>})
      end
    end

    test "is not found", %{server: server} do
      assert PgMetadata.get_task_def(server, "t\u0000") == {:error, :not_found}
      assert PgMetadata.get_task_def(server, <<0xFF>>) == {:error, :not_found}
      assert PgMetadata.get_workflow_def(server, "w\u0000", 1) == {:error, :not_found}
      assert PgMetadata.get_latest_workflow_def(server, "w\u0000") == {:error, :not_found}
    end
  end

  describe "the write fence" do
    setup %{server: server} do
      keep_epoch()
      Postgres.clear_epoch()
      %{fenced: %{server | fence: :runtime}}
    end

    test "every write raises with a stale epoch and changes nothing", %{fenced: fenced} do
      for {fun, args} <- [
            create_task_def: [%TaskDef{name: "t"}],
            update_task_def: [%TaskDef{name: "t"}],
            create_workflow_def: [%WorkflowDef{name: "w", version: 1}],
            update_workflow_def: [%WorkflowDef{name: "w", version: 1}]
          ] do
        assert_raise FencedError, fn -> apply(PgMetadata, fun, [fenced | args]) end
      end

      # Reads are not fenced.
      assert PgMetadata.get_task_def(fenced, "t") == {:error, :not_found}
      assert PgMetadata.get_latest_workflow_def(fenced, "w") == {:error, :not_found}
      assert PgMetadata.get_all_task_defs(fenced) == []
    end

    test "writes with the published epoch", %{fenced: fenced} do
      {:ok, epoch} = Postgres.advance_epoch(fenced)
      Postgres.put_epoch(epoch)

      assert PgMetadata.create_task_def(fenced, %TaskDef{name: "t"}) == :ok
      assert PgMetadata.update_task_def(fenced, %TaskDef{name: "t"}) == :ok
      assert PgMetadata.create_workflow_def(fenced, %WorkflowDef{name: "w", version: 1}) == :ok

      assert PgMetadata.create_workflow_def(fenced, %WorkflowDef{name: "w", version: 1}) ==
               {:error, :conflict}

      assert PgMetadata.update_workflow_def(fenced, %WorkflowDef{name: "w", version: 1}) == :ok
      assert {:ok, %TaskDef{name: "t"}} = PgMetadata.get_task_def(fenced, "t")
    end
  end

  defp table(instance, name), do: Postgres.table(instance, name)
end
