# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.RuntimeHooks do
  @moduledoc """
  The runtime's clock, IDs, timer and failure points for tests (ADR 0018, decision 10), wired by
  `config/test.exs`. Without anything installed each one behaves as the default: the system
  clock, random UUIDs, `Process.send_after/3` and no failure.

  Installed values are global, so tests that install them are not `async`.

    * `install(clock: ms)` - a clock that only moves with `advance/1`.
    * `install(timer: pid)` - timers are not set; `pid` receives
      `{:timer_set, workflow_pid, message, delay_ms}` instead, and the test sends `message` itself.
    * `install(hook: fun)` - `fun.(point, workflow_id, data)` at the failure points of
      `Archon.Runtime.WorkflowServer`.
  """

  alias Archon.Decider.Context

  @keys [:clock, :timer, :hook]

  @doc "Installs hooks; `reset/0` removes them."
  @spec install(keyword()) :: :ok
  def install(opts) do
    for {key, value} <- opts do
      true = key in @keys

      value =
        if key == :clock do
          clock = :counters.new(1, [:atomics])
          :counters.put(clock, 1, value)
          clock
        else
          value
        end

      :persistent_term.put({__MODULE__, key}, value)
    end

    :ok
  end

  @doc "Removes every installed hook."
  @spec reset() :: :ok
  def reset do
    for key <- @keys, do: :persistent_term.erase({__MODULE__, key})
    :ok
  end

  @doc "Moves the installed clock forward."
  @spec advance(non_neg_integer()) :: integer()
  def advance(ms) do
    clock = :persistent_term.get({__MODULE__, :clock})
    :counters.add(clock, 1, ms)
    :counters.get(clock, 1)
  end

  @doc false
  def now do
    case :persistent_term.get({__MODULE__, :clock}, nil) do
      nil -> System.system_time(:millisecond)
      clock -> :counters.get(clock, 1)
    end
  end

  @doc false
  def new_id, do: Context.uuid4()

  @doc false
  def send_after(pid, message, delay) do
    case :persistent_term.get({__MODULE__, :timer}, nil) do
      nil ->
        Process.send_after(pid, message, delay)

      recorder ->
        send(recorder, {:timer_set, pid, message, delay})
        make_ref()
    end
  end

  @doc false
  def hook(point, workflow_id, data) do
    case :persistent_term.get({__MODULE__, :hook}, nil) do
      nil -> :ok
      fun -> fun.(point, workflow_id, data)
    end
  end
end
