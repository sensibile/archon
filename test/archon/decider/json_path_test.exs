defmodule Archon.Decider.JsonPathTest do
  use ExUnit.Case, async: true

  alias Archon.Decider.JsonPath

  @doc_json %{
    "a" => %{"b" => [10, 20, 30], "c d" => 1, "e.f" => 2, "n" => nil},
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
    assert JsonPath.read(@doc_json, "a.*") == [[10, 20, 30], 1, 2, nil]
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
          "a[x]"
        ] do
      assert JsonPath.read(@doc_json, path) == nil, path
    end
  end
end
