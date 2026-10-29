# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/utils/DateTimeUtilsTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests; the parse_date cases are outputs of
# commons-lang3 3.18.0 DateUtils.parseDate with upstream's patterns on JDK 25 in UTC (ADR 0014).

defmodule Archon.Domain.DateTimeUtilsTest do
  use ExUnit.Case, async: true

  alias Archon.Domain.DateTimeUtils

  describe "parse_duration/1 (DateTimeUtilsTest)" do
    test "shouldParseDuration" do
      for {input, seconds} <- [
            {"", 0},
            {"5s", 5},
            {"5secs", 5},
            {"5seconds", 5},
            {"5m", 300},
            {"5mins", 300},
            {"5minutes", 300},
            {"5h", 18_000},
            {"5hrs", 18_000},
            {"5hours", 18_000},
            {"5d", 432_000},
            {"5days", 432_000},
            {"5m 5s", 305},
            {"5h 5m 5s", 18_305},
            {"5d 5h 5m 5s", 450_305},
            {"5S", 5},
            {"5SECS", 5},
            {"5SECONDS", 5},
            {"5M", 300},
            {"5MINS", 300},
            {"5MINUTES", 300},
            {"5H", 18_000},
            {"5HRS", 18_000},
            {"5HOURS", 18_000},
            {"5D", 432_000},
            {"5DAYS", 432_000},
            {"5M 5S", 305},
            {"5H 5M 5S", 18_305},
            {"5D 5H 5M 5S", 450_305}
          ] do
        assert DateTimeUtils.parse_duration(input) == {:ok, seconds}, input
      end
    end

    test "shouldValidateDuration" do
      for input <-
            ~w(5 s secs seconds m mins minutes h hours d days 5.0s 5.0secs 5.0seconds 5.0m 5.0mins
               5.0minutes 5.0h 5.0hrs 5.0hours 5.0d 5.0days) ++
              ["5.0m 5s", "5.0h 5m 5s", "5.0d 5h 5m 5s"] do
        assert DateTimeUtils.parse_duration(input) == :error, input
      end
    end

    test "a number past the int range is invalid, and days wrap in int arithmetic" do
      assert DateTimeUtils.parse_duration("2147483648s") == :error
      assert DateTimeUtils.parse_duration("2147483647s") == {:ok, 2_147_483_647}
      # 30000 * 86400 overflows an int: Java's (days * 86400) is -1702967296.
      assert DateTimeUtils.parse_duration("30000d") == {:ok, -1_702_967_296}
    end
  end

  describe "parse_date/1 (commons-lang3 DateUtils.parseDate)" do
    test "the three patterns, a zone-less time being UTC" do
      assert DateTimeUtils.parse_date("2022-12-12") == {:ok, 1_670_803_200_000}
      assert DateTimeUtils.parse_date("2022-12-12 10:00") == {:ok, 1_670_839_200_000}
      assert DateTimeUtils.parse_date("2022-12-12 10:00 GMT") == {:ok, 1_670_839_200_000}
      assert DateTimeUtils.parse_date("1970-01-01") == {:ok, 0}
    end

    test "out-of-range fields roll over" do
      for {input, ms} <- [
            {"2022-13-01", 1_672_531_200_000},
            {"2022-02-30", 1_646_179_200_000},
            {"2022-12-12 25:61", 1_670_896_860_000},
            {"2022-0-0", 1_638_230_400_000},
            {"2022-12-0 0:0", 1_669_766_400_000},
            {"2022-12-31 23:60", 1_672_531_200_000},
            {"2023-02-29", 1_677_628_800_000},
            {"2024-02-29", 1_709_164_800_000},
            {"2100-02-29", 4_107_542_400_000},
            {"2400-02-29", 13_574_563_200_000},
            {"1600-03-01", -11_670_912_000_000},
            {"99999-12-12", 3_093_526_252_800_000},
            {"2022-12-12 2147483647:0", 7_732_611_932_400_000},
            {"2022-12-12 0:2147483647", 130_519_822_020_000},
            {"2022-1-2147483647", 185_544_228_009_600_000},
            {"2022-2147483647-1", 5_647_338_169_056_000_000}
          ] do
        assert DateTimeUtils.parse_date(input) == {:ok, ms}, input
      end
    end

    test "numbers take leading zeros and Java whitespace; separators match exactly" do
      for {input, ms} <- [
            {"2022-1-5", 1_641_340_800_000},
            {"002022-012-012", 1_670_803_200_000},
            {"2022-12-12 1:5", 1_670_807_100_000},
            {" 2022-12-12", 1_670_803_200_000},
            {"  2022-12-12", 1_670_803_200_000},
            {"\t2022-12-12", 1_670_803_200_000},
            {" 2022-12-12", 1_670_803_200_000},
            {"2022- 12-12", 1_670_803_200_000},
            {"2022-12- 12", 1_670_803_200_000},
            {"2022-12-12  10:00", 1_670_839_200_000},
            {"2022-12-12 　10:00", 1_670_839_200_000},
            {"2022-12-12 10: 00", 1_670_839_200_000}
          ] do
        assert DateTimeUtils.parse_date(input) == {:ok, ms}, inspect(input)
      end

      for input <- [
            " 2022-12-12",
            "2022-12-12\t10:00",
            "2022-12-12 ",
            "2022-12-12 10:00 GMT ",
            "2022-12-12 10:00  GMT",
            "-2022-12-12",
            "2022-+12-12",
            "99999999999-12-12",
            "2022-99999999999-12",
            "",
            " ",
            "2022",
            "2022-12",
            "2022-12-12 10",
            "2022-12-12T10:00",
            "2022-12-12 10:00:00",
            "2022-12-1210:00"
          ] do
        assert DateTimeUtils.parse_date(input) == :error, inspect(input)
      end
    end

    test "zones: GMT and UTC, GMT offsets with a colon, RFC 822 offsets" do
      for {input, ms} <- [
            {"2022-12-12 10:00 UTC", 1_670_839_200_000},
            {"2022-12-12 10:00 gmt", 1_670_839_200_000},
            {"2022-12-12 10:00 Utc", 1_670_839_200_000},
            {"2022-12-12 10:00 GMT+09:00", 1_670_806_800_000},
            {"2022-12-12 10:00 gmt+09:00", 1_670_806_800_000},
            {"2022-12-12 10:00 GMT+9:00", 1_670_806_800_000},
            {"2022-12-12 10:00 GMT-08:00", 1_670_868_000_000},
            {"2022-12-12 10:00 GMT+23:59", 1_670_752_860_000},
            {"2022-12-12 10:00 GMT-23:59", 1_670_925_540_000},
            {"2022-12-12 10:00 GMT+00:00", 1_670_839_200_000},
            {"2022-12-12 10:00 +0900", 1_670_806_800_000},
            {"2022-12-12 10:00 -0800", 1_670_868_000_000},
            {"2022-12-12 10:00 -0000", 1_670_839_200_000},
            {"2022-12-12 10:00 +2359", 1_670_752_860_000}
          ] do
        assert DateTimeUtils.parse_date(input) == {:ok, ms}, input
      end

      for zone <- ~w(Z UT GMT-0 GMT+9 GMT+09 GMT+0900 GMT+0930 GMT+9:5 GMT+24:00 GMT+09:99
                     UTC+09:00 +9 +09 +090 +09:00 -08:00 +2400 +0099 GMT+09:00x) do
        assert DateTimeUtils.parse_date("2022-12-12 10:00 #{zone}") == :error, zone
      end
    end

    test "zone names other than GMT and UTC are not supported (upstream accepts KST)" do
      assert DateTimeUtils.parse_date("2022-12-12 10:00 KST") == :error
      assert DateTimeUtils.parse_date("2022-12-12 10:00 PST") == :error
    end
  end
end
