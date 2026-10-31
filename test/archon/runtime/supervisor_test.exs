# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.SupervisorTest do
  @moduledoc """
  `Archon.Runtime.Supervisor` refuses a store and a queue of different backends (ADR 0021,
  decision 3): the store writes the commit's queue operations with it.
  """

  use ExUnit.Case, async: false

  alias Archon.Runtime.Queue
  alias Archon.Runtime.Store

  # The configuration is global; it is changed only around the start that reads it.
  defp start_with(config) do
    saved = Application.get_env(:archon, Archon.Runtime, [])

    try do
      Application.put_env(:archon, Archon.Runtime, Keyword.merge(saved, config))
      Archon.Runtime.Supervisor.start_link(name: :archon_mixed_backends)
    after
      Application.put_env(:archon, Archon.Runtime, saved)
    end
  end

  test "a memory store with a Postgres queue is refused" do
    assert start_with(store: Store.Memory, queue: Queue.Postgres) ==
             {:error, {:mixed_backends, Store.Memory, Queue.Postgres}}
  end

  test "a Postgres store with a memory queue is refused" do
    assert start_with(store: Store.Postgres, queue: Queue.Memory) ==
             {:error, {:mixed_backends, Store.Postgres, Queue.Memory}}
  end

  test "a store of an unknown backend is refused" do
    assert start_with(store: __MODULE__, queue: Queue.Memory) ==
             {:error, {:mixed_backends, __MODULE__, Queue.Memory}}
  end
end
