# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.HttpRuntimeTest do
  @moduledoc """
  `HTTP` tasks in the running runtime (ADR 0026, decision 7): the workflow process hands the
  request to `Archon.Runtime.HttpTask` and takes its result by ID. The executor's three
  invariants: a request in flight is not sent again (a `:wake` meanwhile), a result reaches the
  process that replaced the one that asked, and a request whose result nothing takes (the task
  timed out, the workflow ended) is ended and gives its place back. A process with a request in
  flight is not evicted.
  """

  use Archon.RuntimeCase

  alias Archon.Domain.{Task, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.HttpTask

  @moduletag :capture_log

  defmodule Target do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, test: test) do
      send(test, {:target, conn.request_path})

      case conn.path_info do
        ["json"] ->
          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(200, ~s({"a":1}))

        ["sleep", ms] ->
          Process.sleep(String.to_integer(ms))

          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(200, ~s({"slept":true}))

        ["hang"] ->
          Process.sleep(60_000)
          send_resp(conn, 200, "")
      end
    end
  end

  setup do
    {:ok, pid} =
      Bandit.start_link(
        plug: {Target, test: self()},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    on_exit(fn -> Process.exit(pid, :shutdown) end)

    for async_complete <- [false, true] do
      :ok =
        Runtime.metadata().update_workflow_def(%WorkflowDef{
          name: "archon_http_#{async_complete}",
          version: 1,
          schema_version: 2,
          owner_email: "archon@example.com",
          tasks: [
            %WorkflowTask{
              name: "archon_http",
              task_reference_name: "http_ref",
              type: "HTTP",
              async_complete: async_complete,
              input_parameters: %{"http_request" => "${workflow.input.request}"}
            }
          ]
        })
    end

    %{url: "http://127.0.0.1:#{port}"}
  end

  defp start_http(url, path, async_complete \\ false) do
    {:ok, id} =
      Runtime.start_workflow(%{
        name: "archon_http_#{async_complete}",
        input: %{"request" => %{"uri" => url <> path, "method" => "GET"}}
      })

    id
  end

  defp status(id) do
    {:ok, workflow} = Runtime.get_workflow(id)
    workflow.status
  end

  defp put_settings(settings) do
    saved = Application.get_env(:archon, Archon.Runtime)
    Application.put_env(:archon, Archon.Runtime, Keyword.merge(saved, settings))
    on_exit(fn -> Application.put_env(:archon, Archon.Runtime, saved) end)
  end

  # Ends the process without its normal end (no terminate/2 with :normal), as a crash does, but
  # without counting toward the workflow supervisor's restart intensity.
  defp stop_abnormally(pid),
    do: :ok = DynamicSupervisor.terminate_child(Archon.Runtime.WorkflowSupervisor, pid)

  defp idle_executor, do: eventually(fn -> HttpTask.info() == %{running: [], waiting: []} end)

  test "a workflow's HTTP task completes with the response", %{url: url} do
    id = start_http(url, "/json")
    eventually(fn -> status(id) == :completed end)

    assert %Task{status: :completed, poll_count: 1, output_data: %{"response" => response}} =
             task(id, "http_ref")

    assert %{"statusCode" => 200, "body" => %{"a" => 1}, "reasonPhrase" => "OK"} = response
  end

  test "a wake while the request is in flight does not send it again", %{url: url} do
    id = start_http(url, "/sleep/300")
    assert_receive {:target, "/sleep/300"}, 2000
    pid = WorkflowServer.whereis(id)
    assert map_size(:sys.get_state(pid).http) == 1

    for _ <- 1..5, do: send(pid, :wake)
    send(pid, :recover)

    eventually(fn -> status(id) == :completed end)
    refute_received {:target, "/sleep/300"}
    assert task(id, "http_ref").poll_count == 1
  end

  test "a late result of another attempt leaves the attempt in flight", %{url: url} do
    id = start_http(url, "/hang")
    assert_receive {:target, "/hang"}, 2000
    pid = WorkflowServer.whereis(id)
    %Task{task_id: task_id, poll_count: 1, start_time: started} = task(id, "http_ref")
    assert %{^task_id => {1, ^started}} = :sys.get_state(pid).http

    stale = {:ok, %{status: 200, headers: [], body: "{}"}}
    assert :ok = WorkflowServer.http_completed(id, task_id, 1, started - 1, stale)

    assert %{^task_id => {1, ^started}} = :sys.get_state(pid).http
    assert %Task{status: :scheduled} = task(id, "http_ref")
    assert :ok = Runtime.terminate_workflow(id, "stop")
    idle_executor()
  end

  test "the result reaches the process that replaced the one that asked", %{url: url} do
    id = start_http(url, "/sleep/300")
    assert_receive {:target, "/sleep/300"}, 2000
    pid = WorkflowServer.whereis(id)
    stop_abnormally(pid)
    await_down(id)

    eventually(fn -> status(id) == :completed end)
    assert WorkflowServer.whereis(id) != pid

    assert %Task{
             status: :completed,
             output_data: %{"response" => %{"body" => %{"slept" => true}}}
           } =
             task(id, "http_ref")
  end

  test "at its response timeout the task times out and its request ends", %{url: url} do
    RuntimeHooks.install(clock: System.system_time(:millisecond))
    id = start_http(url, "/hang")
    assert_receive {:target, "/hang"}, 2000
    assert [_running] = HttpTask.info().running

    RuntimeHooks.advance(3_600_000)
    send(WorkflowServer.whereis(id), :wake)

    # A task that timed out ends its workflow TIMED_OUT, as upstream's decide does.
    eventually(fn -> status(id) == :timed_out end)

    assert %Task{
             status: :timed_out,
             reason_for_incompletion: "Task did not complete within its responseTimeout of 3600s"
           } = task(id, "http_ref")

    idle_executor()
  end

  test "a terminated workflow ends its request and gives its place back", %{url: url} do
    id = start_http(url, "/hang")
    assert_receive {:target, "/hang"}, 2000
    assert [_running] = HttpTask.info().running

    assert :ok = Runtime.terminate_workflow(id, "stop")
    assert %Task{status: :canceled} = task(id, "http_ref")
    idle_executor()
  end

  test "a removed workflow ends its request", %{url: url} do
    id = start_http(url, "/hang")
    assert_receive {:target, "/hang"}, 2000
    assert :ok = Runtime.terminate_workflow(id, "stop")
    assert :ok = WorkflowServer.remove(id, false)
    idle_executor()
  end

  test "a process activated after a crash cancels the request the old one sent", %{url: url} do
    id = start_http(url, "/hang")
    assert_receive {:target, "/hang"}, 2000
    stop_abnormally(WorkflowServer.whereis(id))
    await_down(id)

    assert :ok = Runtime.terminate_workflow(id, "stop")
    idle_executor()
  end

  test "a process with a request in flight is not evicted", %{url: url} do
    put_settings(evict_after: 1_000, hibernate_after: 20)
    id = start_http(url, "/sleep/400", true)
    assert_receive {:target, "/sleep/400"}, 2000
    pid = WorkflowServer.whereis(id)

    Process.sleep(200)
    assert WorkflowServer.whereis(id) == pid

    # The answer leaves the task IN_PROGRESS (asyncComplete) and the process may end.
    eventually(fn -> task(id, "http_ref").status == :in_progress end)
    await_down(id)
    assert status(id) == :running
  end
end
