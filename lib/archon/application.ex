defmodule Archon.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Tests start the runtime from test/test_helper.exs, once the database is set up. The REST
    # endpoint starts after the runtime it calls (ADR 0023, decision 1).
    runtime =
      if Application.get_env(:archon, :start_runtime, true),
        do: [Archon.Runtime.Supervisor, ArchonWeb.Endpoint],
        else: []

    children = [Archon.Script.Pool | runtime]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Archon.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
