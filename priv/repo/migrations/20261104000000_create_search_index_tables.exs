# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss sqlite-persistence/src/main/resources/db/migration_sqlite/
# V1__initial_schema.sql, V2__parent_workflow_id.sql, V5__workflow_index_classifier.sql and
# V7__index_end_time.sql at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: times are epoch milliseconds (bigint), text columns other than the IDs
# allow NULL, every table has a `seq` for the default order, and a marker table records the one
# backfill of Archon.Release.backfill_search_index/0 (ADR 0027, decision 2).

defmodule Archon.Repo.Migrations.CreateSearchIndexTables do
  use Ecto.Migration

  def up do
    # Text in byte order, as the search SQL compares it (Archon.Search.Query, COLLATE "C").
    create table(:workflow_index, primary_key: false) do
      add :workflow_id, :text, primary_key: true, collation: "C"
      add :correlation_id, :text, collation: "C"
      add :workflow_type, :text, collation: "C"
      add :start_time, :bigint
      add :end_time, :bigint
      add :update_time, :bigint
      add :status, :text, collation: "C"
      add :parent_workflow_id, :text, collation: "C"
      add :classifier, :text, collation: "C"
      add :json_data, :text, null: false
      add :seq, :bigserial, null: false
    end

    create index(:workflow_index, [:correlation_id])
    create index(:workflow_index, [:start_time])
    create index(:workflow_index, [:status])
    create index(:workflow_index, [:workflow_type])
    create index(:workflow_index, [:parent_workflow_id])
    create index(:workflow_index, [:classifier, :start_time])
    create index(:workflow_index, [:end_time])
    create index(:workflow_index, [:seq])

    create table(:task_index, primary_key: false) do
      add :task_id, :text, primary_key: true, collation: "C"
      add :task_type, :text, collation: "C"
      add :task_def_name, :text, collation: "C"
      add :status, :text, collation: "C"
      add :start_time, :bigint
      add :end_time, :bigint
      add :update_time, :bigint
      add :workflow_type, :text, collation: "C"
      add :json_data, :text, null: false
      add :seq, :bigserial, null: false
    end

    create index(:task_index, [:status])
    create index(:task_index, [:task_def_name])
    create index(:task_index, [:task_type])
    create index(:task_index, [:update_time])
    create index(:task_index, [:workflow_type])
    create index(:task_index, [:end_time])
    create index(:task_index, [:seq])

    create table(:task_execution_logs, primary_key: false) do
      add :log_id, :bigserial, primary_key: true
      add :task_id, :text, null: false, collation: "C"
      add :log, :text, null: false
      add :created_time, :bigint, null: false
    end

    create index(:task_execution_logs, [:task_id])

    # One row once the backfill finished.
    create table(:search_index_backfill, primary_key: false) do
      add :completed_at, :bigint, null: false
    end
  end

  def down do
    drop table(:search_index_backfill)
    drop table(:task_execution_logs)
    drop table(:task_index)
    drop table(:workflow_index)
  end
end
