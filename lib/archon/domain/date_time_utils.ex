# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/utils/DateTimeUtils.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns values instead of throwing; the commons-lang3 DateUtils.parseDate
# call it delegates to is reimplemented for its three patterns (ADR 0014).

defmodule Archon.Domain.DateTimeUtils do
  @moduledoc """
  Upstream `DateTimeUtils`: the `WAIT` task's `duration` and `until` formats.

  `parse_date/1` reproduces what commons-lang3 3.18 `DateUtils.parseDate` (lenient) does with
  upstream's patterns `yyyy-MM-dd HH:mm`, `yyyy-MM-dd HH:mm z` and `yyyy-MM-dd`, as checked
  against the real library:

    * each number may be preceded by Java whitespace, and each literal separator matches itself
      exactly (a tab is not the space between date and time);
    * out-of-range fields roll over (`2022-13-01` is 2023-01-01, `25:61` the next day), and a
      number that does not fit an `int` fails;
    * a time without a zone is UTC, the default time zone of an upstream server running in UTC;
    * the zone is `GMT`/`UTC` (any case), `GMT±H:MM`/`GMT±HH:MM` or `±HHMM`, hours up to 23
      and minutes up to 59.

  Not reproduced (ADR 0014): zone names other than `GMT`/`UTC` such as `KST` or `PST`, which
  need a time zone database and upstream's server locale; non-ASCII digits; and the Julian
  calendar `GregorianCalendar` uses before 1582-10-15 and its overflow for years past the `int`
  range. Those dates are computed in the proleptic Gregorian calendar.
  """

  @int_max 2_147_483_647

  # Upstream's DURATION_PATTERN with possessive quantifiers: whitespace and digits can never be
  # shared between neighbouring parts, so this accepts the same strings without backtracking.
  @duration ~r/^\s*+(?:(\d++)\s*+(?:days?|d))?\s*+(?:(\d++)\s*+(?:hours?|hrs?|h))?\s*+(?:(\d++)\s*+(?:minutes?|mins?|m))?\s*+(?:(\d++)\s*+(?:seconds?|secs?|s))?\s*+\z/i

  # Character.isWhitespace: Unicode space separators other than the no-break ones, the line and
  # paragraph separators, and the ASCII controls \t-\r and \x1C-\x1F.
  @ws "[\\t-\\r\\x{1C}-\\x{20}\\x{1680}\\x{2000}-\\x{2006}\\x{2008}-\\x{200A}\\x{2028}\\x{2029}\\x{205F}\\x{3000}]*+"
  @num "#{@ws}([0-9]++)"
  @date_part "#{@num}-#{@num}-#{@num}"
  @time_part " #{@num}:#{@num}"

  @patterns [
    Regex.compile!("^#{@date_part}#{@time_part}\\z", "u"),
    Regex.compile!("^#{@date_part}#{@time_part} (\\S++)\\z", "u"),
    Regex.compile!("^#{@date_part}\\z", "u")
  ]

  @zone ~r/^(?:(?:GMT|UTC)|GMT([+-])([0-9]{1,2}):([0-9]{2})|([+-])([0-9]{2})([0-9]{2}))\z/i

  @doc """
  Upstream `parseDuration`: whole seconds of `"1d 2h 3m 4s"`-style text, or `:error` where
  upstream throws `IllegalArgumentException` (no match, or a number past the `int` range).
  Like upstream, the days are multiplied in `int` arithmetic and wrap past 24,855 days.
  """
  @spec parse_duration(String.t()) :: {:ok, integer()} | :error
  def parse_duration(text) when is_binary(text) do
    # Trailing parts that did not participate are left out of the groups.
    with groups when is_list(groups) <- Regex.run(@duration, text, capture: :all_but_first),
         {:ok, [days, hours, mins, secs]} <- ints(pad(groups, 4)) do
      {:ok, wrap_int(days * 86_400) + (hours * 60 + mins) * 60 + secs}
    else
      _no_match -> :error
    end
  end

  @doc """
  Upstream `parseDate`: epoch milliseconds of `text`, or `:error` where upstream throws
  `ParseException`.
  """
  @spec parse_date(String.t()) :: {:ok, integer()} | :error
  def parse_date(text) when is_binary(text) do
    Enum.find_value(@patterns, :error, fn pattern ->
      with [_ | _] = groups <- Regex.run(pattern, text, capture: :all_but_first),
           {:ok, ms} <- epoch_ms(groups) do
        {:ok, ms}
      else
        _no_match -> nil
      end
    end)
  end

  defp epoch_ms([year, month, day]), do: epoch_ms([year, month, day, "0", "0"])

  defp epoch_ms([_y, _mo, _d, _h, _mi] = fields) do
    with {:ok, [year, month, day, hour, minute]} <- ints(fields) do
      {:ok, local_ms(year, month, day, hour, minute)}
    end
  end

  defp epoch_ms([y, mo, d, h, mi, zone]) do
    with {:ok, ms} <- epoch_ms([y, mo, d, h, mi]),
         {:ok, offset} <- zone_offset_ms(zone) do
      {:ok, ms - offset}
    end
  end

  # Lenient GregorianCalendar: months roll into years, then days, hours and minutes are added.
  defp local_ms(year, month, day, hour, minute) do
    months = year * 12 + month - 1
    days = days_from_civil(Integer.floor_div(months, 12), Integer.mod(months, 12) + 1) + day - 1
    days * 86_400_000 + hour * 3_600_000 + minute * 60_000
  end

  # Days from 1970-01-01 to the first of the month (Hinnant's days_from_civil).
  defp days_from_civil(year, month) do
    y = if month <= 2, do: year - 1, else: year
    era = Integer.floor_div(y, 400)
    yoe = y - era * 400
    doy = div(153 * (month + if(month > 2, do: -3, else: 9)) + 2, 5)
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    era * 146_097 + doe - 719_468
  end

  defp zone_offset_ms(zone) do
    case Regex.run(@zone, zone, capture: :all_but_first) do
      [] -> {:ok, 0}
      [sign, hours, minutes] -> offset_ms(sign, hours, minutes)
      ["", "", "", sign, hours, minutes] -> offset_ms(sign, hours, minutes)
      nil -> :error
    end
  end

  defp offset_ms(sign, hours, minutes) do
    {hours, minutes} = {String.to_integer(hours), String.to_integer(minutes)}

    if hours <= 23 and minutes <= 59 do
      ms = (hours * 60 + minutes) * 60_000
      {:ok, if(sign == "-", do: -ms, else: ms)}
    else
      :error
    end
  end

  defp pad(groups, size), do: groups ++ List.duplicate("", size - length(groups))

  # Integer.parseInt of each group; an empty group is a missing part, read as 0.
  defp ints(groups) do
    Enum.reduce_while(groups, {:ok, []}, fn digits, {:ok, acc} ->
      case int(digits) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp int(""), do: {:ok, 0}

  # Checked on the digits before converting so huge inputs stay cheap.
  defp int(digits) do
    significant = String.trim_leading(digits, "0")

    cond do
      significant == "" -> {:ok, 0}
      byte_size(significant) > 10 -> :error
      (value = String.to_integer(significant)) <= @int_max -> {:ok, value}
      true -> :error
    end
  end

  defp wrap_int(value) do
    <<wrapped::signed-32>> = <<value::signed-32>>
    wrapped
  end
end
