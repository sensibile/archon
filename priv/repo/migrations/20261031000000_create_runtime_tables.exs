# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Tables of the Postgres runtime backend (ADR 0021, decisions 2 and 7). Each row keeps its index
# columns and the storage encoding as `json_data text`; times are epoch milliseconds from the
# application clock. The migrator's prefix selects the Postgres schema (runtime or contract tests).

defmodule Archon.Repo.Migrations.CreateRuntimeTables do
  use Ecto.Migration

  def up do
    create table(:workflow, primary_key: false) do
      # Byte order ("B" < "a"): the keyset pages of outbox_workflow_ids and due_workflow_ids
      # order by workflow ID and use the indexes below (ADR 0021, decisions 2 and 3).
      add :workflow_id, :text, primary_key: true, collation: "C"
      add :status, :text, null: false
      add :parent_workflow_id, :text
      add :wake_at, :bigint
      add :json_data, :text, null: false
    end

    execute """
    CREATE INDEX workflow_running_wake_index ON #{qualified("workflow")}
      ((COALESCE(wake_at, 0)), workflow_id) WHERE status = 'RUNNING'
    """

    create table(:task, primary_key: false) do
      add :task_id, :text, primary_key: true

      add :workflow_id,
          references(:workflow, column: :workflow_id, type: :text, on_delete: :delete_all),
          null: false,
          collation: "C"

      add :seq, :integer, null: false
      add :status, :text, null: false
      add :task_def_name, :text
      add :json_data, :text, null: false
    end

    create index(:task, [:workflow_id, :seq])
    create index(:task, [:task_def_name], where: "status = 'IN_PROGRESS'")

    create table(:outbox, primary_key: false) do
      add :id, :bigserial, primary_key: true

      add :workflow_id,
          references(:workflow, column: :workflow_id, type: :text, on_delete: :delete_all),
          null: false,
          collation: "C"

      add :effect, :text, null: false
      add :inserted_at, :bigint, null: false
    end

    create index(:outbox, [:workflow_id, :id])

    create table(:queue_message, primary_key: false) do
      add :queue_name, :text, primary_key: true
      add :message_id, :text, primary_key: true
      add :priority, :integer, null: false
      add :deliver_on, :bigint, null: false
      add :popped, :boolean, null: false, default: false
      add :unack_on, :bigint
      add :seq, :bigserial, null: false
    end

    execute """
    CREATE INDEX queue_message_pop_index ON #{qualified("queue_message")}
      (queue_name, priority DESC, deliver_on, seq)
    """

    create table(:node_lease, primary_key: false) do
      add :id, :integer, primary_key: true
      add :epoch, :bigint, null: false
    end

    create constraint(:node_lease, :node_lease_single_row, check: "id = 1")
    execute "INSERT INTO #{qualified("node_lease")} (id, epoch) VALUES (1, 0)"

    create table(:poll_data, primary_key: false) do
      add :queue_name, :text, primary_key: true
      add :domain_key, :text, primary_key: true
      add :domain, :text
      add :worker_id, :text
      add :last_poll_time, :bigint, null: false
    end

    create table(:meta_task_def, primary_key: false) do
      add :name, :text, primary_key: true
      add :json_data, :text, null: false
    end

    create table(:meta_workflow_def, primary_key: false) do
      add :name, :text, primary_key: true
      add :version, :integer, primary_key: true
      add :json_data, :text, null: false
    end
  end

  def down do
    drop table(:meta_workflow_def)
    drop table(:meta_task_def)
    drop table(:poll_data)
    drop table(:node_lease)
    drop table(:queue_message)
    drop table(:outbox)
    drop table(:task)
    drop table(:workflow)
  end

  defp qualified(name) do
    case prefix() do
      nil -> ~s("#{name}")
      prefix -> ~s("#{prefix}"."#{name}")
    end
  end
end
