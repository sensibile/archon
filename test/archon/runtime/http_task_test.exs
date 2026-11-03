# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.HttpTaskTest do
  @moduledoc """
  The `HTTP` task executor and its client (ADR 0026, decision 7) against a local target: the
  answers upstream's client would give, the timeouts, the body and total time limits, redirects
  and decompression, the concurrency limit, a request dropped past its deadline, and a request
  cancelled to give its place to the next.
  """

  use ExUnit.Case, async: false

  alias Archon.Runtime
  alias Archon.Runtime.HttpTask
  alias Archon.Runtime.HttpTask.Client

  @moduletag :capture_log

  # The target: each path one kind of answer.
  defmodule Target do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(conn, opts) do
      {:ok, _body, conn} = read_body(conn)
      record(opts, conn)

      answer(conn, conn.path_info)
    end

    defp answer(conn, ["json"]) do
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, ~s({"a":1}))
    end

    defp answer(conn, ["status", code]) do
      send_resp(conn, String.to_integer(code), "")
    end

    defp answer(conn, ["echo"]) do
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(
        200,
        Jason.encode!(%{method: conn.method, headers: Map.new(conn.req_headers)})
      )
    end

    defp answer(conn, ["hang"]) do
      Process.sleep(60_000)
      send_resp(conn, 200, "late")
    end

    defp answer(conn, ["sleep", ms]) do
      Process.sleep(String.to_integer(ms))
      send_resp(conn, 200, "slept")
    end

    # A byte every 50 ms, never done: each read is well within a read timeout.
    defp answer(conn, ["drip"]) do
      conn = send_chunked(conn, 200)
      drip(conn)
    end

    defp answer(conn, ["big", size]) do
      send_resp(conn, 200, String.duplicate("x", String.to_integer(size)))
    end

    defp answer(conn, ["gzip"]) do
      conn
      |> put_resp_header("content-encoding", "gzip")
      |> put_resp_header("content-type", "text/plain")
      |> send_resp(200, :zlib.gzip("unzipped body"))
    end

    defp answer(conn, ["members"]) do
      conn
      |> put_resp_header("content-encoding", "gzip")
      |> send_resp(200, :zlib.gzip("hello ") <> :zlib.gzip("world"))
    end

    # Two members of 1,000 zeros each: small compressed, 2,000 bytes decompressed.
    defp answer(conn, ["zeros"]) do
      member = :zlib.gzip(String.duplicate("0", 1000))

      conn
      |> put_resp_header("content-encoding", "gzip")
      |> send_resp(200, member <> member)
    end

    defp answer(conn, ["empty_first"]) do
      conn
      |> put_resp_header("content-encoding", "gzip")
      |> send_resp(200, :zlib.gzip("") <> :zlib.gzip("hello"))
    end

    defp answer(conn, ["bomb"]) do
      conn
      |> put_resp_header("content-encoding", "gzip")
      |> send_resp(200, :zlib.gzip(String.duplicate("0", 4096)))
    end

    defp answer(conn, ["redirect", "303"]) do
      conn |> put_resp_header("location", "/echo") |> send_resp(303, "")
    end

    defp answer(conn, ["redirect", "307"]) do
      conn |> put_resp_header("location", "/echo") |> send_resp(307, "")
    end

    # To the same port by IP address: another host name than localhost.
    defp answer(conn, ["away"]) do
      location = "http://127.0.0.1:#{conn.port}/echo"
      conn |> put_resp_header("location", location) |> send_resp(302, "")
    end

    defp answer(conn, ["away303"]) do
      location = "http://127.0.0.1:#{conn.port}/echo"
      conn |> put_resp_header("location", location) |> send_resp(303, "")
    end

    defp answer(conn, ["port"]) do
      conn |> put_resp_header("location", "http://127.0.0.1:9/echo") |> send_resp(302, "")
    end

    defp answer(conn, ["loop"]) do
      conn |> put_resp_header("location", "/loop") |> send_resp(302, "")
    end

    defp answer(conn, _other) do
      send_resp(conn, 404, "")
    end

    defp drip(conn) do
      Process.sleep(50)

      case chunk(conn, "x") do
        {:ok, conn} -> drip(conn)
        {:error, _closed} -> conn
      end
    end

    defp record(opts, conn) do
      with pid when is_pid(pid) <- Keyword.get(opts, :test) do
        send(pid, {:target, conn.method, conn.request_path})
      end
    end
  end

  setup do
    test = self()

    {:ok, pid} =
      Bandit.start_link(
        plug: {Target, test: test},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    on_exit(fn -> Process.exit(pid, :shutdown) end)
    %{url: "http://127.0.0.1:#{port}"}
  end

  defp request(url, fields \\ []) do
    Map.merge(
      %{
        method: "GET",
        uri: url,
        headers: [{"Content-Type", "application/json"}, {"Accept", "application/json"}],
        body: nil,
        connect_timeout: 3000,
        read_timeout: 3000,
        deadline: Runtime.now() + 3_600_000
      },
      Map.new(fields)
    )
  end

  @limits %{total_ms: 60_000, max_body: 10 * 1024 * 1024}

  describe "the client" do
    test "answers the status, the headers by lower-case name and the body", %{url: url} do
      assert {:ok, %{status: 200, headers: headers, body: ~s({"a":1})}} =
               Client.run(request(url <> "/json"), @limits)

      assert {"content-type", "application/json"} in headers
    end

    test "sends the method, the headers and upstream's Accept-Encoding", %{url: url} do
      request =
        request(url <> "/echo", method: "PUT", headers: [{"X-Archon", "1"}], body: "b")

      assert {:ok, %{status: 200, body: body}} = Client.run(request, @limits)
      assert %{"method" => "PUT", "headers" => headers} = Jason.decode!(body)
      assert headers["x-archon"] == "1"
      assert headers["accept-encoding"] == "gzip, x-gzip, deflate"
    end

    test "decompresses a gzip body and drops its coding headers", %{url: url} do
      assert {:ok, %{body: "unzipped body", headers: headers}} =
               Client.run(request(url <> "/gzip"), @limits)

      refute List.keymember?(headers, "content-encoding", 0)
      refute List.keymember?(headers, "content-length", 0)
    end

    test "decompresses every member of a gzip body", %{url: url} do
      assert {:ok, %{body: "hello world"}} = Client.run(request(url <> "/members"), @limits)
      assert {:ok, %{body: "hello"}} = Client.run(request(url <> "/empty_first"), @limits)

      # The decompressed limit counts every member.
      assert {:error, {:io, "Response body is larger than 1500 bytes"}} =
               Client.run(request(url <> "/zeros"), %{@limits | max_body: 1500})
    end

    test "refuses a body over the limit, read or decompressed", %{url: url} do
      limits = %{@limits | max_body: 1024}

      assert {:error, {:io, "Response body is larger than 1024 bytes"}} =
               Client.run(request(url <> "/big/2048"), limits)

      assert {:ok, %{body: body}} = Client.run(request(url <> "/big/1024"), limits)
      assert byte_size(body) == 1024

      assert {:error, {:io, "Response body is larger than 1024 bytes"}} =
               Client.run(request(url <> "/bomb"), limits)
    end

    test "a read that waits longer than readTimeOut is a read timeout", %{url: url} do
      assert {:error, {:io, "Read timed out"}} =
               Client.run(request(url <> "/sleep/500", read_timeout: 100), @limits)

      # 0 waits without a read limit.
      assert {:ok, %{body: "slept"}} =
               Client.run(request(url <> "/sleep/200", read_timeout: 0), @limits)
    end

    test "a target that sends a little at a time is cut at the total limit", %{url: url} do
      started = System.monotonic_time(:millisecond)

      assert {:error, {:io, "Request did not complete within its total time limit"}} =
               Client.run(request(url <> "/drip", read_timeout: 1000), %{@limits | total_ms: 400})

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 400 and elapsed < 2000
    end

    test "a send to a target that does not read ends at the total limit" do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, recbuf: 1024])

      {:ok, port} = :inet.port(listen)
      test = self()

      acceptor =
        spawn_link(fn ->
          # The socket stays open, unread, while the process lives.
          {:ok, _socket} = :gen_tcp.accept(listen)
          send(test, :accepted)
          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(acceptor, :kill) end)
      body = String.duplicate("x", 32 * 1024 * 1024)
      request = request("http://127.0.0.1:#{port}/", method: "POST", body: body)

      started = System.monotonic_time(:millisecond)

      assert {:error, {:io, "Request did not complete within its total time limit"}} =
               Client.run(request, %{@limits | total_ms: 300})

      assert System.monotonic_time(:millisecond) - started < 2000
      assert_received :accepted
    end

    test "user Accept-Encoding is not doubled", %{url: url} do
      request = request(url <> "/echo", headers: [{"accept-encoding", "identity"}])
      assert {:ok, %{body: body}} = Client.run(request, @limits)
      assert Jason.decode!(body)["headers"]["accept-encoding"] == "identity"
    end

    test "a refused connection has upstream's message" do
      assert {:error,
              {:io, "Connect to http://127.0.0.1:9 failed: Connection refused (connect failed)"}} =
               Client.run(request("http://127.0.0.1:9/json"), @limits)
    end

    test "follows redirects as Apache HttpClient: 303 as a GET, 307 as it was", %{url: url} do
      post = request(url <> "/redirect/303", method: "POST", body: "{}")
      assert {:ok, %{status: 200, body: body}} = Client.run(post, @limits)
      assert %{"method" => "GET"} = Jason.decode!(body)
      assert_received {:target, "POST", "/redirect/303"}
      assert_received {:target, "GET", "/echo"}

      put = request(url <> "/redirect/307", method: "PUT", body: "{}")
      assert {:ok, %{body: body}} = Client.run(put, @limits)
      assert %{"method" => "PUT"} = Jason.decode!(body)
    end

    test "a request with credentials is not redirected to another host", %{url: url} do
      other = String.replace(url, "127.0.0.1", "localhost")

      # The same host and port: followed.
      for name <- ["Authorization", "cookie"] do
        request = request(url <> "/redirect/307", headers: [{name, "secret"}])
        assert {:ok, %{status: 200}} = Client.run(request, @limits)
        assert_received {:target, "GET", "/echo"}
      end

      # The same request to the other name of the host gets the redirect as its response.
      request = request(other <> "/away", headers: [{"Authorization", "secret"}])
      assert {:ok, %{status: 302}} = Client.run(request, @limits)
      refute_received {:target, _method, "/echo"}

      # Another port of the same host is another authority too.
      request = request(url <> "/port", headers: [{"Cookie", "c"}])
      assert {:ok, %{status: 302}} = Client.run(request, @limits)
    end

    test "a 303 after a POST is a new GET without the headers, so credentials do not stop it",
         %{url: url} do
      other = String.replace(url, "127.0.0.1", "localhost")

      post =
        request(other <> "/away303",
          method: "POST",
          body: "{}",
          headers: [{"Authorization", "s"}]
        )

      assert {:ok, %{status: 200, body: body}} = Client.run(post, @limits)
      assert %{"method" => "GET", "headers" => headers} = Jason.decode!(body)
      refute Map.has_key?(headers, "authorization")
      refute Map.has_key?(headers, "content-type")
    end

    test "a redirect to a location already visited is circular", %{url: url} do
      assert {:error, {:io, "Circular redirect to '" <> location}} =
               Client.run(request(url <> "/loop"), @limits)

      assert location == url <> "/loop'"
    end

    test "a URI that is not http or https is refused" do
      assert {:error, {:io, "ftp protocol is not supported"}} =
               Client.run(request("ftp://127.0.0.1/x"), @limits)
    end
  end

  describe "the executor" do
    setup do
      test = self()
      config = Application.get_env(:archon, HttpTask, [])
      deliver = {__MODULE__, :forward, [test]}
      Application.put_env(:archon, HttpTask, Keyword.put(config, :deliver, deliver))

      on_exit(fn ->
        Application.put_env(:archon, HttpTask, config)
        restart_executor()
      end)

      :ok
    end

    test "delivers the result by workflow, task and attempt", %{url: url} do
      :ok = HttpTask.request("wf-1", "task-1", 3, request(url <> "/json"))
      assert_receive {:delivered, "wf-1", "task-1", 3, {:ok, %{status: 200}}}, 2000
      assert HttpTask.info() == %{running: [], waiting: []}
    end

    test "sends at most max_concurrency requests at once, the others in order", %{url: url} do
      with_max_concurrency(1)
      :ok = HttpTask.request("wf-1", "a", 1, request(url <> "/sleep/300"))
      :ok = HttpTask.request("wf-1", "b", 1, request(url <> "/json"))

      assert %{running: [{"wf-1", "a"}], waiting: [{"wf-1", "b"}]} = HttpTask.info()
      assert_receive {:delivered, "wf-1", "a", 1, {:ok, %{body: "slept"}}}, 2000
      assert_receive {:delivered, "wf-1", "b", 1, {:ok, %{status: 200}}}, 2000
    end

    test "a cancelled request gives its place to the next, and is not delivered", %{url: url} do
      with_max_concurrency(1)
      :ok = HttpTask.request("wf-1", "a", 1, request(url <> "/hang"))
      :ok = HttpTask.request("wf-1", "b", 1, request(url <> "/json"))
      assert_receive {:target, "GET", "/hang"}, 2000

      :ok = HttpTask.cancel("wf-1", "a")
      assert_receive {:delivered, "wf-1", "b", 1, {:ok, %{status: 200}}}, 2000
      refute_receive {:delivered, "wf-1", "a", _poll_count, _result}, 200
    end

    test "a waiting request cancelled is never sent", %{url: url} do
      with_max_concurrency(1)
      :ok = HttpTask.request("wf-1", "a", 1, request(url <> "/sleep/200"))
      :ok = HttpTask.request("wf-1", "b", 1, request(url <> "/echo"))
      :ok = HttpTask.cancel("wf-1", "b")

      assert_receive {:delivered, "wf-1", "a", 1, _result}, 2000
      refute_receive {:target, _method, "/echo"}, 200
      assert HttpTask.info() == %{running: [], waiting: []}
    end

    test "a waiting request replaced again is sent once, as the newest", %{url: url} do
      with_max_concurrency(1)
      :ok = HttpTask.request("wf-1", "a", 1, request(url <> "/sleep/200"))
      :ok = HttpTask.request("wf-1", "b", 1, request(url <> "/json"))
      :ok = HttpTask.request("wf-1", "b", 2, request(url <> "/json"))

      assert_receive {:delivered, "wf-1", "b", 2, {:ok, %{status: 200}}}, 2000
      refute_received {:delivered, "wf-1", "b", 1, _result}
    end

    test "a new request of the same task replaces the one in flight", %{url: url} do
      :ok = HttpTask.request("wf-1", "a", 1, request(url <> "/hang"))
      assert_receive {:target, "GET", "/hang"}, 2000
      :ok = HttpTask.request("wf-1", "a", 2, request(url <> "/json"))

      assert_receive {:delivered, "wf-1", "a", 2, {:ok, %{status: 200}}}, 2000
      refute_receive {:delivered, "wf-1", "a", 1, _result}, 200
    end

    test "a waiting request past its task's deadline is dropped unsent", %{url: url} do
      with_max_concurrency(1)
      :ok = HttpTask.request("wf-1", "a", 1, request(url <> "/sleep/200"))
      late = request(url <> "/echo", deadline: Runtime.now() + 100)
      :ok = HttpTask.request("wf-1", "b", 1, late)

      assert_receive {:delivered, "wf-1", "a", 1, _result}, 2000
      refute_receive {:delivered, "wf-1", "b", _poll_count, _result}, 200
      refute_received {:target, _method, "/echo"}
    end

    test "a request task that crashes is delivered as an I/O error", %{url: url} do
      broken = Map.delete(request(url <> "/json"), :headers)
      :ok = HttpTask.request("wf-1", "a", 1, broken)
      assert_receive {:delivered, "wf-1", "a", 1, {:error, {:io, _cause}}}, 2000
      assert HttpTask.info() == %{running: [], waiting: []}
    end

    test "a delivery that fails is tried again; a workflow that is gone stops it", %{url: url} do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      config = Application.get_env(:archon, HttpTask, [])
      deliver = {__MODULE__, :flaky, [self(), attempts]}
      Application.put_env(:archon, HttpTask, Keyword.put(config, :deliver, deliver))

      :ok = HttpTask.request("wf-1", "a", 1, request(url <> "/json"))
      assert_receive {:delivered, "wf-1", "a", 1, {:ok, %{status: 200}}}, 2000
      assert Agent.get(attempts, & &1) == 3

      :ok = HttpTask.request("gone", "a", 1, request(url <> "/json"))
      assert_receive {:not_found, "gone"}, 2000
      refute_receive {:not_found, "gone"}, 300
    end

    test "a request the client does not end is ended a second after the total limit", %{url: url} do
      config = Application.get_env(:archon, HttpTask, [])

      Application.put_env(
        :archon,
        HttpTask,
        Keyword.merge(config, client: __MODULE__.Stuck, max_request_ms: 100, max_concurrency: 1)
      )

      restart_executor()
      :ok = HttpTask.request("wf-1", "a", 1, request(url <> "/json"))
      :ok = HttpTask.request("wf-1", "b", 1, request(url <> "/json"))

      assert_receive {:delivered, "wf-1", "a", 1,
                      {:error, {:io, "Request did not complete within its total time limit"}}},
                     3000

      # The place went to the next request.
      assert %{running: [{"wf-1", "b"}]} = HttpTask.info()
      :ok = HttpTask.cancel("wf-1", "b")
      assert HttpTask.info() == %{running: [], waiting: []}
    end

    test "a request ends at the total limit, never past the task's deadline", %{url: url} do
      :ok =
        HttpTask.request("wf-1", "a", 1, request(url <> "/drip", deadline: Runtime.now() + 300))

      assert_receive {:delivered, "wf-1", "a", 1,
                      {:error, {:io, "Request did not complete within its total time limit"}}},
                     2000
    end
  end

  defmodule Stuck do
    @moduledoc false
    # A client that never ends, whatever its limits.
    def run(_request, _limits), do: Process.sleep(:infinity)
  end

  @doc false
  def forward(test, workflow_id, task_id, poll_count, result),
    do: send(test, {:delivered, workflow_id, task_id, poll_count, result})

  @doc false
  # Fails twice with what a busy process answers, then takes the result; "gone" is not found.
  def flaky(test, _attempts, "gone", _task_id, _poll_count, _result) do
    send(test, {:not_found, "gone"})
    {:error, :not_found}
  end

  def flaky(test, attempts, workflow_id, task_id, poll_count, result) do
    case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
      n when n < 3 -> {:error, {:exit, :timeout}}
      _n -> forward(test, workflow_id, task_id, poll_count, result)
    end
  end

  defp with_max_concurrency(max) do
    config = Application.get_env(:archon, HttpTask, [])
    Application.put_env(:archon, HttpTask, Keyword.put(config, :max_concurrency, max))
    restart_executor()
  end

  # The executor with the requests' supervisor, as a crash of either restarts them (manually, so
  # the restarts do not count toward the supervisor's restart intensity).
  defp restart_executor do
    :ok = Supervisor.terminate_child(HttpTask.Supervisor, :requests)
    {:ok, _pid} = Supervisor.restart_child(HttpTask.Supervisor, :requests)
  end
end
