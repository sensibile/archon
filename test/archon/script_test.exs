# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/events/TestScriptEval.java,
# core/.../execution/evaluators/JavascriptEvaluatorTest.java and GraalJSEvaluatorTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests against the archon_js pool; the remaining
# cases are expectations from a GraalJS 25.0.2 oracle (ADR 0015, decision 7).

defmodule Archon.ScriptTest do
  use ExUnit.Case, async: true

  alias Archon.Decider.Parameters
  alias Archon.Script
  alias Archon.Script.Error

  defp eval!(script, input \\ %{}) do
    assert {:ok, value} = Script.eval(script, input)
    value
  end

  defp error_message(script, input \\ %{}) do
    assert {:error, %Error{} = error} = Script.eval(script, input)
    Exception.message(error)
  end

  defp negative_zero?(value), do: match?(<<1::1, 0::63>>, <<value::float>>)

  describe "upstream TestScriptEval" do
    @payload %{
      "app" => %{"name" => "conductor", "version" => 2.0, "license" => "Apache 2.0"},
      "author" => "Netflix",
      "oss" => true
    }

    defp eval_bool(script, input), do: script |> eval!(input) |> Script.to_boolean()

    test "testScript" do
      assert eval_bool("$.app.name == 'conductor'", @payload)
      refute eval_bool("$.version > 3", @payload)
      assert eval_bool("$.oss", @payload)
      refute eval_bool("$.author == 'me'", @payload)
    end

    test "testES6Support" do
      script = """
      (function(){\s
      const variable = 1; // const support => es6\s
      return $.app.name == 'conductor';})();\
      """

      assert eval_bool(script, @payload)
    end

    test "testArrayAndObjectHandling" do
      payload = %{"numbers" => [1, 2, 3, 4, 5]}
      assert eval_bool("$.numbers.length > 3", payload)
      assert eval!("$.numbers.reduce((a, b) => a + b, 0)", payload) == 15
    end

    test "testNullHandling" do
      assert eval_bool("$.value == null", %{"value" => nil})
    end
  end

  describe "upstream JavascriptEvaluatorTest and GraalJSEvaluatorTest" do
    test "basic, nested and complex expressions" do
      assert eval!("$.value * 2", %{"value" => 42}) == 84

      assert eval!("$.level1.level2.value", %{"level1" => %{"level2" => %{"value" => "deep"}}}) ==
               "deep"

      assert eval!("($.a + $.b) * $.c", %{"a" => 10, "b" => 20, "c" => 30}) == 900

      assert eval!("$.config.timeout * $.config.retries", %{
               "config" => %{"timeout" => 4, "retries" => 3}
             }) == 12

      assert eval!("$.a + $.b", %{"a" => 5, "b" => 10}) == 15
    end

    test "ES6 features" do
      script = """
      (function() {
          const greeting = 'Hello';
          let engine = $.name;
          return `${greeting}, ${engine}!`;
      })()
      """

      assert eval!(script, %{"name" => "Conductor"}) == "Hello, Conductor!"
    end

    test "deep copy protection: the script sees a copy of the input" do
      input = %{"data" => %{"original" => "value"}}

      script = """
      (function() {
          $.data.newKey = 'new value';
          return $.data.newKey;
      })()
      """

      assert eval!(script, input) == "new value"
      assert input == %{"data" => %{"original" => "value"}}
    end

    test "array operations and object results" do
      numbers = %{"numbers" => [1, 2, 3, 4, 5]}
      assert eval!("$.numbers.filter(n => n > 2).map(n => n * 2)", numbers) == [6, 8, 10]
      assert eval!("$.values.reduce((sum, val) => sum + val, 0)", %{"values" => [10, 20]}) == 30

      script = """
      (function() {
          return {
              result: $.value,
              doubled: $.value * 2,
              message: 'success'
          };
      })()
      """

      assert eval!(script, %{"value" => 42}) == %{
               "result" => 42,
               "doubled" => 84,
               "message" => "success"
             }

      conditional = """
      (function() {
          if ($.status === 'COMPLETED') {
              return { success: true, message: 'Task completed' };
          } else {
              return { success: false, message: 'Task pending' };
          }
      })()
      """

      assert eval!(conditional, %{"status" => "COMPLETED"}) == %{
               "success" => true,
               "message" => "Task completed"
             }
    end

    test "null safety" do
      assert eval!("$.value === null ? 'null value' : $.value", %{"value" => nil}) ==
               "null value"
    end
  end

  # Each expected value below is what upstream's getObject returns for the same script on
  # GraalJS 25.0.2 (polyglot + js-language jars from the Gradle cache), with the input
  # {"a": 1, "n": {"x": [1, 2.5]}}.
  describe "result conversion (GraalJS oracle)" do
    @input %{"a" => 1, "n" => %{"x" => [1, 2.5]}}

    test "numbers: long range integers, doubles, -0 and the non-finite doubles" do
      cases = [
        {"1+1", 2},
        {"0.1+0.2", 0.30000000000000004},
        {"1e21", 1.0e21},
        {"1e7", 10_000_000},
        {"2**31", 2_147_483_648},
        {"-(2**31)-1", -2_147_483_649},
        {"2**53", 9_007_199_254_740_992},
        {"9007199254740993", 9_007_199_254_740_992},
        {"2**63-1024", 9_223_372_036_854_774_784},
        {"2**63", 9.223_372_036_854_776e18},
        {"1.5e-7", 1.5e-7},
        {"123456789.125", 123_456_789.125},
        {"Number.MAX_VALUE", 1.797_693_134_862_315_7e308},
        {"Number.MIN_VALUE", 5.0e-324},
        {"$.n.x[1]", 2.5},
        {"1/0", :infinity},
        {"0/0", :nan},
        {"-1/0", :neg_infinity},
        {"new Number(5)", 5},
        {"new Number(1.5)", 1.5},
        {"new Number(NaN)", :nan}
      ]

      for {script, expected} <- cases do
        assert eval!(script, @input) === expected, script
      end

      assert negative_zero?(eval!("-0"))
      assert negative_zero?(eval!("[-0]") |> hd())
    end

    test "BigInt: a long, an exact double, otherwise an empty map" do
      cases = [
        {"10n", 10},
        {"2n**63n-1n", 9_223_372_036_854_775_807},
        {"-(2n**63n)", -9_223_372_036_854_775_808},
        {"2n**63n", 9.223_372_036_854_776e18},
        {"2n**64n", 1.844_674_407_370_955_2e19},
        {"-(2n**64n)", -1.844_674_407_370_955_2e19},
        {"2n**70n", 1.180_591_620_717_411_3e21},
        {"2n**70n+1n", %{}},
        {"-(2n**63n)-1n", %{}},
        {"2n**1024n", %{}},
        {"Object(10n)", %{}}
      ]

      for {script, expected} <- cases do
        assert eval!(script) === expected, script
      end
    end

    test "strings, booleans, null and undefined" do
      cases = [
        {"'abc\\u00e9'", "abcé"},
        {"'\\u0000x'", <<0, ?x>>},
        {"'😀'", "😀"},
        {"new String('ab')", "ab"},
        {"new Boolean(true)", true},
        {"true", true},
        {"null", nil},
        {"undefined", nil},
        {"var x = 1", nil},
        {"function f(){}", nil},
        {"// just a comment", nil},
        {"$.n.x[5]", nil},
        {"typeof $", "object"},
        {"Array.isArray($.n.x)", true},
        {"$.a = 5; $.a", 5}
      ]

      for {script, expected} <- cases do
        assert eval!(script, @input) === expected, script
      end
    end

    test "a lone surrogate becomes U+FFFD" do
      # Archon strings are UTF-8; GraalJS keeps the lone surrogate in a Java String.
      assert eval!("'\\ud800a\\udc00'") == "�a�"
      assert eval!("'\\ud83d\\ude00'") == "😀"
    end

    test "lists: arrays, typed arrays and arguments" do
      cases = [
        {"[1,,3]", [1, nil, 3]},
        {"[1, [2, [3]]]", [1, [2, [3]]]},
        {"[]", []},
        {"Object.assign([1,2], {extra: 3})", [1, 2]},
        {"new Uint8Array([1,2])", [1, 2]},
        {"(function(a){return arguments})(1, 'x')", [1, "x"]},
        {"(function(a){'use strict'; return arguments})(1, 'x')", [1, "x"]}
      ]

      for {script, expected} <- cases do
        assert eval!(script) === expected, script
      end
    end

    test "maps: own enumerable string-keyed members" do
      cases = [
        {"({})", %{}},
        {"({a:1, b:[true,null,undefined]})", %{"a" => 1, "b" => [true, nil, nil]}},
        {"({2: 'b', 1: 'a', z: 1, y: 2})", %{"1" => "a", "2" => "b", "y" => 2, "z" => 1}},
        {"({f: function(){}, n: null, u: undefined})", %{"f" => %{}, "n" => nil, "u" => nil}},
        {"({get g(){ return 7 }})", %{"g" => 7}},
        {"({[Symbol('s')]: 1, k: 2})", %{"k" => 2}},
        {"Object.defineProperty({a:1}, 'h', {value: 2, enumerable: false})", %{"a" => 1}},
        {"Object.create({inh: 1}, {own: {value: 2, enumerable: true}})", %{"own" => 2}},
        {"class P { constructor(){ this.v = 1 } get g(){ return 2 } }; new P()", %{"v" => 1}},
        {"new Proxy({a:1}, {})", %{"a" => 1}},
        {"new Proxy([1,2], {})", %{"0" => 1, "1" => 2}},
        {"new Set([1,2])", %{}},
        {"new WeakMap()", %{}},
        {"Symbol('x')", %{}},
        {"Object(Symbol())", %{}},
        {"(function(){})", %{}},
        {"new Date(0)", %{}},
        {"new Error('x')", %{}},
        {"/ab/g", %{}},
        {"Promise.resolve(1)", %{}},
        {"$.n", %{"x" => [1, 2.5]}}
      ]

      for {script, expected} <- cases do
        assert eval!(script, @input) === expected, script
      end
    end

    test "a Map's keys are converted, then printed as Java strings" do
      assert eval!("new Map([[1,'a'],['k',{z:1}]])") == %{"1" => "a", "k" => %{"z" => 1}}

      assert eval!("new Map([[{a:1}, 'obj'], [null, 'n'], [true, 't'], [1.5, 'f']])") == %{
               "{a=1}" => "obj",
               "null" => "n",
               "true" => "t",
               "1.5" => "f"
             }
    end

    test "promise jobs run before the result is read" do
      cases = [
        {"var r = {selectedCase:'before'}; Promise.resolve().then(() => r.selectedCase = 'after'); r",
         %{"selectedCase" => "after"}},
        {"var r = {v: 0}; (async () => { r.v = 1; await null; r.v = 2 })(); r", %{"v" => 2}},
        {"var r = {n: 0}; Promise.resolve().then(() => { r.n = 1; return Promise.resolve() })" <>
           ".then(() => r.n = 2); r", %{"n" => 2}},
        {"Promise.reject(new Error('unhandled')); 5", 5}
      ]

      for {script, expected} <- cases do
        assert eval!(script) === expected, script
      end
    end

    test "the result is read as GraalJS reads it, even when reading changes it" do
      cases = [
        {"var a = new Uint8Array([1,2]); Object.defineProperty(a, 'length', {value: 0}); a",
         [1, 2]},
        {"var a = (function(){ return arguments })(1,2); a.length = 4; a", [1, 2, nil, nil]},
        {"var a = [1, 2]; Object.defineProperty(a, '0', {get(){ a.length = 1; return 7 }}); a",
         [7]},
        {"var m = new Map([['a', {get x(){ m.set('b', 9); return 1 }}], ['b', 2]]); m",
         %{"a" => %{"x" => 1}, "b" => 9}},
        {"var m = new Map(); var k = {get x(){ m.set(k, 9); return 1 }}; m.set(k, 2); m",
         %{"{x=1}" => 9}},
        {"var r = {a: 1}; new Proxy(r, {ownKeys(t){ " <>
           "Promise.resolve().then(() => t.a = 9); return ['a'] }})", %{"a" => 9}},
        {"var r = {get selectedCase(){ var a = {v: 1}; " <>
           "Promise.resolve().then(() => a.v = 9); return a }}; r",
         %{"selectedCase" => %{"v" => 9}}},
        {"Object.defineProperty(Array.prototype, '0', {set(v){}, get(){ return 'hijacked' }, " <>
           "configurable: true}); new Map([['key', 'value']])", %{"key" => "value"}}
      ]

      for {script, expected} <- cases do
        assert eval!(script) === expected, script
      end
    end

    test "objects shaped like protocol tags stay maps and lists" do
      assert eval!("({selectedCase: ['nonfinite', 'NaN']})") == %{
               "selectedCase" => ["nonfinite", "NaN"]
             }

      assert eval!(~S|({"$archon_number": "Infinity"})|) == %{"$archon_number" => "Infinity"}
      assert eval!("[['int', '5'], ['map', []]]") == [["int", "5"], ["map", []]]
    end

    test "Java strings, toBoolean and stored form of results" do
      # String.valueOf, toBoolean and Jackson 2.18.8 writeValueAsString of the oracle results.
      cases = [
        {"1e21", "1.0E21", true, 1.0e21},
        {"2**63", "9.223372036854776E18", true, 9.223_372_036_854_776e18},
        {"1e-3/10", "1.0E-4", true, 1.0e-4},
        {"Number.MIN_VALUE", "4.9E-324", true, 5.0e-324},
        {"-0", "-0.0", false, -0.0},
        {"1/0", "Infinity", true, "Infinity"},
        {"0/0", "NaN", false, "NaN"},
        {"-1/0", "-Infinity", false, "-Infinity"},
        {"10n", "10", true, 10},
        {"'abc'", "abc", false, "abc"},
        {"[1, null, 'x']", "[1, null, x]", false, [1, nil, "x"]},
        {"({x: 0/0, y: [1/0, -0], z: {w: -1/0}})", "{x=NaN, y=[Infinity, -0.0], z={w=-Infinity}}",
         false, %{"x" => "NaN", "y" => ["Infinity", -0.0], "z" => %{"w" => "-Infinity"}}}
      ]

      for {script, java, bool, stored} <- cases do
        value = eval!(script)
        assert Parameters.java_string(value) == java, script
        assert Script.to_boolean(value) == bool, script
        assert Script.storable(value) == stored, script
      end
    end
  end

  describe "errors" do
    test "a thrown error is wrapped as upstream, with the line of the innermost frame" do
      # Same text as the GraalJS oracle.
      assert error_message("x.y") ==
               "Error evaluating the script `ReferenceError: x is not defined` at line 1"

      assert error_message("(function(){ return undefinedVar })()") ==
               "Error evaluating the script `ReferenceError: undefinedVar is not defined` at line 1"

      assert error_message("\n\nx") ==
               "Error evaluating the script `ReferenceError: x is not defined` at line 3"

      # The engine message differs from GraalJS ("Cannot read property ..."); the line does not.
      assert error_message("var a = 1;\nfunction f() {\n  return a.b.c;\n}\nf()") ==
               "Error evaluating the script `TypeError: cannot read property 'c' of undefined` " <>
                 "at line 3"
    end

    test "a thrown value that is not an Error has no line" do
      # GraalJS reports the line of the throw statement; QuickJS-ng does not know it (ADR 0015).
      assert error_message("throw 'abc'") == "Error evaluating the script `abc`"
      assert error_message("throw null") == "Error evaluating the script `null`"
    end

    test "a syntax error is a script error" do
      assert {:error, %Error{kind: :runtime, line: 1, reason: "SyntaxError: " <> _}} =
               Script.eval("foo(", %{})
    end

    test "an exception while reading the result is reported unwrapped" do
      # GraalJS lets the getter's PolyglotException through as "Error: in getter".
      assert error_message("({get g(){ throw new Error('in getter') }})") == "Error: in getter"
    end

    test "a cyclic result is rejected instead of overflowing the stack" do
      # GraalJS getObject recurses until StackOverflowError (ADR 0015).
      assert error_message("var a = {}; a.self = a; a") == "Script result is nested too deeply"
    end

    test "messages" do
      timeout = %Error{kind: :timeout, reason: "interrupted"}
      assert Exception.message(timeout) == "Script not evaluated within 4 seconds, interrupted."

      assert Exception.message(%{timeout | timeout: 250}) ==
               "Script not evaluated within 0.25 seconds, interrupted."

      assert Exception.message(%Error{kind: :crashed, reason: "exited with status 9"}) ==
               "Script evaluator exited with status 9"
    end
  end

  describe "validate_syntax/2 (upstream validateScriptSyntax)" do
    test "parses without running" do
      # WorkflowTaskTypeConstraintTest#testSwitchJavascriptExpressionWithRuntimeBoundVariableIsAccepted
      assert Script.validate_syntax("$.items.filter(i => i > 10).length > 0 ? 'big' : 'small'") ==
               :ok

      assert Script.validate_syntax("while (true) {}") == :ok
      assert Script.validate_syntax("throw new Error('never runs')") == :ok
      assert Script.validate_syntax("1;\n2;\n3") == :ok
    end

    test "returns the engine message of a syntax error" do
      # WorkflowTaskTypeConstraintTest#testSwitchJavascriptExpressionWithSyntaxErrorIsRejected
      assert {:error, "SyntaxError: " <> _} =
               Script.validate_syntax("$.inputValue > 10 ? 'big' :")

      assert {:error, "SyntaxError: unexpected token in expression: ''"} =
               Script.validate_syntax("foo(")

      assert {:error, "SyntaxError: " <> _} = Script.validate_syntax("import x from 'qjs:std'")
    end

    test "a parse stopped by the stack limit is not a syntax error" do
      deep = String.duplicate("(", 10_000) <> "1" <> String.duplicate(")", 10_000)
      assert Script.validate_syntax(deep) == :ok
    end

    test "anything but a syntax error counts as valid" do
      for kind <- [:timeout, :crashed, :limit, :runtime] do
        evaluate = fn :parse, _script, nil -> {:error, %Error{kind: kind, reason: "r"}} end
        assert Script.validate_syntax("x", evaluate) == :ok
      end
    end
  end
end
