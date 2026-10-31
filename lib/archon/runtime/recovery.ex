# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/org/conductoross/conductor/core/execution/WorkflowSweeper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: instead of sweeping a decider queue, the workflows whose re-evaluation
# time is due and those with outbox entries are activated, each process running its own recovery
# check (ADR 0018, decision 7; ADR 0021, decision 6).

defmodule Archon.Runtime.Recovery do
  @moduledoc """
  Activates workflows when the runtime starts, and again when `Archon.Runtime.Supervisor`
  restarts it after the store or the queue (ADR 0018, decision 7; ADR 0021, decision 6). Each
  activated process runs the `:recover` check. `Archon.Runtime.Waker` runs the same `:due`
  activation periodically.

  `run/1` activates, one keyset page (`activation_page_size`, 100) at a time:

    * with `:due`, the `RUNNING` workflows whose stored re-evaluation time is at most
      `now + activation_margin` (5 s) or not set (`Store.due_workflow_ids/3`). A `PAUSED`
      workflow is activated by the request that resumes it.
    * with `:all`, every running or paused workflow (`Store.running_workflow_ids/0`). This is
      the start of the memory backend: its queue can restart without its store and lose the
      messages, which only an activated process puts back, and after a VM restart it has nothing
      to activate anyway.
    * in both, the workflows that have outbox entries (`Store.outbox_workflow_ids/2`), terminal
      ones included.

  Workflows that already have a process are left alone.
  """

  use Task, restart: :transient

  require Logger

  alias Archon.Runtime
  alias Archon.Runtime.WorkflowServer

  @doc false
  def start_link(_arg), do: Task.start_link(__MODULE__, :run, [])

  @doc """
  Activates the workflows of `selection` (`:all` with the memory store, else `:due`) and those
  with outbox entries; returns how many processes it started.
  """
  @spec run(:all | :due) :: non_neg_integer()
  def run(selection \\ default_selection()) do
    started =
      case selection do
        :all -> activate(Runtime.store().running_workflow_ids())
        :due -> due(Runtime.now() + Runtime.setting(:activation_margin, 5_000), nil, 0)
      end

    started + outbox(nil, 0)
  end

  defp default_selection,
    do: if(Runtime.store() == Archon.Runtime.Store.Memory, do: :all, else: :due)

  defp due(before_ms, cursor, started) do
    page = Runtime.store().due_workflow_ids(before_ms, cursor, page_size())
    started = started + activate(Enum.map(page, fn {_wake_key, id} -> id end))

    if last_page?(page),
      do: started,
      else: due(before_ms, List.last(page), started)
  end

  defp outbox(cursor, started) do
    page = Runtime.store().outbox_workflow_ids(cursor, page_size())
    started = started + activate(page)

    if last_page?(page),
      do: started,
      else: outbox(List.last(page), started)
  end

  defp activate(ids) do
    Enum.count(ids, fn id ->
      WorkflowServer.whereis(id) == nil and
        case WorkflowServer.activate(id) do
          {:ok, _pid} ->
            true

          {:error, reason} ->
            Logger.warning("could not activate workflow #{id}: #{inspect(reason)}")
            false
        end
    end)
  end

  defp last_page?(page), do: page == [] or length(page) < page_size()

  defp page_size, do: Runtime.setting(:activation_page_size, 100)
end
