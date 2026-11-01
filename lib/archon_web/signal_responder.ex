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
  tasks and with `signalTimeout` true; the workflow goes on.

  A `BLOCKING_TASK*` strategy without a blocking task has no answer, and upstream's Reactor fails:
  `{:error, {:server_error, message}}`, with Reactor's message for a mapper that returned `null`
  (upstream names a JVM lambda class there) or, after the timeout, `"value"`
  (`Mono.just(null)`).
  """

  alias Archon.Domain.{SignalResponse, Task, Workflow}
  alias Archon.Runtime
  alias Archon.Runtime.Tasks

  @tick_ms 100

  @null_mapper "The mapper [com.netflix.conductor.rest.controllers.WorkflowSignalResponder$$Lambda] " <>
                 "returned a null value."

  @doc """
  Waits for the workflow `workflow_id` as described in the moduledoc. `task_refs` are the
  reference names whose terminal tasks block (each is trimmed); `timeout_ms` may be 0 or less,
  which answers at once with the timed-out state.
  """
  @spec await(String.t(), [String.t()], SignalResponse.strategy(), String.t(), integer()) ::
          {:ok, SignalResponse.t()} | {:error, term()}
  def await(workflow_id, task_refs, strategy, request_id, timeout_ms) do
    refs = Enum.map(task_refs, &String.trim/1)
    start = System.monotonic_time(:millisecond)
    tick(workflow_id, refs, strategy, request_id, start, start + timeout_ms, 1)
  end

  # Flux.interval(100ms) with a timeout: the n-th read is at start + n * 100 ms, unless the
  # deadline comes first.
  defp tick(id, refs, strategy, request_id, start, deadline, n) do
    at = start + n * @tick_ms

    if at >= deadline do
      sleep_until(deadline)
      timed_out(id, strategy, request_id)
    else
      sleep_until(at)

      with {:ok, workflow} <- read(id) do
        {tasks, blocking} = blocking_tasks(workflow, refs)

        if Workflow.terminal?(workflow.status) or tasks != [] do
          answer(
            SignalResponse.new(
              workflow,
              blocking || workflow,
              tasks,
              false,
              strategy,
              request_id
            ),
            @null_mapper
          )
        else
          tick(id, refs, strategy, request_id, start, deadline, n + 1)
        end
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
    case at - System.monotonic_time(:millisecond) do
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

    if id not in [nil, ""] and String.trim(id) != "" and not Task.terminal?(task.status) do
      case owned_child(workflow, task, seen) do
        {:ok, %Workflow{} = child} -> blocking_tasks(child, refs, [child.workflow_id | seen])
        _passed_over -> {[], nil}
      end
    else
      {[], nil}
    end
  end

  defp child_blocking(_workflow, _task, _refs, _seen), do: {[], nil}

  # Upstream skips a child it cannot fetch, whatever the exception.
  defp owned_child(workflow, task, seen) do
    Tasks.owned_child(workflow, task, seen)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
