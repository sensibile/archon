# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss postgres-persistence/src/main/java/com/netflix/conductor/postgres/dao/PostgresMetadataDAO.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: reduced to the operations of `Archon.Runtime.Metadata` (ADR 0018,
# decision 3); definitions are stored with the storage encoding, every write is fenced by the node
# epoch, and there is no task definition cache or latest-version column (ADR 0021, decisions 2
# and 7).

defmodule Archon.Runtime.Metadata.Postgres do
  @moduledoc """
  PostgreSQL `Archon.Runtime.Metadata` on the `meta_task_def` and `meta_workflow_def` tables
  (ADR 0021, decision 2).

  Each function takes an optional first argument, an `Archon.Runtime.Postgres` instance
  (`Archon.Runtime.Postgres.runtime/0` by default); the arities without it are the behaviour
  callbacks.

  A row keeps its key columns and the definition's storage encoding (`to_storage/1`) as
  `json_data` text. The latest version of a workflow definition is the highest stored version;
  upstream's `latest_version` column and its task definition cache, refreshed on a timer, are not
  kept, so a read always sees the last write.

  Writes run in `Archon.Runtime.Postgres.transaction!/2` and raise
  `Archon.Runtime.Postgres.FencedError` when the node epoch is stale (ADR 0021, decision 7).
  Names are index columns of plain `text`, which cannot hold NUL or invalid UTF-8 (as in
  upstream): writing a definition with such a name raises `ArgumentError`, and reading one is
  `{:error, :not_found}`.
  """

  @behaviour Archon.Runtime.Metadata

  alias Archon.Domain.{TaskDef, WorkflowDef}
  alias Archon.Runtime.{Metadata, Postgres}

  @impl Metadata
  @spec create_task_def(Postgres.t(), TaskDef.t()) :: :ok
  def create_task_def(instance \\ Postgres.runtime(), %TaskDef{name: name} = task_def)
      when is_binary(name),
      do: put_task_def(instance, task_def)

  @impl Metadata
  @spec update_task_def(Postgres.t(), TaskDef.t()) :: :ok
  def update_task_def(instance \\ Postgres.runtime(), %TaskDef{name: name} = task_def)
      when is_binary(name),
      do: put_task_def(instance, task_def)

  @impl Metadata
  @spec get_task_def(Postgres.t(), String.t()) :: {:ok, TaskDef.t()} | {:error, :not_found}
  def get_task_def(instance \\ Postgres.runtime(), name) when is_binary(name) do
    fetch(
      instance,
      TaskDef,
      "SELECT json_data FROM #{table(instance, "meta_task_def")} WHERE name = $1",
      [name]
    )
  end

  @impl Metadata
  @spec create_workflow_def(Postgres.t(), WorkflowDef.t()) :: :ok | {:error, :conflict}
  def create_workflow_def(
        instance \\ Postgres.runtime(),
        %WorkflowDef{name: name, version: version} = definition
      )
      when is_binary(name) and is_integer(version) do
    put_workflow_def(instance, definition, "DO NOTHING")
  end

  @impl Metadata
  @spec update_workflow_def(Postgres.t(), WorkflowDef.t()) :: :ok
  def update_workflow_def(
        instance \\ Postgres.runtime(),
        %WorkflowDef{name: name, version: version} = definition
      )
      when is_binary(name) and is_integer(version) do
    :ok = put_workflow_def(instance, definition, "DO UPDATE SET json_data = EXCLUDED.json_data")
  end

  @impl Metadata
  @spec get_workflow_def(Postgres.t(), String.t(), integer()) ::
          {:ok, WorkflowDef.t()} | {:error, :not_found}
  def get_workflow_def(instance \\ Postgres.runtime(), name, version)
      when is_binary(name) and is_integer(version) do
    fetch(
      instance,
      WorkflowDef,
      "SELECT json_data FROM #{table(instance, "meta_workflow_def")} " <>
        "WHERE name = $1 AND version = $2",
      [name, version]
    )
  end

  @impl Metadata
  @spec get_latest_workflow_def(Postgres.t(), String.t()) ::
          {:ok, WorkflowDef.t()} | {:error, :not_found}
  def get_latest_workflow_def(instance \\ Postgres.runtime(), name) when is_binary(name) do
    fetch(
      instance,
      WorkflowDef,
      "SELECT json_data FROM #{table(instance, "meta_workflow_def")} " <>
        "WHERE name = $1 ORDER BY version DESC LIMIT 1",
      [name]
    )
  end

  # PostgresMetadataDAO#insertOrUpdateTaskDef: both create and update replace by name.
  defp put_task_def(instance, %TaskDef{name: name} = task_def) do
    check_storable!(name)
    json = task_def |> TaskDef.to_storage() |> JSON.encode!()

    Postgres.transaction!(instance, fn ->
      query!(
        instance,
        "INSERT INTO #{table(instance, "meta_task_def")} (name, json_data) VALUES ($1, $2) " <>
          "ON CONFLICT (name) DO UPDATE SET json_data = EXCLUDED.json_data",
        [name, json]
      )

      :ok
    end)
  end

  # `on_conflict` is "DO NOTHING" for create (PostgresMetadataDAO#createWorkflowDef refuses an
  # existing name and version) or the replacing update.
  defp put_workflow_def(
         instance,
         %WorkflowDef{name: name, version: version} = definition,
         on_conflict
       ) do
    check_storable!(name)
    json = definition |> WorkflowDef.to_storage() |> JSON.encode!()

    Postgres.transaction!(instance, fn ->
      %{num_rows: rows} =
        query!(
          instance,
          "INSERT INTO #{table(instance, "meta_workflow_def")} (name, version, json_data) " <>
            "VALUES ($1, $2, $3) ON CONFLICT (name, version) #{on_conflict}",
          [name, version, json]
        )

      if rows == 1, do: :ok, else: {:error, :conflict}
    end)
  end

  defp fetch(instance, module, sql, [name | _rest] = params) do
    with true <- storable?(name),
         %{rows: [[json]]} <- query!(instance, sql, params) do
      case module.from_storage(JSON.decode!(json)) do
        {:ok, definition} ->
          {:ok, definition}

        {:error, errors} ->
          raise ArgumentError,
                "stored #{inspect(module)} #{inspect(name)} does not decode: #{inspect(errors)}"
      end
    else
      _absent -> {:error, :not_found}
    end
  end

  defp check_storable!(name) do
    unless storable?(name),
      do: raise(ArgumentError, "a definition name must be UTF-8 without NUL: #{inspect(name)}")
  end

  defp storable?(name), do: String.valid?(name) and not String.contains?(name, <<0>>)

  defp query!(%Postgres{repo: repo}, sql, params), do: repo.query!(sql, params)

  defp table(instance, name), do: Postgres.table(instance, name)
end
