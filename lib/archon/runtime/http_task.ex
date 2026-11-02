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

  # How long after its total time limit the executor ends a request the client did not.
  @grace_ms 1_000

  # The first wait before a delivery is tried again, doubled up to @max_retry_ms.
  @retry_ms 100
  @max_retry_ms 5_000

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
    do: GenServer.call(__MODULE__, {:request, {workflow_id, task_id}, poll_count, request})

  @doc "Drops the request of the task: unsent if it waits, ended if it runs."
  @spec cancel(String.t(), String.t()) :: :ok
  def cancel(workflow_id, task_id),
    do: GenServer.cast(__MODULE__, {:cancel, {workflow_id, task_id}})

  @doc false
  # For tests: the keys of the running and the waiting requests.
  @spec info() :: %{running: [key()], waiting: [key()]}
  def info, do: GenServer.call(__MODULE__, :info)

  @impl GenServer
  def handle_cast({:cancel, key}, state), do: {:noreply, state |> drop(key) |> next()}

  @impl GenServer
  def init(_opts) do
    {:ok, %__MODULE__{max: setting(:max_concurrency, System.schedulers_online() * 2)}}
  end

  # A call, so a workflow process sees an executor that is not there (restarting) as a failed
  # effect instead of a request it believes in flight.
  @impl GenServer
  def handle_call({:request, key, poll_count, request}, _from, state) do
    state = drop(state, key)
    job = %{key: key, poll_count: poll_count, request: request, id: make_ref()}

    state = %{
      state
      | queue: :queue.in({key, job.id}, state.queue),
        waiting: Map.put(state.waiting, key, job)
    }

    {:reply, :ok, next(state)}
  end

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

    # Upstream's start catches the exception and fails the task.
    deliver(job, {:error, {:io, Exception.format_exit(reason)}})
    {:noreply, next(state)}
  end

  # The backstop of the total time limit: a request the client did not end by then (a send that
  # blocks on a target that does not read) is ended here.
  def handle_info({:expire, key, id}, state) do
    case state.running do
      %{^key => %{job: %{id: ^id} = job}} ->
        state = drop(state, key)
        deliver(job, {:error, {:io, Client.total_error()}})
        {:noreply, next(state)}

      _done ->
        {:noreply, state}
    end
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
      Process.send_after(self(), {:expire, job.key, job.id}, limits.total_ms + @grace_ms)

      %{
        state
        | running: Map.put(state.running, job.key, %{task: task, job: job}),
          refs: Map.put(state.refs, task.ref, job.key)
      }
    end
  end

  # Delivered from its own process, so a workflow process that is busy or being activated does
  # not hold the executor. A delivery that fails (a store that is down, a call that timed out) is
  # tried again until the task's deadline, after which the task is timed out anyway; a workflow
  # that is gone takes nothing.
  defp deliver(%{key: {workflow_id, task_id}, poll_count: poll_count, request: request}, result) do
    {module, function, args} =
      setting(:deliver, {Archon.Runtime.WorkflowServer, :http_completed, []})

    args = args ++ [workflow_id, task_id, poll_count, result]

    Task.Supervisor.start_child(@tasks, fn ->
      deliver_until(module, function, args, request.deadline, @retry_ms)
    end)
  end

  defp deliver_until(module, function, [workflow_id, task_id | _rest] = args, deadline, wait) do
    case apply(module, function, args) do
      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        if Runtime.now() + wait < deadline do
          Process.sleep(wait)
          deliver_until(module, function, args, deadline, min(wait * 2, @max_retry_ms))
        else
          Logger.error(
            "the HTTP result of task #{task_id} of workflow #{workflow_id} was not delivered: " <>
              inspect(reason)
          )
        end

      _delivered ->
        :ok
    end
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
