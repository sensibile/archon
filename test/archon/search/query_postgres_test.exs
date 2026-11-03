# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Search.QueryPostgresTest do
  @moduledoc """
  Runs `Archon.Search.Query.sql/3` on PostgreSQL over the rows of `Archon.Search.QueryOracle`, in
  temporary tables shaped as ADR 0027 decision 2's index tables, and compares the outcome with
  upstream's builder on SQLite.
  """

  use ExUnit.Case, async: false

  alias Archon.Repo
  alias Archon.Search.{Query, QueryOracle}

  @moduletag :postgres

  @columns %{
    workflow_index:
      ~w(workflow_id correlation_id workflow_type start_time end_time update_time status
         parent_workflow_id classifier json_data)a,
    task_index:
      ~w(task_id task_type task_def_name status start_time end_time update_time workflow_type
         json_data)a
  }

  @times ~w(start_time end_time update_time)a

  test "the SQL gives upstream's totals, rows and failures" do
    {:error, :checked} =
      Repo.transaction(fn ->
        load(:workflow_index, QueryOracle.workflow_rows())
        load(:task_index, QueryOracle.task_rows())

        for {table, query, free_text, start, size, sort, outcome} <- QueryOracle.cases() do
          table = if table == "w", do: :workflow_index, else: :task_index
          label = inspect({table, query, free_text, start, size, sort})

          result =
            with {:ok, parsed} <- Query.parse(query, free_text, Query.sort_list(sort)),
                 {:ok, total, ids} <- search(parsed, table, start, size) do
              {:ok, total, ids, parsed.sort}
            end

          case {outcome, result} do
            {{:ok, total, ids}, {:ok, total, got, []}} ->
              assert Enum.sort(got) == Enum.sort(ids), label

            {{:ok, total, ids}, {:ok, total, got, _sort}} ->
              assert got == ids, label

            {{:error, exception, message, _cause}, {:error, error}} ->
              assert Query.describe(error) == {exception, message}, label

            _mismatch ->
              flunk("#{label}: upstream #{inspect(outcome)}, Archon #{inspect(result)}")
          end
        end

        Repo.rollback(:checked)
      end)
  end

  test "LIKE has no escape character and lower() takes every letter" do
    {:error, :checked} =
      Repo.transaction(fn ->
        load(:workflow_index, [
          %{seq: 1, workflow_id: "a", json_data: ~S|{"p":"C:\\x"}|},
          %{seq: 2, workflow_id: "b", json_data: ~S|{"p":"ÉTÉ"}|}
        ])

        assert {:ok, 1, ["a"]} = search(parse!(~S|\x|), :workflow_index, 0, 10)
        assert {:ok, 1, ["b"]} = search(parse!("été"), :workflow_index, 0, 10)
        Repo.rollback(:checked)
      end)
  end

  defp parse!(free_text) do
    {:ok, query} = Query.parse("", free_text, [])
    query
  end

  defp search(query, table, start, size) do
    id = hd(@columns[table])

    with {:ok, %{where: where, params: params, order_by: order_by}} <- Query.sql(query, table) do
      {limit, offset} = Query.limit_offset(start, size)
      n = length(params)

      %{rows: rows} =
        Repo.query!(
          "SELECT #{id} FROM #{table} #{where} #{order_by} LIMIT $#{n + 1} OFFSET $#{n + 2}",
          params ++ [limit, offset]
        )

      %{rows: [[total]]} = Repo.query!("SELECT count(*) FROM #{table} #{where}", params)
      {:ok, total, List.flatten(rows)}
    end
  end

  defp load(table, rows) do
    columns = @columns[table]

    definitions =
      Enum.map_join(columns, ", ", fn column ->
        "#{column} #{if column in @times, do: "bigint", else: "text"}"
      end)

    Repo.query!("CREATE TEMP TABLE #{table} (#{definitions}, seq bigint) ON COMMIT DROP")

    for row <- rows do
      names = columns ++ [:seq]
      placeholders = Enum.map_join(1..length(names), ", ", &"$#{&1}")

      Repo.query!(
        "INSERT INTO #{table} (#{Enum.join(names, ", ")}) VALUES (#{placeholders})",
        Enum.map(names, &Map.get(row, &1))
      )
    end
  end
end
