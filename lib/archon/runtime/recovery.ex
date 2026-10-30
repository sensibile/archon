# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/org/conductoross/conductor/core/execution/WorkflowSweeper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: instead of sweeping a decider queue, the running workflows are activated
# once when the runtime starts; each process then runs its own recovery check (ADR 0018,
# decision 7).

defmodule Archon.Runtime.Recovery do
  @moduledoc """
  Activates every running workflow of the store (`Store.running_workflow_ids/0`) when the
  runtime starts, and again when `Archon.Runtime.Supervisor` restarts it after the store or the
  queue (ADR 0018, decision 7). Each activated process runs the `:recover` check.

  Activating many workflows lazily (only when their next evaluation is due) is left to the
  Phase 4 store.
  """

  use Task, restart: :transient

  require Logger

  alias Archon.Runtime
  alias Archon.Runtime.WorkflowServer

  @doc false
  def start_link(_arg), do: Task.start_link(__MODULE__, :run, [])

  @doc "Activates the store's running workflows; returns how many were activated."
  @spec run() :: non_neg_integer()
  def run do
    Runtime.store().running_workflow_ids()
    |> Enum.count(fn id ->
      case WorkflowServer.activate(id) do
        {:ok, _pid} ->
          true

        {:error, reason} ->
          Logger.warning("could not activate workflow #{id}: #{inspect(reason)}")
          false
      end
    end)
  end
end
