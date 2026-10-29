# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/dal/ExecutionDAOFacade.java,
# sqlite-persistence/src/main/java/com/netflix/conductor/sqlite/dao/SqliteExecutionDAO.java and
# SqlitePollDataDAO.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: an in-memory GenServer holding the structs as they are (ADR 0018,
# decision 3); a commit is applied in one message, so readers never see half of it.

defmodule Archon.Runtime.Store.Memory do
  @moduledoc """
  In-memory `Archon.Runtime.Store` for development and tests (ADR 0018, decision 3).

  One GenServer holds the workflows (without tasks), the tasks and the poll data. Data is lost
  when the process stops. Each function takes an optional first argument, the server (this module's
  name by default); the arities without it are the behaviour callbacks.

  Options of `start_link/1`: `:name` (this module by default).
  """

  @behaviour Archon.Runtime.Store

  use GenServer

  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.{Commit, Store}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Store
  @spec commit(GenServer.server(), String.t(), Commit.t()) ::
          :ok | {:error, :conflict | :not_found}
  def commit(server \\ __MODULE__, workflow_id, %Commit{} = commit) when is_binary(workflow_id) do
    check_commit!(workflow_id, commit)
    GenServer.call(server, {:commit, workflow_id, commit})
  end

  @impl Store
  @spec get_workflow(GenServer.server(), String.t(), boolean()) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow(server \\ __MODULE__, id, include_tasks?) when is_boolean(include_tasks?) do
    GenServer.call(server, {:get_workflow, id, include_tasks?})
  end

  @impl Store
  @spec get_task(GenServer.server(), String.t()) ::
          {:ok, Task.t(), String.t()} | {:error, :not_found}
  def get_task(server \\ __MODULE__, task_id), do: GenServer.call(server, {:get_task, task_id})

  @impl Store
  @spec running_workflow_ids(GenServer.server()) :: [String.t()]
  def running_workflow_ids(server \\ __MODULE__),
    do: GenServer.call(server, :running_workflow_ids)

  @impl Store
  @spec remove_workflow(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def remove_workflow(server \\ __MODULE__, id),
    do: GenServer.call(server, {:remove_workflow, id})

  @impl Store
  @spec in_progress_count(GenServer.server(), String.t()) :: non_neg_integer()
  def in_progress_count(server \\ __MODULE__, task_def_name) do
    GenServer.call(server, {:in_progress_count, task_def_name})
  end

  @impl Store
  @spec put_poll_data(
          GenServer.server(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          integer()
        ) ::
          :ok
  def put_poll_data(server \\ __MODULE__, task_type, domain, worker_id, now)
      when is_binary(task_type) and is_integer(now) do
    poll_data = %{
      queue_name: task_type,
      domain: domain,
      worker_id: worker_id,
      last_poll_time: now
    }

    GenServer.call(server, {:put_poll_data, poll_data})
  end

  @impl Store
  @spec get_poll_data(GenServer.server(), String.t(), String.t() | nil) ::
          {:ok, Store.poll_data()} | {:error, :not_found}
  def get_poll_data(server \\ __MODULE__, task_type, domain) do
    GenServer.call(server, {:get_poll_data, task_type, domain})
  end

  # Upstream ExecutionDAO#createTasks rejects these before writing; a bad commit is a bug in the
  # caller, so it raises there instead of crashing the store.
  defp check_commit!(workflow_id, %Commit{create: create, workflow: workflow} = commit) do
    for %Workflow{workflow_id: id} <- [create, workflow], id != workflow_id do
      raise ArgumentError, "commit for #{workflow_id} carries workflow #{inspect(id)}"
    end

    created_tasks = if create, do: create.tasks, else: []
    Enum.each(created_tasks ++ commit.upsert_tasks, &check_task!(workflow_id, &1))
  end

  defp check_task!(workflow_id, %Task{} = task) do
    cond do
      task.task_id in [nil, ""] ->
        raise ArgumentError, "Task id cannot be null"

      task.workflow_instance_id in [nil, ""] ->
        raise ArgumentError, "Workflow instance id cannot be null"

      task.workflow_instance_id != workflow_id ->
        raise ArgumentError, "task #{task.task_id} belongs to #{task.workflow_instance_id}"

      task.reference_task_name in [nil, ""] ->
        raise ArgumentError, "Task reference name cannot be null"

      true ->
        :ok
    end
  end

  @impl GenServer
  def init(:ok) do
    {:ok, %{workflows: %{}, tasks: %{}, task_ids: %{}, poll_data: %{}}}
  end

  @impl GenServer
  def handle_call({:commit, workflow_id, commit}, _from, state) do
    case apply_commit(state, workflow_id, commit) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:get_workflow, id, include_tasks?}, _from, state) do
    reply =
      case state.workflows do
        %{^id => workflow} when include_tasks? -> {:ok, %{workflow | tasks: tasks_of(state, id)}}
        %{^id => workflow} -> {:ok, workflow}
        %{} -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:get_task, task_id}, _from, state) do
    reply =
      case state.tasks do
        %{^task_id => task} -> {:ok, task, task.workflow_instance_id}
        %{} -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:running_workflow_ids, _from, state) do
    ids =
      for {id, %Workflow{status: status}} <- state.workflows,
          not Workflow.terminal?(status),
          do: id

    {:reply, Enum.sort(ids), state}
  end

  def handle_call({:remove_workflow, id}, _from, state) do
    if Map.has_key?(state.workflows, id) do
      state = %{
        state
        | workflows: Map.delete(state.workflows, id),
          tasks: Map.drop(state.tasks, MapSet.to_list(state.task_ids[id])),
          task_ids: Map.delete(state.task_ids, id)
      }

      {:reply, :ok, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:in_progress_count, task_def_name}, _from, state) do
    count =
      Enum.count(state.tasks, fn {_id, task} ->
        task.status == :in_progress and Task.task_def_name(task) == task_def_name
      end)

    {:reply, count, state}
  end

  def handle_call({:put_poll_data, poll_data}, _from, state) do
    key = {poll_data.queue_name, poll_data.domain}
    {:reply, :ok, %{state | poll_data: Map.put(state.poll_data, key, poll_data)}}
  end

  def handle_call({:get_poll_data, task_type, domain}, _from, state) do
    reply = Map.fetch(state.poll_data, {task_type, domain})
    {:reply, if(reply == :error, do: {:error, :not_found}, else: reply), state}
  end

  defp apply_commit(state, workflow_id, %Commit{} = commit) do
    with {:ok, state} <- apply_create(state, workflow_id, commit.create),
         :ok <- check_exists(state, workflow_id),
         :ok <- check_owner(state, workflow_id, commit.upsert_tasks) do
      state =
        state
        |> put_workflow(commit.workflow)
        |> put_tasks(workflow_id, commit.upsert_tasks)
        |> delete_tasks(workflow_id, commit.delete_task_ids)

      {:ok, state}
    end
  end

  defp apply_create(state, _workflow_id, nil), do: {:ok, state}

  defp apply_create(state, workflow_id, %Workflow{tasks: tasks} = workflow) do
    if Map.has_key?(state.workflows, workflow_id) do
      {:error, :conflict}
    else
      with :ok <- check_owner(state, workflow_id, tasks) do
        state = %{state | task_ids: Map.put(state.task_ids, workflow_id, MapSet.new())}
        {:ok, state |> put_workflow(workflow) |> put_tasks(workflow_id, tasks)}
      end
    end
  end

  defp check_exists(state, workflow_id) do
    if Map.has_key?(state.workflows, workflow_id), do: :ok, else: {:error, :not_found}
  end

  defp check_owner(state, workflow_id, tasks) do
    owned_elsewhere? = fn %Task{task_id: id} ->
      match?(%{^id => %Task{workflow_instance_id: owner}} when owner != workflow_id, state.tasks)
    end

    if Enum.any?(tasks, owned_elsewhere?), do: {:error, :conflict}, else: :ok
  end

  defp put_workflow(state, nil), do: state

  defp put_workflow(state, %Workflow{workflow_id: id} = workflow) do
    %{state | workflows: Map.put(state.workflows, id, %{workflow | tasks: []})}
  end

  defp put_tasks(state, workflow_id, tasks) do
    Enum.reduce(tasks, state, fn %Task{task_id: id} = task, state ->
      %{
        state
        | tasks: Map.put(state.tasks, id, task),
          task_ids: Map.update!(state.task_ids, workflow_id, &MapSet.put(&1, id))
      }
    end)
  end

  defp delete_tasks(state, workflow_id, task_ids) do
    owned = Enum.filter(task_ids, &MapSet.member?(state.task_ids[workflow_id], &1))

    %{
      state
      | tasks: Map.drop(state.tasks, owned),
        task_ids:
          Map.update!(state.task_ids, workflow_id, &MapSet.difference(&1, MapSet.new(owned)))
    }
  end

  defp tasks_of(state, workflow_id) do
    state.task_ids[workflow_id]
    |> Enum.map(&Map.fetch!(state.tasks, &1))
    |> Enum.sort_by(&{&1.seq, &1.task_id})
  end
end
