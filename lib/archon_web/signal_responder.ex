# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/WorkflowSignalResponder.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: a loop in the request's process instead of a Reactor Flux; a child
# is read only when the SUB_WORKFLOW task owns it (ADR 0024, decision 2); the failures of the
# missing answer carry fixed messages.

defmodule ArchonWeb.SignalResponder do
  @moduledoc """
  The wait of the synchronous start and signal (ADR 0025, decision 5; BOSS decision: polling
  as upstream, no subscription to the workflow's process).

  Every 100 ms, `await/5` reads the workflow with its tasks (`Archon.Runtime.get_workflow/2`)
  until it is terminal or has a blocking task, then answers with an
  `Archon.Domain.SignalResponse` for the return strategy. A blocking task is a `WAIT` task that
  is not terminal and waits without an end (`wait_timeout` 0), or a terminal task whose reference
  name is one of the given ones. The search descends into the children of the `SUB_WORKFLOW`
  tasks that are not terminal, depth first in task order; a child its task does not own, or one
  that cannot be read, is passed over as upstream's `catch`.

  When the timeout passes first, the answer is the workflow as it is then, without blocking
  tasks and with `signalTimeout` true; the workflow goes on. No wait lasts over 30 s
  (`await/5`), so a request holds its connection process and reads the store for at most that
  long, also after its client went away.

  A `BLOCKING_TASK*` strategy without a blocking task has no answer, and upstream's Reactor fails:
  `{:error, {:server_error, message}}`, with Reactor's message for a mapper that returned `null`
  (upstream names a JVM lambda class there) or, after the timeout, `"value"`
  (`Mono.just(null)`).
  """

  alias Archon.Domain.{SignalResponse, Task, Validation, Workflow}
  alias Archon.Runtime
  alias Archon.Runtime.Tasks

  @tick_ms 100
  # Tomcat's default asynchronous request timeout (spring.mvc.async.request-timeout unset);
  # `config :archon, ArchonWeb.SignalResponder, async_timeout_ms: ...` changes it (tests).
  @async_timeout_ms 30_000

  @null_mapper "The mapper [com.netflix.conductor.rest.controllers.WorkflowSignalResponder$$Lambda] " <>
                 "returned a null value."

  @doc """
  Waits for the workflow `workflow_id` as described in the moduledoc. `task_refs` are the
  reference names whose terminal tasks block (each is trimmed as Java's `String#trim`);
  `timeout_ms` may be 0 or less, which answers at once with the timed-out state.

  Whatever `timeout_ms` is, the wait ends after 30 s with `{:error, :async_timeout}`: upstream
  answers through Spring MVC's asynchronous request, which Tomcat ends after its default 30 s
  (`AsyncRequestTimeoutException`, a 500 without a message, observed on the upstream server).
  A timeout of exactly 30 s answers as a timeout.
  """
  @spec await(String.t(), [String.t()], SignalResponse.strategy(), String.t(), integer()) ::
          {:ok, SignalResponse.t()} | {:error, term()}
  def await(workflow_id, task_refs, strategy, request_id, timeout_ms) do
    refs = Enum.map(task_refs, &java_trim/1)
    start = System.monotonic_time(:millisecond)

    wait = %{
      id: workflow_id,
      refs: refs,
      strategy: strategy,
      request_id: request_id,
      start: start,
      deadline: start + timeout_ms,
      limit: start + async_timeout_ms()
    }

    tick(wait, 1)
  end

  # Flux.interval(100ms) with a timeout: the n-th read is at start + n * 100 ms, unless the
  # deadline or the asynchronous request's limit comes first. A read that ends past either
  # answers as that end, as upstream's timers fire while the read runs.
  defp tick(wait, n) do
    at = wait.start + n * @tick_ms

    if at >= finish(wait) do
      sleep_until(finish(wait))
      finished(wait)
    else
      sleep_until(at)
      read_tick(wait, n)
    end
  end

  defp read_tick(wait, n) do
    case within(finish(wait), fn -> check(wait) end, :finished) do
      :waiting -> tick(wait, n + 1)
      :finished -> finished(wait)
      answer -> unless_finished(wait, answer)
    end
  end

  defp unless_finished(wait, answer),
    do: if(now() >= finish(wait), do: finished(wait), else: answer)

  defp finish(%{deadline: deadline, limit: limit}), do: min(deadline, limit)

  # Reactor's fallback read after the deadline, which the asynchronous request's limit still
  # ends; a deadline at the limit gives the read one tick, so that it answers as a timeout.
  defp finished(%{deadline: deadline, limit: limit} = wait) when deadline <= limit do
    within(
      max(limit, deadline + @tick_ms),
      fn -> timed_out(wait.id, wait.strategy, wait.request_id) end,
      {:error, :async_timeout}
    )
  end

  defp finished(_wait), do: {:error, :async_timeout}

  # Runs the reads of `fun` in a process of their own until `at` at most: upstream's timers fire
  # while a read is stuck (a slow database), so a read still running then is killed and `late`
  # answers. A read that raises or exits fails the request as it would in the request's process.
  # The reader is not linked, and runs at most one store read past a request that went away. A
  # reader killed during a Postgres query makes DBConnection drop that connection and reconnect.
  defp within(at, fun, late) do
    caller = self()
    ref = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(caller, {ref, run(fun)}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        unwrap(result)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        exit(reason)
    after
      max(at - now(), 0) ->
        Process.exit(pid, :kill)

        # Whatever the reader sent arrives before its DOWN, so nothing is left in the mailbox of
        # the connection process, which serves the next request of a kept-alive connection.
        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        receive do
          {^ref, _result} -> late
        after
          0 -> late
        end
    end
  end

  defp run(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:raise, exception, __STACKTRACE__}
  catch
    :exit, reason -> {:exit, reason}
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:raise, exception, stacktrace}), do: reraise(exception, stacktrace)
  defp unwrap({:exit, reason}), do: exit(reason)

  defp async_timeout_ms,
    do:
      Keyword.get(
        Application.get_env(:archon, __MODULE__, []),
        :async_timeout_ms,
        @async_timeout_ms
      )

  defp now, do: System.monotonic_time(:millisecond)

  # One read: the answer once the workflow is terminal or a task blocks, else `:waiting`.
  defp check(wait) do
    with {:ok, workflow} <- read(wait.id) do
      {tasks, blocking} = blocking_tasks(workflow, wait.refs)

      if Workflow.terminal?(workflow.status) or tasks != [] do
        workflow
        |> SignalResponse.new(blocking || workflow, tasks, false, wait.strategy, wait.request_id)
        |> answer(@null_mapper)
      else
        :waiting
      end
    end
  end

  defp timed_out(id, strategy, request_id) do
    with {:ok, workflow} <- read(id) do
      answer(SignalResponse.new(workflow, workflow, [], true, strategy, request_id), "value")
    end
  end

  defp answer(nil, message), do: {:error, {:server_error, message}}
  defp answer(response, _message), do: {:ok, response}

  defp sleep_until(at) do
    case at - now() do
      delay when delay > 0 -> Process.sleep(delay)
      _due -> :ok
    end
  end

  # WorkflowService#getWorkflowModel: an unknown workflow (removed while waiting) fails the wait.
  defp read(id) do
    case Runtime.get_workflow(id, true) do
      {:ok, workflow} -> {:ok, workflow}
      {:error, :not_found} -> {:error, {:not_found, "No such workflow found by id: #{id}"}}
    end
  end

  @doc """
  Upstream `findBlockingTasks`: the blocking tasks of the workflow and its children in task
  order, and the workflow of the first one (`nil` without one).
  """
  @spec blocking_tasks(Workflow.t(), [String.t()]) :: {[Task.t()], Workflow.t() | nil}
  def blocking_tasks(%Workflow{} = workflow, refs),
    do: blocking_tasks(workflow, refs, [workflow.workflow_id])

  defp blocking_tasks(%Workflow{tasks: tasks} = workflow, refs, seen) do
    {found, blocking} =
      Enum.reduce(tasks, {[], nil}, fn task, {found, blocking} ->
        own = own_blocking(task, refs)
        blocking = if own != [] and blocking == nil, do: workflow, else: blocking
        {child_tasks, child_blocking} = child_blocking(workflow, task, refs, seen)
        {[child_tasks, own | found], blocking || child_blocking}
      end)

    {found |> Enum.reverse() |> List.flatten(), blocking}
  end

  # A WAIT waiting without an end, then once per matching reference name.
  defp own_blocking(%Task{} = task, refs) do
    terminal? = Task.terminal?(task.status)

    wait =
      if task.task_type == "WAIT" and not terminal? and task.wait_timeout == 0,
        do: [task],
        else: []

    wait ++ for ref <- refs, terminal? and ref == task.reference_task_name, do: task
  end

  defp child_blocking(workflow, %Task{task_type: "SUB_WORKFLOW"} = task, refs, seen) do
    id = Task.sub_workflow_id(task)

    if not Validation.java_blank?(id) and not Task.terminal?(task.status) do
      case owned_child(workflow, task, seen) do
        {:ok, %Workflow{} = child} -> blocking_tasks(child, refs, [child.workflow_id | seen])
        _passed_over -> {[], nil}
      end
    else
      {[], nil}
    end
  end

  defp child_blocking(_workflow, _task, _refs, _seen), do: {[], nil}

  # Java's String#trim: code points up to U+0020 at both ends.
  defp java_trim(text), do: String.replace(text, ~r/\A[\x00-\x20]+|[\x00-\x20]+\z/, "")

  # Upstream skips a child it cannot fetch, whatever the exception.
  defp owned_child(workflow, task, seen) do
    Tasks.owned_child(workflow, task, seen)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
