# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Script.Pool do
  @moduledoc """
  The `archon_js` worker pool (ADR 0015, decision 2).

  A supervisor (`:rest_for_one`) over a dispatcher and `workers` `Archon.Script.Worker`s, each
  owning one `archon_js` port. A request waits in the dispatcher until a worker is idle; the
  worker answers the caller directly. A worker that stops while busy is answered for by the
  dispatcher, and if the dispatcher restarts, the workers restart and register again.

  Options (defaults from `config :archon, Archon.Script.Pool`, then the values below):

    * `:name` - the pool name, `Archon.Script.Pool` by default.
    * `:workers` - number of worker processes, `System.schedulers_online/0` by default.
    * `:timeout` - evaluation time limit in milliseconds, 4000 (upstream's 4 seconds). The engine
      interrupts the script at this limit.
    * `:grace` - how much longer, in milliseconds, a worker waits for an answer before it kills
      the process and starts a new one, 1000.
    * `:memory_limit` - engine memory limit in bytes, 64 MiB.
    * `:stack_limit` - engine stack limit in bytes, 1 MiB.
    * `:max_output` - largest result in bytes, 16 MiB.
    * `:executable` - path of `archon_js`, `priv/archon_js` by default.
  """

  use Supervisor

  alias Archon.Script
  alias Archon.Script.{Error, Worker}

  @defaults [
    timeout: 4_000,
    grace: 1_000,
    memory_limit: 64 * 1024 * 1024,
    stack_limit: 1024 * 1024,
    max_output: 16 * 1024 * 1024
  ]

  @doc false
  def start_link(opts) do
    opts = options(opts)
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc "Runs one `archon_js` operation on the pool `name`."
  @spec run(atom(), Script.op(), String.t(), term()) ::
          {:ok, Script.value()} | {:error, Error.t()}
  def run(name, op, script, input) when op in [:eval, :parse] and is_binary(script) do
    GenServer.call(dispatcher(name), {:run, op, script, input}, :infinity)
  end

  @doc false
  def dispatcher(name), do: Module.concat(name, Dispatcher)

  @impl true
  def init(opts) do
    name = opts[:name]

    workers =
      for i <- 1..opts[:workers] do
        Supervisor.child_spec({Worker, Keyword.put(opts, :dispatcher, dispatcher(name))},
          id: {Worker, i}
        )
      end

    worker_supervisor = %{
      id: :workers,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [workers, [strategy: :one_for_one, name: Module.concat(name, Workers)]]}
    }

    children = [{__MODULE__.Dispatcher, name: dispatcher(name)}, worker_supervisor]
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp options(opts) do
    @defaults
    |> Keyword.merge(
      name: __MODULE__,
      workers: System.schedulers_online(),
      executable: Application.app_dir(:archon, "priv/archon_js")
    )
    |> Keyword.merge(Application.get_env(:archon, __MODULE__, []))
    |> Keyword.merge(opts)
  end

  defmodule Dispatcher do
    @moduledoc false
    # Queues requests and hands each to an idle worker. Workers register on start, are
    # monitored, and report back when idle.

    use GenServer

    alias Archon.Script.Error

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name])

    @impl true
    def init(:ok), do: {:ok, %{idle: [], busy: %{}, queue: :queue.new()}}

    @impl true
    def handle_call({:run, op, script, input}, from, state) do
      request = {op, script, input}

      case state.idle do
        [worker | idle] -> {:noreply, assign(%{state | idle: idle}, worker, request, from)}
        [] -> {:noreply, %{state | queue: :queue.in({request, from}, state.queue)}}
      end
    end

    @impl true
    def handle_cast({:register, worker}, state) do
      Process.monitor(worker)
      {:noreply, idle(state, worker)}
    end

    def handle_cast({:idle, worker}, state),
      do: {:noreply, idle(%{state | busy: Map.delete(state.busy, worker)}, worker)}

    @impl true
    def handle_info({:DOWN, _ref, :process, worker, reason}, state) do
      {from, busy} = Map.pop(state.busy, worker)

      if from do
        error = %Error{kind: :crashed, reason: "worker stopped: #{inspect(reason)}"}
        GenServer.reply(from, {:error, error})
      end

      {:noreply, %{state | busy: busy, idle: List.delete(state.idle, worker)}}
    end

    defp idle(state, worker) do
      case :queue.out(state.queue) do
        {{:value, {request, from}}, queue} ->
          assign(%{state | queue: queue}, worker, request, from)

        {:empty, _queue} ->
          %{state | idle: [worker | state.idle]}
      end
    end

    defp assign(state, worker, request, from) do
      send(worker, {:run, request, from})
      %{state | busy: Map.put(state.busy, worker, from)}
    end
  end
end
