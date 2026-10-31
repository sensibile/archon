# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Release do
  @moduledoc """
  Database migrations outside Mix (ADR 0021, decision 1).

  A release runs `migrate/0`, which migrates the runtime schema only. Development and tests also
  migrate the contract test schema (`migrate/1` with both prefixes; `mix ecto.setup` and
  `test/test_helper.exs` do this). Each Postgres schema keeps its own `schema_migrations` table.
  """

  alias Archon.Runtime.Postgres

  @doc "Migrates the runtime schema of every configured repository."
  @spec migrate() :: :ok
  def migrate, do: migrate([Postgres.runtime_prefix()])

  @doc """
  Migrates each Postgres schema in `prefixes`, creating the schema first when it is missing.
  Starts the repositories when they are not running.
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
    case Ecto.Migrator.with_repo(repo, fn repo -> Enum.each(prefixes, &migrate(repo, &1)) end) do
      {:ok, _result, _apps} -> :ok
      {:error, reason} -> raise "cannot start #{inspect(repo)}: #{inspect(reason)}"
    end
  end

  defp repos do
    Application.load(:archon)
    Application.fetch_env!(:archon, :ecto_repos)
  end
end
