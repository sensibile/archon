# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.FaultyStore do
  @moduledoc """
  An `Archon.Runtime.Store` that runs a test's fault before each call of the configured store,
  for failures no runtime hook reaches (a store read raising, as `Archon.Runtime.Store.Postgres`
  does when the database is down).

  `install(fault)` puts it in front of the runtime's store until the test exits;
  `fault.(callback, args)` runs first and may raise.
  """

  @behaviour Archon.Runtime.Store

  alias Archon.Runtime.Store

  @key {__MODULE__, :installed}

  @doc "Puts the store in front of the runtime's for the rest of the test."
  @spec install((atom(), list() -> term())) :: :ok
  def install(fault) do
    config = Application.get_env(:archon, Archon.Runtime, [])
    inner = Keyword.get(config, :store, Archon.Runtime.Store.Memory)
    :persistent_term.put(@key, {inner, fault})
    Application.put_env(:archon, Archon.Runtime, Keyword.put(config, :store, __MODULE__))

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:archon, Archon.Runtime, config)
      :persistent_term.erase(@key)
    end)

    :ok
  end

  for {name, arity} <- Store.behaviour_info(:callbacks) do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl true
    def unquote(name)(unquote_splicing(args)), do: call(unquote(name), unquote(args))
  end

  defp call(name, args) do
    {inner, fault} = :persistent_term.get(@key)
    fault.(name, args)
    apply(inner, name, args)
  end
end
