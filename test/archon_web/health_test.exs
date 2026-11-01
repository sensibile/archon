defmodule ArchonWeb.HealthTest do
  @moduledoc "`GET /health` and `GET /api/health` against the captured fixtures (ADR 0023, decision 6)."

  use ArchonWeb.ContractCase, async: true

  test "both paths answer as upstream did" do
    replay(steps("health", "health_api"))
  end

  test "the body is JSON with upstream's exact Content-Type" do
    conn = get(build_conn(), "/health")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/json"]

    assert JSON.decode!(conn.resp_body) == %{
             "healthResults" => [],
             "suppressedHealthResults" => [],
             "healthy" => true
           }
  end
end
