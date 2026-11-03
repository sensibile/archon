# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Cases derived from conductor-oss http-task/src/test/java/com/netflix/conductor/tasks/http/HttpTaskTest.java
# and core/src/test/java/com/netflix/conductor/core/execution/mapper/HTTPTaskMapperTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the request is an effect of the workflow's step and the response an
# event (ADR 0026, decision 7), so the cases run the step with the result the executor would
# give instead of a mock server.

defmodule Archon.Runtime.Step.HttpTest do
  @moduledoc """
  `HTTP` through `Archon.Runtime.Step.run/3` (ADR 0026, decision 7): the mapper and its change to
  the definition, the request the start reads, the response it turns into the task's result,
  the started task the passes leave alone until its response timeout, and the result's attempt.
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay, only: [apply_commit: 2]

  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.{Env, Http, Postpone}

  @now 1_000_000
  @hour 3_600_000

  defp env(now, opts \\ []) do
    counter = :counters.new(1, [])

    [
      now: now,
      new_id: fn ->
        :counters.add(counter, 1, 1)
        "id-#{now}-#{:counters.get(counter, 1)}"
      end
    ]
    |> Keyword.merge(opts)
    |> Env.new()
  end

  defp http_task(fields \\ []) do
    struct!(
      %WorkflowTask{
        name: "http",
        task_reference_name: "http_ref",
        type: "HTTP",
        input_parameters: %{"http_request" => "${workflow.input.request}"}
      },
      fields
    )
  end

  defp start(input, tasks \\ [http_task()], opts \\ []) do
    workflow = %Workflow{
      workflow_id: "wf",
      status: :running,
      owner_app: "",
      input: input,
      workflow_definition: %WorkflowDef{name: "caller", version: 1, tasks: tasks}
    }

    {{:ok, "wf"}, stored, _pre, commit, post} =
      Step.run(nil, {:start, workflow}, env(@now, opts))

    assert apply_commit(nil, commit) == stored
    {stored, post}
  end

  defp run(workflow, event, now, opts \\ []) do
    {reply, stored, pre, commit, post} = Step.run(workflow, event, env(now, opts))
    assert apply_commit(workflow, commit) == stored
    {reply, stored, pre, post}
  end

  defp requests(post),
    do: for({:http_request, id, count, request} <- post, do: {id, count, request})

  defp http(%Workflow{} = workflow), do: Enum.find(workflow.tasks, &(&1.task_type == "HTTP"))

  @get %{"uri" => "http://target/json", "method" => "GET"}

  defp ok(status, body, headers \\ [{"content-type", "application/json"}]),
    do: {:ok, %{status: status, headers: headers, body: body}}

  describe "the mapper" do
    test "the task is SCHEDULED with asyncComplete in its input and the definition" do
      {stored, _post} = start(%{"request" => @get}, [http_task(async_complete: true)])

      assert %Task{
               task_type: "HTTP",
               status: :scheduled,
               input_data: %{"http_request" => @get, "asyncComplete" => true}
             } = http(stored)

      # HTTPTaskMapper puts asyncComplete in the definition's inputParameters.
      assert [%WorkflowTask{input_parameters: %{"asyncComplete" => true}}] =
               stored.workflow_definition.tasks
    end

    test "an asyncComplete expression in inputParameters is replaced" do
      task =
        http_task(
          input_parameters: %{"http_request" => @get, "asyncComplete" => "${workflow.input.a}"}
        )

      {stored, _post} = start(%{"a" => true}, [task])

      assert http(stored).input_data["asyncComplete"] == false

      assert [%WorkflowTask{input_parameters: %{"asyncComplete" => false}}] =
               stored.workflow_definition.tasks
    end

    test "copies the definition's rate limit, isolation group and namespace, not its response timeout" do
      task_def = %TaskDef{
        name: "http",
        rate_limit_per_frequency: 5,
        rate_limit_frequency_in_seconds: 10,
        isolation_group_id: "group",
        execution_name_space: "space",
        response_timeout_seconds: 7
      }

      {stored, _post} =
        start(%{"request" => @get}, [http_task()],
          task_def_lookup: fn "http" -> {:ok, task_def} end
        )

      assert %Task{
               rate_limit_per_frequency: 5,
               rate_limit_frequency_in_seconds: 10,
               isolation_group_id: "group",
               execution_name_space: "space",
               response_timeout_seconds: 0
             } = http(stored)
    end

    test "startDelay is callbackAfterSeconds, and the task waits for it" do
      {stored, post} = start(%{"request" => @get}, [http_task(start_delay: 5)])
      assert %Task{status: :scheduled, poll_count: 0, callback_after_seconds: 5} = http(stored)
      assert requests(post) == []
    end
  end

  describe "the start" do
    test "posts the request for the attempt with the task's response timeout as its deadline" do
      {stored, post} = start(%{"request" => @get})
      task = http(stored)
      assert %Task{status: :scheduled, poll_count: 1, start_time: @now} = task
      assert task.worker_id == Atom.to_string(node())

      assert [{id, 1, request}] = requests(post)
      assert id == task.task_id

      assert request == %{
               method: "GET",
               uri: "http://target/json",
               headers: [{"Content-Type", "application/json"}, {"Accept", "application/json"}],
               body: nil,
               connect_timeout: 3000,
               read_timeout: 3000,
               deadline: @now + @hour
             }
    end

    test "without http_request, the whole input is the request" do
      task = http_task(input_parameters: %{"uri" => "http://target/x", "method" => "DELETE"})
      {_stored, post} = start(%{}, [task])
      assert [{_id, 1, %{method: "DELETE", uri: "http://target/x"}}] = requests(post)
    end

    test "a missing uri or method fails the task, as upstream" do
      {stored, post} = start(%{"request" => %{"method" => "GET"}})
      assert requests(post) == []

      assert %Task{
               status: :failed,
               reason_for_incompletion:
                 "Missing HTTP URI.  See documentation for HttpTask for required input parameters"
             } = http(stored)

      assert stored.status == :failed

      {stored, _post} = start(%{"request" => %{"uri" => "http://target"}})

      assert %Task{status: :failed, reason_for_incompletion: "No HTTP method specified"} =
               http(stored)
    end

    test "the request's headers, accept list, body and timeouts" do
      request = %{
        "uri" => "http://target/post",
        "method" => "POST",
        "headers" => %{"X-Number" => 1, "X-Null" => nil, "X-Text" => "t"},
        "accept" => ["text/plain", "application/json"],
        "body" => %{"k" => 1},
        "connectionTimeOut" => "250",
        "readTimeOut" => 1.9
      }

      assert {:ok, built} = Http.request(%{"http_request" => request})

      assert built.headers -- [{"X-Number", "1"}, {"X-Text", "t"}] ==
               [{"Content-Type", "application/json"}, {"Accept", "text/plain, application/json"}]

      assert built.body == ~s({"k":1})
      assert built.connect_timeout == 250
      assert built.read_timeout == 1

      # A string body is sent as it is; a timeout set to null is the provider's default.
      assert {:ok, %{body: "raw", read_timeout: 150, connect_timeout: 100}} =
               Http.request(%{
                 "uri" => "u",
                 "method" => "PUT",
                 "body" => "raw",
                 "readTimeOut" => nil,
                 "connectionTimeOut" => nil
               })
    end

    test "a string body is written in the content type's charset, as StringHttpMessageConverter" do
      base = %{"uri" => "http://target", "method" => "POST", "body" => "é€"}

      assert {:ok, %{body: <<0xE9, ??>>}} =
               Http.request(Map.put(base, "contentType", "text/plain"))

      assert {:ok, %{body: "é€"}} =
               Http.request(Map.put(base, "contentType", "text/plain; charset=UTF-8"))

      # JSON without a charset is UTF-8.
      assert {:ok, %{body: "é€"}} = Http.request(base)
    end

    test "what upstream refuses before sending fails the task with its exception" do
      base = %{"uri" => "http://target", "method" => "POST"}

      assert {:failed,
              "Failed to invoke HTTP task due to: org.springframework.http.InvalidMediaTypeException: Invalid mime type \"json\": does not contain '/'",
              "org.springframework.http.InvalidMediaTypeException: Invalid mime type \"json\": does not contain '/'"} =
               Http.request(Map.put(base, "contentType", "json"))

      for type <- ["*/*", "*/*; q=1"] do
        assert {:failed, _reason,
                "java.lang.IllegalArgumentException: Content-Type cannot contain wildcard type '*'"} =
                 Http.request(Map.put(base, "contentType", type))
      end

      for type <- ["application/*", "application/*+json"] do
        assert {:failed, _reason,
                "java.lang.IllegalArgumentException: Content-Type cannot contain wildcard subtype '*'"} =
                 Http.request(Map.put(base, "contentType", type))
      end

      assert {:failed,
              "Failed to invoke HTTP task due to: java.lang.Exception: No HttpMessageConverter for java.util.LinkedHashMap and content type \"text/plain\"",
              _text} =
               Http.request(
                 Map.merge(base, %{"contentType" => "text/plain", "body" => %{"a" => 1}})
               )

      assert {:failed,
              "Failed to invoke HTTP task due to: java.lang.NullPointerException: " <> _rest,
              _text} =
               Http.request(Map.put(base, "headers", nil))

      # testHTTPGETReadTimeOut: a negative read timeout fails the task.
      assert {:failed,
              "Failed to invoke HTTP task due to: java.lang.IllegalArgumentException: " <> _rest,
              _text} =
               Http.request(Map.put(base, "readTimeOut", -1))

      {stored, post} = start(%{"request" => Map.put(base, "headers", nil)})
      assert requests(post) == []

      assert %Task{
               status: :failed,
               output_data: %{"response" => "java.lang.NullPointerException: " <> _}
             } = http(stored)
    end

    test "an input that is not an HttpTask.Input is left SCHEDULED and times out at its deadline" do
      for request <- [
            "not an object",
            %{"uri" => %{"a" => 1}, "method" => "GET"},
            %{"uri" => "u", "method" => "GET", "headers" => "h"},
            %{"uri" => "u", "method" => "GET", "readTimeOut" => "soon"},
            %{"uri" => "u", "method" => "GET", "connectionTimeOut" => 3_000_000_000}
          ] do
        assert Http.request(%{"http_request" => request}) == :invalid, inspect(request)
      end

      {stored, post} = start(%{"request" => "not an object"})
      assert requests(post) == []
      assert %Task{status: :scheduled, poll_count: 1} = task = http(stored)
      assert task.worker_id == Atom.to_string(node())

      # Not started again before its deadline.
      {:ok, waited, _pre, post} = run(stored, :wake, @now + 60_000)
      assert requests(post) == []
      assert http(waited).poll_count == 1

      {:ok, timed_out, _pre, _post} = run(waited, :wake, @now + @hour)

      assert %Task{
               status: :timed_out,
               reason_for_incompletion:
                 "Task did not complete within its responseTimeout of 3600s"
             } = http(timed_out)
    end
  end

  describe "the response" do
    defp complete(result, fields \\ []) do
      {stored, [_ | _] = post} = start(%{"request" => @get}, [http_task(fields)])
      [{id, count, _request}] = requests(post)
      {:ok, done, _pre, _post} = run(stored, {:http_completed, id, count, result}, @now + 100)
      {http(done), done}
    end

    test "testJsonGET: a 2xx JSON object is the body with the headers, status and phrase" do
      {task, workflow} = complete(ok(200, ~s({"key":"value1","num":42,"SomeKey":null})))

      assert %Task{status: :completed, end_time: end_time} = task
      assert end_time > 0
      assert workflow.status == :completed

      assert task.output_data == %{
               "response" => %{
                 "body" => %{"key" => "value1", "num" => 42, "SomeKey" => nil},
                 "headers" => %{"content-type" => ["application/json"]},
                 "statusCode" => 200,
                 "reasonPhrase" => "OK"
               }
             }
    end

    test "testTextGET and testNumberGET: text as it is, a number as a double" do
      {task, _workflow} = complete(ok(200, "plain text", [{"content-type", "text/plain"}]))
      assert task.output_data["response"]["body"] == "plain text"

      {task, _workflow} = complete(ok(200, "42"))
      assert task.output_data["response"]["body"] === 42.0

      {task, _workflow} = complete(ok(200, ~s("quoted")))
      assert task.output_data["response"]["body"] == "quoted"

      {task, _workflow} = complete(ok(200, "true"))
      assert task.output_data["response"]["body"] == "true"
    end

    test "testPostNoContent: an empty 2xx body is null" do
      {task, _workflow} = complete(ok(204, "", []))
      assert %Task{status: :completed} = task
      assert task.output_data["response"]["body"] == nil
      assert task.output_data["response"]["reasonPhrase"] == "No Content"
    end

    test "testPostAsyncComplete: a 2xx answer leaves an asyncComplete task IN_PROGRESS" do
      {task, workflow} = complete(ok(200, "{}"), async_complete: true)
      assert %Task{status: :in_progress} = task
      assert task.output_data["response"]["statusCode"] == 200

      # A wake does not evaluate it again: the worker's update ends it.
      {:ok, waited, _pre, post} = run(workflow, :wake, @now + 60_000)
      assert http(waited) == task
      assert requests(post) == []
    end

    test "JSON past Jackson's default constraints is kept as text" do
      deep = String.duplicate("[", 1000) <> String.duplicate("]", 1000)
      {task, _workflow} = complete(ok(200, deep))
      assert is_list(task.output_data["response"]["body"])

      for text <- [
            String.duplicate("[", 1001) <> String.duplicate("]", 1001),
            String.duplicate("1", 1001),
            ~s({"a":) <> String.duplicate("1", 1001) <> "}"
          ] do
        {task, _workflow} = complete(ok(200, text))
        assert task.output_data["response"]["body"] == text
      end

      # Brackets in strings and digits after a fraction do not count.
      quoted = Jason.encode!(%{"s" => String.duplicate("[", 2000)})
      {task, _workflow} = complete(ok(200, quoted))
      assert task.output_data["response"]["body"] == %{"s" => String.duplicate("[", 2000)}

      # A float is limited by its length (Jackson 2.18.8 measured: one more character at the top
      # level than inside an array).
      {task, _workflow} = complete(ok(200, "1." <> String.duplicate("1", 1000)))
      assert is_float(task.output_data["response"]["body"])

      for text <- [
            "1." <> String.duplicate("1", 1001),
            "1.5e" <> String.duplicate("1", 999),
            "[1." <> String.duplicate("1", 1000) <> "]"
          ] do
        {task, _workflow} = complete(ok(200, text))
        assert task.output_data["response"]["body"] == text
      end

      {task, _workflow} = complete(ok(200, "[-1." <> String.duplicate("1", 999) <> "]"))
      assert [value] = task.output_data["response"]["body"]
      assert is_float(value)
    end

    test "a text body without a charset is read as ISO-8859-1, JSON as UTF-8" do
      {task, _workflow} = complete(ok(200, <<0xE9>>, [{"content-type", "text/plain"}]))
      assert task.output_data["response"]["body"] == "é"

      {task, _workflow} = complete(ok(200, ~s("é")))
      assert task.output_data["response"]["body"] == "é"
    end

    test "a 2xx code Spring does not know fails with IllegalArgumentException" do
      {task, _workflow} = complete(ok(299, "{}"))

      assert %Task{
               status: :failed,
               reason_for_incompletion:
                 "Failed to invoke HTTP task due to: java.lang.IllegalArgumentException: No matching constant for [299]",
               output_data: %{
                 "response" =>
                   "java.lang.IllegalArgumentException: No matching constant for [299]"
               }
             } = task
    end

    test "a 3xx answer has no body and fails without a response from the remote service" do
      {task, _workflow} = complete(ok(304, "", []))

      assert %Task{
               status: :failed,
               reason_for_incompletion: "No response from the remote service"
             } = task

      assert task.output_data["response"]["statusCode"] == 304
      assert task.output_data["response"]["body"] == nil
    end

    test "testFailure: 4xx and 5xx have Spring's message with the body" do
      uri = @get["uri"]
      {task, workflow} = complete(ok(500, "boom", [{"content-type", "text/plain"}]))

      message =
        ~s(java.lang.Exception: 500 Internal Server Error on GET request for "#{uri}": "boom")

      assert task.status == :failed
      assert task.reason_for_incompletion == "Failed to invoke HTTP task due to: " <> message
      assert task.output_data == %{"response" => message}
      assert workflow.status == :failed

      {task, _workflow} = complete(ok(404, ""))

      assert task.output_data["response"] =~
               ~s(404 Not Found on GET request for "#{uri}": [no body])

      {task, _workflow} = complete(ok(400, "a\r\nb\tc"))
      assert task.output_data["response"] =~ ~s(: "a<EOL><EOL>b?c")
    end

    test "the reason is kept whole in the task and cut to 500 characters in its JSON" do
      {task, workflow} = complete(ok(400, String.duplicate("x", 1000)))
      assert String.length(task.reason_for_incompletion) > 1000
      assert String.length(Task.to_json(task)["reasonForIncompletion"]) == 500
      assert workflow.reason_for_incompletion =~ String.duplicate("x", 1000)
    end

    test "the error message's URI stops at its query" do
      request = %{"uri" => "http://target/q?secret=1", "method" => "GET"}
      {stored, post} = start(%{"request" => request})
      [{id, 1, _request}] = requests(post)
      {:ok, done, _pre, _post} = run(stored, {:http_completed, id, 1, ok(401, "")}, @now + 1)
      assert http(done).output_data["response"] =~ ~s(on GET request for "http://target/q": )
    end

    test "an I/O error is RestTemplate's ResourceAccessException" do
      {task, _workflow} = complete({:error, {:io, "Read timed out"}})

      assert task.reason_for_incompletion ==
               ~s(Failed to invoke HTTP task due to: java.lang.Exception: I/O error on GET request for "http://target/json": Read timed out)
    end
  end

  describe "a started task" do
    test "is not started again while its request is in flight, on a wake or another event" do
      {stored, [_ | _] = post} = start(%{"request" => @get})
      [{id, 1, _request}] = requests(post)

      for event <- [:wake, :recover] do
        {:ok, waited, _pre, post} =
          run(stored, event, @now + 60_000, http_in_flight: MapSet.new([id]))

        assert requests(post) == [], inspect(event)
        assert http(waited).poll_count == 1
      end
    end

    test "a started task with a startDelay is timed out at its deadline, not a delay later" do
      {stored, post} = start(%{"request" => 42}, [http_task(start_delay: 7200)])
      assert requests(post) == []
      {:ok, started, _pre, post} = run(stored, :wake, @now + 7_200_000)
      assert requests(post) == []
      assert %Task{status: :scheduled, poll_count: 1, update_time: at} = http(started)

      {:ok, timed_out, _pre, _post} = run(started, :wake, at + @hour)
      assert %Task{status: :timed_out} = http(timed_out)
      assert Postpone.wake_at(started, env(at + 1)) <= at + @hour
    end

    test "a started task with a startDelay over is not woken every second" do
      {stored, _post} = start(%{"request" => 42}, [http_task(start_delay: 60)])
      {:ok, started, _pre, _post} = run(stored, :wake, @now + 60_000)
      assert %Task{status: :scheduled, poll_count: 1, update_time: at} = http(started)

      # Past the delay, the next evaluation is the workflow's offset, not a second away.
      now = at + 120_000
      assert Postpone.wake_at(started, env(now)) == now + 30_000
    end

    test "lost with its process (not in flight, its pollCount counted) waits for its deadline too" do
      {stored, _post} = start(%{"request" => @get})

      {:ok, waited, _pre, post} = run(stored, :recover, @now + 60_000)
      assert requests(post) == []
      assert http(waited).poll_count == 1
    end

    test "is woken at its deadline and timed out there; a later result is dropped" do
      {stored, post} = start(%{"request" => @get})
      [{id, 1, _request}] = requests(post)
      assert {:wake_at, wake} = List.keyfind(post, :wake_at, 0)
      assert wake <= @now + @hour
      assert Postpone.wake_at(stored, env(@now + 1)) <= @now + @hour

      {:ok, timed_out, _pre, _post} =
        run(stored, :wake, @now + @hour, http_in_flight: MapSet.new([id]))

      assert %Task{status: :timed_out} = http(timed_out)

      {:ok, after_result, _pre, _post} =
        run(timed_out, {:http_completed, id, 1, ok(200, "{}")}, @now + @hour + 1)

      assert after_result == timed_out
    end

    test "takes the result of its own attempt only" do
      {stored, post} = start(%{"request" => @get})
      [{id, 1, _request}] = requests(post)

      {:ok, same, _pre, _post} = run(stored, {:http_completed, id, 2, ok(200, "{}")}, @now + 1)
      assert same == stored

      {:ok, same, _pre, _post} =
        run(stored, {:http_completed, "other", 1, ok(200, "{}")}, @now + 1)

      assert same == stored
    end

    test "a result after the workflow ended is dropped" do
      {stored, post} = start(%{"request" => @get})
      [{id, 1, _request}] = requests(post)
      {:ok, terminated, _pre, _post} = run(stored, {:terminate, "stop"}, @now + 1)
      assert %Task{status: :canceled} = http(terminated)

      {:ok, same, _pre, _post} =
        run(terminated, {:http_completed, id, 1, ok(200, "{}")}, @now + 2)

      assert same == terminated
    end

    test "a DYNAMIC task resolved to HTTP keeps its definition's response timeout" do
      dynamic = %WorkflowTask{
        name: "dyn",
        task_reference_name: "http_ref",
        type: "DYNAMIC",
        dynamic_task_name_param: "taskToExecute",
        async_complete: true,
        input_parameters: %{
          "taskToExecute" => "HTTP",
          "http_request" => "${workflow.input.request}"
        }
      }

      lookup = fn "HTTP" -> {:ok, %TaskDef{name: "HTTP", response_timeout_seconds: 7}} end
      {stored, post} = start(%{"request" => @get}, [dynamic], task_def_lookup: lookup)
      assert [{id, 1, %{deadline: deadline}}] = requests(post)
      assert deadline == @now + 7_000
      assert %Task{task_type: "HTTP", response_timeout_seconds: 7} = http(stored)

      {:ok, waited, _pre, _post} = run(stored, :wake, @now + 6_000)
      assert %Task{status: :scheduled, poll_count: 1} = http(waited)

      {:ok, done, _pre, _post} =
        run(waited, {:http_completed, id, 1, ok(200, "{}")}, @now + 6_500)

      assert %Task{status: :in_progress} = http(done)

      {:ok, timed_out, _pre, _post} = run(stored, :wake, @now + 7_000)

      assert %Task{
               status: :timed_out,
               reason_for_incompletion: "Task did not complete within its responseTimeout of 7s"
             } = http(timed_out)
    end

    test "rerun from another branch starts a failed HTTP task again (finalizeRerun)" do
      fork = %WorkflowTask{
        name: "fork",
        task_reference_name: "fork_ref",
        type: "FORK_JOIN",
        fork_tasks: [
          [http_task()],
          [%WorkflowTask{name: "simple", task_reference_name: "simple_ref", type: "SIMPLE"}]
        ]
      }

      join = %WorkflowTask{
        name: "join",
        task_reference_name: "join_ref",
        type: "JOIN",
        join_on: ["http_ref", "simple_ref"]
      }

      {stored, post} = start(%{"request" => @get}, [fork, join])
      [{id, 1, _request}] = requests(post)
      {:ok, failed, _pre, _post} = run(stored, {:http_completed, id, 1, ok(500, "")}, @now + 1)
      assert failed.status == :failed

      simple = Enum.find(failed.tasks, &(&1.reference_task_name == "simple_ref"))

      rerun = %{
        task_id: simple.task_id,
        task_input: nil,
        workflow_input: nil,
        correlation_id: nil
      }

      {:ok, rerun_wf, _pre, post} = run(failed, {:rerun, rerun}, @now + 2)

      assert rerun_wf.status == :running
      assert [{^id, 1, _request}] = requests(post)
      assert %Task{status: :scheduled, poll_count: 1} = http(rerun_wf)
    end

    test "the concurrent execution limit comes before the deadline, and keeps the attempt" do
      task_def = %TaskDef{name: "http", concurrent_exec_limit: 1}
      task = http_task(task_definition: task_def)
      {stored, post} = start(%{"request" => @get}, [task])
      [{id, 1, _request}] = requests(post)

      # Another task holds the only slot past the deadline.
      {:ok, waited, _pre, _post} =
        run(stored, :wake, @now + @hour, in_progress: %{"http" => 1})

      assert %Task{status: :scheduled, poll_count: 1} = http(waited)

      {:ok, done, _pre, _post} =
        run(waited, {:http_completed, id, 1, ok(200, "{}")}, @now + @hour + 1)

      assert %Task{status: :completed} = http(done)
    end
  end
end
