# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Postgres.FencedError do
  @moduledoc """
  Raised by a Postgres write whose node epoch is stale (ADR 0021, decision 7) when the callback
  has no error result to return it in: `Archon.Runtime.Postgres.transaction!/2`.
  """

  defexception message: "the node epoch is stale; another node holds the database"
end
