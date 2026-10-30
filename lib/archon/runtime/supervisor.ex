# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Supervisor do
  @moduledoc """
  The runtime's process tree (ADR 0018, decision 1), `rest_for_one`:

      Archon.Runtime.Supervisor
      ├── metadata, store and queue (`config :archon, Archon.Runtime`, memory by default)
      ├── Archon.Runtime.Registry            (workflow ID → process)
      ├── Archon.Runtime.WorkflowSupervisor  (a DynamicSupervisor of Archon.Runtime.WorkflowServer)
      └── Archon.Runtime.Recovery            (activates the running workflows once)

  When the store or the queue restarts, the registry and every workflow process restart after
  it and `Archon.Runtime.Recovery` activates the running workflows again.
  """

  use Supervisor

  alias Archon.Runtime

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    children = [
      Runtime.metadata(),
      Runtime.store(),
      {Runtime.queue(), clock: &Runtime.now/0},
      {Registry, keys: :unique, name: Archon.Runtime.Registry},
      {DynamicSupervisor, name: Archon.Runtime.WorkflowSupervisor, strategy: :one_for_one},
      Archon.Runtime.Recovery
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
