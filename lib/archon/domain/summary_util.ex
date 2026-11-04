# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/utils/SummaryUtil.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: only the default Map.toString serialization, plus the GMT date format,
# String.length and String.isBlank that WorkflowSummary and TaskSummary use (ADR 0027).

defmodule Archon.Domain.SummaryUtil do
  @moduledoc """
  What `Archon.Domain.WorkflowSummary` and `Archon.Domain.TaskSummary` share with upstream's
  summary constructors (ADR 0027, decision 3).

  Checked against the upstream classes on JDK 25 (`SimpleDateFormat` in GMT, `String#length`,
  `String#isBlank`).
  """

  alias Archon.Decider.Parameters
  alias Archon.Domain.Codec

  # 1582-10-15T00:00:00Z: GregorianCalendar's default cutover. Earlier instants are Julian dates.
  @gregorian_cutover_ms -12_219_292_800_000
  @day_ms 86_400_000

  @doc """
  Upstream `SummaryUtil.serializeInputOutput` with its default setting
  (`summary-input-output-json-serialization.enabled=false`): Java `Map#toString`. Keys are in
  sorted order (`Archon.Decider.Parameters.java_string/1`); upstream keeps the input order.
  """
  @spec serialize_input_output(Codec.json_object()) :: String.t()
  def serialize_input_output(map) when is_map(map), do: Parameters.java_string(map)

  @doc """
  `SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")` in GMT of epoch milliseconds: the Julian
  calendar before 1582-10-15, the year of era (no sign) before year 1, and at least four year
  digits.
  """
  @spec format_time(integer()) :: String.t()
  def format_time(ms) when is_integer(ms) do
    days = Integer.floor_div(ms, @day_ms)
    in_day = ms - days * @day_ms

    {year, month, day} =
      if ms >= @gregorian_cutover_ms, do: gregorian(days), else: julian(days)

    year_of_era = if year > 0, do: year, else: 1 - year

    [
      year_of_era |> Integer.to_string() |> String.pad_leading(4, "0"),
      ?-,
      pad2(month),
      ?-,
      pad2(day),
      ?T,
      pad2(div(in_day, 3_600_000)),
      ?:,
      pad2(rem(div(in_day, 60_000), 60)),
      ?:,
      pad2(rem(div(in_day, 1000), 60)),
      ?.,
      in_day |> rem(1000) |> Integer.to_string() |> String.pad_leading(3, "0"),
      ?Z
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Java `String#length`: UTF-16 code units."
  @spec utf16_length(String.t()) :: non_neg_integer()
  def utf16_length(string) when is_binary(string) do
    for <<char::utf8 <- string>>, reduce: 0 do
      units -> if char > 0xFFFF, do: units + 2, else: units + 1
    end
  end

  @doc "Java `String#isBlank`: empty, or only `Character#isWhitespace` code points."
  @spec blank?(String.t()) :: boolean()
  def blank?(string) when is_binary(string),
    do:
      string =~
        ~r/\A[\t-\r\x{1C}-\x{20}\x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}\x{3000}]*\z/u

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's civil_from_days).
  defp gregorian(days) do
    z = days + 719_468
    era = Integer.floor_div(z, 146_097)
    doe = z - era * 146_097
    yoe = div(doe - div(doe, 1460) + div(doe, 36_524) - div(doe, 146_096), 365)
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    day = doy - div(153 * mp + 2, 5) + 1
    month = if mp < 10, do: mp + 3, else: mp - 9
    year = yoe + era * 400
    {if(month <= 2, do: year + 1, else: year), month, day}
  end

  # Days since 1970-01-01 to a Julian calendar date, through the Julian day number.
  defp julian(days) do
    c = days + 2_440_588 + 32_082
    d = Integer.floor_div(4 * c + 3, 1461)
    e = c - Integer.floor_div(1461 * d, 4)
    m = div(5 * e + 2, 153)
    day = e - div(153 * m + 2, 5) + 1
    month = m + 3 - 12 * div(m, 10)
    {d - 4800 + div(m, 10), month, day}
  end
end
