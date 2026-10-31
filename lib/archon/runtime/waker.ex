# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Waker do
  @moduledoc """
  Activates, every `waker_interval` (1 s), the workflows without a process whose stored
  re-evaluation time is within `activation_margin` (5 s) and those with outbox entries
  (`Archon.Runtime.Recovery.run(:due)`, ADR 0021, decision 6). It brings back the processes
  that ended idle (`evict_after`) before their timer is due, and the work a process left when it
  ended. The margin is longer than the interval, so a timer is not late.

  The keyset pages are read to the end on every round, so a running process whose stored time
  is stale does not starve the workflows after it. A round that fails (the store is down) is
  logged and the next round tries again.
  """

  use GenServer

  require Logger

  alias Archon.Runtime
  alias Archon.Runtime.Recovery

  @doc false
  def start_link(_arg), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "One round: activates the due workflows; returns how many had no process (`Recovery.run/1`)."
  @spec run() :: non_neg_integer()
  def run, do: Recovery.run(:due)

  @impl GenServer
  def init(nil), do: {:ok, schedule()}

  @impl GenServer
  def handle_info({:tick, ref}, ref) do
    try do
      run()
    rescue
      exception ->
        Logger.error("the waker failed: " <> Exception.format(:error, exception, __STACKTRACE__))
    catch
      kind, reason -> Logger.error("the waker failed: #{inspect({kind, reason})}")
    end

    {:noreply, schedule()}
  end

  def handle_info(_stale, ref), do: {:noreply, ref}

  defp schedule do
    ref = make_ref()
    Process.send_after(self(), {:tick, ref}, Runtime.setting(:waker_interval, 1_000))
    ref
  end
end
