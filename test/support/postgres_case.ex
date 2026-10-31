# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.PostgresCase do
  @moduledoc """
  A case for tests that need PostgreSQL (ADR 0021, decision 9): tagged `:postgres`, not `async`,
  and given `instance`, an `Archon.Runtime.Postgres` on the contract test schema with every
  table emptied before the test.

  `test/test_helper.exs` calls `setup_database/0` once. When the database cannot be reached the
  `:postgres` tests are excluded, unless `ARCHON_REQUIRE_POSTGRES` is set (CI), which fails the
  run instead. There is no Ecto sandbox: tests share the database, so each test empties the
  schema it uses.
  """

  use ExUnit.CaseTemplate

  alias Archon.Repo
  alias Archon.Runtime.Postgres

  # Every table of the migrations except the single node_lease row, which is reset.
  @tables ~w(workflow task outbox queue_message poll_data meta_task_def meta_workflow_def)

  using do
    quote do
      import Archon.PostgresCase

      alias Archon.Repo
      alias Archon.Runtime.Postgres

      @moduletag :postgres
    end
  end

  setup do
    instance = Postgres.new(prefix: Postgres.contract_prefix())
    reset!(instance)
    %{instance: instance}
  end

  @doc """
  Creates the test database if needed, starts `Archon.Repo` and migrates the runtime and contract
  test schemas. Returns `{:error, reason}` when the database cannot be reached.
  """
  @spec setup_database() :: :ok | {:error, String.t()}
  def setup_database do
    config = Repo.config()

    with :ok <- reachable(config),
         :ok <- storage_up(config),
         {:ok, _pid} <- Supervisor.start_child(Archon.Supervisor, Repo) do
      for prefix <- [Postgres.runtime_prefix(), Postgres.contract_prefix()],
          do: Archon.Release.migrate(Repo, prefix)

      :ok
    end
  end

  # A plain TCP check first, so that a missing server is reported without connection crash logs.
  defp reachable(config) do
    host = String.to_charlist(config[:hostname] || "localhost")

    case :gen_tcp.connect(host, config[:port] || 5432, [], 1_000) do
      {:ok, socket} -> :gen_tcp.close(socket)
      {:error, reason} -> {:error, "cannot reach #{database(config)}: #{inspect(reason)}"}
    end
  end

  defp storage_up(config) do
    case Repo.__adapter__().storage_up(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> {:error, "cannot reach #{database(config)}: #{inspect(reason)}"}
    end
  end

  defp database(config),
    do: "#{config[:hostname]}:#{config[:port] || 5432}/#{config[:database]}"

  @doc "Empties every table of `instance`'s schema and resets the node epoch to 0."
  @spec reset!(Postgres.t()) :: :ok
  def reset!(%Postgres{repo: repo} = instance) do
    tables = Enum.map_join(@tables, ", ", &Postgres.table(instance, &1))
    repo.query!("TRUNCATE #{tables} RESTART IDENTITY")
    repo.query!("UPDATE #{Postgres.table(instance, "node_lease")} SET epoch = 0")
    :ok
  end
end
