# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss sqlite-persistence/src/test/java/com/netflix/conductor/sqlite/util/SqliteIndexQueryBuilderTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests of the parsed query and its PostgreSQL, plus
# the outcomes of upstream's builder run on SQLite (Archon.Search.QueryOracle) (ADR 0027).

defmodule Archon.Search.QueryTest do
  use ExUnit.Case, async: true

  alias Archon.Search.{Query, QueryOracle}

  defp parse!(query, free_text \\ "*", sort \\ []) do
    {:ok, parsed} = Query.parse(query, free_text, sort)
    parsed
  end

  defp sql!(query, free_text, sort \\ [], table \\ :workflow_index) do
    {:ok, sql} = query |> parse!(free_text, sort) |> Query.sql(table)
    sql
  end

  describe "SqliteIndexQueryBuilderTest" do
    test "shouldGenerateQueryForEmptyString" do
      assert sql!("", "") == %{where: "", params: [], order_by: "ORDER BY seq"}
    end

    test "shouldGenerateQueryForExactMatch" do
      assert sql!(~S|workflowId="abc123"|, "") ==
               %{where: "WHERE workflow_id = $1", params: ["abc123"], order_by: "ORDER BY seq"}
    end

    test "shouldGenerateQueryWithWildcardPrefix" do
      assert %{where: "WHERE lower(workflow_type) LIKE $1 ESCAPE ''", params: ["abc%"]} =
               sql!("workflowType=abc*", "")
    end

    test "shouldGenerateQueryWithWildcardContains" do
      assert %{where: "WHERE lower(correlation_id) LIKE $1 ESCAPE ''", params: ["%order%"]} =
               sql!(~S|correlationId="*order*"|, "")
    end

    test "shouldGenerateExactMatchQueryWhenNoWildcard" do
      assert %{where: "WHERE workflow_type = $1", params: ["abc"]} = sql!("workflowType=abc", "")
    end

    test "shouldNotExpandWildcardInINClause" do
      assert %{where: "WHERE status IN ($1, $2)", params: ["COMP*", "RUNNING"]} =
               sql!("status IN (COMP*,RUNNING)", "")
    end

    test "shouldGenerateQueryForClassifier" do
      assert %{where: "WHERE classifier = $1", params: ["agent"]} =
               sql!(~S|classifier="agent"|, "")
    end

    test "shouldMatchLegacyNullRowsForUntaggedClassifier" do
      assert %{where: "WHERE (classifier = $1 OR classifier IS NULL)", params: ["workflow"]} =
               sql!(~S|classifier="workflow"|, "")
    end

    test "shouldMatchLegacyNullRowsForUntaggedClassifierInClause" do
      assert %{
               where: "WHERE (classifier IN ($1, $2) OR classifier IS NULL)",
               params: ["agent", "workflow"]
             } = sql!("classifier IN (agent,workflow)", "")
    end

    test "shouldGenerateQueryForStartTimeGreaterThanInCanonicalUtc" do
      # Upstream binds "2023-02-06 16:54:58.000" against its UTC text column; Archon's column
      # holds the epoch milliseconds.
      assert %{where: "WHERE start_time > $1", params: [1_675_702_498_000]} =
               sql!("startTime>1675702498000", "")
    end

    test "shouldGenerateQueryForParentWorkflowId" do
      assert %{where: "WHERE parent_workflow_id = $1", params: [""]} =
               sql!(~S|parentWorkflowId=""|, "")
    end

    test "shouldSortWorkflowsOnEndTime" do
      assert %{order_by: "ORDER BY end_time DESC NULLS LAST, seq"} =
               sql!("", "", ["endTime:DESC"])
    end

    test "shouldSortTasksOnEndTime" do
      assert %{order_by: "ORDER BY end_time DESC NULLS LAST, seq"} =
               sql!("", "", ["endTime:DESC"], :task_index)
    end

    test "shouldGenerateQueryForEndTimeRangeInCanonicalUtc" do
      assert %{where: "WHERE end_time > $1", params: [1_675_702_498_000]} =
               sql!("endTime>1675702498000", "")
    end

    test "shouldRejectLongInputWithoutOperatorWithoutCatastrophicBacktracking" do
      long_input = String.duplicate("a", 5000)
      assert {:error, {:invalid_clause, ^long_input} = error} = Query.parse(long_input, "", [])

      assert Query.describe(error) ==
               {"IllegalArgumentException", "Incorrectly formatted query string: " <> long_input}
    end

    test "shouldHandleVariousWhitespaceAroundOperators" do
      # Upstream orders the clauses by their SQL: "status IN (?,?)" before "workflow_id = ?".
      assert %{
               where: "WHERE status IN ($1, $2) AND workflow_id = $3",
               params: ["COMPLETED", "RUNNING", "abc123"]
             } = sql!(~S|workflowId = "abc123" AND status   IN   (COMPLETED,RUNNING)|, "")
    end
  end

  describe "upstream's builder on SQLite (QueryOracle)" do
    test "gives the same totals, rows and failures in memory" do
      for {table, query, free_text, start, size, sort, outcome} <- QueryOracle.cases() do
        {table, rows} =
          if table == "w",
            do: {:workflow_index, QueryOracle.workflow_rows()},
            else: {:task_index, QueryOracle.task_rows()}

        id = if table == :workflow_index, do: :workflow_id, else: :task_id
        label = inspect({table, query, free_text, start, size, sort})

        result =
          with {:ok, parsed} <- Query.parse(query, free_text, Query.sort_list(sort)),
               {:ok, total, page} <- Query.run(parsed, table, rows, start, size) do
            {:ok, total, Enum.map(page, & &1[id]), parsed.sort}
          end

        case {outcome, result} do
          {{:ok, total, ids}, {:ok, total, got, []}} ->
            # Without a sort SQLite's order follows its plan (ADR 0027, decision 4).
            assert Enum.sort(got) == Enum.sort(ids), label

          {{:ok, total, ids}, {:ok, total, got, _sort}} ->
            assert got == ids, label

          {{:error, exception, message, _cause}, {:error, error}} ->
            assert Query.describe(error) == {exception, message}, label

          _mismatch ->
            flunk("#{label}: upstream #{inspect(outcome)}, Archon #{inspect(result)}")
        end
      end
    end
  end

  describe "parse/3" do
    test "drops clauses on fields outside the allow list, after converting their time" do
      assert parse!("foo=bar AND fooTime=12").conditions == []
      assert {:error, {:invalid_number, "x"}} = Query.parse("fooTime=x", "*", [])
    end

    test "keeps later time values as text" do
      assert parse!("startTime IN (5,6)").conditions == [
               %{column: :start_time, operator: :in, values: [5, "6"]}
             ]
    end

    test "reads a Java long" do
      assert parse!("endTime>-9223372036854775808").conditions == [
               %{column: :end_time, operator: :gt, values: [-9_223_372_036_854_775_808]}
             ]

      assert {:error, {:invalid_number, "9223372036854775808"}} =
               Query.parse("endTime>9223372036854775808", "*", [])

      # Java's Long.parseLong also reads other scripts' digits; Archon does not (ADR 0027).
      assert {:error, {:invalid_number, "١٢"}} = Query.parse("endTime>١٢", "*", [])
    end

    test "turns freeText into a lowered LIKE pattern" do
      assert parse!("", "A*b_%").free_text == "%a%b_%%"
      assert parse!("", nil).free_text == nil
      assert parse!(nil, "*").free_text == nil
    end

    test "drops the agentHierarchy sort (ADR 0027)" do
      assert parse!("", "*", ["agentHierarchy:DESC", "startTime:asc"]).sort == [
               start_time: :asc
             ]
    end

    test "takes bytes that are not UTF-8" do
      assert {:ok, query} = Query.parse(<<"status=", 0xFF>>, <<0xFE>>, [<<0xFF, ":ASC">>])
      assert query.free_text == <<?%, 0xFE, ?%>>
      refute Query.matches?(query, %{status: "x", json_data: "y", seq: 1})
    end
  end

  describe "sort_list/1" do
    test "splits on | as upstream's Utils.convertStringToList does" do
      assert Query.sort_list(nil) == []
      assert Query.sort_list(" \t") == []
      assert Query.sort_list("a:ASC|b:DESC|") == ["a:ASC", "b:DESC"]
      assert Query.sort_list("|") == []
      assert Query.sort_list("|a:ASC") == ["", "a:ASC"]
    end
  end

  describe "check/2" do
    test "names the first missing column, in the WHERE before the sort" do
      query = parse!("taskType=x", "*", ["taskId:ASC"])
      assert Query.check(query, :workflow_index) == {:error, {:unknown_column, "task_type"}}
      assert Query.check(query, :task_index) == :ok

      assert Query.check(parse!("workflowId=x"), :task_index) ==
               {:error, {:unknown_column, "workflow_id"}}
    end

    test "counts the free text among the parameters" do
      assert Query.check(parse!("status=a,b", "x"), :workflow_index) ==
               {:error, {:bind_overflow, 4}}
    end
  end

  describe "run/5" do
    test "puts NULL first when ascending and last when descending, then orders by seq" do
      rows = [
        %{seq: 1, workflow_id: "a", correlation_id: "x"},
        %{seq: 2, workflow_id: "b", correlation_id: nil},
        %{seq: 3, workflow_id: "c", correlation_id: "x"}
      ]

      ids = fn sort ->
        {:ok, 3, page} = Query.run(parse!("", "*", sort), :workflow_index, rows, 0, -1)
        Enum.map(page, & &1.workflow_id)
      end

      assert ids.(["correlationId:ASC"]) == ["b", "a", "c"]
      assert ids.(["correlationId:DESC"]) == ["a", "c", "b"]
      assert ids.([]) == ["a", "b", "c"]
    end

    test "compares text by bytes" do
      rows = [%{seq: 1, status: "b"}, %{seq: 2, status: "B"}, %{seq: 3, status: "é"}]
      {:ok, 2, page} = Query.run(parse!("status>a"), :workflow_index, rows, 0, 10)
      assert Enum.map(page, & &1.seq) == [1, 3]
    end

    test "matches LIKE wildcards by characters and lowers every letter" do
      rows = [%{seq: 1, json_data: ~S|{"name":"ÉTÉ"}|}]
      assert {:ok, 1, _page} = Query.run(parse!("", "été"), :workflow_index, rows, 0, 10)
      assert {:ok, 1, _page} = Query.run(parse!("", ~S|"_t_"|), :workflow_index, rows, 0, 10)
      assert {:ok, 0, []} = Query.run(parse!("", ~S|"__t_"|), :workflow_index, rows, 0, 10)
    end
  end

  describe "limit_offset/2" do
    test "gives no limit for a negative size and offset 0 for a negative start" do
      assert Query.limit_offset(-5, -1) == {nil, 0}
      assert Query.limit_offset(3, 7) == {7, 3}
    end
  end

  describe "sql/3" do
    test "numbers parameters from the given index and binds the free text last" do
      assert {:ok,
              %{
                where: ~s{WHERE status COLLATE "C" > $3 AND lower(json_data) LIKE $4 ESCAPE ''},
                params: ["F%", "%x%"],
                order_by: ~s(ORDER BY workflow_type COLLATE "C" ASC NULLS FIRST, seq)
              }} = Query.sql(parse!("status>F*", "X", ["workflowType:asc"]), :workflow_index, 3)
    end

    test "binds only the first time value of an IN" do
      assert %{where: "WHERE start_time = $1", params: [5]} = sql!("startTime IN (5,6)", "")
    end

    test "fails as check/2 does" do
      assert {:error, :missing_value} = Query.sql(parse!("status IN (,)"), :workflow_index)
    end
  end
end
