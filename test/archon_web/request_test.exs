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

  defp read(body, opts \\ [], content_type \\ "application/json") do
    conn = conn("", body)

    conn =
      if content_type,
        do: Plug.Conn.put_req_header(conn, "content-type", content_type),
        else: conn

    case Request.read_json(conn, opts) do
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

    # Observed upstream: "123abc" and "01" fail; a container root may be followed by anything.
    test "a scalar root value must end at whitespace or the end of the body" do
      assert {:error, {:server_error, "JSON parse error: " <> _}} = read("123abc")
      assert {:error, {:server_error, "JSON parse error: " <> _}} = read("01")
      assert read(~s("s" )) == {:ok, "s"}
      assert read("[1]x") == {:ok, [1]}
    end

    # StreamReadConstraints: upstream accepts 1000 levels and refuses 1001 with this message.
    test "nesting deeper than 1000 is refused before decoding" do
      deep = fn n -> String.duplicate(~s({"a":), n) <> "1" <> String.duplicate("}", n) end
      assert {:ok, _json} = read(deep.(1000))

      assert read(deep.(1001)) ==
               {:error,
                {:server_error,
                 "JSON parse error: Document nesting depth (1001) exceeds the maximum allowed " <>
                   "(1000, from `StreamReadConstraints.getMaxNestingDepth()`)"}}

      assert {:error, {:server_error, "JSON parse error: Document nesting" <> _}} =
               read(String.duplicate("[", 8_000_000))

      # Only the first value is read, as Jackson does.
      assert read("{}" <> String.duplicate("[", 1001)) == {:ok, %{}}
      assert read("1 " <> String.duplicate("[", 1001)) == {:ok, 1}

      # Brackets inside strings do not count.
      assert {:ok, %{"a" => _}} = read(~s({"a": ") <> String.duplicate("[", 2000) <> ~s(\\"x"}))
    end

    # StreamReadConstraints.getMaxNumberLength, observed upstream: integer, fraction and exponent
    # digits count, signs do not.
    test "a number longer than 1000 digits is refused before decoding" do
      digits = &String.duplicate("1", &1)
      assert {:ok, %{"a" => _}} = read(~s({"a": #{digits.(1000)}}))
      assert {:ok, %{"a" => _}} = read(~s({"a": -#{digits.(1000)}}))

      message = fn n ->
        {:error,
         {:server_error,
          "JSON parse error: Number value length (#{n}) exceeds the maximum allowed " <>
            "(1000, from `StreamReadConstraints.getMaxNumberLength()`)"}}
      end

      assert read(~s({"a": #{digits.(1001)}})) == message.(1001)
      assert read(~s({"a": [#{digits.(600)}.#{digits.(600)}]})) == message.(1200)
      assert read(~s([1, 2, #{digits.(5000)}])) == message.(5000)
      assert read(digits.(1001)) == message.(1001)
      assert read(~s({"a": 1.0e-#{digits.(999)}})) == message.(1001)
      assert read(~s({"a": #{digits.(1000)}e5})) == message.(1001)
      # 1000 digits pass the limit (upstream accepts 1e<999 digits>); :json cannot build it.
      assert {:error, {:server_error, "JSON parse error: the request body" <> _}} =
               read(~s([1e#{digits.(999)}]))

      assert read(~s({"#{digits.(2000)}": "#{digits.(2000)}"})) |> elem(0) == :ok
    end

    # Observed upstream (Spring's JSON message converter).
    test "a non-empty body needs a JSON Content-Type" do
      for type <- [
            "application/json;charset=UTF-8",
            "APPLICATION/JSON",
            "application/merge-patch+json",
            "application/json; foo=bar"
          ] do
        assert read("{}", [], type) == {:ok, %{}}, type
      end

      unsupported = &{:error, {:server_error, "Content-Type '#{&1}' is not supported"}}
      assert read("{}", [], nil) == unsupported.("application/octet-stream")
      assert read("{}", [], "text/plain") == unsupported.("text/plain;charset=UTF-8")

      assert read("{}", [], "text/plain; charset=ISO-8859-1") ==
               unsupported.("text/plain;charset=ISO-8859-1")

      assert read("{}", [], "application/x-ndjson") ==
               unsupported.("application/x-ndjson;charset=UTF-8")

      assert read("{}", [], "multipart/form-data; boundary=x") ==
               unsupported.("multipart/form-data;boundary=x;charset=UTF-8")

      assert read("{}", [], "application/*+json") ==
               {:error, {:invalid, "Content-Type cannot contain wildcard subtype '*'"}}

      assert read("{}", [], "garbage") ==
               {:error, {:server_error, ~s(Invalid mime type "garbage": does not contain '/')}}

      # An empty body is the missing body whatever its type.
      assert read("", [], "text/plain") ==
               {:error, {:server_error, "Required request body is missing"}}
    end

    test "a UTF-8 byte order mark is skipped" do
      assert read(<<0xEF, 0xBB, 0xBF>> <> ~s({"a": 1})) == {:ok, %{"a" => 1}}
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
      assert Request.int(conn("count=-0x10"), "count", 1) == {:ok, -16}
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
            {"count=0xZZ", ~s(For input string: "ZZ" under radix 16)},
            {"count=%2B0x10", ~s(For input string: "+0x10")}
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

  describe "convert_int/4" do
    test "converts a value that is not a query value as int/4 does" do
      assert Request.convert_int("version", "0x10", nil, "java.lang.Integer") == {:ok, 16}
      assert Request.convert_int("version", " ", nil, "java.lang.Integer") == {:ok, nil}
      assert Request.convert_int("version", "", 7, "java.lang.Integer") == {:ok, 7}

      assert {:error, {:server_error, "Method parameter 'version': " <> _rest}} =
               Request.convert_int("version", "x", nil, "java.lang.Integer")
    end
  end

  test "values/2 lists every value of a parameter in order" do
    assert Request.values(conn("a=1&b=2&a=3"), "a") == ["1", "3"]
    assert Request.values(conn("b=2"), "a") == []
  end

  describe "long/4" do
    test "takes Java's long range and names java.lang.Long" do
      assert Request.long(conn(), "t", nil) == {:ok, nil}
      assert Request.long(conn("t=%20"), "t", nil) == {:ok, nil}

      assert Request.long(conn("t=-9223372036854775808"), "t", nil) ==
               {:ok, -9_223_372_036_854_775_808}

      assert Request.long(conn("t=0x7fffffffffffffff"), "t", nil) ==
               {:ok, 9_223_372_036_854_775_807}

      # Character.isWhitespace, as int/4: a tab goes, a no-break space stays.
      assert Request.long(conn("t=%091"), "t", nil) == {:ok, 1}
      assert {:error, {:server_error, _message}} = Request.long(conn("t=%C2%A01"), "t", nil)

      assert Request.long(conn("t=9223372036854775808"), "t", nil) ==
               {:error,
                {:server_error,
                 "Method parameter 't': Failed to convert value of type 'java.lang.String' " <>
                   ~s(to required type 'java.lang.Long'; For input string: "9223372036854775808")}}
    end
  end

  test "path_integer/2 takes Java's int range" do
    assert Request.path_integer("2147483647", "version") == {:ok, 2_147_483_647}

    assert Request.path_integer("2147483648", "version") ==
             {:error,
              {:server_error,
               "Method parameter 'version': Failed to convert value of type 'java.lang.String' " <>
                 ~s(to required type 'java.lang.Integer'; For input string: "2147483648")}}
  end

  describe "strings/2" do
    test "splits a single value at commas, trimming as String.trim, and keeps repeated values" do
      assert Request.strings(conn(), "s") == nil
      assert Request.strings(conn("s="), "s") == []
      assert Request.strings(conn("s=%20a%09,b,,%C2%A0c,"), "s") == ["a", "b", "", "\u00A0c", ""]
      assert Request.strings(conn("s=%20a,b&s="), "s") == [" a,b", ""]
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
