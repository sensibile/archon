defmodule ArchonWeb.RequestTest do
  @moduledoc """
  `ArchonWeb.Request` against Spring's conversion on the upstream server (ADR 0023, decisions 1
  and 4). Expected messages come from the fixtures where one was captured; the others were
  observed on the same upstream build (conductor-oss 1488804, `curl` against a fresh server).
  """

  use ExUnit.Case, async: true

  alias Archon.Contract
  alias ArchonWeb.Request

  defp conn(query \\ "", body \\ nil) do
    Plug.Adapters.Test.Conn.conn(%Plug.Conn{}, "POST", "/x?" <> query, body)
  end

  defp read(body, opts \\ []) do
    case Request.read_json(conn("", body), opts) do
      {:ok, json, _conn} -> {:ok, json}
      {:error, reason, _conn} -> {:error, reason}
    end
  end

  defp fixture_message(name), do: Contract.fixture(name)["response"]["body"]["message"]

  describe "read_json/2" do
    test "decodes the body as it is, arrays included" do
      assert read(~s([{"name": "a"}])) == {:ok, [%{"name" => "a"}]}
      assert read(~s({"a": null})) == {:ok, %{"a" => nil}}
    end

    # Jackson reads the first value; a repeated key keeps its last value.
    test "ignores what follows the first value and keeps the last of repeated keys" do
      assert read(~s({"a": 1} x)) == {:ok, %{"a" => 1}}
      assert read(~s({"a": 1, "a": 2})) == {:ok, %{"a" => 2}}
      assert read(~s({"o": {"k": 1, "k": [1]}})) == {:ok, %{"o" => %{"k" => [1]}}}
    end

    test "an empty or null body is a missing body" do
      handler = "public void f(java.util.List)"
      assert read("") == {:error, {:server_error, "Required request body is missing"}}

      assert read("null", handler: handler) ==
               {:error, {:server_error, "Required request body is missing: " <> handler}}
    end

    test "blank text and text that is not JSON are parse errors" do
      assert read("  \n") ==
               {:error,
                {:server_error, "JSON parse error: No content to map due to end-of-input"}}

      assert {:error, {:server_error, "JSON parse error: " <> _detail}} = read("not json")
      assert String.starts_with?(fixture_message("request_body_not_json"), "JSON parse error: ")
    end

    test "a body over 8 MB is a 413" do
      body = ~s({"a": ") <> String.duplicate("x", 8_000_001) <> ~s("})
      assert {:error, {:payload_too_large, _message}} = read(body)
    end
  end

  describe "int/4" do
    test "missing or empty is the default" do
      assert Request.int(conn(), "count", 1) == {:ok, 1}
      assert Request.int(conn("count="), "count", 1) == {:ok, 1}
      assert Request.int(conn("other=5"), "count", 1) == {:ok, 1}
    end

    test "converts like NumberUtils.parseNumber" do
      assert Request.int(conn("count=%202"), "count", 1) == {:ok, 2}
      assert Request.int(conn("count=%2B2"), "count", 1) == {:ok, 2}
      assert Request.int(conn("count=-3"), "count", 1) == {:ok, -3}
      assert Request.int(conn("count=0x10"), "count", 1) == {:ok, 16}
      assert Request.int(conn("count=%2310"), "count", 1) == {:ok, 16}
      assert Request.int(conn("count=2147483647"), "count", 1) == {:ok, 2_147_483_647}
    end

    test "a repeated parameter converts its first value" do
      assert Request.int(conn("count=1&count=abc"), "count", 5) == {:ok, 1}
    end

    test "a value that does not convert is the fixture's 500 message" do
      assert Request.int(conn("count=abc"), "count", 1) ==
               {:error, {:server_error, fixture_message("request_query_not_number")}}
    end

    test "other conversion failures carry NumberFormatException's message" do
      prefix =
        "Method parameter 'count': Failed to convert value of type 'java.lang.String' to required type 'int'; "

      for {query, detail} <- [
            {"count=1.5", ~s(For input string: "1.5")},
            {"count=--1", ~s(For input string: "--1")},
            {"count=99999999999", ~s(For input string: "99999999999")},
            {"count=%20", ~s(For input string: "")},
            {"count=0xZZ", ~s(For input string: "ZZ" under radix 16)}
          ] do
        assert Request.int(conn(query), "count", 1) == {:error, {:server_error, prefix <> detail}}
      end
    end

    test "a boxed Integer takes blank text as the default and names its type" do
      assert Request.int(conn("version=%20"), "version", nil, "java.lang.Integer") == {:ok, nil}

      assert Request.int(conn("version=abc"), "version", nil, "java.lang.Integer") ==
               {:error,
                {:server_error,
                 "Method parameter 'version': Failed to convert value of type 'java.lang.String' " <>
                   ~s(to required type 'java.lang.Integer'; For input string: "abc")}}
    end
  end

  describe "boolean/4" do
    test "missing or empty is the default" do
      assert Request.boolean(conn(), "includeTasks", true) == {:ok, true}
      assert Request.boolean(conn("includeTasks="), "includeTasks", true) == {:ok, true}
    end

    test "accepts CustomBooleanEditor's words in any case" do
      for {text, value} <- [
            {"YES", true},
            {"%20off%20", false},
            {"1", true},
            {"0", false},
            {"On", true},
            {"no", false}
          ] do
        assert Request.boolean(conn("b=" <> text), "b", nil) == {:ok, value}
      end
    end

    test "anything else, blank text included, is the fixture's 500 message" do
      assert Request.boolean(conn("includeTasks=maybe"), "includeTasks", true) ==
               {:error, {:server_error, fixture_message("request_query_not_boolean")}}

      assert {:error, {:server_error, message}} =
               Request.boolean(conn("includeTasks=%20"), "includeTasks", true)

      assert String.ends_with?(message, "Invalid boolean value [ ]")
    end
  end

  describe "string/3" do
    test "joins repeated values with a comma" do
      assert Request.string(conn("reason=a&reason=b"), "reason") == "a,b"
      assert Request.string(conn("reason=a+b"), "reason") == "a b"
    end

    test "missing is the default; empty is the default when there is one" do
      assert Request.string(conn(), "reason") == nil
      assert Request.string(conn("reason="), "reason") == ""
      assert Request.string(conn("reason="), "reason", "x") == "x"
    end
  end

  # Tomcat drops a pair it cannot decode; Plug.Conn.fetch_query_params/1 would raise.
  test "a pair that does not decode is left out" do
    assert Request.boolean(conn("includeTasks=%zz"), "includeTasks", true) == {:ok, true}
    assert Request.int(conn("%zz=1&count=3"), "count", 1) == {:ok, 3}
  end
end
