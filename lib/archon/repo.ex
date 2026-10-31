# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Repo do
  @moduledoc """
  The PostgreSQL repository of the Postgres runtime backend (ADR 0021, decision 1).

  Queries are written without Ecto schema modules, as schemaless `Ecto.Query` or `query/3`; the
  storage encoding of the domain structs (`to_storage/1`, `from_storage/1`) turns rows into
  structs. The connection comes from `DATABASE_URL` (`config/runtime.exs`). Migrations are in
  `priv/repo/migrations` and are applied by `Archon.Release`, not at application start.
  """

  use Ecto.Repo, otp_app: :archon, adapter: Ecto.Adapters.Postgres
end
