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
  The search grammar of upstream's default server (`SqliteIndexQueryBuilder` on SQLite; ADR 0027,
  decision 4), shared by both stores.

  `parse/3` turns the `query`, `freeText` and `sort` parameters into a `t:t/0`. Bytes that are
  not UTF-8 become U+FFFD first, as the servlet container decodes them upstream.

    * `query` is split on `" AND "` (Java `String#split`: trailing empty parts dropped), and each
      part must match `^([a-zA-Z]++)\\s*(=|>|<|IN)\\s*(.*)$` as Java does (`\\s` is ASCII, `.`
      stops at a line terminator, `$` also matches before one final terminator). The value loses
      every `"`, `'`, `(` and `)` and is split on `,` (the parts are not trimmed). A one-value `IN`
      is `=`. The field goes from camelCase to snake_case. For a field ending in `_time` the first
      value must be a Java `long` (epoch milliseconds), even when the field is not searchable.
      Clauses on fields outside the allow list are dropped.
    * `freeText` other than empty or `*` matches the summary JSON as `%<text in lower case>%`,
      where `%`, `_` and `*` are wildcards.
    * each `sort` item is `field:ASC|DESC` (order in any case); anything else is dropped.

  `check/2` then reports what upstream only finds when it runs the SQL for a table: a field the
  table has no column for, a clause with no value (`IN (,)`), a non-`IN` clause with more than
  one value (bound parameters overflow), or a `LIKE` pattern over SQLite's 50,000 bytes.
  `run/5` evaluates a checked query over rows in memory and `sql/3` gives the PostgreSQL for it;
  both order by the sort items and then `seq` (`ASC` puts `NULL` first and `DESC` last, as SQLite
  does), and page as SQLite's `LIMIT ? OFFSET ?` does (`page/3`).

  Matching follows SQLite's:

    * `=` and `IN` compare exactly and `>`/`<` compare text by bytes. A time column holds epoch
      milliseconds here and UTC text (`yyyy-MM-dd HH:mm:ss.SSS`) upstream, which only converts
      the first value: a later `IN` value matches when it is that text exactly.
    * `=` with a `*` is `lower(column) LIKE lower(value)` with `*` as `%`; the free text is
      `lower(json_data) LIKE pattern` with the pattern lowered by Java (final sigma included).
      `%` matches any run, `_` one character, there is no escape character, the pattern ends at
      a NUL, and SQLite's `lower()` and `LIKE` fold ASCII letters only.
    * `classifier` asked for `workflow` (Java `equalsIgnoreCase`) also matches rows without one.

  Not reproduced (ADR 0027): the `agentHierarchy` sort, which is dropped; non-ASCII digits in a
  time value, which Java's `Long.parseLong` reads; and a `LIKE` pattern over the limit fails
  here even when SQLite's plan would not have reached it.
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

  # SQLITE_MAX_LIKE_PATTERN_LENGTH.
  @like_pattern_limit 50_000

  # Java's \s, possessive as in upstream's pattern; nothing after the operator can backtrack
  # into it, so this accepts the same clauses.
  @clause ~r/\A([a-zA-Z]++)[\t\n\x0B\f\r ]*+(=|>|<|IN)[\t\n\x0B\f\r ]*+/

  # Java's line terminators, and what `$` accepts after the value.
  @terminators ["\n", "\r", <<0x85::utf8>>, <<0x2028::utf8>>, <<0x2029::utf8>>]
  @final_terminators ["", "\r\n" | @terminators]

  # How upstream writes a time column (SqliteIndexDAO).
  @utc_text ~r/\A(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d{3})\z/

  # SQLite's lower() in PostgreSQL, whatever the database's ctype.
  @ascii_lower "translate(~s, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')"

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
  `free_text` is the `LIKE` pattern on the summary JSON, already lowered and wrapped in `%`, with
  `*` turned into `%`. Conditions are in upstream's order (by SQL fragment).
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
    * `:pattern_too_complex` - a `LIKE` pattern over 50,000 bytes (an SQLite error, wrapped in
      `NonTransientException`).
  """
  @type error ::
          {:invalid_clause, String.t()}
          | {:invalid_number, String.t()}
          | :missing_value
          | {:unknown_column, String.t()}
          | {:bind_overflow, pos_integer()}
          | :pattern_too_complex

  @typedoc "An index row: its columns by name, and `seq` (insertion order)."
  @type row :: %{required(:seq) => integer(), optional(column()) => String.t() | integer() | nil}

  @doc """
  Parses `query`, `freeText` and the `sort` items (see `sort_list/1`). Fails as upstream's
  builder does, at the first bad `query` part.
  """
  @spec parse(String.t() | nil, String.t() | nil, [String.t()]) :: {:ok, t()} | {:error, error()}
  def parse(query, free_text, sort) when is_list(sort) do
    with {:ok, conditions} <- parse_conditions(utf8(query)) do
      {:ok,
       %__MODULE__{
         conditions: conditions,
         free_text: free_text_pattern(utf8(free_text)),
         sort: Enum.flat_map(sort, &(&1 |> utf8() |> sort_item()))
       }}
    end
  end

  @doc """
  Upstream `Utils.convertStringToList`: the `sort` parameter split on `|`, or `[]` when it is
  missing or blank.
  """
  @spec sort_list(String.t() | nil) :: [String.t()]
  def sort_list(nil), do: []

  def sort_list(sort) when is_binary(sort) do
    sort = utf8(sort)
    if SummaryUtil.blank?(sort), do: [], else: java_split(sort, "|")
  end

  @doc """
  What upstream finds when it prepares, binds and runs the SQL for `table`, in its order: a
  column the table lacks (in `query`, then `sort`), then a clause with no value or more values
  than parameters, then a `LIKE` pattern over the limit. A clause `IN (,)` makes SQLite drop the
  whole `WHERE` before it looks up its columns, so only `sort` columns are checked then.
  """
  @spec check(t(), table()) :: :ok | {:error, error()}
  def check(%__MODULE__{} = query, table) do
    columns = Map.fetch!(@tables, table)

    with :ok <- check_columns(query, columns),
         :ok <- check_binds(query),
         do: check_patterns(query)
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
  `COLLATE "C"` (bytes, as SQLite), `LIKE` has `ESCAPE ''` (no escape character, as SQLite) and
  folds ASCII letters only. A `LIKE` pattern ends at its first NUL, as SQLite reads it. Index
  text never holds NUL (ADR 0027, decision 2), which PostgreSQL text cannot bind, so another value
  with NUL is decided here: `=` and `IN` never match it, and `> "a\\0..."` is `> "a"`,
  `< "a\\0..."` is `<= "a"`.
  """
  @spec sql(t(), table(), pos_integer()) ::
          {:ok, %{where: String.t(), params: [String.t() | integer()], order_by: String.t()}}
          | {:error, error()}
  def sql(%__MODULE__{} = query, table, first \\ 1) do
    with :ok <- check(query, table) do
      clauses =
        Enum.map(query.conditions, &condition_sql/1) ++ free_text_sql(query.free_text)

      {fragments, params} =
        Enum.map_reduce(clauses, [], fn {template, values}, params ->
          {template.(placeholders(values, first + length(params))), params ++ values}
        end)

      where = if fragments == [], do: "", else: "WHERE " <> Enum.join(fragments, " AND ")
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
       "Cannot prepare statement for query: " <> sqlite_error("no such column: #{name}")}

  def describe({:bind_overflow, count}),
    do: {"ArrayIndexOutOfBoundsException", "Index #{count} out of bounds for length #{count}"}

  def describe(:pattern_too_complex),
    do: {"NonTransientException", sqlite_error("LIKE or GLOB pattern too complex")}

  defp sqlite_error(text), do: "[SQLITE_ERROR] SQL error or missing database (#{text})"

  ## Parsing

  defp utf8(nil), do: nil
  defp utf8(text), do: String.replace_invalid(text, <<0xFFFD::utf8>>)

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
        {:ok, parsed |> Enum.reverse() |> Enum.sort_by(&fragment/1) |> searchable()}

      error ->
        error
    end
  end

  defp searchable(parsed) do
    for {name, operator, values} <- parsed,
        Map.has_key?(@column_atoms, name),
        do: %{column: Map.fetch!(@column_atoms, name), operator: operator, values: values}
  end

  defp parse_condition(clause) do
    with {:ok, field, operator, raw} <- match_clause(clause),
         values = raw |> String.replace(~r/["'()]/, "") |> java_split(","),
         name = camel_to_snake(field),
         operator = if(operator == :in and length(values) == 1, do: :eq, else: operator),
         {:ok, values} <- time_values(name, values) do
      {:ok, {name, operator, values}}
    end
  end

  defp match_clause(clause) do
    with [{0, length}, {field_at, field_size}, {op_at, op_size}] <-
           Regex.run(@clause, clause, return: :index),
         {:ok, value} <- line_value(binary_part(clause, length, byte_size(clause) - length)) do
      {:ok, binary_part(clause, field_at, field_size),
       operator(binary_part(clause, op_at, op_size)), value}
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

  defp time_values(name, values) do
    cond do
      not String.ends_with?(name, "_time") ->
        {:ok, values}

      values == [] ->
        {:error, :missing_value}

      true ->
        case java_long(hd(values)) do
          {:ok, millis} -> {:ok, [millis | tl(values)]}
          :error -> {:error, {:invalid_number, hd(values)}}
        end
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
    do: String.replace("%" <> String.downcase(free_text, :greek) <> "%", "*", "%")

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
  defp fragment({name, :in, values}) do
    list = "#{name} IN (#{Enum.map_join(values, ",", fn _value -> "?" end)})"
    if untagged?(name, values), do: "(#{list} OR #{name} IS NULL)", else: list
  end

  defp fragment({name, operator, values}) do
    cond do
      String.ends_with?(name, "_time") -> "#{name} #{symbol(operator)} ?"
      operator == :eq and wildcard?(values) -> "lower(#{name}) LIKE lower(?)"
      operator == :eq and untagged?(name, values) -> "(#{name} = ? OR #{name} IS NULL)"
      true -> "#{name} #{symbol(operator)} ?"
    end
  end

  defp symbol(:eq), do: "="
  defp symbol(:gt), do: ">"
  defp symbol(:lt), do: "<"

  # `=` with one value holding a `*` is upstream's `lower(column) LIKE lower(?)`.
  defp wildcard?([value]) when is_binary(value), do: String.contains?(value, "*")
  defp wildcard?(_values), do: false

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

  # A later time value of an IN: the epoch milliseconds of upstream's UTC column text, or nil
  # for text no column holds.
  defp utc_text_millis(text) do
    with [date, time] <- Regex.run(@utc_text, text, capture: :all_but_first),
         {:ok, naive} <- NaiveDateTime.from_iso8601(date <> "T" <> time) do
      naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
    else
      _other -> nil
    end
  end

  defp time_list([millis | later]),
    do: Enum.uniq([millis | later |> Enum.map(&utc_text_millis/1) |> Enum.reject(&is_nil/1)])

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

  defp check_patterns(%__MODULE__{conditions: conditions, free_text: free_text}) do
    patterns =
      for %{column: column, operator: :eq, values: [value]} <- conditions,
          column not in @time_columns and wildcard?([value]),
          do: value

    if Enum.any?(
         [free_text | patterns],
         &(is_binary(&1) and byte_size(&1) > @like_pattern_limit)
       ),
       do: {:error, :pattern_too_complex},
       else: :ok
  end

  ## Memory evaluation

  defp condition_match?(%{column: column, operator: operator, values: values}, row)
       when column in @time_columns do
    case {Map.get(row, column), operator} do
      {nil, _operator} -> false
      {value, :in} -> value in time_list(values)
      {value, operator} -> compare(operator, value, hd(values))
    end
  end

  defp condition_match?(%{column: column, operator: :in, values: values}, row) do
    case Map.get(row, column) do
      nil -> untagged?(column, values)
      value -> value in values
    end
  end

  defp condition_match?(%{column: column, operator: operator, values: [value]}, row) do
    bound = String.replace(value, "*", "%")

    case {Map.get(row, column), operator == :eq and wildcard?([value])} do
      {nil, false} -> operator == :eq and untagged?(column, [value])
      {nil, true} -> false
      {text, true} -> like?(text, bound)
      {text, false} -> compare(operator, text, bound)
    end
  end

  defp compare(:eq, a, b), do: a == b
  defp compare(:gt, a, b), do: a > b
  defp compare(:lt, a, b), do: a < b

  # `lower(text) LIKE pattern` in SQLite: ASCII letters folded on both sides.
  defp like?(nil, _pattern), do: false

  defp like?(text, pattern),
    do: like_match?(String.downcase(text, :ascii), like_pattern(pattern), 0, 0, nil)

  # SQLite reads the pattern as a C string: it ends at the first NUL. Only its length limit
  # counts the whole value.
  defp like_pattern(pattern),
    do: pattern |> :binary.split(<<0>>) |> hd() |> String.downcase(:ascii)

  # SQL LIKE without an escape character: `%` matches any run of characters, `_` one character.
  # Backtracks only to the last `%`, so the work is at most text size times pattern size.
  defp like_match?(text, pattern, t, p, star) do
    case {at(pattern, p), at(text, t)} do
      {?%, _char} -> like_match?(text, pattern, t, p + 1, {p + 1, t})
      {_char, nil} -> rest_is_percent?(pattern, p)
      {?_, _char} -> like_match?(text, pattern, t + char_size(text, t), p + 1, star)
      {same, same} -> like_match?(text, pattern, t + 1, p + 1, star)
      _mismatch -> retry(text, pattern, star)
    end
  end

  defp retry(_text, _pattern, nil), do: false

  defp retry(text, pattern, {star_p, star_t}) do
    next = star_t + char_size(text, star_t)
    like_match?(text, pattern, next, star_p, {star_p, next})
  end

  defp at(binary, index) when index < byte_size(binary), do: :binary.at(binary, index)
  defp at(_binary, _index), do: nil

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

  # Each clause is a template taking its parameter placeholders, and its parameters.
  defp condition_sql(%{column: column, operator: :in, values: values})
       when column in @time_columns,
       do: {&"#{column} IN (#{Enum.join(&1, ", ")})", time_list(values)}

  defp condition_sql(%{column: column, operator: operator, values: [millis | _later]})
       when column in @time_columns,
       do: {&"#{column} #{symbol(operator)} #{hd(&1)}", [millis]}

  defp condition_sql(%{column: column, operator: :in, values: values}) do
    bindable = Enum.reject(values, &nul?/1)
    null = if untagged?(column, values), do: " OR #{column} IS NULL", else: ""

    case bindable do
      [] -> {fn [] -> parenthesize("FALSE", null) end, []}
      _some -> {&parenthesize("#{column} IN (#{Enum.join(&1, ", ")})", null), bindable}
    end
  end

  defp condition_sql(%{column: column, operator: operator, values: [value]}) do
    bound = String.replace(value, "*", "%")

    cond do
      operator == :eq and wildcard?([value]) ->
        like_sql(column, bound)

      operator == :eq ->
        null = if untagged?(column, [value]), do: " OR #{column} IS NULL", else: ""

        if nul?(bound),
          do: {fn [] -> parenthesize("FALSE", null) end, []},
          else: {&parenthesize("#{column} = #{hd(&1)}", null), [bound]}

      true ->
        range_sql(column, operator, bound)
    end
  end

  defp parenthesize(sql, ""), do: sql
  defp parenthesize(sql, null), do: "(#{sql}#{null})"

  # Index text never holds NUL: against a value "p\0...", `>` is `> p` and `<` is `<= p`.
  defp range_sql(column, operator, bound) do
    case :binary.split(bound, <<0>>) do
      [_whole] -> {&~s(#{column} COLLATE "C" #{symbol(operator)} #{hd(&1)}), [bound]}
      [prefix, _rest] when operator == :gt -> {&~s(#{column} COLLATE "C" > #{hd(&1)}), [prefix]}
      [prefix, _rest] -> {&~s(#{column} COLLATE "C" <= #{hd(&1)}), [prefix]}
    end
  end

  defp free_text_sql(nil), do: []
  defp free_text_sql(pattern), do: [like_sql(:json_data, pattern)]

  defp like_sql(column, pattern),
    do: {&"#{ascii_lower(column)} LIKE #{hd(&1)} ESCAPE ''", [like_pattern(pattern)]}

  defp placeholders(values, at),
    do: values |> Enum.with_index(at) |> Enum.map(fn {_value, n} -> "$#{n}" end)

  defp ascii_lower(column), do: String.replace(@ascii_lower, "~s", Atom.to_string(column))

  defp nul?(value), do: is_binary(value) and String.contains?(value, <<0>>)

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
