# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss sqlite-persistence/src/main/java/com/netflix/conductor/sqlite/dao/metadata/SqliteWorkflowMetadataDAO.java
# and SqliteTaskMetadataDAO.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: an in-memory GenServer (ADR 0018, decision 3).

defmodule Archon.Runtime.Metadata.Memory do
  @moduledoc """
  In-memory `Archon.Runtime.Metadata` for development and tests (ADR 0018, decision 3).

  One GenServer holds the task and workflow definitions. Data is lost when the process stops.
  Each function takes an optional first argument, the server (this module's name by default); the
  arities without it are the behaviour callbacks.

  Options of `start_link/1`: `:name` (this module by default).
  """

  @behaviour Archon.Runtime.Metadata

  use GenServer

  alias Archon.Domain.{TaskDef, WorkflowDef}
  alias Archon.Runtime.Metadata

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Metadata
  @spec create_task_def(GenServer.server(), TaskDef.t()) :: :ok
  def create_task_def(server \\ __MODULE__, %TaskDef{name: name} = task_def)
      when is_binary(name) do
    GenServer.call(server, {:put_task_def, task_def})
  end

  @impl Metadata
  @spec update_task_def(GenServer.server(), TaskDef.t()) :: :ok
  def update_task_def(server \\ __MODULE__, %TaskDef{name: name} = task_def)
      when is_binary(name) do
    GenServer.call(server, {:put_task_def, task_def})
  end

  @impl Metadata
  @spec get_task_def(GenServer.server(), String.t()) :: {:ok, TaskDef.t()} | {:error, :not_found}
  def get_task_def(server \\ __MODULE__, name), do: GenServer.call(server, {:get_task_def, name})

  @impl Metadata
  @spec create_workflow_def(GenServer.server(), WorkflowDef.t()) :: :ok | {:error, :conflict}
  def create_workflow_def(server \\ __MODULE__, %WorkflowDef{} = definition) do
    GenServer.call(server, {:create_workflow_def, definition})
  end

  @impl Metadata
  @spec update_workflow_def(GenServer.server(), WorkflowDef.t()) :: :ok
  def update_workflow_def(server \\ __MODULE__, %WorkflowDef{} = definition) do
    GenServer.call(server, {:update_workflow_def, definition})
  end

  @impl Metadata
  @spec get_workflow_def(GenServer.server(), String.t(), integer()) ::
          {:ok, WorkflowDef.t()} | {:error, :not_found}
  def get_workflow_def(server \\ __MODULE__, name, version) when is_integer(version) do
    GenServer.call(server, {:get_workflow_def, name, version})
  end

  @impl Metadata
  @spec get_latest_workflow_def(GenServer.server(), String.t()) ::
          {:ok, WorkflowDef.t()} | {:error, :not_found}
  def get_latest_workflow_def(server \\ __MODULE__, name) do
    GenServer.call(server, {:get_latest_workflow_def, name})
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{task_defs: %{}, workflow_defs: %{}}}

  @impl GenServer
  def handle_call({:put_task_def, task_def}, _from, state) do
    {:reply, :ok, put_in(state.task_defs[task_def.name], task_def)}
  end

  def handle_call({:get_task_def, name}, _from, state) do
    {:reply, fetch(state.task_defs, name), state}
  end

  def handle_call({:create_workflow_def, definition}, _from, state) do
    key = {definition.name, definition.version}

    if Map.has_key?(state.workflow_defs, key) do
      {:reply, {:error, :conflict}, state}
    else
      {:reply, :ok, put_in(state.workflow_defs[key], definition)}
    end
  end

  def handle_call({:update_workflow_def, definition}, _from, state) do
    key = {definition.name, definition.version}
    {:reply, :ok, put_in(state.workflow_defs[key], definition)}
  end

  def handle_call({:get_workflow_def, name, version}, _from, state) do
    {:reply, fetch(state.workflow_defs, {name, version}), state}
  end

  def handle_call({:get_latest_workflow_def, name}, _from, state) do
    latest =
      for({{^name, version}, definition} <- state.workflow_defs, do: {version, definition})
      |> Enum.max_by(&elem(&1, 0), fn -> nil end)

    {:reply, if(latest, do: {:ok, elem(latest, 1)}, else: {:error, :not_found}), state}
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end
end
