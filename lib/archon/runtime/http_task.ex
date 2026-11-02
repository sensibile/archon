# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.HttpTask do
  @moduledoc """
  The executor of `HTTP` task requests (ADR 0026, decision 7), in place of upstream's system task
  worker threads. A workflow process hands it a request with `request/4` after the commit that
  started the task; the executor sends it in a supervised task
  (`Task.Supervisor.async_nolink`, `Archon.Runtime.HttpTask.Client`) and delivers the result by
  workflow ID, not to the process that asked, as `{:http_completed, task_id, poll_count, result}`
  (`Archon.Runtime.WorkflowServer.http_completed/4`): a process that ended abnormally since then is
  replaced by the one the delivery activates, which takes the result if the task is still the
  same attempt.

  At most `max_concurrency` requests are sent at once; the others wait in order. A waiting
  request whose task's response timeout (`deadline`) is over is dropped unsent: the task is
  `TIMED_OUT` by then. A request is identified by its workflow and task: `cancel/2` (and a new
  request for the same task) drops a waiting one or ends a running one, which closes its
  connection and gives its place to the next.

  Settings, `config :archon, Archon.Runtime.HttpTask, ...`:

    * `max_concurrency` - the requests sent at once, `System.schedulers_online() * 2` by default.
    * `max_request_ms` - the total time of one request, redirects included: 60 000 (never past
      the task's response timeout).
    * `max_response_bytes` - the largest response body, read or decompressed: 10 MiB.
    * `deliver` - `{module, function, args}` called with `(workflow_id, task_id, poll_count,
      result)`, `Archon.Runtime.WorkflowServer.http_completed/4` by default (for tests).

  `Archon.Runtime.HttpTask.Supervisor` starts it with its task supervisor; either one ending
  restarts both, so the counts never miss a running request. The requests running then end,
  and their tasks time out.
  """

  use GenServer

  require Logger

  alias Archon.Runtime
  alias Archon.Runtime.HttpTask.Client
  alias Archon.Runtime.Step.Http

  @tasks Archon.Runtime.HttpTask.Tasks

  defstruct max: 1, queue: :queue.new(), waiting: %{}, running: %{}, refs: %{}

  @type key :: {String.t(), String.t()}

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Sends the request of the task `task_id` of the workflow, for the attempt `poll_count`. A request
  of the same task already waiting or running is dropped first.
  """
  @spec request(String.t(), String.t(), non_neg_integer(), Http.request()) :: :ok
  def request(workflow_id, task_id, poll_count, request),
    do: GenServer.cast(__MODULE__, {:request, {workflow_id, task_id}, poll_count, request})

  @doc "Drops the request of the task: unsent if it waits, ended if it runs."
  @spec cancel(String.t(), String.t()) :: :ok
  def cancel(workflow_id, task_id),
    do: GenServer.cast(__MODULE__, {:cancel, {workflow_id, task_id}})

  @doc false
  # For tests: the keys of the running and the waiting requests.
  @spec info() :: %{running: [key()], waiting: [key()]}
  def info, do: GenServer.call(__MODULE__, :info)

  @impl GenServer
  def init(_opts) do
    {:ok, %__MODULE__{max: setting(:max_concurrency, System.schedulers_online() * 2)}}
  end

  @impl GenServer
  def handle_cast({:request, key, poll_count, request}, state) do
    state = drop(state, key)
    job = %{key: key, poll_count: poll_count, request: request, id: make_ref()}

    state = %{
      state
      | queue: :queue.in({key, job.id}, state.queue),
        waiting: Map.put(state.waiting, key, job)
    }

    {:noreply, next(state)}
  end

  def handle_cast({:cancel, key}, state), do: {:noreply, state |> drop(key) |> next()}

  @impl GenServer
  def handle_call(:info, _from, state),
    do: {:reply, %{running: Map.keys(state.running), waiting: Map.keys(state.waiting)}, state}

  @impl GenServer
  def handle_info({ref, result}, %__MODULE__{refs: refs} = state) when is_map_key(refs, ref) do
    Process.demonitor(ref, [:flush])
    {job, state} = finished(state, ref)
    deliver(job, result)
    {:noreply, next(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{refs: refs} = state)
      when is_map_key(refs, ref) do
    {job, state} = finished(state, ref)
    {workflow_id, task_id} = job.key

    Logger.error(
      "the HTTP request of task #{task_id} of workflow #{workflow_id} failed: #{inspect(reason)}"
    )

    {:noreply, next(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A waiting request leaves the queue lazily (its ID no longer matches); a running one ends.
  defp drop(state, key) do
    state = %{state | waiting: Map.delete(state.waiting, key)}

    case Map.pop(state.running, key) do
      {nil, _running} ->
        state

      {%{task: task}, running} ->
        Task.shutdown(task, :brutal_kill)
        %{state | running: running, refs: Map.delete(state.refs, task.ref)}
    end
  end

  defp finished(state, ref) do
    {key, refs} = Map.pop(state.refs, ref)
    {%{job: job}, running} = Map.pop(state.running, key)
    {job, %{state | refs: refs, running: running}}
  end

  defp next(%__MODULE__{} = state) when map_size(state.running) >= state.max, do: state

  defp next(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, {key, id}}, queue} ->
        state = %{state | queue: queue}

        case Map.pop(state.waiting, key) do
          {%{id: ^id} = job, waiting} -> next(run(%{state | waiting: waiting}, job))
          _dropped_or_replaced -> next(state)
        end
    end
  end

  defp run(state, %{request: request} = job) do
    left = request.deadline - Runtime.now()

    if left <= 0 do
      state
    else
      limits = %{
        total_ms: min(setting(:max_request_ms, 60_000), left),
        max_body: setting(:max_response_bytes, 10 * 1024 * 1024)
      }

      task = Task.Supervisor.async_nolink(@tasks, Client, :run, [request, limits])

      %{
        state
        | running: Map.put(state.running, job.key, %{task: task, job: job}),
          refs: Map.put(state.refs, task.ref, job.key)
      }
    end
  end

  # Delivered from its own process, so a workflow process that is busy or being activated does
  # not hold the executor.
  defp deliver(%{key: {workflow_id, task_id}, poll_count: poll_count}, result) do
    {module, function, args} =
      setting(:deliver, {Archon.Runtime.WorkflowServer, :http_completed, []})

    Task.Supervisor.start_child(@tasks, fn ->
      apply(module, function, args ++ [workflow_id, task_id, poll_count, result])
    end)
  end

  defp setting(key, default),
    do: :archon |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end

defmodule Archon.Runtime.HttpTask.Supervisor do
  @moduledoc """
  The `HTTP` task executor (`Archon.Runtime.HttpTask`) and the task supervisor of its requests
  and deliveries, restarted together (`:one_for_all`).
  """

  use Supervisor

  @doc false
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    Supervisor.init(
      [{Task.Supervisor, name: Archon.Runtime.HttpTask.Tasks}, Archon.Runtime.HttpTask],
      strategy: :one_for_all
    )
  end
end
