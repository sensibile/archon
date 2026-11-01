# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule ArchonWeb.ContractCase do
  @moduledoc """
  Replays the golden fixtures (`test/fixtures/contract/`) against `ArchonWeb.Endpoint` through
  `Phoenix.ConnTest` and compares Archon's answers with upstream's (ADR 0023, decision 6).

  ## Scenario

  The fixture files carry no order, and the capture script waits and repeats requests it does
  not save. `scenario/0` is that order in code, step for step with
  `scripts/contract/capture_fixtures.sh`:

    * `{:exchange, name}` or `{:exchange, name, opts}` - send the fixture's request, compare the
      response.
    * `{:poll_until, name}` - repeat the request until it answers 200 (a task arrived), then
      compare the last answer.
    * `{:batch_poll_until, name}` - repeat until the answer is a non-empty list.
    * `{:wait_status, name, status}` - wait until the workflow whose ID fixture `name` answered
      (a start's text body) reaches `status`. It reads `Archon.Runtime` directly, as the script's
      wait is not a fixture.

  A fixture request body is sent as JSON, except a string, which is sent as the raw text it holds
  (the capture script stores a body that is not JSON as a string; no fixture sends a JSON string).

  Exchange options record the deliberate differences from upstream:

    * `expect: :no_route` - Archon answers the 404 of a path without a handler instead of the
      fixture's response (Later routes, and an MVP path with another method, where upstream
      answers 405; ADR 0023, decision 2).
    * `ignore: [path]` - leave out these key paths (lists of keys) of both bodies, for a message
      Archon cannot reproduce (Jackson's parse errors).
    * `only: :expected_names` - keep only the elements of Archon's list body whose `name` is a
      name in the fixture's list, for a list of definitions the shared runtime also holds other
      tests' definitions in (`metadata_list_taskdefs`).

  `steps/2` cuts a part of the scenario. Run them with `replay/2`, threading the state from one
  call to the next.

  ## Generated IDs

  The state maps each captured UUID to the value Archon generated. A captured UUID is bound the
  first time it shows up in a response, to the value at the same place in Archon's response. A
  captured UUID that shows up in a request first (an unknown ID such as `00000000-...`) is sent
  unchanged and bound to itself. The mapping is one-to-one: a step fails when a captured UUID
  would be bound to a value already bound to another one. Requests are sent with the bound
  values, and expected bodies are compared after replacing the captured UUIDs with them.

  Prerequisites a slice sets up without replaying (a workflow started through `Archon.Runtime`)
  are bound with `bind/3`.

  ## Comparison

  Status, `Content-Type` and body are compared after masking only the timestamp keys
  (`Archon.Contract.mask_times/1`, not `normalize/1`, which masks UUIDs too; a `0` timestamp is
  kept), so an ID that does not match its binding fails. `instance` (the host) is compared as present or absent, and
  `validationErrors` without order (Hibernate reports violations in no defined order). A response
  of a fixture listed in `Archon.Contract.fixture_schemas/0` is also checked against its schema.

  Fixtures depend on the state earlier steps left, as the capture ran on an empty server. The
  runtime under test is shared with other tests, so a test replaying a list response (such as
  `metadata_list_taskdefs`) has to keep other tests' definitions out of it (`only:`), and a test
  replaying registrations has to remove the fixtures' definitions other tests stored first.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Archon.Contract
  alias Archon.Domain.Codec

  @endpoint ArchonWeb.Endpoint

  # Polls and waits give up after 10 s.
  @deadline_ms 10_000
  @attempts 400
  @attempt_ms 25

  @type exchange_opts :: [expect: :no_route, ignore: [[String.t()]], only: :expected_names]
  @type step ::
          {:exchange, String.t()}
          | {:exchange, String.t(), exchange_opts()}
          | {:poll_until, String.t()}
          | {:batch_poll_until, String.t()}
          | {:wait_status, String.t(), String.t()}

  @type state :: %{ids: %{String.t() => String.t()}, actuals: %{String.t() => String.t()}}

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import ArchonWeb.ContractCase

      @endpoint ArchonWeb.Endpoint
    end
  end

  # Deliberate differences from the captured responses (see the moduledoc).
  @no_route [expect: :no_route]
  @jackson_message [ignore: [["message"]]]
  @expected_names [only: :expected_names]

  @scenario [
    # metadata
    {:exchange, "metadata_register_taskdefs"},
    {:exchange, "metadata_get_taskdef"},
    {:exchange, "metadata_get_taskdef_not_found"},
    {:exchange, "metadata_register_workflow_simple"},
    {:exchange, "metadata_register_workflow_switch"},
    {:exchange, "metadata_register_workflow_fork"},
    {:exchange, "metadata_register_workflow_conflict"},
    {:exchange, "metadata_get_workflow"},
    {:exchange, "metadata_get_workflow_switch"},
    {:exchange, "metadata_get_workflow_fork"},
    {:exchange, "metadata_get_workflow_not_found"},
    # SIMPLE: start, poll, update, complete
    {:exchange, "workflow_start_simple"},
    {:poll_until, "task_poll_simple_a"},
    {:exchange, "workflow_get_running"},
    {:exchange, "task_update_simple_a"},
    {:poll_until, "task_poll_simple_b"},
    {:exchange, "task_update_v2_simple_b"},
    {:wait_status, "workflow_start_simple", "COMPLETED"},
    {:exchange, "workflow_get_completed_simple"},
    {:exchange, "workflow_get_without_tasks"},
    {:exchange, "workflow_get_status"},
    {:exchange, "task_get"},
    {:exchange, "task_poll_empty"},
    # SWITCH: start with StartWorkflowRequest
    {:exchange, "workflow_start_request_switch"},
    {:poll_until, "task_poll_switch_b"},
    {:exchange, "task_update_switch_b"},
    {:wait_status, "workflow_start_request_switch", "COMPLETED"},
    {:exchange, "workflow_get_completed_switch"},
    # FORK_JOIN / JOIN
    {:exchange, "workflow_start_fork"},
    {:batch_poll_until, "task_batch_poll_fork_a"},
    {:exchange, "task_update_fork_a"},
    {:poll_until, "task_poll_fork_b"},
    {:exchange, "task_update_fork_b"},
    {:wait_status, "workflow_start_fork", "COMPLETED"},
    {:exchange, "workflow_get_completed_fork"},
    # terminate
    {:exchange, "workflow_start_to_terminate"},
    {:exchange, "workflow_terminate"},
    {:exchange, "workflow_get_terminated"},
    {:exchange, "workflow_get_not_found"},
    # health
    {:exchange, "health"},
    {:exchange, "health_api"},
    # metadata: list, single update, overwrite, bulk update, validation
    {:exchange, "metadata_list_taskdefs", @expected_names},
    {:exchange, "metadata_register_taskdefs_single"},
    {:exchange, "metadata_update_taskdef"},
    {:exchange, "metadata_get_taskdef_updated"},
    {:exchange, "metadata_update_taskdef_not_found"},
    {:exchange, "metadata_register_taskdefs_empty"},
    {:exchange, "metadata_register_taskdefs_no_name"},
    {:exchange, "metadata_register_taskdefs_blank_name"},
    {:exchange, "metadata_register_taskdefs_coerced"},
    {:exchange, "metadata_register_workflow_no_tasks"},
    {:exchange, "metadata_register_workflow_overwrite"},
    {:exchange, "metadata_get_workflow_overwritten"},
    {:exchange, "metadata_get_workflow_version_not_found"},
    {:exchange, "metadata_update_workflows"},
    {:exchange, "metadata_get_workflow_bulk_latest"},
    {:exchange, "metadata_update_workflows_invalid"},
    {:exchange, "metadata_get_workflow_bulk_rejected"},
    {:exchange, "metadata_update_workflows_empty"},
    # workflow: start errors, inline definition, fetch options, terminate errors
    {:exchange, "workflow_start_not_found"},
    {:exchange, "workflow_start_request_not_found"},
    {:exchange, "workflow_start_inline"},
    {:exchange, "workflow_get_running_without_tasks"},
    {:exchange, "workflow_get_status_default"},
    {:exchange, "workflow_get_status_all"},
    {:exchange, "workflow_get_status_not_found"},
    {:exchange, "workflow_start_inline_second"},
    {:poll_until, "task_poll_inline_c"},
    {:exchange, "workflow_get_inline"},
    {:exchange, "task_update_v2_next"},
    {:wait_status, "workflow_start_inline", "COMPLETED"},
    {:exchange, "workflow_terminate_completed"},
    {:exchange, "workflow_terminate_not_found"},
    # task: empty batch, unknown task, validation
    {:exchange, "task_batch_poll_empty"},
    {:exchange, "task_get_not_found"},
    {:exchange, "task_update_not_found"},
    {:exchange, "task_update_workflow_not_found"},
    {:exchange, "task_update_v2_not_found"},
    {:exchange, "task_update_invalid"},
    {:exchange, "task_update_v2_invalid"},
    # routing: unknown path, Later paths shaped like MVP parameter paths, other methods, bad input
    {:exchange, "route_not_found"},
    {:exchange, "route_later_workflow_search", @no_route},
    {:exchange, "route_later_workflow_running", @no_route},
    {:exchange, "route_later_workflow_test", @no_route},
    {:exchange, "route_later_metadata_names", @no_route},
    {:exchange, "route_later_tasks_search", @no_route},
    {:exchange, "route_method_patch_workflow", @no_route},
    {:exchange, "route_method_put_task", @no_route},
    {:exchange, "request_body_not_json", @jackson_message},
    {:exchange, "request_query_not_number"},
    {:exchange, "request_query_not_boolean"}
  ]

  @doc "Every captured exchange in capture order, with the waits between them."
  @spec scenario() :: [step()]
  def scenario, do: @scenario

  @doc """
  The steps of `scenario/0` from fixture `first` through fixture `last`, both included (a
  `:wait_status` step is found by the start fixture it names).
  """
  @spec steps(String.t(), String.t()) :: [step()]
  def steps(first, last) do
    from = index!(first)
    through = index!(last)
    true = from <= through
    Enum.slice(@scenario, from..through)
  end

  defp index!(name) do
    Enum.find_index(@scenario, &(elem(&1, 1) == name)) ||
      raise ArgumentError, "no step for fixture #{inspect(name)}"
  end

  @doc "An empty ID mapping."
  @spec new_state() :: state()
  def new_state, do: %{ids: %{}, actuals: %{}}

  @doc "Binds captured UUID `captured` to `actual`, one-to-one (see the moduledoc)."
  @spec bind(state(), String.t(), String.t()) :: state()
  def bind(state, captured, actual) do
    case state.ids do
      %{^captured => ^actual} ->
        state

      %{^captured => bound} ->
        flunk("captured ID #{captured} is bound to #{bound}, not #{actual}")

      _unbound ->
        case state.actuals do
          %{^actual => other} ->
            flunk("#{actual} is already bound to captured ID #{other}, not to #{captured}")

          _free ->
            %{
              state
              | ids: Map.put(state.ids, captured, actual),
                actuals: Map.put(state.actuals, actual, captured)
            }
        end
    end
  end

  @doc "Replays `steps`, asserting every response; returns the ID mapping for the next steps."
  @spec replay([step()], state()) :: state()
  def replay(steps, state \\ new_state()), do: Enum.reduce(steps, state, &run/2)

  defp run({:exchange, name}, state), do: run({:exchange, name, []}, state)

  defp run({:exchange, name, opts}, state) do
    fixture = Contract.fixture(name)
    {state, actual} = send_fixture(fixture, state)
    check(name, fixture, actual, state, opts)
  end

  defp run({:poll_until, name}, state),
    do: repeat(name, state, fn actual -> actual.status == 200 end)

  defp run({:batch_poll_until, name}, state),
    do: repeat(name, state, fn actual -> match?([_ | _], actual.body) end)

  defp run({:wait_status, name, status}, state) do
    %{"response" => %{"body" => captured}} = Contract.fixture(name)

    case Map.fetch(state.ids, captured) do
      {:ok, id} -> wait_status(name, id, status, @attempts)
      :error -> flunk("#{name}: the started workflow's ID #{captured} was never bound")
    end

    state
  end

  defp repeat(name, state, done?) do
    fixture = Contract.fixture(name)

    actual =
      repeat_until(fixture, state, done?, System.monotonic_time(:millisecond) + @deadline_ms)

    {state, _actual} = prepare_request(fixture["request"], state)
    check(name, fixture, actual, state, [])
  end

  # The deadline counts the requests' own time (a poll can wait for its timeout).
  defp repeat_until(fixture, state, done?, deadline) do
    {_state, actual} = send_fixture(fixture, state)

    if done?.(actual) or System.monotonic_time(:millisecond) >= deadline do
      actual
    else
      Process.sleep(@attempt_ms)
      repeat_until(fixture, state, done?, deadline)
    end
  end

  defp wait_status(name, id, status, 0),
    do: flunk("#{name}: workflow #{id} did not reach #{status}")

  defp wait_status(name, id, status, attempts) do
    case Archon.Runtime.get_workflow(id, false) do
      {:ok, workflow} ->
        if Codec.enum_name(workflow.status) == status do
          :ok
        else
          Process.sleep(@attempt_ms)
          wait_status(name, id, status, attempts - 1)
        end

      {:error, reason} ->
        flunk("#{name}: workflow #{id} cannot be read: #{inspect(reason)}")
    end
  end

  # --- request ---------------------------------------------------------------------------------

  @doc false
  # Sends a fixture's request with the bound IDs (public for the helper's own tests).
  @spec send_fixture(map(), state()) :: {state(), map()}
  def send_fixture(fixture, state) do
    {state, request} = prepare_request(fixture["request"], state)
    {state, dispatch(request)}
  end

  defp prepare_request(%{"method" => method, "path" => path, "body" => body}, state) do
    {state, path} = request_ids(path, state)
    {state, body} = request_ids(body, state)
    {state, %{method: method, path: path, body: body}}
  end

  # A captured ID that is not bound yet appears first in a request: it is sent as it is.
  defp request_ids(string, state) when is_binary(string) do
    state =
      Contract.uuid_regex()
      |> Regex.scan(string)
      |> List.flatten()
      |> Enum.reduce(state, fn id, state ->
        if Map.has_key?(state.ids, id), do: state, else: bind(state, id, id)
      end)

    {state, substitute(string, state)}
  end

  defp request_ids(list, state) when is_list(list) do
    {items, state} =
      Enum.map_reduce(list, state, fn item, state -> swap(request_ids(item, state)) end)

    {state, items}
  end

  defp request_ids(map, state) when is_map(map) do
    {pairs, state} =
      Enum.map_reduce(map, state, fn {key, value}, state ->
        {state, value} = request_ids(value, state)
        {{key, value}, state}
      end)

    {state, Map.new(pairs)}
  end

  defp request_ids(other, state), do: {state, other}

  defp swap({state, value}), do: {value, state}

  defp dispatch(%{method: method, path: path, body: body}) do
    conn = Phoenix.ConnTest.build_conn()

    conn =
      case body do
        nil ->
          Phoenix.ConnTest.dispatch(conn, @endpoint, method, path, nil)

        body ->
          raw = if is_binary(body), do: body, else: JSON.encode!(body)

          conn
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(@endpoint, method, path, raw)
      end

    content_type = conn |> Plug.Conn.get_resp_header("content-type") |> List.first()
    body = response_body(conn.resp_body, content_type)

    %{status: conn.status, content_type: content_type, body: body, path: path}
  end

  defp response_body(body, _content_type) when body in [nil, ""], do: nil

  defp response_body(body, content_type) do
    if String.starts_with?(content_type || "", "application/json"),
      do: JSON.decode!(body),
      else: body
  end

  # --- response --------------------------------------------------------------------------------

  @doc false
  # Compares one response with a fixture (public for the helper's own tests): `actual` is
  # `%{status:, content_type:, body:, path:}`.
  @spec check(String.t(), map(), map(), state(), exchange_opts()) :: state()
  def check(name, fixture, actual, state, opts \\ []) do
    expected = fixture["response"]

    case Keyword.get(opts, :expect) do
      # Upstream's answer has nothing to do with Archon's 404: no ID is bound from it.
      :no_route ->
        assert_no_route(name, actual)
        state

      nil ->
        actual = only(actual, expected["body"], Keyword.get(opts, :only))
        state = bind_response(expected["body"], actual.body, state)
        assert_same(name, expected, actual, state, Keyword.get(opts, :ignore, []))
        state
    end
  end

  defp only(actual, expected, :expected_names) when is_list(expected) and is_list(actual.body) do
    names = MapSet.new(expected, & &1["name"])
    %{actual | body: Enum.filter(actual.body, &(&1["name"] in names))}
  end

  # Not a list (an error): left for the comparison to report.
  defp only(actual, _expected, _only), do: actual

  defp assert_no_route(name, actual) do
    "/" <> path = actual.path |> URI.parse() |> Map.fetch!(:path)

    assert %{status: 404, content_type: "application/json"} = actual, "#{name}: not a 404"

    assert %{
             "status" => 404,
             "message" => "No static resource " <> ^path <> ".",
             "instance" => instance,
             "retryable" => false
           } = actual.body,
           "#{name}: #{inspect(actual.body)}"

    assert is_binary(instance)
  end

  defp assert_same(name, expected, actual, state, ignore) do
    want = %{
      status: expected["status"],
      content_type: expected["content_type"],
      body: comparable(substitute(expected["body"], state), ignore)
    }

    got = %{
      status: actual.status,
      content_type: actual.content_type,
      body: comparable(actual.body, ignore)
    }

    assert got == want, "#{name}: Archon's response differs from the fixture"

    case Contract.fixture_schemas() do
      %{^name => {:response, schema}} ->
        assert Contract.validate_schema(schema, actual.body) == :ok, "#{name}: schema"

      _other ->
        :ok
    end
  end

  defp comparable(body, ignore) do
    body
    |> Contract.mask_times()
    |> drop_paths(ignore)
    |> mask_error()
  end

  defp drop_paths(body, paths) when is_map(body) do
    Enum.reduce(paths, body, fn path, body ->
      {_value, body} = pop_in(body, Enum.map(path, &Access.key(&1)))
      body
    end)
  end

  defp drop_paths(body, _paths), do: body

  defp mask_error(body) when is_map(body) do
    body = if Map.has_key?(body, "instance"), do: %{body | "instance" => "<host>"}, else: body

    case body do
      %{"validationErrors" => errors} when is_list(errors) ->
        %{body | "validationErrors" => Enum.sort(errors)}

      body ->
        body
    end
  end

  defp mask_error(body), do: body

  defp bind_response(expected, actual, state) when is_binary(expected) and is_binary(actual) do
    captured = expected |> scan_ids()
    produced = actual |> scan_ids()

    if length(captured) == length(produced) do
      captured |> Enum.zip(produced) |> Enum.reduce(state, &bind_new/2)
    else
      state
    end
  end

  defp bind_response(expected, actual, state) when is_list(expected) and is_list(actual) do
    expected
    |> Enum.zip(actual)
    |> Enum.reduce(state, fn {expected, actual}, state ->
      bind_response(expected, actual, state)
    end)
  end

  defp bind_response(expected, actual, state) when is_map(expected) and is_map(actual) do
    Enum.reduce(expected, state, fn {key, value}, state ->
      case actual do
        %{^key => produced} -> bind_response(value, produced, state)
        _missing -> state
      end
    end)
  end

  defp bind_response(_expected, _actual, state), do: state

  # Only the first appearance binds; a later mismatch is the comparison's to report.
  defp bind_new({captured, produced}, state) do
    if Map.has_key?(state.ids, captured), do: state, else: bind(state, captured, produced)
  end

  defp scan_ids(string), do: Contract.uuid_regex() |> Regex.scan(string) |> List.flatten()

  defp substitute(string, state) when is_binary(string),
    do: Regex.replace(Contract.uuid_regex(), string, &Map.get(state.ids, &1, &1))

  defp substitute(list, state) when is_list(list), do: Enum.map(list, &substitute(&1, state))

  defp substitute(map, state) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, substitute(value, state)} end)

  defp substitute(other, _state), do: other
end
