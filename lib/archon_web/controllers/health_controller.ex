# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/HealthCheckResource.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: a Phoenix action writing the same HealthCheckStatus body.

defmodule ArchonWeb.HealthController do
  @moduledoc "`GET /health` and `GET /api/health` (upstream `HealthCheckResource.doCheck`)."

  use ArchonWeb, :controller

  @doc "Always healthy with no health results, as upstream's `HealthCheckStatus.create(true, [])`."
  @spec check(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def check(conn, _params) do
    Response.json(conn, %{
      "healthResults" => [],
      "suppressedHealthResults" => [],
      "healthy" => true
    })
  end
end
