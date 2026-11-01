defmodule Archon.Runtime.PostgresTest do
  @moduledoc """
  The Postgres foundation (ADR 0021, decisions 1, 2 and 7): the instance, the migrations in both
  schemas, the storage encoding in a `json_data text` column and the write fence.
  """

  use Archon.PostgresCase

  alias Archon.Domain.{Workflow, WorkflowDef}
  alias Archon.Release

  @scratch "archon_migration_test"
  # The first migration: the runtime tables.
  @first 20_261_031_000_000

  describe "new/1" do
    test "defaults to the runtime schema without fencing" do
      assert %Postgres{repo: Repo, prefix: "public", fence: nil} = Postgres.new()
    end

    test "rejects a schema name that is not a plain identifier" do
      for prefix <- ["Public", "a-b", ~s(x"; DROP TABLE y; --), "", "1a"] do
        assert_raise ArgumentError, fn -> Postgres.new(prefix: prefix) end
      end
    end

    test "rejects an unknown fence" do
      assert_raise ArgumentError, fn -> Postgres.new(fence: :maybe) end
    end

    test "quotes the schema-qualified table name" do
      assert Postgres.table(Postgres.new(prefix: "archon_contract"), "task") ==
               ~s("archon_contract"."task")
    end
  end

  describe "migrations" do
    setup do
      on_exit(fn -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{@scratch}" CASCADE)) end)
    end

    test "create the schema, the tables and the node_lease row, and roll back" do
      assert [@first, _query_columns] = Release.migrate(Repo, @scratch)
      assert tables(@scratch) == ~w(meta_task_def meta_workflow_def node_lease outbox poll_data
                                     queue_message schema_migrations task workflow)
      assert Repo.query!(~s(SELECT id, epoch FROM "#{@scratch}".node_lease)).rows == [[1, 0]]
      assert Release.migrate(Repo, @scratch) == []

      assert [_query_columns, @first] = Release.rollback(Repo, @scratch, 0)
      assert tables(@scratch) == ["schema_migrations"]

      assert [@first, _query_columns] = Release.migrate(Repo, @scratch)
      assert Repo.query!(~s(SELECT id, epoch FROM "#{@scratch}".node_lease)).rows == [[1, 0]]
    end

    # ADR 0025, decision 4: the query columns of the rows written before the migration.
    test "the query columns are filled from json_data, a NUL left NULL" do
      migrate_to(@first)

      rows = [
        {"w-1",
         %Workflow{
           workflow_id: "w-1",
           status: :paused,
           workflow_definition: %WorkflowDef{name: "flow", version: 2},
           correlation_id: "corr",
           create_time: 1_793_571_042_687
         }},
        # A literal backslash before "u0000" is not a NUL.
        {"w-2",
         %Workflow{
           workflow_id: "w-2",
           status: :completed,
           workflow_definition: %WorkflowDef{name: "fl\\u0000ow", version: 1},
           correlation_id: "c\u0000rr",
           create_time: 5
         }},
        {"w-3", %Workflow{workflow_id: "w-3", status: :running}}
      ]

      for {id, workflow} <- rows do
        Repo.query!(
          ~s|INSERT INTO "#{@scratch}".workflow (workflow_id, status, json_data) | <>
            "VALUES ($1, 'RUNNING', $2)",
          [id, workflow |> Workflow.to_storage() |> JSON.encode!()]
        )
      end

      assert [_query_columns] = Release.migrate(Repo, @scratch)

      assert Repo.query!(
               "SELECT workflow_id, workflow_name, workflow_version, correlation_id, create_time " <>
                 ~s|FROM "#{@scratch}".workflow ORDER BY workflow_id|
             ).rows == [
               ["w-1", "flow", 2, "corr", 1_793_571_042_687],
               ["w-2", "fl\\u0000ow", 1, nil, 5],
               ["w-3", nil, nil, nil, 0]
             ]
    end

    test "node_lease holds a single row" do
      Release.migrate(Repo, @scratch)

      assert_raise Postgrex.Error, ~r/node_lease_single_row/, fn ->
        Repo.query!(~s|INSERT INTO "#{@scratch}".node_lease (id, epoch) VALUES (2, 0)|)
      end
    end

    test "workflow ID columns compare in byte order" do
      for prefix <- [Postgres.runtime_prefix(), Postgres.contract_prefix()] do
        %{rows: rows} =
          Repo.query!(
            "SELECT table_name, collation_name FROM information_schema.columns " <>
              "WHERE table_schema = $1 AND column_name = 'workflow_id' ORDER BY 1",
            [prefix]
          )

        assert rows == [["outbox", "C"], ["task", "C"], ["workflow", "C"]]
      end
    end

    test "both test schemas are migrated" do
      assert "node_lease" in tables(Postgres.runtime_prefix())
      assert "node_lease" in tables(Postgres.contract_prefix())
    end
  end

  test "a workflow round-trips through json_data text, NUL included", %{instance: instance} do
    workflow = %Workflow{
      # Index columns are plain text and refuse NUL, as upstream's do; json_data escapes it.
      workflow_id: "w-1",
      status: :running,
      input: %{"k\u0000" => "v\u0000"},
      reason_for_incompletion: "\u0000",
      end_count: 3,
      revived_parent_end_count: 2
    }

    json = workflow |> Workflow.to_storage() |> JSON.encode!()

    Repo.query!(
      "INSERT INTO #{Postgres.table(instance, "workflow")} (workflow_id, status, json_data) " <>
        "VALUES ($1, 'RUNNING', $2)",
      [workflow.workflow_id, json]
    )

    %{rows: [[stored]]} =
      Repo.query!("SELECT json_data FROM #{Postgres.table(instance, "workflow")}")

    assert stored == json
    assert Workflow.from_storage(JSON.decode!(stored)) == {:ok, workflow}
  end

  describe "transaction/2" do
    test "without a fence commits fun's result", %{instance: instance} do
      assert Postgres.transaction(instance, fn -> insert_task_def(instance, "a") end) ==
               {:ok, :inserted}

      assert task_def_names(instance) == ["a"]
    end

    test "rolls back with the reason given to rollback/2", %{instance: instance} do
      assert Postgres.transaction(instance, fn ->
               insert_task_def(instance, "a")
               Postgres.rollback(instance, :nope)
             end) == {:error, :nope}

      assert task_def_names(instance) == []
    end
  end

  describe "transaction!/2" do
    test "returns fun's result, and raises on a fenced write or a rollback", %{instance: instance} do
      assert Postgres.transaction!(instance, fn -> insert_task_def(instance, "a") end) ==
               :inserted

      assert_raise ArgumentError, ~r/rollback/, fn ->
        Postgres.transaction!(instance, fn -> Postgres.rollback(instance, :nope) end)
      end

      keep_epoch()
      Postgres.clear_epoch()

      assert_raise Postgres.FencedError, fn ->
        Postgres.transaction!(%{instance | fence: :runtime}, fn ->
          insert_task_def(instance, "b")
        end)
      end

      assert task_def_names(instance) == ["a"]
    end
  end

  describe "the write fence" do
    setup %{instance: instance} do
      keep_epoch()
      Postgres.clear_epoch()
      %{fenced: %{instance | fence: :runtime}}
    end

    test "fences every write before an epoch is published", %{fenced: fenced} do
      assert Postgres.transaction(fenced, fn -> insert_task_def(fenced, "a") end) ==
               {:error, :fenced}

      assert task_def_names(fenced) == []
    end

    test "lets the node with the current epoch write", %{fenced: fenced} do
      assert {:ok, 1} = Postgres.advance_epoch(fenced)
      Postgres.put_epoch(1)

      assert Postgres.transaction(fenced, fn -> insert_task_def(fenced, "a") end) ==
               {:ok, :inserted}

      assert task_def_names(fenced) == ["a"]
    end

    test "fences a node whose epoch another node has passed", %{fenced: fenced} do
      {:ok, epoch} = Postgres.advance_epoch(fenced)
      Postgres.put_epoch(epoch)
      assert {:ok, 2} = Postgres.advance_epoch(fenced)

      assert Postgres.transaction(fenced, fn -> insert_task_def(fenced, "a") end) ==
               {:error, :fenced}

      assert task_def_names(fenced) == []
    end

    test "does not check an instance without a fence", %{instance: instance} do
      assert Postgres.epoch() == nil

      assert {:ok, :inserted} =
               Postgres.transaction(instance, fn -> insert_task_def(instance, "a") end)
    end

    test "raising the epoch waits for the writes already past the fence", %{fenced: fenced} do
      {:ok, epoch} = Postgres.advance_epoch(fenced)
      Postgres.put_epoch(epoch)
      test = self()

      writer =
        Task.async(fn ->
          Postgres.transaction(fenced, fn ->
            send(test, :fence_passed)
            receive do: (:commit -> insert_task_def(fenced, "a"))
          end)
        end)

      assert_receive :fence_passed
      advancer = Task.async(fn -> Postgres.advance_epoch(fenced) end)
      refute Task.yield(advancer, 200)

      send(writer.pid, :commit)
      assert Task.await(writer) == {:ok, :inserted}
      assert Task.await(advancer) == {:ok, epoch + 1}
      assert task_def_names(fenced) == ["a"]
    end

    # Under REPEATABLE READ the epoch read would reuse the snapshot taken before the lock wait.
    for isolation <- ["READ COMMITTED", "REPEATABLE READ"] do
      test "a write waiting for the fence reads the epoch raised while it waited (#{isolation})",
           %{fenced: fenced} do
        assert_fenced_after_wait(fenced, unquote(isolation))
      end
    end
  end

  defp assert_fenced_after_wait(fenced, isolation) do
    {:ok, epoch} = Postgres.advance_epoch(fenced)
    Postgres.put_epoch(epoch)
    test = self()

    # Holds the exclusive fence lock with the epoch already raised, as a new node does.
    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1)", [Postgres.fence_key()])

          Repo.query!(
            "UPDATE #{Postgres.table(fenced, "node_lease")} SET epoch = epoch + 1 WHERE id = 1"
          )

          send(test, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :locked

    writer =
      Task.async(fn ->
        # As if the server default isolation were stricter than READ COMMITTED.
        Repo.transaction(fn -> fenced_insert(fenced, isolation) end)
      end)

    refute Task.yield(writer, 200)

    send(holder.pid, :release)
    assert Task.await(holder) == {:ok, :ok}
    assert Task.await(writer) == {:error, :fenced}
    assert task_def_names(fenced) == []
  end

  defp fenced_insert(fenced, isolation) do
    Repo.query!("SET TRANSACTION ISOLATION LEVEL #{isolation}")

    case Postgres.check_fence(fenced) do
      :ok -> insert_task_def(fenced, "a")
      {:error, :fenced} -> Repo.rollback(:fenced)
    end
  end

  defp insert_task_def(instance, name) do
    Repo.query!(
      "INSERT INTO #{Postgres.table(instance, "meta_task_def")} (name, json_data) VALUES ($1, '{}')",
      [name]
    )

    :inserted
  end

  defp task_def_names(instance) do
    %{rows: rows} =
      Repo.query!("SELECT name FROM #{Postgres.table(instance, "meta_task_def")} ORDER BY name")

    List.flatten(rows)
  end

  # Release.migrate/2 runs every migration; this stops after `version`.
  defp migrate_to(version) do
    Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{@scratch}"))
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(Repo, :up, to: version, prefix: @scratch, log: false)
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  defp tables(schema) do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 ORDER BY 1",
        [schema]
      )

    List.flatten(rows)
  end
end
