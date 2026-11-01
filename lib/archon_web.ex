# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb do
  @moduledoc """
  The Phoenix REST layer (ADR 0023): `use ArchonWeb, :controller` or `use ArchonWeb, :router`.

  Controllers call only `Archon.Runtime`, `Archon.Runtime.Tasks` and `Archon.Metadata`
  (ADR 0023, decision 2). They read bodies and query values with `ArchonWeb.Request`, write
  successful responses with `ArchonWeb.Response` and every error with `ArchonWeb.Errors`.
  """

  @doc false
  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn

      alias ArchonWeb.{Errors, Request, Response}
    end
  end

  @doc false
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
    end
  end

  defmacro __using__(which) when which in [:controller, :router], do: apply(__MODULE__, which, [])
end
