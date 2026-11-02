# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Script.Worker do
  @moduledoc """
  One evaluator process (`archon_js`, ADR 0015, or `archon_jq`, ADR 0026 decision 6) behind an
  Erlang port (`{:packet, 4}`), with the options of its `Archon.Script.Pool`.

  The worker runs one request at a time. The evaluator stops itself at `timeout`; if no answer
  has come `grace` milliseconds after that, the worker kills the OS process, answers with a
  timeout and starts a new process. A process that exits on its own is replaced the same way;
  so is one that answers and exits (`archon_jq` over its memory limit). Neither stops the
  worker.
  """

  use GenServer

  alias Archon.Script.Error

  require Logger

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    # So that terminate/2 runs on shutdown and kills a process still busy in native code.
    Process.flag(:trap_exit, true)

    state = %{
      opts: opts,
      dispatcher: Keyword.fetch!(opts, :dispatcher),
      port: nil,
      current: nil
    }

    state = open(state)
    GenServer.cast(state.dispatcher, {:register, self()})
    {:ok, state}
  end

  @impl true
  def handle_info({:run, request, from}, %{current: nil} = state) do
    true = Port.command(state.port, JSON.encode!(request))
    ref = make_ref()

    timer =
      Process.send_after(self(), {:deadline, ref}, state.opts[:timeout] + state.opts[:grace])

    {:noreply, %{state | current: %{from: from, ref: ref, timer: timer}}}
  end

  def handle_info({port, {:data, data}}, %{port: port, current: current} = state)
      when current != nil do
    Process.cancel_timer(current.timer)
    {reply, exiting?} = decode(data, state.opts)
    # An evaluator that answers on its way out (archon_jq over a limit) is replaced before the
    # next request can reach it. It ends by itself, so closing its port is enough.
    state = if exiting?, do: state |> tap(&close(&1.port)) |> open(), else: state
    finish(state, reply)
  end

  def handle_info({:deadline, ref}, %{current: %{ref: ref}} = state) do
    Logger.warning("#{name(state)} did not answer within the time limit; restarting it")
    kill(state.port)
    error = %Error{kind: :timeout, reason: "interrupted", timeout: state.opts[:timeout]}
    finish(open(state), {:error, error})
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("#{name(state)} exited with status #{status}; restarting it")
    state = open(state)

    case state.current do
      nil ->
        {:noreply, state}

      current ->
        Process.cancel_timer(current.timer)
        finish(state, {:error, %Error{kind: :crashed, reason: "exited with status #{status}"}})
    end
  end

  # Messages from a port this worker already replaced, and stale deadlines.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: kill(state.port)

  defp finish(state, reply) do
    GenServer.reply(state.current.from, reply)
    GenServer.cast(state.dispatcher, {:idle, self()})
    {:noreply, %{state | current: nil}}
  end

  defp open(state) do
    opts = state.opts

    args = Enum.flat_map(opts[:args], fn {key, flag} -> [flag, Integer.to_string(opts[key])] end)

    port =
      Port.open({:spawn_executable, opts[:executable]}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:packet, 4},
        args: args
      ])

    %{state | port: port}
  end

  defp name(state), do: Path.basename(state.opts[:executable])

  defp close(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp kill(nil), do: :ok

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        # The engine did not stop at its deadline (or the worker is stopping): the process may
        # be busy in native code and never read its closed stdin, so kill it outright.
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
        Port.close(port)

      nil ->
        :ok
    end

    :ok
  catch
    :error, :badarg -> :ok
  end

  # The reply, and whether the evaluator exits after this answer.
  defp decode(data, opts) do
    case JSON.decode(data) do
      {:ok, %{"ok" => value}} ->
        {{:ok, opts[:decode].(value)}, false}

      {:ok, %{"error" => kind, "message" => message} = error} ->
        reply =
          {:error,
           %Error{
             kind: error_kind(kind),
             reason: message,
             line: error["line"],
             timeout: opts[:timeout]
           }}

        {reply, error["exit"] == true}

      _malformed ->
        {{:error, %Error{kind: :crashed, reason: "sent a malformed response"}}, false}
    end
  end

  defp error_kind("syntax"), do: :syntax
  defp error_kind("runtime"), do: :runtime
  defp error_kind("timeout"), do: :timeout
  defp error_kind("conversion"), do: :conversion
  defp error_kind("limit"), do: :limit
  defp error_kind("request"), do: :request
end
