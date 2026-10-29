# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Script.PoolTest do
  # Isolation and recovery of the archon_js pool (ADR 0015, decisions 1, 2 and 7).
  use ExUnit.Case, async: true

  alias Archon.Script.{Error, Pool}

  # Workers log each restart.
  @moduletag :capture_log

  defp start_pool(name, opts) do
    start_supervised!({Pool, [name: name, workers: 1] ++ opts}, id: name)
    name
  end

  defp worker(pool) do
    [{_id, pid, :worker, _}] = Supervisor.which_children(Module.concat(pool, Workers))
    pid
  end

  # nil while the port is closed and not yet replaced.
  defp os_pid(pool) do
    case Port.info(:sys.get_state(worker(pool)).port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> wait_and_retry(fun, tries)
    end
  end

  defp wait_and_retry(fun, tries) do
    Process.sleep(10)
    wait_until(fun, tries - 1)
  end

  defp eval(pool, script, input \\ %{}), do: Pool.run(pool, :eval, script, input)

  describe "no host access" do
    test "no module loader, std, os or other host functions" do
      assert {:ok, "undefined undefined undefined undefined undefined undefined undefined"} =
               Archon.Script.eval(
                 "[typeof std, typeof os, typeof console, typeof print, typeof setTimeout, " <>
                   "typeof require, typeof performance].join(' ')",
                 %{}
               )

      # import() returns a promise that rejects: there is no module loader.
      assert {:ok, %{}} = Archon.Script.eval("import('qjs:std')", %{})

      assert {:ok, %{"err" => "ReferenceError: could not load module 'qjs:os'"}} =
               Archon.Script.eval(
                 "var r = {}; import('qjs:os').then(m => r.ok = 1, e => r.err = String(e)); r",
                 %{}
               )

      assert {:error, %Error{kind: :runtime, reason: "SyntaxError: " <> _}} =
               Archon.Script.eval("import * as std from 'qjs:std'", %{})
    end

    test "each evaluation starts from fresh globals and built-ins" do
      pool = start_pool(:fresh_pool, [])

      assert {:ok, 1} =
               eval(pool, """
               globalThis.leak = 1;
               Object.prototype.polluted = 1;
               Array.prototype.push = null;
               JSON.stringify = () => 'hacked';
               1
               """)

      assert {:ok, "undefined undefined function {\"a\":1}"} =
               eval(
                 pool,
                 "[typeof leak, typeof ({}).polluted, typeof [].push, JSON.stringify({a: 1})]" <>
                   ".join(' ')"
               )
    end

    test "a script replacing built-ins cannot change how its result is read" do
      assert {:ok, %{"1" => "a"}} =
               Archon.Script.eval(
                 "Map.prototype.entries = function* () { yield ['x', 'y'] }; " <>
                   "Number.prototype.valueOf = () => 99; new Map([[1, 'a']])",
                 %{}
               )

      assert {:ok, 5} =
               Archon.Script.eval("Number.prototype.valueOf = () => 99; new Number(5)", %{})
    end
  end

  describe "limits" do
    test "the engine interrupts an endless loop at the time limit without a restart" do
      pool = start_pool(:loop_pool, timeout: 200, grace: 5_000)
      before = os_pid(pool)

      {micros, result} = :timer.tc(fn -> eval(pool, "while (true) {}") end)

      assert {:error, %Error{kind: :timeout} = error} = result
      assert Exception.message(error) == "Script not evaluated within 0.2 seconds, interrupted."
      assert micros < 2_000_000
      assert os_pid(pool) == before
      assert {:ok, 2} = eval(pool, "1 + 1")
    end

    test "a try/catch cannot swallow the interrupt" do
      pool = start_pool(:catch_pool, timeout: 200)

      assert {:error, %Error{kind: :timeout}} =
               eval(pool, "for (;;) { try { while (true) {} } catch (e) {} }")
    end

    test "memory is capped and the next evaluation is unaffected" do
      pool = start_pool(:memory_pool, memory_limit: 16 * 1024 * 1024)

      assert {:error, %Error{kind: :runtime, reason: reason}} =
               eval(pool, "let a = []; while (true) a.push(new Array(100000).fill(1))")

      assert reason =~ "out of memory"
      assert {:ok, 3} = eval(pool, "[1, 2, 3].length")
    end

    test "promise jobs run under the same time limit" do
      pool = start_pool(:job_pool, timeout: 200)

      assert {:error, %Error{kind: :timeout}} =
               eval(pool, "Promise.resolve().then(() => { while (true) {} }); 1")
    end

    test "deep recursion stops at the stack limit" do
      assert {:error, %Error{kind: :runtime, reason: "RangeError: " <> _}} =
               Archon.Script.eval("function f() { return f() + 1 } f()", %{})
    end

    test "a result larger than the output limit is rejected" do
      pool = start_pool(:output_pool, max_output: 1024)

      assert {:error, %Error{kind: :limit} = error} = eval(pool, "'x'.repeat(2000)")
      assert Exception.message(error) == "Script result is too large"
      assert {:ok, "ok"} = eval(pool, "'ok'")
    end
  end

  describe "recovery" do
    test "a process killed while idle is replaced" do
      pool = start_pool(:kill_idle_pool, [])
      killed = os_pid(pool)
      System.cmd("kill", ["-KILL", "#{killed}"])
      # A request racing the exit notice would get the crash error; wait for the restart.
      wait_until(fn -> os_pid(pool) not in [killed, nil] end)

      assert {:ok, 2} = eval(pool, "1 + 1")
    end

    test "a process killed while evaluating answers with an error and is replaced" do
      pool = start_pool(:kill_busy_pool, timeout: 10_000)
      killed = os_pid(pool)
      task = Task.async(fn -> eval(pool, "while (true) {}") end)
      Process.sleep(100)
      System.cmd("kill", ["-KILL", "#{killed}"])

      assert {:error, %Error{kind: :crashed} = error} = Task.await(task)
      assert Exception.message(error) == "Script evaluator exited with status 137"
      assert {:ok, 2} = eval(pool, "1 + 1")
    end

    test "a worker that stops while busy is answered for and restarted" do
      pool = start_pool(:worker_down_pool, timeout: 10_000)
      busy = worker(pool)
      task = Task.async(fn -> eval(pool, "while (true) {}") end)
      Process.sleep(100)
      Process.exit(busy, :kill)

      assert {:error, %Error{kind: :crashed}} = Task.await(task)
      assert {:ok, 2} = eval(pool, "1 + 1")
      refute worker(pool) == busy
    end

    @tag :tmp_dir
    test "a process that never answers is killed after the grace period", %{tmp_dir: dir} do
      silent = Path.join(dir, "silent")
      File.write!(silent, "#!/bin/sh\nexec sleep 600\n")
      File.chmod!(silent, 0o755)
      pool = start_pool(:silent_pool, executable: silent, timeout: 100, grace: 100)
      first = os_pid(pool)

      assert {:error, %Error{kind: :timeout} = error} = eval(pool, "1")
      assert Exception.message(error) == "Script not evaluated within 0.1 seconds, interrupted."
      refute alive?(first)
      refute os_pid(pool) == first
      assert {:error, %Error{kind: :timeout}} = eval(pool, "1")
    end

    @tag :tmp_dir
    test "a process that exits at once answers each request with an error", %{tmp_dir: dir} do
      failing = Path.join(dir, "failing")
      File.write!(failing, "#!/bin/sh\nhead -c 1 > /dev/null\nexit 3\n")
      File.chmod!(failing, 0o755)
      pool = start_pool(:failing_pool, executable: failing)

      for _ <- 1..3 do
        assert {:error, %Error{kind: :crashed, reason: "exited with status 3"}} = eval(pool, "1")
      end
    end
  end

  describe "queue" do
    test "a full queue rejects new requests at once" do
      pool = start_pool(:full_pool, timeout: 2_000, max_queue: 1)
      busy = Task.async(fn -> eval(pool, "while (true) {}") end)
      Process.sleep(50)
      waiting = Task.async(fn -> eval(pool, "1") end)
      Process.sleep(50)

      assert {:error, %Error{kind: :limit} = error} = eval(pool, "2")
      assert Exception.message(error) == "Script evaluation queue is full"
      assert {:error, %Error{kind: :timeout}} = Task.await(busy, 5_000)
      assert {:ok, 1} = Task.await(waiting)
    end

    test "a waiting request whose caller exited is dropped" do
      pool = start_pool(:abandoned_pool, timeout: 300)
      busy = Task.async(fn -> eval(pool, "while (true) {}") end)
      Process.sleep(50)

      for _ <- 1..3 do
        pid = spawn(fn -> eval(pool, "while (true) {}") end)
        Process.sleep(10)
        Process.exit(pid, :kill)
      end

      assert {:error, %Error{kind: :timeout}} = Task.await(busy)
      {micros, result} = :timer.tc(fn -> eval(pool, "1") end)
      assert result == {:ok, 1}
      assert micros < 250_000
    end
  end

  @tag :tmp_dir
  test "archon_js frees everything and exits 0 at the end of its input", %{tmp_dir: dir} do
    # Under the sanitizer build on Linux (CI), a leak or memory error makes the exit status
    # non-zero; the pool itself never sees how a process exits after its input closes.
    requests = [
      {"eval", "({a: [1, 2.5, 'x', null], m: new Map([[1, {b: 1/0}]]), n: new Number(3)})"},
      {"eval", "x.y"},
      {"eval", "throw {toString() { throw 1 }}"},
      {"eval", "({get g() { throw new Error('getter') }})"},
      {"eval", "var a = {}; a.self = a; a"},
      {"eval", "while (true) {}"},
      {"eval", "let s = 'x'; while (true) s += s"},
      {"eval", "'\\ud800'.repeat(3)"},
      {"eval", "10n ** 30n"},
      {"parse", "1 +"},
      {"parse", "$.a"},
      {"bogus", "1"}
    ]

    frames =
      for {op, script} <- requests, into: <<>> do
        payload = JSON.encode!(%{"op" => op, "script" => script, "input" => %{"a" => 1}})
        <<byte_size(payload)::32, payload::binary>>
      end

    input = Path.join(dir, "requests")
    File.write!(input, frames <> <<0, 0, 0, 3, "{\"x">>)

    executable =
      Application.get_env(:archon, Pool, [])[:executable] ||
        Application.app_dir(:archon, "priv/archon_js")

    {output, status} =
      System.cmd("sh", ["-c", ~S|"$0" --timeout-ms 200 < "$1"|, executable, input],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  test "requests beyond the number of workers wait their turn" do
    pool = start_pool(:queue_pool, workers: 2)

    results =
      1..20
      |> Task.async_stream(fn i -> eval(pool, "$.i * 2", %{"i" => i}) end, timeout: 10_000)
      |> Enum.map(fn {:ok, result} -> result end)

    assert results == Enum.map(1..20, &{:ok, &1 * 2})
  end
end
