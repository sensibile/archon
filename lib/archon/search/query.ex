# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss sqlite-persistence/src/main/java/com/netflix/conductor/sqlite/util/SqliteIndexQueryBuilder.java
# and core/src/main/java/com/netflix/conductor/core/utils/Utils.java (convertStringToList)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: parses into a value that is evaluated in memory or turned into
# PostgreSQL with bound parameters, and reports upstream's failures as values (ADR 0027).

defmodule Archon.Search.Query do
  @moduledoc """
  The search grammar of upstream's default server (`SqliteIndexQueryBuilder`; ADR 0027,
  decision 4), shared by both stores.

  `parse/3` turns the `query`, `freeText` and `sort` parameters into a `t:t/0`:

    * `query` is split on `" AND "` (Java `String#split`: trailing empty parts dropped), and each
      part must match `^([a-zA-Z]++)\\s*(=|>|<|IN)\\s*(.*)$` as Java does (`\\s` is ASCII, `.`
      stops at a line terminator, `$` also matches before one final terminator). The value loses
      every `"`, `'`, `(` and `)` and is split on `,` (the parts are not trimmed). A one-value `IN`
      is `=`. The field goes from camelCase to snake_case. For a field ending in `_time` the first
      value must be a Java `long` (epoch milliseconds), even when the field is not searchable;
      later values stay text, which never matches a time. Clauses on fields outside the allow
      list are dropped.
    * `freeText` other than empty or `*` matches the summary JSON case-insensitively as
      `%<text>%`, where `%`, `_` and `*` are wildcards.
    * each `sort` item is `field:ASC|DESC` (order in any case); anything else is dropped.

  `check/2` then reports what upstream only finds when it runs the SQL for a table: a field the
  table has no column for, a clause with no value (`IN (,)`), or a non-`IN` clause with more than
  one value (bound parameters overflow). `run/5` evaluates a checked query over rows in memory and
  `sql/3` gives the PostgreSQL for it; both order by the sort items and then `seq` (`ASC` puts
  `NULL` first and `DESC` last, as SQLite does), and page as SQLite's `LIMIT ? OFFSET ?` does
  (`page/3`).

  Matching follows SQLite: `=` and `IN` compare exactly, `>`/`<` compare text by bytes and times
  by value, `=` with a `*` is a case-insensitive `LIKE` where `*` and `%` match any run and `_`
  one character (there is no escape character), and `classifier` asked for `workflow` (in any
  case) also matches rows without a classifier.

  Not reproduced (ADR 0027): the `agentHierarchy` sort, which is dropped; non-ASCII digits in a
  time value, which Java's `Long.parseLong` reads; and SQLite's ASCII-only `lower()`, which here
  lowers every letter.
  """

  alias Archon.Domain.SummaryUtil

  @searchable ~w(workflow_id correlation_id workflow_type start_time end_time status task_id
                 task_type task_def_name update_time json_data parent_workflow_id classifier)
  @column_atoms Map.new(@searchable, &{&1, String.to_atom(&1)})

  @tables %{
    workflow_index:
      ~w(workflow_id correlation_id workflow_type start_time end_time update_time status
         parent_workflow_id classifier json_data)a,
    task_index:
      ~w(task_id task_type task_def_name status start_time end_time update_time workflow_type
         json_data)a
  }

  @time_columns [:start_time, :end_time, :update_time]

  @long_min -9_223_372_036_854_775_808
  @long_max 9_223_372_036_854_775_807

  # Java's \s, possessive as in upstream's pattern; nothing after the operator can backtrack
  # into it, so this accepts the same clauses.
  @clause ~r/\A([a-zA-Z]++)[\t\n\x0B\f\r ]*+(=|>|<|IN)[\t\n\x0B\f\r ]*+/

  # Java's line terminators, and what `$` accepts after the value.
  @terminators ["\n", "\r", <<0x85::utf8>>, <<0x2028::utf8>>, <<0x2029::utf8>>]
  @final_terminators ["", "\r\n" | @terminators]

  defstruct conditions: [], free_text: nil, sort: []

  @type column ::
          :workflow_id
          | :correlation_id
          | :workflow_type
          | :start_time
          | :end_time
          | :status
          | :task_id
          | :task_type
          | :task_def_name
          | :update_time
          | :json_data
          | :parent_workflow_id
          | :classifier

  @typedoc "An index table: `workflow_index` or `task_index`."
  @type table :: :workflow_index | :task_index

  @typedoc """
  A clause on a searchable column. A time column's first value is epoch milliseconds; every
  other value is text as given.
  """
  @type condition :: %{
          column: column(),
          operator: :eq | :gt | :lt | :in,
          values: [String.t() | integer()]
        }

  @typedoc """
  `free_text` is the `LIKE` pattern on the lowered summary JSON, already lowered and wrapped in
  `%`, with `*` turned into `%`. Conditions are in upstream's order (by SQL fragment).
  """
  @type t :: %__MODULE__{
          conditions: [condition()],
          free_text: String.t() | nil,
          sort: [{column(), :asc | :desc}]
        }

  @typedoc """
  Why upstream fails a search. `describe/1` gives upstream's exception and message.

    * `{:invalid_clause, clause}` - a `query` part that does not match the grammar
      (`IllegalArgumentException`).
    * `{:invalid_number, value}` - a `_time` value that is not a `long` (`NumberFormatException`).
    * `:missing_value` - a `_time` clause, or a clause on a column of the table, with no value
      (`IndexOutOfBoundsException`).
    * `{:unknown_column, name}` - a searchable field the table has no column for, in `query` or
      `sort` (an SQLite error, wrapped in `NonTransientException`).
    * `{:bind_overflow, placeholders}` - more values than the SQL has parameters, from a non-`IN`
      clause with several values (`ArrayIndexOutOfBoundsException`).
  """
  @type error ::
          {:invalid_clause, String.t()}
          | {:invalid_number, String.t()}
          | :missing_value
          | {:unknown_column, String.t()}
          | {:bind_overflow, pos_integer()}

  @typedoc "An index row: its columns by name, and `seq` (insertion order)."
  @type row :: %{required(:seq) => integer(), optional(column()) => String.t() | integer() | nil}

  @doc """
  Parses `query`, `freeText` and the `sort` items (see `sort_list/1`). Fails as upstream's
  builder does, at the first bad `query` part.
  """
  @spec parse(String.t() | nil, String.t() | nil, [String.t()]) :: {:ok, t()} | {:error, error()}
  def parse(query, free_text, sort) when is_list(sort) do
    with {:ok, conditions} <- parse_conditions(query) do
      {:ok,
       %__MODULE__{
         conditions: conditions,
         free_text: free_text_pattern(free_text),
         sort: Enum.flat_map(sort, &sort_item/1)
       }}
    end
  end

  @doc """
  Upstream `Utils.convertStringToList`: the `sort` parameter split on `|`, or `[]` when it is
  missing or blank.
  """
  @spec sort_list(String.t() | nil) :: [String.t()]
  def sort_list(nil), do: []

  def sort_list(sort) when is_binary(sort),
    do: if(SummaryUtil.blank?(sort), do: [], else: java_split(sort, "|"))

  @doc """
  What upstream finds when it prepares and binds the SQL for `table`, in its order: a column the
  table lacks (in `query`, then `sort`), then a clause with no value or more values than
  parameters. A clause `IN (,)` makes SQLite drop the whole `WHERE` before it looks up its
  columns, so only `sort` columns are checked then.
  """
  @spec check(t(), table()) :: :ok | {:error, error()}
  def check(%__MODULE__{} = query, table) do
    columns = Map.fetch!(@tables, table)

    with :ok <- check_columns(query, columns), do: check_binds(query)
  end

  @doc """
  Searches `rows` of `table` in memory: `{:ok, total, page}`, where `total` counts every match
  and `page` is the sorted page (`page/3`).
  """
  @spec run(t(), table(), [row()], integer(), integer()) ::
          {:ok, non_neg_integer(), [row()]} | {:error, error()}
  def run(%__MODULE__{} = query, table, rows, start, size) do
    with :ok <- check(query, table) do
      matched = Enum.filter(rows, &matches?(query, &1))
      {:ok, length(matched), matched |> sort(query) |> page(start, size)}
    end
  end

  @doc "Whether `row` matches every clause and the free text. `query` must pass `check/2`."
  @spec matches?(t(), row()) :: boolean()
  def matches?(%__MODULE__{} = query, row) do
    Enum.all?(query.conditions, &condition_match?(&1, row)) and
      (query.free_text == nil or like?(Map.get(row, :json_data), query.free_text))
  end

  @doc "Orders `rows` by the sort items, then `seq`."
  @spec sort([row()], t()) :: [row()]
  def sort(rows, %__MODULE__{sort: items}) do
    Enum.sort(rows, fn a, b -> compare_rows(items, a, b) != :gt end)
  end

  @doc """
  SQLite's `LIMIT size OFFSET start`: a negative `size` takes every row and a negative `start`
  is 0.
  """
  @spec page([row()], integer(), integer()) :: [row()]
  def page(rows, start, size) do
    rows = Enum.drop(rows, max(start, 0))
    if size < 0, do: rows, else: Enum.take(rows, size)
  end

  @doc """
  The PostgreSQL `LIMIT` and `OFFSET` values for `page/3`: `nil` (`LIMIT NULL`, no limit) for a
  negative `size`, 0 for a negative `start`.
  """
  @spec limit_offset(integer(), integer()) :: {non_neg_integer() | nil, non_neg_integer()}
  def limit_offset(start, size), do: {if(size < 0, do: nil, else: size), max(start, 0)}

  @doc """
  The PostgreSQL for a query on `table`, after `check/2`: `where` (`""` or `"WHERE ..."`), its
  `params` numbered from `$<first>`, and `order_by` (`"ORDER BY ..., seq"`). Column names come
  from the allow list only; every value is a parameter. Text is compared and sorted with
  `COLLATE "C"` (bytes, as SQLite) and `LIKE` has `ESCAPE ''` (no escape character, as SQLite).
  """
  @spec sql(t(), table(), pos_integer()) ::
          {:ok, %{where: String.t(), params: [String.t() | integer()], order_by: String.t()}}
          | {:error, error()}
  def sql(%__MODULE__{} = query, table, first \\ 1) do
    with :ok <- check(query, table) do
      {fragments, params} =
        Enum.reduce(query.conditions, {[], []}, fn condition, {fragments, params} ->
          {fragment, values} = condition_sql(condition, first + length(params))
          {[fragment | fragments], params ++ values}
        end)

      {fragments, params} =
        case query.free_text do
          nil ->
            {fragments, params}

          pattern ->
            {["lower(json_data) LIKE $#{first + length(params)} ESCAPE ''" | fragments],
             params ++ [pattern]}
        end

      where =
        case Enum.reverse(fragments) do
          [] -> ""
          parts -> "WHERE " <> Enum.join(parts, " AND ")
        end

      {:ok, %{where: where, params: params, order_by: order_by_sql(query.sort)}}
    end
  end

  @doc "Upstream's exception class and message for `error`."
  @spec describe(error()) :: {String.t(), String.t()}
  def describe({:invalid_clause, clause}),
    do: {"IllegalArgumentException", "Incorrectly formatted query string: " <> clause}

  def describe({:invalid_number, value}),
    do: {"NumberFormatException", ~s(For input string: "#{value}")}

  def describe(:missing_value),
    do: {"IndexOutOfBoundsException", "Index 0 out of bounds for length 0"}

  def describe({:unknown_column, name}),
    do:
      {"NonTransientException",
       "Cannot prepare statement for query: [SQLITE_ERROR] SQL error or missing database " <>
         "(no such column: #{name})"}

  def describe({:bind_overflow, count}),
    do: {"ArrayIndexOutOfBoundsException", "Index #{count} out of bounds for length #{count}"}

  ## Parsing

  defp parse_conditions(query) when query in [nil, ""], do: {:ok, []}

  defp parse_conditions(query) when is_binary(query) do
    query
    |> java_split(" AND ")
    |> Enum.reduce_while({:ok, []}, fn clause, {:ok, parsed} ->
      case parse_condition(clause) do
        {:ok, condition} -> {:cont, {:ok, [condition | parsed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} ->
        conditions =
          parsed
          |> Enum.reverse()
          |> Enum.sort_by(&fragment/1)
          |> Enum.flat_map(fn {name, operator, values} ->
            case Map.fetch(@column_atoms, name) do
              {:ok, column} -> [%{column: column, operator: operator, values: values}]
              :error -> []
            end
          end)

        {:ok, conditions}

      error ->
        error
    end
  end

  defp parse_condition(clause) do
    with {:ok, field, operator, raw} <- match_clause(clause) do
      values = raw |> String.replace(~r/["'()]/, "") |> java_split(",")
      name = camel_to_snake(field)
      operator = if operator == :in and length(values) == 1, do: :eq, else: operator

      if String.ends_with?(name, "_time") do
        with {:ok, values} <- time_values(values), do: {:ok, {name, operator, values}}
      else
        {:ok, {name, operator, values}}
      end
    end
  end

  defp match_clause(clause) do
    with [{0, length}, field, operator] <- Regex.run(@clause, clause, return: :index),
         rest = binary_part(clause, length, byte_size(clause) - length),
         {:ok, value} <- line_value(rest) do
      {:ok, binary_part(clause, elem(field, 0), elem(field, 1)),
       operator(binary_part(clause, elem(operator, 0), elem(operator, 1))), value}
    else
      _no_match -> {:error, {:invalid_clause, clause}}
    end
  end

  # `(.*)$`: the value runs to the first line terminator, which must end the clause.
  defp line_value(rest) do
    case :binary.match(rest, @terminators) do
      :nomatch ->
        {:ok, rest}

      {at, _length} ->
        if binary_part(rest, at, byte_size(rest) - at) in @final_terminators,
          do: {:ok, binary_part(rest, 0, at)},
          else: :error
    end
  end

  defp operator("="), do: :eq
  defp operator(">"), do: :gt
  defp operator("<"), do: :lt
  defp operator("IN"), do: :in

  defp time_values([]), do: {:error, :missing_value}

  defp time_values([first | rest]) do
    case java_long(first) do
      {:ok, millis} -> {:ok, [millis | rest]}
      :error -> {:error, {:invalid_number, first}}
    end
  end

  # Long.parseLong for ASCII digits.
  defp java_long(text) do
    with true <- text =~ ~r/\A[+-]?[0-9]+\z/,
         value when value in @long_min..@long_max <- String.to_integer(text) do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp free_text_pattern(free_text) when free_text in [nil, "", "*"], do: nil

  defp free_text_pattern(free_text),
    do: String.replace("%" <> String.downcase(free_text) <> "%", "*", "%")

  defp sort_item(item) do
    with [field, order] <- java_split(item, ":"),
         {:ok, column} <- Map.fetch(@column_atoms, camel_to_snake(field)),
         {:ok, direction} <- direction(String.upcase(order)) do
      [{column, direction}]
    else
      _invalid -> []
    end
  end

  defp direction("ASC"), do: {:ok, :asc}
  defp direction("DESC"), do: {:ok, :desc}
  defp direction(_other), do: :error

  # `camel.replaceAll("\\B([A-Z])", "_$1").toLowerCase()`; Java's \B is ASCII since JDK 19.
  defp camel_to_snake(field),
    do: field |> String.replace(~r/(?<=[A-Za-z0-9_])([A-Z])/, "_\\1") |> String.downcase()

  # Java String#split with a literal separator: no match gives the whole string, and trailing
  # empty parts are dropped.
  defp java_split(string, separator) do
    if String.contains?(string, separator) do
      string
      |> String.split(separator)
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == ""))
      |> Enum.reverse()
    else
      [string]
    end
  end

  # Upstream's SQL fragment of a clause, by which it orders the clauses (and so their parameters
  # and the first failure).
  defp fragment({name, operator, values}) do
    cond do
      operator == :in ->
        list = "#{name} IN (#{Enum.map_join(values, ",", fn _value -> "?" end)})"
        if untagged?(name, values), do: "(#{list} OR #{name} IS NULL)", else: list

      String.ends_with?(name, "_time") ->
        "#{name} #{symbol(operator)} ?"

      operator == :eq and match?([value] when is_binary(value), values) and
          String.contains?(hd(values), "*") ->
        "lower(#{name}) LIKE lower(?)"

      operator == :eq and untagged?(name, values) ->
        "(#{name} = ? OR #{name} IS NULL)"

      true ->
        "#{name} #{symbol(operator)} ?"
    end
  end

  defp symbol(:eq), do: "="
  defp symbol(:gt), do: ">"
  defp symbol(:lt), do: "<"

  # `classifier` asked for the untagged token also matches rows indexed without a classifier.
  defp untagged?(name, values) when name in ["classifier", :classifier],
    do: Enum.any?(values, &(is_binary(&1) and equals_ignore_case?(&1, "workflow")))

  defp untagged?(_name, _values), do: false

  # Java String#equalsIgnoreCase: same length, and each pair of characters equal, equal in upper
  # case or equal in lower case of upper case.
  defp equals_ignore_case?(a, b) do
    chars_a = String.codepoints(a)
    chars_b = String.codepoints(b)

    length(chars_a) == length(chars_b) and
      Enum.zip(chars_a, chars_b)
      |> Enum.all?(fn {x, y} ->
        x == y or String.upcase(x) == String.upcase(y) or
          String.downcase(String.upcase(x)) == String.downcase(String.upcase(y))
      end)
  end

  ## Checking

  defp check_columns(%__MODULE__{conditions: conditions, sort: sort}, columns) do
    always_false? = Enum.any?(conditions, &(&1.operator == :in and &1.values == []))
    where = if always_false?, do: [], else: Enum.map(conditions, & &1.column)

    case Enum.find(where ++ Enum.map(sort, &elem(&1, 0)), &(&1 not in columns)) do
      nil -> :ok
      column -> {:error, {:unknown_column, Atom.to_string(column)}}
    end
  end

  # Upstream binds each clause's values in order, then the free text, then LIMIT and OFFSET.
  defp check_binds(%__MODULE__{conditions: conditions, free_text: free_text}) do
    trailing = if(free_text, do: 1, else: 0) + 2
    placeholders = Enum.sum_by(conditions, &placeholders/1) + trailing

    conditions
    |> Enum.reduce_while(0, fn %{values: values}, bound ->
      cond do
        values == [] -> {:halt, {:error, :missing_value}}
        bound + length(values) > placeholders -> {:halt, {:error, {:bind_overflow, placeholders}}}
        true -> {:cont, bound + length(values)}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      bound when bound + trailing > placeholders -> {:error, {:bind_overflow, placeholders}}
      _bound -> :ok
    end
  end

  defp placeholders(%{operator: :in, values: values}), do: length(values)
  defp placeholders(_condition), do: 1

  ## Memory evaluation

  defp condition_match?(%{column: column, operator: operator, values: [millis | _rest]}, row)
       when column in @time_columns do
    case Map.get(row, column) do
      value when is_integer(value) -> compare(operator, value, millis)
      _null -> false
    end
  end

  defp condition_match?(%{column: column, operator: :in, values: values}, row) do
    case Map.get(row, column) do
      nil -> untagged?(column, values)
      value -> value in values
    end
  end

  defp condition_match?(%{column: column, operator: operator, values: [value]} = condition, row) do
    bound = String.replace(value, "*", "%")

    case {Map.get(row, column), wildcard?(condition)} do
      {nil, false} -> operator == :eq and untagged?(column, [value])
      {nil, true} -> false
      {text, true} -> like?(text, String.downcase(bound))
      {text, false} -> compare(operator, text, bound)
    end
  end

  defp compare(:eq, a, b), do: a == b
  defp compare(:in, a, b), do: a == b
  defp compare(:gt, a, b), do: a > b
  defp compare(:lt, a, b), do: a < b

  # `=` with one value holding a `*` is upstream's `lower(column) LIKE lower(?)`.
  defp wildcard?(%{column: column, operator: operator, values: values}),
    do:
      operator == :eq and column not in @time_columns and match?([_value], values) and
        String.contains?(hd(values), "*")

  # `lower(text) LIKE pattern`, with `pattern` already lowered.
  defp like?(nil, _pattern), do: false
  defp like?(text, pattern), do: text |> String.downcase() |> like_match?(pattern, 0, 0, nil)

  # SQL LIKE without an escape character: `%` matches any run of characters, `_` one character.
  # Backtracks only to the last `%`, so the work is at most text size times pattern size.
  defp like_match?(text, pattern, t, p, star) do
    cond do
      p < byte_size(pattern) and :binary.at(pattern, p) == ?% ->
        like_match?(text, pattern, t, p + 1, {p + 1, t})

      t == byte_size(text) ->
        rest_is_percent?(pattern, p)

      p < byte_size(pattern) and :binary.at(pattern, p) == ?_ ->
        like_match?(text, pattern, t + char_size(text, t), p + char_size(pattern, p), star)

      p < byte_size(pattern) and :binary.at(pattern, p) == :binary.at(text, t) ->
        like_match?(text, pattern, t + 1, p + 1, star)

      star != nil ->
        {star_p, star_t} = star
        next = star_t + char_size(text, star_t)
        like_match?(text, pattern, next, star_p, {star_p, next})

      true ->
        false
    end
  end

  defp rest_is_percent?(pattern, p),
    do: binary_part(pattern, p, byte_size(pattern) - p) =~ ~r/\A%*\z/

  # Bytes of the UTF-8 character at `at` (1 for a byte that does not start one).
  defp char_size(binary, at) do
    case binary_part(binary, at, byte_size(binary) - at) do
      <<char::utf8, _rest::binary>> -> byte_size(<<char::utf8>>)
      _byte -> 1
    end
  end

  defp compare_rows([], a, b), do: compare_values(a.seq, b.seq)

  defp compare_rows([{column, direction} | items], a, b) do
    case compare_values(Map.get(a, column), Map.get(b, column)) do
      :eq -> compare_rows(items, a, b)
      order when direction == :asc -> order
      :lt -> :gt
      :gt -> :lt
    end
  end

  # NULL sorts first, as in SQLite.
  defp compare_values(same, same), do: :eq
  defp compare_values(nil, _b), do: :lt
  defp compare_values(_a, nil), do: :gt
  defp compare_values(a, b) when a < b, do: :lt
  defp compare_values(_a, _b), do: :gt

  ## PostgreSQL

  defp condition_sql(%{column: column, operator: operator, values: [millis | _rest]}, at)
       when column in @time_columns do
    {"#{column} #{if operator == :in, do: "=", else: symbol(operator)} $#{at}", [millis]}
  end

  defp condition_sql(%{column: column, operator: :in, values: values}, at) do
    list =
      "#{column} IN (#{values |> Enum.with_index(at) |> Enum.map_join(", ", &"$#{elem(&1, 1)}")})"

    sql = if untagged?(column, values), do: "(#{list} OR #{column} IS NULL)", else: list
    {sql, values}
  end

  defp condition_sql(%{column: column, operator: operator, values: [value]} = condition, at) do
    bound = String.replace(value, "*", "%")

    cond do
      wildcard?(condition) ->
        {"lower(#{column}) LIKE $#{at} ESCAPE ''", [String.downcase(bound)]}

      operator == :eq and untagged?(column, [value]) ->
        {"(#{column} = $#{at} OR #{column} IS NULL)", [bound]}

      operator == :eq ->
        {"#{column} = $#{at}", [bound]}

      true ->
        {~s(#{column} COLLATE "C" #{symbol(operator)} $#{at}), [bound]}
    end
  end

  defp order_by_sql(items) do
    items
    |> Enum.map(fn {column, direction} ->
      collate = if column in @time_columns, do: "", else: ~s( COLLATE "C")

      case direction do
        :asc -> "#{column}#{collate} ASC NULLS FIRST"
        :desc -> "#{column}#{collate} DESC NULLS LAST"
      end
    end)
    |> Enum.concat(["seq"])
    |> then(&("ORDER BY " <> Enum.join(&1, ", ")))
  end
end
