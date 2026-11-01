defmodule ArchonWeb.ContractCaseTest do
  @moduledoc "The replay helper itself (ADR 0023, decision 6): scenario coverage and the ID mapping."

  use ArchonWeb.ContractCase, async: true

  alias Archon.Contract

  @a "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @b "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @c "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

  test "the scenario names every fixture once" do
    names = for step <- scenario(), elem(step, 0) != :wait_status, do: elem(step, 1)
    assert Enum.sort(names) == Contract.fixture_names()
    assert Enum.uniq(names) == names
  end

  test "a wait follows the start it names" do
    for {{:wait_status, start, _status}, index} <- Enum.with_index(scenario()) do
      start_index = Enum.find_index(scenario(), &(&1 == {:exchange, start}))
      assert start_index && start_index < index, start
    end
  end

  test "steps/2 cuts the scenario from one fixture through another" do
    assert steps("health", "health_api") == [{:exchange, "health"}, {:exchange, "health_api"}]
    assert_raise ArgumentError, fn -> steps("health", "missing") end
  end

  describe "bind/3" do
    test "binds one-to-one" do
      state = new_state() |> bind(@a, @b)
      assert state.ids == %{@a => @b}
      assert bind(state, @a, @b) == state
    end

    test "a captured ID cannot be bound to a second value" do
      state = bind(new_state(), @a, @b)
      assert_raise ExUnit.AssertionError, ~r/is bound to/, fn -> bind(state, @a, @c) end
    end

    test "a value cannot be bound to a second captured ID" do
      state = bind(new_state(), @a, @b)
      assert_raise ExUnit.AssertionError, ~r/already bound/, fn -> bind(state, @c, @b) end
    end
  end

  describe "replay/2" do
    test "a captured ID that appears in a request first is sent as it is and bound to itself" do
      state = replay(steps("route_method_put_task", "route_method_put_task"))
      id = "00000000-0000-0000-0000-000000000000"
      assert state.ids == %{id => id}
    end

    test "an ID bound to another value is sent with that value" do
      state = bind(new_state(), "00000000-0000-0000-0000-000000000000", @a)

      # The 404 names the path that was sent.
      replay(steps("route_method_put_task", "route_method_put_task"), state)
    end

    test "a response that differs from the fixture fails" do
      # The fixture's 404 message names the captured path; with the ID bound elsewhere it differs.
      state = bind(new_state(), "00000000-0000-0000-0000-000000000000", @a)

      assert_raise ExUnit.AssertionError, ~r/workflow_get_not_found/, fn ->
        replay(steps("workflow_get_not_found", "workflow_get_not_found"), state)
      end
    end
  end
end
