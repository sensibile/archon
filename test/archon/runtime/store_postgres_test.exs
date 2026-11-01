# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.StorePostgresTest do
  @moduledoc """
  `Archon.Runtime.Store.Postgres` against the store contract and its Postgres cases (ADR 0021,
  decisions 2 to 5, 7 and 9).
  """

  use Archon.PostgresCase
  use Archon.Runtime.StoreContract

  alias Archon.Runtime.Postgres.FencedError
  alias Archon.Runtime.Queue.Postgres, as: PgQueue
  alias Archon.Runtime.Store.Postgres, as: PgStore

  setup %{instance: instance} do
    offset = :atomics.new(1, [])
    clock = fn -> 1_000_000 + :atomics.get(offset, 1) end
    server = %{instance | clock: clock}

    %{
      impl: PgStore,
      server: server,
      queue_impl: PgQueue,
      queue: server,
      now: clock,
      advance: &:atomics.add(offset, 1, &1)
    }
  end

  test "the behaviour arities use the runtime instance" do
    keep_epoch()
    Postgres.clear_epoch()
    assert PgStore.get_workflow("store-postgres-none", false) == {:error, :not_found}
    assert is_list(PgStore.running_workflow_ids())
    # Without a published epoch the runtime instance's writes are fenced.
    assert_raise FencedError, fn -> PgStore.remove_workflow("store-postgres-none") end
  end

  describe "rows" do
    test "keep index columns and the storage encoding without tasks", ctx do
      wf =
        workflow("wf1",
          parent_workflow_id: "parent",
          tasks: [task("wf1", 1, task_def_name: nil, task_type: "worker", status: :in_progress)]
        )

      create(ctx, wf)

      assert [["RUNNING", "parent", nil, json]] =
               Repo.query!(
                 "SELECT status, parent_workflow_id, wake_at, json_data FROM #{t(ctx, "workflow")}"
               ).rows

      refute Map.has_key?(JSON.decode!(json), "tasks")

      assert Repo.query!(
               "SELECT task_id, workflow_id, seq, status, task_def_name FROM #{t(ctx, "task")}"
             ).rows ==
               [["wf1_t1", "wf1", 1, "IN_PROGRESS", "worker"]]
    end

    # ADR 0025, decision 4: the query columns, NULL for what a column cannot hold.
    test "keep the definition name and version, correlation ID and create time", ctx do
      create(ctx, workflow("wf1"))

      create(
        ctx,
        workflow("wf2",
          workflow_definition: %WorkflowDef{name: "n\u0000", version: 2 ** 40},
          correlation_id: "c\u0000",
          create_time: 2 ** 70
        )
      )

      assert Repo.query!(
               "SELECT workflow_id, workflow_name, workflow_version, correlation_id, create_time " <>
                 "FROM #{t(ctx, "workflow")} ORDER BY workflow_id"
             ).rows == [
               ["wf1", "Junit Workflow", 3, "correlationX", 90],
               ["wf2", nil, nil, nil, nil]
             ]

      assert {:ok,
              %Workflow{correlation_id: "c\u0000", create_time: 1_180_591_620_717_411_303_424}} =
               s(ctx, :get_workflow, ["wf2", false])
    end

    test "NUL inside values goes through JSON and comes back", ctx do
      wf =
        workflow("wf1",
          input: %{"k\u0000" => "v\u0000"},
          tasks: [task("wf1", 1, output_data: %{"o" => "\u0000"})]
        )

      create(ctx, wf)
      assert {:ok, ^wf} = s(ctx, :get_workflow, ["wf1", true])
    end
  end

  describe "values the columns cannot hold" do
    test "a commit with NUL or invalid UTF-8 in an ID or name raises before writing", ctx do
      create(ctx, workflow("wf1"))

      bad = [
        {"wf\u0000", %Commit{create: workflow("wf\u0000")}},
        {<<0xFF>>, %Commit{create: workflow(<<0xFF>>)}},
        {"wf1", %Commit{upsert_tasks: [task("wf1", 1, task_id: "t\u0000")]}},
        {"wf1", %Commit{upsert_tasks: [task("wf1", 1, task_def_name: "n\u0000")]}},
        {"wf1", %Commit{workflow: workflow("wf1", parent_workflow_id: "p\u0000")}},
        {"wf1", %Commit{queue: [{:push, "q\u0000", "a", 0, 0}]}}
      ]

      for {id, commit} <- bad do
        assert_raise ArgumentError, ~r/UTF-8 without NUL/, fn -> s(ctx, :commit, [id, commit]) end
      end

      assert_raise ArgumentError, ~r/UTF-8 JSON/, fn ->
        commit(ctx, "wf1", workflow: workflow("wf1", input: %{"k" => <<0xFF>>}))
      end

      assert {:ok, %Workflow{tasks: [], input: %{"param1" => _}}} =
               s(ctx, :get_workflow, ["wf1", true])
    end

    test "a task without seq or status is refused before writing", ctx do
      create(ctx, workflow("wf1"))

      for bad <- [task("wf1", 1, seq: nil), task("wf1", 1, status: nil)] do
        assert_raise ArgumentError, ~r/seq and a status/, fn ->
          commit(ctx, "wf1", upsert_tasks: [bad])
        end
      end
    end

    test "reads and deletes treat such IDs as absent", ctx do
      create(ctx, workflow("wf1"))

      for id <- ["wf1\u0000", <<0xFF>>] do
        assert s(ctx, :get_workflow, [id, true]) == {:error, :not_found}
        assert s(ctx, :get_task, [id]) == {:error, :not_found}
        assert s(ctx, :remove_workflow, [id]) == {:error, :not_found}
        assert s(ctx, :in_progress_count, [id]) == 0
        assert s(ctx, :pending_outbox, [id]) == []
        assert s(ctx, :ack_outbox, [id, [1]]) == :ok
        assert s(ctx, :get_poll_data, [id, nil]) == {:error, :not_found}
        assert s(ctx, :get_poll_data, ["q", id]) == {:error, :not_found}
      end

      assert commit(ctx, "wf1", delete_task_ids: ["x\u0000"], limits: %{"n\u0000" => 1}) == :ok
      assert_raise ArgumentError, fn -> s(ctx, :put_poll_data, ["q\u0000", nil, "w", 1]) end
      assert_raise ArgumentError, fn -> s(ctx, :put_poll_data, ["q", nil, "w\u0000", 1]) end
    end

    test "a page cursor with NUL raises", ctx do
      assert_raise ArgumentError, fn -> s(ctx, :outbox_workflow_ids, ["a\u0000", 1]) end
      assert_raise ArgumentError, fn -> s(ctx, :due_workflow_ids, [0, {0, "a\u0000"}, 1]) end
    end
  end

  describe "outbox entries" do
    test "every outbox kind comes back, a notice with the stored child", ctx do
      definition = %WorkflowDef{name: "failure", version: 2}

      start = %{
        workflow_id: "f1",
        name: "failure",
        version: nil,
        definition: definition,
        input: %{"reason" => "boom", "nested" => %{"n" => [1, nil, "\u0000"]}},
        correlation_id: nil,
        priority: 3,
        task_to_domain: %{"a" => "b"},
        parent_workflow_id: nil,
        parent_workflow_task_id: nil,
        triggering_workflow_id: "wf1",
        idempotency_key: nil,
        idempotency_strategy: nil
      }

      effects = [
        {:terminate_sub_workflow, "c1", "because"},
        {:terminate_sub_workflow, "c1", "because", 2},
        {:notify_parent, "p", "pt", workflow("wf1", output: %{"stale" => true})},
        {:notify_parent, "p", nil, nil},
        {:revive_parent, "p", nil},
        {:retry_sub_workflow, "c2"},
        {:start_failure_workflow, start}
      ]

      wf = workflow("wf1", tasks: [task("wf1", 1)])
      assert commit(ctx, "wf1", create: wf, outbox: effects) == :ok
      later = %{wf | output: %{"later" => true}, tasks: []}
      commit(ctx, "wf1", workflow: later)
      stored = %{later | tasks: wf.tasks}

      assert outbox_effects(ctx, "wf1") == [
               {:terminate_sub_workflow, "c1", "because"},
               {:terminate_sub_workflow, "c1", "because", 2},
               {:notify_parent, "p", "pt", stored},
               {:notify_parent, "p", nil, stored},
               {:revive_parent, "p", nil},
               {:retry_sub_workflow, "c2"},
               {:start_failure_workflow, start}
             ]

      [[json] | _] =
        Repo.query!("SELECT effect FROM #{t(ctx, "outbox")} ORDER BY id OFFSET 2").rows

      assert JSON.decode!(json) == %{"kind" => "notify_parent", "args" => ["p", "pt"]}
    end

    test "effects of other kinds or shapes are refused before writing", ctx do
      create(ctx, workflow("wf1"))

      for bad <- [
            {:queue_push, "q", "t", 0, 0},
            {:start_sub_workflow, "t", %{}},
            {:retry_sub_workflow, "c", :extra},
            {:terminate_sub_workflow, "c", :shutdown},
            {:revive_parent, :p, nil},
            {:start_failure_workflow, %{workflow_id: "f", definition: %{"name" => "x"}}},
            {:start_failure_workflow, %{workflow_id: "f", unknown: 1}},
            :cancel_wake
          ] do
        assert_raise ArgumentError, fn -> commit(ctx, "wf1", outbox: [bad]) end
      end

      assert s(ctx, :pending_outbox, ["wf1"]) == []
    end
  end

  describe "transactions" do
    test "an exception late in a commit rolls back every field", ctx do
      create(ctx, workflow("wf1", tasks: [task("wf1", 1)]))
      commit(ctx, "wf1", outbox: [{:retry_sub_workflow, "a"}], wake: {:at, 100})
      [a] = outbox_ids(ctx, "wf1")
      {:ok, before} = s(ctx, :get_workflow, ["wf1", true])

      # The queue goes last; a priority past int4 fails there.
      assert_raise DBConnection.EncodeError, fn ->
        commit(ctx, "wf1",
          workflow: workflow("wf1", status: :completed),
          upsert_tasks: [task("wf1", 1, status: :in_progress), task("wf1", 2)],
          delete_task_ids: ["wf1_t1"],
          outbox_ack: [a],
          outbox: [{:retry_sub_workflow, "b"}],
          wake: {:at, 5},
          limits: %{"task1" => 5},
          queue: [{:push, "q", "ok", 0, 0}, {:push, "q", "x", 2 ** 31, 0}]
        )
      end

      assert s(ctx, :get_workflow, ["wf1", true]) == {:ok, before}
      assert outbox_ids(ctx, "wf1") == [a]
      assert due(ctx, 1_000) == [{100, "wf1"}]
      assert PgQueue.size(ctx.queue, "q") == 0
    end

    test "concurrent commits over one limit never exceed it", ctx do
      ids = for i <- 1..12, do: "wf#{i}"

      for id <- ids,
          do: create(ctx, workflow(id, tasks: [task(id, 1, task_def_name: "lim")]))

      results =
        ids
        |> Enum.map(fn id ->
          Elixir.Task.async(fn ->
            commit(ctx, id,
              upsert_tasks: [task(id, 1, task_def_name: "lim", status: :in_progress)],
              limits: %{"lim" => 3, "other" => 1}
            )
          end)
        end)
        |> Enum.map(&Elixir.Task.await(&1, 30_000))

      assert Enum.count(results, &(&1 == :ok)) == 3
      assert Enum.count(results, &(&1 == {:error, {:limit, "lim"}})) == 9
      assert s(ctx, :in_progress_count, ["lim"]) == 3
    end

    test "a reader never sees a workflow with tasks of another commit", ctx do
      tasks = for n <- 1..5, do: task("wf1", n, output_data: %{"v" => 0})
      create(ctx, workflow("wf1", output: %{"v" => 0}, tasks: tasks))

      writer =
        Elixir.Task.async(fn ->
          for v <- 1..150 do
            commit(ctx, "wf1",
              workflow: workflow("wf1", output: %{"v" => v}),
              upsert_tasks: for(t <- tasks, do: %{t | output_data: %{"v" => v}})
            )
          end
        end)

      reads =
        Stream.repeatedly(fn -> s(ctx, :get_workflow, ["wf1", true]) end)
        |> Stream.take_while(fn _ -> Process.alive?(writer.pid) end)
        |> Enum.to_list()

      Elixir.Task.await(writer, 60_000)
      assert reads != []

      for {:ok, wf} <- reads do
        assert Enum.uniq([wf.output | Enum.map(wf.tasks, & &1.output_data)]) |> length() == 1
      end
    end
  end

  describe "the write fence" do
    setup %{server: server} do
      keep_epoch()
      Postgres.clear_epoch()
      %{fenced: %{server | fence: :runtime}}
    end

    test "every write is refused with a stale epoch and changes nothing", ctx do
      %{fenced: fenced} = ctx
      create(ctx, workflow("wf1"))
      commit(ctx, "wf1", outbox: [{:retry_sub_workflow, "a"}])
      [a] = outbox_ids(ctx, "wf1")

      assert PgStore.commit(fenced, "wf2", %Commit{create: workflow("wf2")}) ==
               {:error, :fenced}

      assert PgStore.commit(fenced, "wf1", %Commit{
               workflow: workflow("wf1", status: :completed),
               queue: [{:push, "q", "x", 0, 0}]
             }) == {:error, :fenced}

      assert_raise FencedError, fn -> PgStore.remove_workflow(fenced, "wf1") end
      assert_raise FencedError, fn -> PgStore.ack_outbox(fenced, "wf1", [a]) end
      assert_raise FencedError, fn -> PgStore.put_poll_data(fenced, "q", nil, "w", 1) end

      assert {:ok, %Workflow{status: :running}} = PgStore.get_workflow(fenced, "wf1", false)
      assert PgStore.get_workflow(fenced, "wf2", false) == {:error, :not_found}
      assert PgStore.pending_outbox(fenced, "wf1") != []
      assert PgStore.get_poll_data(fenced, "q", nil) == {:error, :not_found}
      assert PgQueue.size(fenced, "q") == 0
    end

    test "writes with the published epoch", %{fenced: fenced} do
      {:ok, epoch} = Postgres.advance_epoch(fenced)
      Postgres.put_epoch(epoch)

      assert PgStore.commit(fenced, "wf1", %Commit{
               create: workflow("wf1"),
               outbox: [{:retry_sub_workflow, "a"}],
               queue: [{:push, "q", "x", 0, 0}]
             }) == :ok

      [{a, _effect}] = PgStore.pending_outbox(fenced, "wf1")
      assert PgStore.ack_outbox(fenced, "wf1", [a]) == :ok
      assert PgStore.put_poll_data(fenced, "q", nil, "w", 1) == :ok
      assert PgStore.remove_workflow(fenced, "wf1") == :ok
      assert PgQueue.contains?(fenced, "q", "x")
    end
  end

  defp t(ctx, name), do: Postgres.table(ctx.server, name)
end
