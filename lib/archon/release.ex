# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Release do
  @moduledoc """
  Database migrations outside Mix (ADR 0021, decision 1).

  A release runs `migrate/0`, which migrates the runtime schema only. Development and tests also
  migrate the contract test schema (`migrate/1` with both prefixes; `mix ecto.setup` and
  `test/test_helper.exs` do this). Each Postgres schema keeps its own `schema_migrations` table.

  `migrate/0` and `migrate/1` end with `backfill_search_index/2` for each schema, so the search
  index holds the rows written before it existed before the application starts (ADR 0027,
  decision 2). `migrate/2` and `rollback/3`, for tests, only migrate.
  """

  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.{Postgres, SearchIndex}

  @backfill_batch 500

  @doc "Migrates the runtime schema of every configured repository."
  @spec migrate() :: :ok
  def migrate, do: migrate([Postgres.runtime_prefix()])

  @doc """
  Migrates each Postgres schema in `prefixes`, creating the schema first when it is missing, and
  backfills its search index (`backfill_search_index/2`). Starts the repositories when they are
  not running.
  """
  @spec migrate([String.t()]) :: :ok
  def migrate(prefixes) when is_list(prefixes) do
    Enum.each(repos(), &migrate_repo(&1, prefixes))
  end

  @doc """
  Runs every pending migration in the Postgres schema `prefix` of a running `repo`, creating the
  schema first when it is missing. Returns the versions it applied.
  """
  @spec migrate(module(), String.t()) :: [integer()]
  def migrate(repo, prefix) do
    repo.query!("CREATE SCHEMA IF NOT EXISTS #{Postgres.quote_identifier(prefix)}")
    run(repo, :up, all: true, prefix: prefix)
  end

  @doc """
  Backfills the search index of the runtime schema of every configured repository
  (`backfill_search_index/2`). Starts the repositories when they are not running. `migrate/0`
  already does this; it is for a schema migrated another way (`mix ecto.migrate`).
  """
  @spec backfill_search_index() :: :ok
  def backfill_search_index do
    Enum.each(repos(), fn repo ->
      with_repo(repo, &backfill_search_index(&1, Postgres.runtime_prefix()))
    end)
  end

  @doc """
  Indexes every workflow and task in the Postgres schema `prefix` of a running `repo`, once
  (ADR 0027, decision 2): `:done` when an earlier run finished, else `{:ok, workflows, tasks}`,
  the rows it read.

  Every row then in the store predates the index, so nothing is compared: workflows are read in
  `create_time` order (none last) and then ID, in batches, each with its tasks in `seq` and then
  task ID order, and inserted with `ON CONFLICT DO NOTHING`, which keeps a row a commit already
  wrote. The run ends by recording that it finished; a run that stopped before that starts over,
  and the rows it wrote stay. `queueWaitTime` of a task summary is taken at the time of the run.
  Like a migration, it runs before the application and is not fenced. A row that does not decode
  raises.
  """
  @spec backfill_search_index(module(), String.t()) ::
          :done | {:ok, non_neg_integer(), non_neg_integer()}
  def backfill_search_index(repo, prefix) do
    table = &Postgres.table(%Postgres{repo: repo, prefix: prefix}, &1)

    case repo.query!("SELECT 1 FROM #{table.("search_index_backfill")} LIMIT 1") do
      %{num_rows: 1} ->
        :done

      %{num_rows: 0} ->
        %{rows: ids} =
          repo.query!(
            "SELECT workflow_id FROM #{table.("workflow")} " <>
              "ORDER BY create_time NULLS LAST, workflow_id",
            [],
            timeout: :infinity
          )

        now = System.system_time(:millisecond)

        {workflows, tasks} =
          ids
          |> List.flatten()
          |> Enum.chunk_every(@backfill_batch)
          |> Enum.reduce({0, 0}, fn batch, {workflows, tasks} ->
            {w, t} = backfill_batch(repo, table, batch, now)
            {workflows + w, tasks + t}
          end)

        repo.query!(
          "INSERT INTO #{table.("search_index_backfill")} (completed_at) VALUES ($1)",
          [System.system_time(:millisecond)]
        )

        {:ok, workflows, tasks}
    end
  end

  # A workflow removed since its ID was read is skipped, and so are its tasks.
  defp backfill_batch(repo, table, ids, now) do
    %{rows: workflow_rows} =
      repo.query!(
        "SELECT workflow_id, json_data FROM #{table.("workflow")} WHERE workflow_id = ANY($1)",
        [ids]
      )

    %{rows: task_rows} =
      repo.query!(
        "SELECT workflow_id, task_id, json_data FROM #{table.("task")} " <>
          ~s|WHERE workflow_id = ANY($1) ORDER BY seq, task_id COLLATE "C"|,
        [ids]
      )

    json = Map.new(workflow_rows, fn [id, json] -> {id, json} end)
    tasks = Enum.group_by(task_rows, &hd/1, fn [_id, task_id, json] -> {task_id, json} end)

    workflows =
      for id <- ids,
          Map.has_key?(json, id),
          do: SearchIndex.workflow_row(decode!(Workflow, json[id], id))

    tasks =
      for id <- ids,
          Map.has_key?(json, id),
          {task_id, json} <- Map.get(tasks, id, []),
          do: SearchIndex.task_row(decode!(Task, json, task_id), now)

    insert_index(repo, table.("workflow_index"), workflows, ~w(workflow_id correlation_id
      workflow_type start_time end_time update_time status parent_workflow_id classifier
      json_data)a, ~w(text text text bigint bigint bigint text text text text))

    insert_index(
      repo,
      table.("task_index"),
      tasks,
      ~w(task_id task_type task_def_name status
      start_time end_time update_time workflow_type json_data)a,
      ~w(text text text text bigint bigint bigint text text)
    )

    {length(workflows), length(tasks)}
  end

  defp decode!(module, json, id) do
    case module.from_storage(JSON.decode!(json)) do
      {:ok, value} -> value
      {:error, reason} -> raise "cannot index #{id}: #{inspect(reason)}"
    end
  end

  defp insert_index(_repo, _table, [], _columns, _types), do: :ok

  # In list order, so new rows take their seq in that order.
  defp insert_index(repo, table, rows, columns, types) do
    names = Enum.join(columns, ", ")
    arrays = types |> Enum.with_index(1) |> Enum.map_join(", ", fn {t, i} -> "$#{i}::#{t}[]" end)

    repo.query!(
      "INSERT INTO #{table} (#{names}) SELECT #{Enum.map_join(columns, ", ", &"u.#{&1}")} " <>
        "FROM unnest(#{arrays}) WITH ORDINALITY AS u(#{names}, n) ORDER BY u.n " <>
        "ON CONFLICT DO NOTHING",
      Enum.map(columns, fn column -> Enum.map(rows, &Map.fetch!(&1, column)) end)
    )

    :ok
  end

  @doc """
  Rolls the Postgres schema `prefix` of a running `repo` back to `version` (exclusive): every
  migration after it is reverted. Returns the versions it reverted.
  """
  @spec rollback(module(), String.t(), integer()) :: [integer()]
  def rollback(repo, prefix, version) do
    run(repo, :down, to_exclusive: version, prefix: prefix)
  end

  # The migrator compiles each migration file on every run, so migrating a second schema would
  # warn that the migration modules are redefined.
  defp run(repo, direction, opts) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(repo, direction, [log: false] ++ opts)
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  defp migrate_repo(repo, prefixes) do
    with_repo(repo, fn repo ->
      Enum.each(prefixes, fn prefix ->
        migrate(repo, prefix)
        backfill_search_index(repo, prefix)
      end)
    end)
  end

  defp with_repo(repo, fun) do
    case Ecto.Migrator.with_repo(repo, fun) do
      {:ok, _result, _apps} -> :ok
      {:error, reason} -> raise "cannot start #{inspect(repo)}: #{inspect(reason)}"
    end
  end

  defp repos do
    Application.load(:archon)
    Application.fetch_env!(:archon, :ecto_repos)
  end
end
