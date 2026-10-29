defmodule Archon.Decider.JsonPathTest do
  use ExUnit.Case, async: true

  alias Archon.Decider.JsonPath

  # Supported-syntax expectations were checked against Jayway JsonPath 2.4.0 (json-path-2.4.0.jar
  # with Option.SUPPRESS_EXCEPTIONS, as upstream ParametersUtils reads) on the same document.
  # Two differences are intended (ADR 0014): `a.*` lists map values in key order rather than
  # insertion order, and the unsupported syntax below reads as nil where Jayway returns a value.
  @doc_json %{
    "a" => %{
      "b" => [10, 20, 30],
      "c d" => 1,
      "e.f" => 2,
      "n" => nil,
      "customer's name" => 7,
      "back\\slash" => 8,
      "😀" => 42
    },
    "list" => [%{"x" => 1}, %{"y" => 2}, %{"x" => 3}],
    "s" => "text"
  }

  test "dot notation with or without the $ root" do
    assert JsonPath.read(@doc_json, "a.b") == [10, 20, 30]
    assert JsonPath.read(@doc_json, "$.a.b") == [10, 20, 30]
    assert JsonPath.read(@doc_json, "  a.b  ") == [10, 20, 30]
    assert JsonPath.read(@doc_json, "$") == @doc_json
  end

  test "quoted brackets and indexes" do
    assert JsonPath.read(@doc_json, "a['c d']") == 1
    assert JsonPath.read(@doc_json, ~s(a["e.f"])) == 2
    assert JsonPath.read(@doc_json, "$['a']['b'][1]") == 20
    assert JsonPath.read(@doc_json, "a.b[-1]") == 30
    assert JsonPath.read(@doc_json, "a.b[ 0 ]") == 10
    assert JsonPath.read(@doc_json, "a.b[0001]") == 20
    assert JsonPath.read(@doc_json, "a[ 'c d' ]") == 1
  end

  test "brackets right after the root, with or without a dot" do
    assert JsonPath.read(@doc_json, "['a']['c d']") == 1
    assert JsonPath.read(@doc_json, "$.['a']['c d']") == 1
    assert JsonPath.read(@doc_json, "a.['c d']") == 1
  end

  test "backslash escapes in quoted names" do
    assert JsonPath.read(@doc_json, "a['customer\\'s name']") == 7
    assert JsonPath.read(@doc_json, ~s(a["customer's name"])) == 7
    assert JsonPath.read(@doc_json, "a['back\\\\slash']") == 8
    assert JsonPath.read(@doc_json, "a['c\\u0020d']") == 1
    assert JsonPath.read(@doc_json, "a['e\\.f']") == 2
    assert JsonPath.read(@doc_json, "a['c\\ d']") == 1
    assert JsonPath.read(@doc_json, "a['c\\x d']") == nil
    assert JsonPath.read(@doc_json, "a['\\uD83D\\uDE00']") == 42
    assert JsonPath.read(@doc_json, "a['\\uD83D']") == nil
    assert JsonPath.read(@doc_json, "a['\\ud800']") == nil
    assert JsonPath.read(@doc_json, "a['\\uDE00\\uD83D']") == nil
    assert JsonPath.read(@doc_json, "a['\\uZZZZ']") == nil
    assert JsonPath.read(@doc_json, "a['\\u12']") == nil
    assert JsonPath.read(@doc_json, "a['\\u']") == nil
    assert JsonPath.read(@doc_json, "a['\\u-001']") == nil
    assert JsonPath.read(@doc_json, "a['\\u+041']") == nil
  end

  test "paths that do not resolve read as nil" do
    assert JsonPath.read(@doc_json, "a.missing") == nil
    assert JsonPath.read(@doc_json, "a.b[3]") == nil
    assert JsonPath.read(@doc_json, "a.b[-4]") == nil
    assert JsonPath.read(@doc_json, "a.b.c") == nil
    assert JsonPath.read(@doc_json, "s.length") == nil
    assert JsonPath.read(@doc_json, "a[0]") == nil
    assert JsonPath.read(@doc_json, "a.n") == nil
  end

  test "wildcards read as the list of what they reach, skipping misses" do
    assert JsonPath.read(@doc_json, "list[*].x") == [1, 3]
    assert JsonPath.read(@doc_json, "list.*.y") == [2]
    assert JsonPath.read(@doc_json, "list[*].z") == []
    assert JsonPath.read(@doc_json, "a.*") == [[10, 20, 30], 8, 1, 7, 2, nil, 42]
  end

  test "unsupported or invalid syntax reads as nil" do
    for path <- [
          "$..b",
          "a..b",
          "a.",
          "a b",
          "a.b[0:2]",
          "a.b[?(@ > 1)]",
          "a['b','c d']",
          "a.b.length()",
          "@.a",
          "$a",
          "a[x]",
          "a.b[2147483648]",
          "a.b[-2147483649]",
          "a.b[" <> String.duplicate("9", 2_000_000) <> "]"
        ] do
      assert JsonPath.read(@doc_json, path) == nil, path
    end
  end
end
