defmodule ArchonWeb.ContractCaseTest do
  @moduledoc """
  The replay helper itself (ADR 0023 decision 6, ADR 0025 decision 7): scenario coverage, the ID
  mapping, the step options and the skipping of Phase 6 actions not implemented yet.
  """

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
    for {step, index} <- Enum.with_index(scenario()), elem(step, 0) == :wait_status do
      start = elem(step, 1)
      start_index = Enum.find_index(scenario(), &(&1 == {:exchange, start}))
      assert start_index && start_index < index, start
    end
  end

  # ADR 0025, decision 7: the Phase 6 steps come after every MVP step.
  test "the Phase 6 steps come last" do
    first = Enum.find_index(scenario(), &(&1 == {:exchange, "metadata_register_ops_taskdefs"}))
    assert {:exchange, "workflow_get_options"} == Enum.at(scenario(), first - 1)
  end

  describe "skip?/1" do
    # A step that reaches an action still not implemented, the first of these in slice order
    # (ADR 0025, decision 8); slice 6h removes the skipping.
    @unimplemented_steps [
      {"workflow_rerun", ArchonWeb.WorkflowLifecycleController, :rerun},
      {"workflow_bulk_pause", ArchonWeb.WorkflowBulkController, :pause}
    ]

    defp unimplemented_step do
      Enum.find(@unimplemented_steps, fn {_name, controller, action} ->
        action in controller.unimplemented()
      end)
    end

    test "a step reaching an action its controller has not implemented is skipped" do
      if step = unimplemented_step() do
        {name, _controller, _action} = step
        assert skip?({:exchange, name})
      end

      refute :pause in ArchonWeb.WorkflowLifecycleController.unimplemented()
      refute skip?({:exchange, "workflow_pause"})
      refute skip?({:exchange, "workflow_get_paused"})
      refute skip?({:exchange, "route_unsupported_workflow_decide", expect: :no_route})
    end

    test "a step requiring an action not implemented yet is skipped, waits too" do
      if step = unimplemented_step() do
        {_name, controller, action} = step
        requires = [requires: [{controller, action}]]
        assert skip?({:exchange, "workflow_get_paused", requires})
        assert skip?({:wait_status, "workflow_start_life", "PAUSED", requires})
      end

      implemented = [requires: [{ArchonWeb.WorkflowLifecycleController, :pause}]]
      refute skip?({:exchange, "workflow_get_paused", implemented})
      refute skip?({:wait_status, "workflow_start_life", "RUNNING"})
      refute skip?({:exchange, "health", requires: [{ArchonWeb.HealthController, :check}]})
    end

    test "every requirement names a Phase 6 action of the router" do
      routes = MapSet.new(ArchonWeb.Router.__routes__(), &{&1.plug, &1.plug_opts})

      for step <- scenario(),
          opts = List.last(Tuple.to_list(step)),
          is_list(opts),
          action <- Keyword.get(opts, :requires, []) do
        assert action in routes, inspect(step)
      end
    end
  end

  test "until: repeats the request until the conditions hold" do
    replay([
      {:exchange, "health", until: [{["healthy"], true}, {["healthResults"], {:length, 0}}]}
    ])
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

    test "ignored paths may hold list indexes" do
      check(
        "t",
        fixture(%{"tasks" => [%{"pollCount" => 3}, %{"pollCount" => 1}]}),
        actual(%{"tasks" => [%{"pollCount" => 2}, %{"pollCount" => 1}]}),
        new_state(),
        ignore: [["tasks", 0, "pollCount"]]
      )
    end

    test "only: :expected_names keeps the names of a list of strings and of a map's keys" do
      opts = [only: :expected_names]
      check("t", fixture(["a", "b"]), actual(["a", "x", "b"]), new_state(), opts)
      check("t", fixture(%{"a" => [1]}), actual(%{"a" => [1], "x" => [2]}), new_state(), opts)

      check(
        "t",
        fixture([%{"name" => "a"}]),
        actual([%{"name" => "x"}, %{"name" => "a"}]),
        new_state(),
        opts
      )
    end

    test "only: :bound_ids keeps the workflows this replay bound" do
      state = bind(new_state(), @a, @b)
      opts = [only: :bound_ids]
      check("t", fixture([@a]), actual([@c, @b]), state, opts)

      check(
        "t",
        fixture([%{"workflowId" => @a}]),
        actual([%{"workflowId" => @c}, %{"workflowId" => @b}]),
        state,
        opts
      )

      check(
        "t",
        fixture(%{"k" => [%{"workflowId" => @a}]}),
        actual(%{"k" => [%{"workflowId" => @b}, %{"workflowId" => @c}]}),
        state,
        opts
      )

      assert_raise ExUnit.AssertionError, ~r/differs/, fn ->
        check("t", fixture([@a]), actual([@c]), state, opts)
      end
    end

    test "unordered: true compares lists without order and binds nothing" do
      state = new_state() |> bind(@a, @a) |> bind(@b, @b)
      opts = [unordered: true]
      assert check("t", fixture([@a, @b]), actual([@b, @a]), state, opts) == state
      check("t", fixture(%{"k" => [1, 2]}), actual(%{"k" => [2, 1]}), state, opts)

      # An ID no earlier step bound is not bound here: it differs.
      assert_raise ExUnit.AssertionError, ~r/differs/, fn ->
        check("t", fixture([@c]), actual([@b]), new_state(), opts)
      end

      assert_raise ExUnit.AssertionError, ~r/differs/, fn ->
        check("t", fixture([@a, @b]), actual([@a, @a]), state, opts)
      end
    end

    test "map keys holding captured IDs are compared with their bindings" do
      state = bind(new_state(), @a, @b)

      check(
        "t",
        fixture(%{"bulkErrorResults" => %{@a => "x"}, "bulkSuccessfulResults" => [@a]}),
        actual(%{"bulkErrorResults" => %{@b => "x"}, "bulkSuccessfulResults" => [@b]}),
        state
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
