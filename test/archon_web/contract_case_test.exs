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

    test "a request is sent with the bound values" do
      state = bind(new_state(), "00000000-0000-0000-0000-000000000000", @a)
      {_state, actual} = send_fixture(Contract.fixture("route_method_put_task"), state)
      assert actual.path == "/api/tasks/#{@a}"
      assert actual.body["message"] == "No static resource api/tasks/#{@a}."
    end
  end

  # In-memory exchanges: what the comparison accepts and rejects.
  describe "check/5" do
    defp fixture(body),
      do: %{
        "response" => %{"status" => 200, "content_type" => "application/json", "body" => body}
      }

    defp actual(body),
      do: %{status: 200, content_type: "application/json", body: body, path: "/x"}

    test "binds an ID at its first appearance and accepts the same structure" do
      state =
        check(
          "t",
          fixture(%{"workflowId" => @a, "tasks" => [%{"workflowInstanceId" => @a}]}),
          actual(%{"workflowId" => @b, "tasks" => [%{"workflowInstanceId" => @b}]}),
          new_state()
        )

      assert state.ids == %{@a => @b}
    end

    test "an ID that differs from its binding fails" do
      assert_raise ExUnit.AssertionError, ~r/differs/, fn ->
        check(
          "t",
          fixture(%{"workflowId" => @a, "parentWorkflowId" => @a}),
          actual(%{"workflowId" => @b, "parentWorkflowId" => @c}),
          new_state()
        )
      end
    end

    test "two captured IDs answered with one value fail" do
      assert_raise ExUnit.AssertionError, ~r/already bound/, fn ->
        check(
          "t",
          fixture(%{"workflowId" => @a, "taskId" => @c}),
          actual(%{"workflowId" => @b, "taskId" => @b}),
          new_state()
        )
      end
    end

    test "timestamps are masked but a 0 (not set) is kept" do
      check(
        "t",
        fixture(%{"startTime" => 1, "queueWaitTime" => 0}),
        actual(%{"startTime" => 2, "queueWaitTime" => 5}),
        new_state()
      )

      assert_raise ExUnit.AssertionError, ~r/differs/, fn ->
        check(
          "t",
          fixture(%{"endTime" => 0}),
          actual(%{"endTime" => 1_793_502_389_691}),
          new_state()
        )
      end
    end

    test "instance is compared as present or absent, validation errors without order" do
      errors = [%{"path" => "a", "message" => "x"}, %{"path" => "b", "message" => "y"}]

      check(
        "t",
        fixture(%{"instance" => "<redacted-hostname>", "validationErrors" => errors}),
        actual(%{"instance" => "host", "validationErrors" => Enum.reverse(errors)}),
        new_state()
      )

      assert_raise ExUnit.AssertionError, fn ->
        check(
          "t",
          fixture(%{"status" => 400}),
          actual(%{"status" => 400, "instance" => "host"}),
          new_state()
        )
      end
    end

    test "ignored keys are left out of both bodies" do
      opts = [ignore: [["message"]]]

      check(
        "t",
        fixture(%{"message" => "Jackson"}),
        actual(%{"message" => "Archon"}),
        new_state(),
        opts
      )
    end

    test "a no-route step binds nothing from upstream's body" do
      upstream = fixture(%{"results" => [%{"workflowId" => @a}]})

      no_route = %{
        status: 404,
        content_type: "application/json",
        path: "/api/workflow/search",
        body: %{
          "status" => 404,
          "message" => "No static resource api/workflow/search.",
          "instance" => "h",
          "retryable" => false
        }
      }

      assert check("t", upstream, no_route, new_state(), expect: :no_route) == new_state()
    end
  end
end
