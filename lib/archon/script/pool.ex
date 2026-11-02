# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Script.Pool do
  @moduledoc """
  A pool of evaluator processes behind Erlang ports: the `archon_js` pool (ADR 0015, decision 2)
  and, started by `Archon.Jq.Pool` with its own options, the `archon_jq` pool (ADR 0026,
  decision 6).

  A supervisor (`:rest_for_one`) over a dispatcher and `workers` `Archon.Script.Worker`s, each
  owning one port of `executable`. A request waits in the dispatcher until a worker is idle; the
  worker answers the caller directly. At most `max_queue` requests wait; beyond that a request
  fails at once with `Script evaluation queue is full`, and a waiting request whose caller has
  exited is dropped instead of run. A worker that stops while busy is answered for by the
  dispatcher, and if the dispatcher restarts, the workers restart and register again.

  Options of the `archon_js` pool (defaults from `config :archon, Archon.Script.Pool`, then the
  values below):

    * `:name` - the pool name, `Archon.Script.Pool` by default.
    * `:workers` - number of worker processes, `System.schedulers_online/0` by default.
    * `:timeout` - evaluation time limit in milliseconds, 4000 (upstream's 4 seconds). The engine
      interrupts the script at this limit.
    * `:grace` - how much longer, in milliseconds, a worker waits for an answer before it kills
      the process and starts a new one, 1000.
    * `:memory_limit` - engine memory limit in bytes, 64 MiB.
    * `:stack_limit` - engine stack limit in bytes, 1 MiB.
    * `:max_output` - largest result in bytes, 16 MiB.
    * `:max_queue` - most requests waiting for a worker, 1000.
    * `:executable` - path of `archon_js`, `priv/archon_js` by default.

  What makes a pool run one evaluator rather than another (set by `start_link/1` for
  `archon_js`, by `Archon.Jq.Pool` for `archon_jq`):

    * `:args` - the options passed to `executable`, as `{option, flag}` pairs: the process is
      started with `flag value` for each.
    * `:ops` - the `"op"` values a request may carry; any other is rejected without a worker.
    * `:decode` - turns the `"ok"` value of an answer into the result.
  """

  use Supervisor

  alias Archon.Script
  alias Archon.Script.{Error, Worker}

  @defaults [
    timeout: 4_000,
    grace: 1_000,
    memory_limit: 64 * 1024 * 1024,
    stack_limit: 1024 * 1024,
    max_output: 16 * 1024 * 1024,
    max_queue: 1_000,
    args: [
      memory_limit: "--memory-limit",
      stack_limit: "--stack-limit",
      timeout: "--timeout-ms",
      max_output: "--max-output"
    ],
    ops: ["eval", "parse"],
    decode: &Script.decode_value/1
  ]

  @doc false
  def start_link(opts), do: opts |> options() |> start_pool()

  @doc false
  # Starts a pool from complete options (`Archon.Jq.Pool` builds its own).
  @spec start_pool(keyword()) :: Supervisor.on_start()
  def start_pool(opts), do: Supervisor.start_link(__MODULE__, opts, name: opts[:name])

  @doc "Runs one `archon_js` operation on the pool `name`."
  @spec run(atom(), Script.op(), String.t(), term()) ::
          {:ok, Script.value()} | {:error, Error.t()}
  def run(name, op, script, input) when op in [:eval, :parse] and is_binary(script),
    do: request(name, %{"op" => Atom.to_string(op), "script" => script, "input" => input})

  @doc """
  Sends one request, a JSON object whose `"op"` is one of the pool's `:ops`, to the pool `name`
  and answers the decoded result or the error.
  """
  @spec request(atom(), %{required(String.t()) => term()}) :: {:ok, term()} | {:error, Error.t()}
  def request(name, %{"op" => op} = request) when is_binary(op),
    do: GenServer.call(dispatcher(name), {:run, request}, :infinity)

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

    children = [
      {__MODULE__.Dispatcher,
       name: dispatcher(name), max_queue: opts[:max_queue], ops: opts[:ops]},
      worker_supervisor
    ]

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

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    @impl true
    def init(opts) do
      {:ok,
       %{
         idle: [],
         busy: %{},
         queue: :queue.new(),
         max_queue: opts[:max_queue],
         ops: opts[:ops]
       }}
    end

    @impl true
    def handle_call({:run, request}, from, state) do
      cond do
        request["op"] not in state.ops ->
          {:reply, {:error, %Error{kind: :request, reason: "unknown op #{request["op"]}"}}, state}

        state.idle != [] ->
          [worker | idle] = state.idle
          {:noreply, assign(%{state | idle: idle}, worker, request, from)}

        :queue.len(state.queue) >= state.max_queue ->
          {:reply, {:error, %Error{kind: :limit, reason: "evaluation queue is full"}}, state}

        true ->
          {:noreply, %{state | queue: :queue.in({request, from}, state.queue)}}
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
        {{:value, {request, {caller, _tag} = from}}, queue} ->
          # Nobody waits for the answer of a caller that has exited.
          if Process.alive?(caller),
            do: assign(%{state | queue: queue}, worker, request, from),
            else: idle(%{state | queue: queue}, worker)

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
