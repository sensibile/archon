defmodule ArchonWeb.ContractCaseTest do
  @moduledoc """
  The replay helper itself (ADR 0023 decision 6, ADR 0025 decision 7, ADR 0026 decision 8): scenario coverage, the ID
  mapping, and the step options.
  """

  use ArchonWeb.ContractCase, async: true

  alias Archon.Contract
  alias Archon.Decider.Mapper

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

  test "until: repeats the request until the conditions hold" do
    replay([
      {:exchange, "health", until: [{["healthy"], true}, {["healthResults"], {:length, 0}}]}
    ])
  end

  # ADR 0026, decision 8: the Phase 7 steps come after every Phase 6 step, and every type they
  # use runs (slice 7h removed the skipping of steps whose type had no mapper yet).
  test "the Phase 7 steps come last" do
    first = Enum.find_index(scenario(), &(&1 == {:exchange, "p7_register_taskdefs"}))
    assert {:exchange, "metadata_get_taskdef_deleted"} == Enum.at(scenario(), first - 1)

    assert Enum.all?(Enum.drop(scenario(), first), &String.starts_with?(elem(&1, 1), "p7_"))
  end

  test "every Phase 7 task type has a mapper of its own" do
    types = ~w(TERMINATE SET_VARIABLE NOOP HUMAN EXCLUSIVE_JOIN DYNAMIC FORK_JOIN_DYNAMIC
               START_WORKFLOW INLINE LAMBDA JSON_JQ_TRANSFORM HTTP)

    assert Enum.filter(types, &(not Mapper.mapped?(&1))) == []
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

    test "the captured HTTP stub address is the replay's own" do
      captured = captured_http_stub()
      state = new_state(http_stub: "http://127.0.0.1:4242")

      check(
        "t",
        fixture(%{"uri" => "#{captured}/json", "message" => "for \"#{captured}/short/404\""}),
        actual(%{
          "uri" => "http://127.0.0.1:4242/json",
          "message" => "for \"http://127.0.0.1:4242/short/404\""
        }),
        state
      )

      assert_raise ExUnit.AssertionError, ~r/differs/, fn ->
        check(
          "t",
          fixture(%{"uri" => "#{captured}/json"}),
          actual(%{"uri" => "#{captured}/json"}),
          state
        )
      end
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

    test "an Archon expectation checks Archon's own answer and binds nothing" do
      upstream = %{"response" => %{"status" => 500, "content_type" => nil, "body" => nil}}
      answer = actual(%{"workflowId" => @b, "status" => "FAILED"})
      expect = {:archon, 200, [{["status"], "FAILED"}]}

      assert check("t", upstream, answer, new_state(), expect: expect) == new_state()

      assert_raise ExUnit.AssertionError, ~r/not the expected 200/, fn ->
        check("t", upstream, actual(%{"status" => "RUNNING"}), new_state(), expect: expect)
      end

      assert_raise ExUnit.AssertionError, ~r/not the expected 200/, fn ->
        check("t", upstream, %{answer | status: 500}, new_state(), expect: expect)
      end
    end

    test "a started step takes Archon's start for upstream's error and binds nothing" do
      upstream = %{
        "response" => %{
          "status" => 500,
          "content_type" => "application/json",
          "body" => %{"status" => 500, "message" => "class java.lang.Integer cannot be cast"}
        }
      }

      started = %{status: 200, content_type: "text/plain;charset=UTF-8", path: "/", body: @a}
      assert check("t", upstream, started, new_state(), expect: :started) == new_state()

      assert_raise ExUnit.AssertionError, ~r/not a start/, fn ->
        check("t", upstream, %{started | status: 500}, new_state(), expect: :started)
      end

      assert_raise ExUnit.AssertionError, ~r/not a start/, fn ->
        check("t", upstream, %{started | body: "error"}, new_state(), expect: :started)
      end
    end
  end
end
