# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Supervisor do
  @moduledoc """
  The runtime's process tree (ADR 0018, decision 1), `rest_for_one`:

      Archon.Runtime.Supervisor
      ├── Archon.Repo                        (Postgres backend)
      ├── Archon.Runtime.Postgres.NodeLock   (Postgres backend: one node, write epoch)
      ├── metadata, store and queue          (memory backend, the default)
      ├── Archon.Runtime.Registry            (workflow ID → process, {:outbox, ID} → runner)
      ├── Archon.Runtime.TaskSupervisor      (outbox runners, ADR 0021)
      ├── Archon.Runtime.WorkflowSupervisor  (a DynamicSupervisor of Archon.Runtime.WorkflowServer)
      ├── Archon.Runtime.Recovery            (activates the workflows to run, once)
      └── Archon.Runtime.Waker               (activates the due workflows periodically)

  The backend is the one of `config :archon, Archon.Runtime` `:store` and `:queue` (ADR 0021,
  decision 8). The Postgres store, queue and metadata are modules without processes; the
  repository and the node lock come first instead, so when either restarts the whole runtime
  restarts after it and the lock is taken again before anything writes (decision 7).

  When the store or the queue restarts, the registry and every workflow process restart after
  it and `Archon.Runtime.Recovery` activates the workflows to run again (ADR 0021, decision 6). When the task
  supervisor restarts, the workflow processes restart after it and run the outbox entries left
  when they are activated again (ADR 0021, decision 8).

  The store writes a commit's queue operations with it (ADR 0021, decision 3), so the store and
  the queue must be the same backend: a configuration that mixes them, or names one this module
  does not know, is refused with `{:error, {:mixed_backends, store, queue}}` before anything
  starts.
  """

  use Supervisor

  alias Archon.Runtime

  @backends %{
    Archon.Runtime.Store.Memory => :memory,
    Archon.Runtime.Queue.Memory => :memory,
    Archon.Runtime.Store.Postgres => :postgres,
    Archon.Runtime.Queue.Postgres => :postgres
  }

  @doc false
  def start_link(opts \\ []) do
    store = Runtime.store()
    queue = Runtime.queue()

    case {Map.get(@backends, store), Map.get(@backends, queue)} do
      {backend, backend} when backend != nil ->
        Supervisor.start_link(__MODULE__, backend, name: Keyword.get(opts, :name, __MODULE__))

      _mixed ->
        {:error, {:mixed_backends, store, queue}}
    end
  end

  @impl true
  def init(backend) do
    children =
      backend_children(backend) ++
        [
          {Registry, keys: :unique, name: Archon.Runtime.Registry},
          {Task.Supervisor, name: Archon.Runtime.TaskSupervisor},
          {DynamicSupervisor, name: Archon.Runtime.WorkflowSupervisor, strategy: :one_for_one},
          Archon.Runtime.Recovery,
          Archon.Runtime.Waker
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp backend_children(:memory),
    do: [Runtime.metadata(), Runtime.store(), {Runtime.queue(), clock: &Runtime.now/0}]

  # The metadata is not written with the store's commits, so either implementation goes with
  # the Postgres store; only the memory one is a process.
  defp backend_children(:postgres) do
    metadata =
      if Runtime.metadata() == Archon.Runtime.Metadata.Memory, do: [Runtime.metadata()], else: []

    [Archon.Repo, Archon.Runtime.Postgres.NodeLock | metadata]
  end
end
