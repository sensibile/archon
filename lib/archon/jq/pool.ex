# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Jq.Pool do
  @moduledoc """
  The `archon_jq` worker pool (ADR 0026, decision 6): an `Archon.Script.Pool` that runs
  `priv/archon_jq` instead of `archon_js`.

  Options (defaults from `config :archon, Archon.Jq.Pool`, then the values below):

    * `:name` - the pool name, `Archon.Jq.Pool` by default.
    * `:workers` - number of worker processes, `System.schedulers_online/0` by default.
    * `:timeout` - evaluation time limit in milliseconds, 4000. The process answers a timeout
      and exits at this limit.
    * `:grace` - how much longer, in milliseconds, a worker waits for an answer before it kills
      the process and starts a new one, 1000.
    * `:memory_limit` - what jq and oniguruma may allocate, in bytes, 64 MiB. Over it the
      process answers a limit error and exits.
    * `:max_output` - largest answer in bytes, 16 MiB.
    * `:max_queue` - most requests waiting for a worker, 1000.
    * `:executable` - path of `archon_jq`, `priv/archon_jq` by default.
  """

  alias Archon.Script

  @defaults [
    timeout: 4_000,
    grace: 1_000,
    memory_limit: 64 * 1024 * 1024,
    max_output: 16 * 1024 * 1024,
    max_queue: 1_000,
    args: [memory_limit: "--memory-limit", timeout: "--timeout-ms", max_output: "--max-output"],
    ops: ["eval"]
  ]

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc false
  def start_link(opts) do
    @defaults
    |> Keyword.merge(
      name: __MODULE__,
      workers: System.schedulers_online(),
      executable: Application.app_dir(:archon, "priv/archon_jq"),
      decode: &decode_results/1
    )
    |> Keyword.merge(Application.get_env(:archon, __MODULE__, []))
    |> Keyword.merge(opts)
    |> Script.Pool.start_pool()
  end

  # archon_jq answers plain JSON: the list of results.
  defp decode_results(results) when is_list(results), do: results
end
