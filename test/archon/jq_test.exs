# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.JqTest do
  # The jq evaluator (ADR 0026, decision 6): results against a jackson-jq oracle, the documented
  # differences, isolation from the server and the limits of the archon_jq process.
  use ExUnit.Case, async: true

  alias Archon.Jq
  alias Archon.Script.{Error, Pool}

  # Workers log each restart.
  @moduletag :capture_log

  # As JsonJqTransform runs it: the whole task input, queryExpression included, is `.`.
  defp run(query, input \\ %{}), do: Jq.evaluate(query, Map.put(input, "queryExpression", query))

  defp start_pool(name, opts) do
    start_supervised!({Jq.Pool, [name: name, workers: 1] ++ opts})
    name
  end

  defp eval(pool, query, input \\ nil),
    do: Pool.request(pool, %{"op" => "eval", "query" => query, "input" => input})

  # Cases where jackson-jq 0.0.13 (the version upstream uses, with Jackson 2.18.8 and joni
  # 2.1.27 from the Gradle cache) running upstream's JsonJqTransform#start and extractBody gave
  # the same resultList: [query, input without queryExpression, results]. Compared with ===, so
  # an integer and a float of the same value differ. Generated with the oracle on 2026-11-03.
  @oracle ~S"""
  [
    [".a", {"a": 1}, [1]],
    [".a", {"a": 1.0}, [1.0]],
    [".a", {"a": 1.5}, [1.5]],
    [".a + 1", {"a": 1.5}, [2.5]],
    [".a * 2", {"a": 1.5}, [3]],
    [".a / 2", {"a": 3}, [1.5]],
    [".a / 2", {"a": 4}, [2]],
    ["1.0", {}, [1.0]],
    ["1.5 * 2", {}, [3]],
    ["1e2", {}, [100.0]],
    [".a", {"a": 9007199254740993}, [9007199254740993]],
    [".a", {"a": 9223372036854775807}, [9223372036854775807]],
    ["10 / 3", {}, [3.3333333333333335]],
    ["[.items[] | select(. > 1)]", {"items": [1, 2, 3]}, [[2, 3]]],
    [".items | map(. * 10)", {"items": [1, 2, 3]}, [[10, 20, 30]]],
    [".items | length", {"items": [1, 2, 3]}, [3]],
    [".s | length", {"s": "héllo"}, [5]],
    ["keys", {"b": 1, "a": 2}, [["a", "b", "queryExpression"]]],
    ["{name: .n, x: [.items[] | tostring]}", {"n": "k", "items": [1, 2.5, "x"]}, [{"name": "k", "x": ["1", "2.5", "x"]}]],
    [".items | add", {"items": [1, 2, 3]}, [6]],
    [".items | add", {"items": []}, [null]],
    [".items | sort", {"items": [3, 1, 2]}, [[1, 2, 3]]],
    [".items | sort_by(.k)", {"items": [{"k": 2}, {"k": 1}]}, [[{"k": 1}, {"k": 2}]]],
    [".items | group_by(.k)", {"items": [{"k": 2}, {"k": 1}, {"k": 2}]}, [[[{"k": 1}], [{"k": 2}, {"k": 2}]]]],
    [".items | unique", {"items": [3, 1, 3]}, [[1, 3]]],
    [".items | min, max", {"items": [3, 1, 3]}, [1, 3]],
    [".s | ascii_downcase", {"s": "ABC"}, ["abc"]],
    [".s | split(\",\")", {"s": "a,b,c"}, [["a", "b", "c"]]],
    [".s | test(\"b\")", {"s": "abc"}, [true]],
    [".s | sub(\"b\"; \"x\")", {"s": "abcb"}, ["axcb"]],
    [".s | gsub(\"b\"; \"x\")", {"s": "abcb"}, ["axcx"]],
    [".s | startswith(\"a\")", {"s": "abc"}, [true]],
    [".s | ltrimstr(\"a\")", {"s": "abc"}, ["bc"]],
    [".s | tonumber", {"s": "42"}, [42]],
    [".s | tonumber", {"s": "4.5"}, [4.5]],
    [".n | tostring", {"n": 4.5}, ["4.5"]],
    [".n | tostring", {"n": 4}, ["4"]],
    [".n | tostring", {"n": 4.0}, ["4.0"]],
    [".s | fromjson", {"s": "{\"a\":1.0}"}, [{"a": 1.0}]],
    ["if .a then \"y\" else \"n\" end", {"a": true}, ["y"]],
    [".a // \"d\"", {}, ["d"]],
    ["has(\"a\")", {"a": 1}, [true]],
    ["del(.a)", {"a": 1, "b": 2}, [{"queryExpression": "del(.a)", "b": 2}]],
    ["to_entries | from_entries", {"a": 1}, [{"queryExpression": "to_entries | from_entries", "a": 1}]],
    ["[.. | numbers]", {"a": {"b": 1}}, [[1]]],
    ["reduce .items[] as $i (0; . + $i)", {"items": [1, 2]}, [3]],
    ["[range(3)]", {}, [[0, 1, 2]]],
    ["[limit(2; .items[])]", {"items": [1, 2, 3]}, [[1, 2]]],
    ["first(.items[])", {"items": [1, 2, 3]}, [1]],
    [".items | first", {"items": [1, 2, 3]}, [1]],
    [".items | index(2)", {"items": [1, 2, 3]}, [1]],
    ["any(.items[]; . > 2)", {"items": [1, 2, 3]}, [true]],
    [".items | join(\"-\")", {"items": ["a", "b"]}, ["a-b"]],
    [".items | flatten", {"items": [[1, [2]], 3]}, [[1, 2, 3]]],
    ["type", {}, ["object"]],
    [".x | type", {"x": 1.0}, ["number"]],
    ["empty", {}, []],
    [".a, .b", {"a": 1, "b": 2}, [1, 2]],
    [".s | @base64", {"s": "hi"}, ["aGk="]],
    [".s | @uri", {"s": "a b"}, ["a%20b"]],
    ["[.items[] | @text]", {"items": [1, "a"]}, [["1", "a"]]],
    ["\"\\(.a) x\"", {"a": 1.5}, ["1.5 x"]],
    ["infinite", {}, ["Infinity"]],
    ["nan | isnan", {}, [true]],
    [".s | [splits(\",\")]", {"s": "a,b"}, [["a", "b"]]],
    [".a | sqrt", {"a": 2}, [1.4142135623730951]],
    ["-(.a)", {"a": 1}, [-1]],
    [".a % 3", {"a": 10}, [1]],
    ["to_entries | map(select(.key != \"queryExpression\")) | from_entries", {"a": 1}, [{"a": 1}]],
    [".a[1:]", {"a": [1, 2, 3]}, [[2, 3]]],
    [".a[-1]", {"a": [1, 2, 3]}, [3]],
    ["[.a[] | select(type == \"number\")]", {"a": [1, "x", 2.0]}, [[1, 2.0]]],
    ["[.a | recurse | numbers]", {"a": [1, [2]]}, [[1, 2]]],
    ["contains({a: 1})", {"a": 1}, [true]],
    ["inside({a: 1, b: 2})", {"a": 1}, [false]],
    [".a | indices(1)", {"a": [1, 2, 1]}, [[0, 2]]],
    [".a | @csv", {"a": [1, "x", 2.5]}, ["1,\"x\",2.5"]],
    [".a | @tsv", {"a": [1, "x"]}, ["1\tx"]],
    [".a | @html", {"a": "<a>"}, ["&lt;a&gt;"]],
    [".a | @sh", {"a": "x y"}, ["'x y'"]],
    [".a | ascii_downcase | explode", {"a": "A"}, [[97]]],
    [".a | implode", {"a": [65]}, ["A"]],
    ["limit(0; 1)", {}, []],
    ["try error(\"x\") catch .", {}, ["x"]],
    [".a?", {}, [null]],
    ["def f(x): x * 2; f(.a)", {"a": 3}, [6]],
    [".a += 1", {"a": 1}, [{"queryExpression": ".a += 1", "a": 2}]],
    [".a |= . * 2", {"a": 1.5}, [{"queryExpression": ".a |= . * 2", "a": 3}]],
    ["tojson | fromjson", {"a": 1.0}, [{"queryExpression": "tojson | fromjson", "a": 1.0}]],
    ["[.a, .b] | transpose", {"a": [1, 2], "b": [3, 4]}, [[[1, 3], [2, 4]]]],
    [".a | test(\"A\"; \"i\")", {"a": "a"}, [true]],
    [".a | match(\"b+\") | .string", {"a": "abbc"}, ["bb"]],
    [".a | capture(\"(?<x>b+)\")", {"a": "abbc"}, [{"x": "bb"}]],
    [".a | scan(\"b\")", {"a": "abbc"}, ["b", "b"]],
    [".x | max_by(.a)", {"x": [{"a": 1}, {"a": 3}]}, [{"a": 3}]],
    [".", {"a": [1, {"b": null}]}, [{"queryExpression": ".", "a": [1, {"b": null}]}]],
    ["[.a[] | tojson]", {"a": [1, 1.0, 1.5, 100000000000000000000]}, [["1", "1.0", "1.5", "100000000000000000000"]]],
    [".a", {"a": 1e+300}, [1e+300]],
    [".a * 10", {"a": 1e+308}, ["Infinity"]],
    ["@text \"v=\\(.a)\"", {"a": 2}, ["v=2"]],
    ["1 as $x | $x + 1", {}, [2]],
    [". as {a: $a} | $a", {"a": 1}, [1]],
    ["[.[] | numbers] | add / length", {"a": 1, "b": 2}, [1.5]],
    [".a | utf8bytelength", {"a": "é"}, [2]]
  ]
  """

  test "results match the jackson-jq oracle" do
    for [query, input, expected] <- JSON.decode!(@oracle) do
      assert {:ok, results} = run(query, input)
      assert results === expected, "#{query} on #{inspect(input)}: #{inspect(results)}"
    end
  end

  describe "differences from jackson-jq (ADR 0026, decision 6)" do
    test "an integral result of a math function is an integer (jackson-jq: a double)" do
      # jackson-jq: [1.0, -2.0] and 2.0; its arithmetic gives integers as jq does (5, not 5.0).
      assert {:ok, [[1, -2]]} = run("[.a[] | floor]", %{"a" => [1.5, -1.5]})
      assert {:ok, [2]} = run(".a | sqrt", %{"a" => 4})
      assert {:ok, [5]} = run(".a * 2", %{"a" => 2.5})
    end

    test "arithmetic is on doubles, past 2^53 too (jackson-jq: longs)" do
      # jackson-jq: 9007199254740993. A number jq passes through unchanged keeps its digits.
      assert {:ok, [9_007_199_254_740_992]} = run(".a + 0", %{"a" => 9_007_199_254_740_993})
      assert {:ok, [9_007_199_254_740_993]} = run(".a", %{"a" => 9_007_199_254_740_993})
    end

    test "jq 1.8 has functions jackson-jq 0.0.13 does not (round, todate, getpath, label, ...)" do
      assert {:ok, [3]} = run(".a | round", %{"a" => 2.5})
      assert {:ok, ["1970-01-01T00:00:00Z"]} = run("0 | todate")
      assert {:ok, [1]} = run(~S|getpath(["a", "b"])|, %{"a" => %{"b" => 1}})
      assert {:ok, [1]} = run("label $f | 1, break $f, 2")
      assert {:ok, [1]} = run(".a % 3", %{"a" => 10.5})
    end

    test "error messages are jq's" do
      assert {:error, %Error{kind: :runtime} = error} = run("\"a\" + 1")
      assert Jq.message(error) == "string (\"a\") and number (1) cannot be added"

      assert {:error, %Error{kind: :runtime} = error} = run("error({\"a\": 1})")
      assert Jq.message(error) == "{\"a\":1} (not a string)"

      assert {:error, %Error{kind: :syntax} = error} = run("nosuchfn")

      assert Jq.message(error) ==
               "nosuchfn/0 is not defined at <top-level>, line 1, column 1:\n" <>
                 "    nosuchfn\n    ^^^^^^^^"
    end

    test "NaN and the infinities are the strings upstream stores" do
      assert {:ok, ["NaN", "Infinity", "-Infinity"]} = run("nan, infinite, -infinite")
    end
  end

  describe "values" do
    test "a number written in the input or the query keeps its kind" do
      input = %{
        "i" => 1,
        "f" => 1.0,
        "e" => 150.0,
        "z" => -0.0,
        "big" => 9_223_372_036_854_775_807
      }

      assert {:ok, [[1, 1.0, 150.0, -0.0, 9_223_372_036_854_775_807]]} =
               run("[.i, .f, .e, .z, .big]", input)

      assert {:ok, [1.0, 1, 100.0, 0]} = run("1.0, 1, 1e2, -0")
    end

    test "a computed number is an integer when integral and within the long range" do
      assert {:ok, [3, 0.30000000000000004, 9_223_372_036_854_775_808.0, -4]} =
               run("1.5 * 2, 0.1 + 0.2, 9223372036854775807 + 1, -4.0 + 0")
    end

    test "strings, unicode and escapes survive the round trip" do
      text = "é\n\"\\\u0001 😀"
      assert {:ok, [^text, ["A", "é"]]} = run(~S|.s, ["A", "\u00e9"]|, %{"s" => text})
    end
  end

  describe "isolation" do
    test "the environment is empty but for TZ=UTC" do
      assert {:ok, [%{"TZ" => "UTC"}, %{"TZ" => "UTC"}, nil]} =
               run("$ENV, env, env.PATH", %{})

      assert {:ok, ["1970-01-01T00:00:00Z"]} = run("0 | localtime | todate")
    end

    test "modules cannot be imported or included" do
      for query <- [
            "import \"a\" as a; .",
            "include \"a\"; .",
            "import \"passwd\" as $p {search: \"/etc\"}; .",
            "include \"hosts\" {search: \"/etc\"}; ."
          ] do
        assert {:error, %Error{kind: :request} = error} = run(query)
        assert Jq.message(error) == "JQ query rejected: import and include are not supported"
      end

      # No library search path: modulemeta finds nothing.
      assert {:error, %Error{reason: "module not found: /etc/hosts"}} =
               run("\"/etc/hosts\" | modulemeta")

      assert {:ok, [[]]} = run("get_search_list")
    end

    test "a query with a NUL character is rejected, not cut short" do
      assert {:error, %Error{kind: :request} = error} =
               run(".a\u0000| error(\"blocked\")", %{"a" => "secret"})

      assert Jq.message(error) == "JQ query rejected: the query contains a NUL character"
      assert {:ok, ["a\u0000b"]} = run(".s", %{"s" => "a\u0000b"})
    end

    test "there is no input beyond the request's" do
      assert {:ok, [[]]} = run("[inputs]")
      assert {:error, %Error{kind: :runtime}} = run("input")
      assert {:ok, [nil]} = run("input_filename")
    end

    test "debug and stderr pass their input on; halt and halt_error are errors" do
      assert {:ok, [1]} = run(".a | debug | stderr | debug(\"x\")", %{"a" => 1})

      for query <- ["halt", "\"bye\" | halt_error", "{} | halt_error(1)"] do
        assert {:error, %Error{kind: :runtime, reason: "halt and halt_error are not supported"}} =
                 run(query)
      end
    end
  end

  describe "limits" do
    test "a query past the time limit is stopped and the next one runs" do
      pool = start_pool(:jq_time_pool, timeout: 300)

      for query <- ["last(range(0; 1e12))", "def f: f; f"] do
        assert {:error, %Error{kind: :timeout} = error} = eval(pool, query)
        assert Jq.message(error) == "JQ query not evaluated within 0.3 seconds, interrupted."
      end

      assert {:ok, [2]} = eval(pool, "1 + 1")
    end

    test "memory is capped, oniguruma's allocations included, and the next query runs" do
      pool = start_pool(:jq_memory_pool, memory_limit: 16 * 1024 * 1024)

      assert {:error, %Error{kind: :limit} = error} = eval(pool, "[range(0; 100000000)]")
      assert Jq.message(error) == "JQ query memory limit exceeded"
      assert {:error, %Error{kind: :limit}} = eval(pool, "\"x\" * 100000000 | length")

      # The 1 MB string fits; the regex match stack of the same string does not.
      assert {:ok, [1_000_000]} = eval(pool, "(\"a\" * 1000000) | length")
      assert {:error, %Error{kind: :limit}} = eval(pool, "(\"a\" * 1000000) | test(\"^(a|b)*$\")")

      assert {:ok, [true]} = eval(pool, "(\"a\" * 1000) | test(\"^(a|b)*$\")")
    end

    test "a request larger than the memory limit is answered without being held" do
      pool = start_pool(:jq_request_pool, memory_limit: 1024 * 1024)
      big = String.duplicate("x", 2 * 1024 * 1024)

      assert {:error, %Error{kind: :limit, reason: "memory limit exceeded"}} =
               eval(pool, ".s | length", %{"s" => big})

      assert {:ok, [3]} = eval(pool, ".s | length", %{"s" => "abc"})
    end

    test "a result larger than the output limit or nested too deeply is rejected" do
      pool = start_pool(:jq_output_pool, max_output: 1000)

      assert {:error, %Error{kind: :limit, reason: "result is too large"} = error} =
               eval(pool, "[range(0; 1000)]")

      assert Jq.message(error) == "JQ query result is too large"
      assert {:ok, [[0, 1]]} = eval(pool, "[range(0; 2)]")

      assert {:error, %Error{kind: :limit, reason: "result is nested too deeply"}} =
               run("reduce range(0; 1001) as $i (0; [.])")

      assert {:ok, [_nested]} = run("reduce range(0; 1000) as $i (0; [.])")
    end

    test "an evaluator that answers and exits is replaced before the next request" do
      pool = start_pool(:jq_exit_pool, memory_limit: 16 * 1024 * 1024)

      for _ <- 1..3 do
        assert {:error, %Error{kind: :limit}} = eval(pool, "[range(0; 100000000)]")
        assert {:ok, [1]} = eval(pool, "1")
      end
    end
  end

  @tag :tmp_dir
  test "archon_jq frees everything and exits 0 at the end of its input", %{tmp_dir: dir} do
    # Under the sanitizer build on Linux (CI), a leak or memory error makes the exit status
    # non-zero; the pool itself never sees how a process exits after its input closes. The
    # limits that end the process are left out: they exit at once by design.
    requests = [
      {"eval", ".items[] | {v: (. * 2)}"},
      {"eval", "[.items[] | tostring, tojson], (.items | add), nan, infinite, 1.0, 1e1000"},
      {"eval", ".items["},
      {"eval", "nosuchfn"},
      {"eval", "error({\"a\": [1]})"},
      {"eval", "\"a\" + 1"},
      {"eval", "import \"a\" as a; ."},
      {"eval", "include \"a\" {search: \"/etc\"}; ."},
      {"eval", "\"x\" | modulemeta"},
      {"eval", "halt"},
      {"eval", "\"bye\" | halt_error"},
      {"eval", "[inputs], (input? // 0), $ENV, $__loc__"},
      {"eval", "reduce range(0; 1001) as $i (0; [.])"},
      {"eval", "[.items[] | test(\"(a|b)*c\")?], (\"a,b\" | [splits(\",\")])"},
      {"eval", "0 | todate, (now | type), (\"2015-03-05T23:51:47Z\" | fromdate)"},
      {"bogus", "."}
    ]

    frames =
      for {op, query} <- requests, into: <<>> do
        payload =
          JSON.encode!(%{"op" => op, "query" => query, "input" => %{"items" => [1, 2.5, "x"]}})

        <<byte_size(payload)::32, payload::binary>>
      end

    input = Path.join(dir, "requests")
    File.write!(input, frames <> <<0, 0, 0, 3, "{\"x">>)

    executable =
      Application.get_env(:archon, Jq.Pool, [])[:executable] ||
        Application.app_dir(:archon, "priv/archon_jq")

    {output, status} =
      System.cmd("sh", ["-c", ~S|"$0" --timeout-ms 2000 < "$1"|, executable, input],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "only the eval op reaches archon_jq" do
    assert {:error, %Error{kind: :request, reason: "unknown op parse"}} =
             Pool.request(Jq.Pool, %{"op" => "parse", "query" => ".", "input" => nil})
  end
end
