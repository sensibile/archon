# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# The workflow columns of the queries by name and correlation ID (ADR 0025, decision 4). Existing
# rows are filled from json_data as a commit writes them (Archon.Runtime.Store.Postgres): a name
# or correlation ID with NUL, or a number outside its column, stays NULL.

defmodule Archon.Repo.Migrations.AddWorkflowQueryColumns do
  use Ecto.Migration

  @page 500
  @int_range -0x80000000..0x7FFFFFFF
  @bigint_range -0x8000000000000000..0x7FFFFFFFFFFFFFFF

  def up do
    alter table(:workflow) do
      add :workflow_name, :text
      add :workflow_version, :integer
      add :correlation_id, :text
      add :create_time, :bigint
    end

    # Decoded here, not with Postgres JSON operators, which fail on a string holding an escaped
    # NUL; the values follow the commit's rules.
    table = qualified("workflow")
    execute(fn -> fill(table, "") end)

    create index(:workflow, [:workflow_name, :correlation_id])
    create index(:workflow, [:workflow_name, :create_time])

    create index(:workflow, [:workflow_name],
             name: :workflow_pending_name_index,
             where: "status IN ('RUNNING', 'PAUSED')"
           )
  end

  def down do
    alter table(:workflow) do
      remove :create_time
      remove :correlation_id
      remove :workflow_version
      remove :workflow_name
    end
  end

  # Keyset pages in workflow ID order (COLLATE "C").
  defp fill(table, after_id) do
    %{rows: rows} =
      repo().query!(
        "SELECT workflow_id, json_data FROM #{table} WHERE workflow_id > $1 " <>
          "ORDER BY workflow_id LIMIT $2",
        [after_id, @page]
      )

    unless rows == [] do
      values = Enum.map(rows, fn [id, json] -> [id | columns(JSON.decode!(json))] end)
      [ids, names, versions, correlation_ids, create_times] = Enum.zip_with(values, & &1)

      repo().query!(
        """
        UPDATE #{table} AS w SET workflow_name = u.name, workflow_version = u.version,
          correlation_id = u.correlation_id, create_time = u.create_time
        FROM unnest($1::text[], $2::text[], $3::integer[], $4::text[], $5::bigint[])
          AS u(workflow_id, name, version, correlation_id, create_time)
        WHERE w.workflow_id = u.workflow_id
        """,
        [ids, names, versions, correlation_ids, create_times]
      )

      fill(table, List.last(ids))
    end
  end

  defp columns(json) do
    definition = if is_map(json["workflowDefinition"]), do: json["workflowDefinition"], else: %{}

    [
      queryable(definition["name"]),
      in_range(definition["version"], @int_range),
      queryable(json["correlationId"]),
      in_range(json["createTime"], @bigint_range)
    ]
  end

  # Text an index column can hold.
  defp queryable(value) when is_binary(value),
    do: if(String.valid?(value) and not String.contains?(value, <<0>>), do: value)

  defp queryable(_value), do: nil

  defp in_range(value, range) when is_integer(value), do: if(value in range, do: value)
  defp in_range(_value, _range), do: nil

  defp qualified(name) do
    case prefix() do
      nil -> ~s("#{name}")
      prefix -> ~s("#{prefix}"."#{name}")
    end
  end
end
