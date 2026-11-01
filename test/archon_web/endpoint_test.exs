defmodule ArchonWeb.EndpointTest do
  @moduledoc "The endpoint's address (ADR 0024, decision 4) as `config/runtime.exs` reads it."

  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  setup do
    saved = for name <- ~w(ARCHON_HTTP_IP PORT), into: %{}, do: {name, System.get_env(name)}

    on_exit(fn ->
      for {name, value} <- saved,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)
  end

  defp http(env) do
    for name <- ~w(ARCHON_HTTP_IP PORT), do: System.delete_env(name)
    for {name, value} <- env, do: System.put_env(name, value)
    @runtime |> Config.Reader.read!(env: :test) |> get_in([:archon, ArchonWeb.Endpoint, :http])
  end

  test "defaults to 127.0.0.1:8080" do
    assert http(%{}) == [ip: {127, 0, 0, 1}, port: 8080]
    assert http(%{"ARCHON_HTTP_IP" => "", "PORT" => ""}) == [ip: {127, 0, 0, 1}, port: 8080]
  end

  test "ARCHON_HTTP_IP and PORT open another address" do
    assert http(%{"ARCHON_HTTP_IP" => "0.0.0.0", "PORT" => "18080"}) == [
             ip: {0, 0, 0, 0},
             port: 18_080
           ]

    assert http(%{"ARCHON_HTTP_IP" => "::1"}) == [ip: {0, 0, 0, 0, 0, 0, 0, 1}, port: 8080]
  end

  test "an address or port that does not parse stops the start" do
    assert_raise RuntimeError, ~r/ARCHON_HTTP_IP/, fn ->
      http(%{"ARCHON_HTTP_IP" => "localhost"})
    end

    assert_raise RuntimeError, ~r/ARCHON_HTTP_IP/, fn -> http(%{"ARCHON_HTTP_IP" => "1.2.3"}) end
    assert_raise RuntimeError, ~r/PORT/, fn -> http(%{"PORT" => "80a"}) end
    assert_raise RuntimeError, ~r/PORT/, fn -> http(%{"PORT" => "65536"}) end
  end

  test "the test endpoint does not listen" do
    assert Application.get_env(:archon, ArchonWeb.Endpoint)[:server] == false
    assert Process.whereis(ArchonWeb.Endpoint)
  end
end
