# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/service/ExecutionService.java
# (poll, getLastPollTask, ackTaskReceived, updateTask, getTask),
# core/.../service/TaskServiceImpl.java (poll, batchPoll, updateTask, getTask),
# core/.../core/dal/ExecutionDAOFacade.java (updateTaskLastPoll) and
# rest/src/main/java/com/netflix/conductor/rest/controllers/TaskResource.java (updateTaskV2,
# updateTaskSync), ExecutionService.java (getPendingTaskForWorkflow) and TaskServiceImpl.java
# (updateTask by reference, signalTask, findPendingBlockingTask) at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: each popped task goes to its workflow's process, which applies the poll
# (ADR 0018, decisions 1 and 7); this module pops, records the poll data and acks. A signal
# descends only into children the SUB_WORKFLOW task owns (ADR 0024, decision 2).

defmodule Archon.Runtime.Tasks do
  @moduledoc """
  The runtime API for workers (ADR 0018, decision 7). Phase 5 REST calls these functions; the
  workflow API is `Archon.Runtime`.

    * `poll/3` - upstream `getLastPollTask` (`GET /api/tasks/poll/{tasktype}`): one task, waiting
      up to 100 ms.
    * `batch_poll/5` - upstream `ExecutionService#poll` (`GET /api/tasks/poll/batch/{tasktype}`).
    * `update/1` - upstream `updateTask` (`POST /api/tasks`).
    * `update_v2/1` - upstream `TaskResource#updateTaskV2` (`POST /api/tasks/update-v2`): the
      update, then the next task of the same type and domain when the updated task is terminal.
    * `get/1` - upstream `getTask`: reads the store.
    * `pending_task/2`, `update_by_ref/6` - upstream `getPendingTaskForWorkflow` and
      `updateTask(workflowId, taskRefName, ...)` (`POST /api/tasks/{workflowId}/{taskRefName}/{status}`
      and `.../sync`, ADR 0025 decision 5).
    * `signal/3` - upstream `signalTask` (`POST /api/tasks/{workflowId}/{status}/signal` and
      `.../sync`).

  A poll pops task IDs from the queue `[domain:]taskType` and sends each to the process of its
  workflow (`Archon.Runtime.WorkflowServer.poll/3`), which checks the task, the concurrent
  execution limit and saves it `IN_PROGRESS`. A task the store or its workflow does not have is
  removed from the queue; one that failed in between is postponed by
  `task_execution_postpone_ms` with priority 0 so it is polled again, as upstream does when the
  database fails. After the batch the poll data of the type and domain is written, also for an
  empty poll, and the messages of the tasks given out are acked.
  """

  require Logger

  alias Archon.Decider.Parameters
  alias Archon.Domain.{Task, TaskResult, Validation, Workflow}
  alias Archon.Runtime
  alias Archon.Runtime.Step.Schedule
  alias Archon.Runtime.WorkflowServer

  # ExecutionService.MAX_POLL_TIMEOUT_MS, POLL_COUNT_ONE and POLLING_TIMEOUT_IN_MS
  @max_poll_timeout_ms 5_000
  @poll_timeout_ms 100

  @doc """
  Upstream `getLastPollTask`: the next task of the type in the domain, or `nil` when none is
  available within 100 ms (REST 204).
  """
  @spec poll(String.t(), String.t() | nil, String.t() | nil) :: {:ok, Task.t() | nil}
  def poll(task_type, worker_id, domain \\ nil) do
    {:ok, tasks} = batch_poll(task_type, worker_id, domain, 1, @poll_timeout_ms)
    {:ok, List.first(tasks)}
  end

  @doc """
  Upstream `ExecutionService#poll`: up to `count` tasks of the type in the domain, waiting up to
  `timeout_ms` for the first one. A timeout over 5000 ms is
  `{:error, {:invalid, "Long Poll Timeout value cannot be more than 5 seconds"}}`.
  """
  @spec batch_poll(String.t(), String.t() | nil, String.t() | nil, integer(), integer()) ::
          {:ok, [Task.t()]} | {:error, {:invalid, String.t()}}
  def batch_poll(task_type, _worker_id, _domain, _count, timeout_ms)
      when is_binary(task_type) and is_integer(timeout_ms) and timeout_ms > @max_poll_timeout_ms,
      do: {:error, {:invalid, "Long Poll Timeout value cannot be more than 5 seconds"}}

  def batch_poll(task_type, worker_id, domain, count, timeout_ms)
      when is_binary(task_type) and is_integer(count) and is_integer(timeout_ms) do
    queue = queue_name(task_type, domain)
    tasks = queue |> pop(count, timeout_ms) |> Enum.flat_map(&poll_task(queue, &1, worker_id))
    record_poll(task_type, domain, worker_id)

    for task <- tasks, do: Runtime.queue().ack(Schedule.queue_name(task), task.task_id)
    {:ok, tasks}
  end

  # QueueUtils#getQueueName without execution namespace and isolation group.
  defp queue_name(task_type, nil), do: task_type
  defp queue_name(task_type, domain), do: "#{domain}:#{task_type}"

  defp pop(queue, count, timeout_ms) do
    Runtime.queue().pop(queue, count, timeout_ms)
  rescue
    exception -> pop_failed(queue, exception)
  catch
    :exit, reason -> pop_failed(queue, reason)
  end

  defp pop_failed(queue, reason) do
    Logger.error("could not poll #{queue}: #{inspect(reason)}")
    []
  end

  defp poll_task(queue, task_id, worker_id) do
    case owner_poll(task_id, worker_id) do
      %Task{} = task ->
        [task]

      nil ->
        []

      {:error, :not_found} ->
        remove(queue, task_id)

      {:error, reason} ->
        postpone(queue, task_id, reason)
    end
  end

  # A message without a task; a failed removal is postponed, as upstream's catch does.
  defp remove(queue, task_id) do
    case guarded(fn -> Runtime.queue().remove(queue, task_id) end) do
      {:error, reason} -> postpone(queue, task_id, reason)
      _removed -> []
    end
  end

  # A failure between the pop and the save: polled again later, as upstream re-enqueues.
  defp postpone(queue, task_id, reason) do
    Logger.warning(
      "poll of task #{task_id} failed, postponing it in #{queue}: #{inspect(reason)}"
    )

    Runtime.queue().postpone(queue, task_id, 0, postpone_ms())
    []
  end

  defp owner_poll(task_id, worker_id) do
    guarded(fn ->
      with {:ok, _task, workflow_id} <- Runtime.store().get_task(task_id),
           do: WorkflowServer.poll(workflow_id, task_id, worker_id)
    end)
  end

  defp guarded(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp postpone_ms,
    do: Keyword.get(Runtime.setting(:settings, []), :task_execution_postpone_ms, 60_000)

  # ExecutionDAOFacade#updateTaskLastPoll logs a failure and goes on.
  defp record_poll(task_type, domain, worker_id) do
    Runtime.store().put_poll_data(task_type, domain, worker_id, Runtime.now())
  rescue
    exception -> poll_data_failed(task_type, domain, exception)
  catch
    :exit, reason -> poll_data_failed(task_type, domain, reason)
  end

  defp poll_data_failed(task_type, domain, reason) do
    Logger.error(
      "could not record the poll of #{task_type} in #{inspect(domain)}: #{inspect(reason)}"
    )

    :ok
  end

  @doc """
  Upstream `updateTask`: the saved task once the decide that follows is saved, `nil` for an
  `extendLease` result, or `{:error, :not_found}` when the workflow or the task does not exist.
  A task or workflow that is already terminal is returned unchanged and its message removed.
  """
  @spec update(TaskResult.t()) :: {:ok, Task.t() | nil} | {:error, term()}
  def update(%TaskResult{workflow_instance_id: id} = result) when is_binary(id) do
    case WorkflowServer.update(result) do
      {:error, _reason} = error -> error
      task -> {:ok, task}
    end
  end

  def update(%TaskResult{}), do: {:error, :not_found}

  @doc """
  Upstream `TaskResource#updateTaskV2`: the result must name the workflow and the task
  (`{:error, {:invalid, errors}}`, the `@Valid` check). After the update, the next task of the
  updated task's type and domain for the same worker when the updated task is terminal, else
  `nil` (REST 204).
  """
  @spec update_v2(TaskResult.t()) :: {:ok, Task.t() | nil} | {:error, term()}
  def update_v2(%TaskResult{} = result) do
    with :ok <- valid(result),
         {:ok, %Task{} = task} <- update(result),
         true <- Task.terminal?(task.status) do
      poll(task.task_type, result.worker_id, task.domain)
    else
      {:ok, nil} -> {:ok, nil}
      false -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp valid(result) do
    case TaskResult.validate(result) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid, errors}}
    end
  end

  @doc "Upstream `getTask`: the stored task, or `{:error, :not_found}`."
  @spec get(String.t()) :: {:ok, Task.t()} | {:error, :not_found}
  def get(task_id) when is_binary(task_id) do
    case Runtime.store().get_task(task_id) do
      {:ok, task, _workflow_id} -> {:ok, task}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Upstream `ExecutionService#getPendingTaskForWorkflow`: the first task of the workflow that is
  not terminal and has the reference name, else the first one whose reference name without its
  `DO_WHILE` iteration suffix (`__<n>`) is the name. `nil` without one, also for an unknown
  workflow (upstream reads the workflow's tasks, which are none).
  """
  @spec pending_task(String.t(), String.t()) :: Task.t() | nil
  def pending_task(workflow_id, ref) when is_binary(workflow_id) and is_binary(ref) do
    case Runtime.get_workflow(workflow_id, true) do
      {:ok, %Workflow{tasks: tasks}} ->
        pending = Enum.reject(tasks, &Task.terminal?(&1.status))

        Enum.find(pending, &(&1.reference_task_name == ref)) ||
          Enum.find(pending, &(Parameters.remove_iteration(&1.reference_task_name) == ref))

      {:error, :not_found} ->
        nil
    end
  end

  @doc """
  Upstream `TaskServiceImpl#updateTask(workflowId, taskRefName, status, workerId, output)`: updates
  `pending_task/2` with the status, its output merged with `output`, and `worker_id` unless it is
  blank (`keep_worker: true`, the default) or always (`keep_worker: false`, `updateTaskSync`).
  The updated task's ID, or `nil` without a pending task.
  """
  @spec update_by_ref(String.t(), String.t(), TaskResult.status(), String.t() | nil, map(),
          keep_worker: boolean()
        ) :: {:ok, String.t() | nil} | {:error, term()}
  def update_by_ref(workflow_id, ref, status, worker_id, output, opts \\ []) do
    case pending_task(workflow_id, ref) do
      nil ->
        {:ok, nil}

      %Task{} = task ->
        worker_id =
          if Keyword.get(opts, :keep_worker, true) and blank?(worker_id),
            do: task.worker_id,
            else: worker_id

        update_pending(task, status, output, worker_id)
    end
  end

  @doc """
  Upstream `TaskServiceImpl#signalTask`: updates the workflow's first `WAIT` task that is not
  terminal, else the one a non-terminal `SUB_WORKFLOW` task's child would signal, depth first, with
  the status and its output merged with `output`. The updated task's ID, or `nil` without such a
  task. A child the `SUB_WORKFLOW` task does not own is passed over (ADR 0024, decision 2); an
  unknown workflow, the named one or a child, is
  `{:error, {:not_found, "No such workflow found by id: <id>"}}` as upstream's read.
  """
  @spec signal(String.t(), TaskResult.status(), map()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def signal(workflow_id, status, output) when is_binary(workflow_id) do
    with {:ok, workflow} <- read_workflow(workflow_id),
         {:ok, %Task{} = task} <- blocked_task(workflow, [workflow_id]) do
      update_pending(task, status, output, task.worker_id)
    end
  end

  # findPendingBlockingTask: the workflow's own WAIT tasks first, then its children in task order.
  defp blocked_task(%Workflow{tasks: tasks} = workflow, seen) do
    case Enum.find(tasks, &(&1.task_type == "WAIT" and not Task.terminal?(&1.status))) do
      %Task{} = task -> {:ok, task}
      nil -> child_blocked_task(workflow, Enum.filter(tasks, &running_sub_workflow?/1), seen)
    end
  end

  defp child_blocked_task(_workflow, [], _seen), do: {:ok, nil}

  defp child_blocked_task(workflow, [task | rest], seen) do
    case owned_child(workflow, task, seen) do
      {:ok, %Workflow{} = child} ->
        case blocked_task(child, [child.workflow_id | seen]) do
          {:ok, nil} -> child_blocked_task(workflow, rest, seen)
          found -> found
        end

      {:ok, nil} ->
        child_blocked_task(workflow, rest, seen)

      {:error, _reason} = error ->
        error
    end
  end

  defp running_sub_workflow?(%Task{} = task) do
    task.task_type == "SUB_WORKFLOW" and not Task.terminal?(task.status) and
      not blank?(Task.sub_workflow_id(task))
  end

  @doc """
  The child workflow of the `SUB_WORKFLOW` task `task` of `parent`: `{:ok, child}` when the child
  belongs to that workflow and task (ADR 0024, decision 2), `{:ok, nil}` when it does not or when
  its ID is one of `seen` (a store whose parent fields loop), and
  `{:error, {:not_found, message}}` for an unknown child.
  """
  @spec owned_child(Workflow.t(), Task.t(), [String.t()]) ::
          {:ok, Workflow.t() | nil} | {:error, {:not_found, String.t()}}
  def owned_child(%Workflow{} = parent, %Task{} = task, seen) do
    id = Task.sub_workflow_id(task)

    with false <- id in seen,
         {:ok, child} <- read_workflow(id) do
      if child.parent_workflow_id == parent.workflow_id and
           child.parent_workflow_task_id == task.task_id,
         do: {:ok, child},
         else: {:ok, nil}
    else
      true -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp read_workflow(id) do
    case Runtime.get_workflow(id, true) do
      {:ok, workflow} -> {:ok, workflow}
      {:error, :not_found} -> {:error, {:not_found, "No such workflow found by id: #{id}"}}
    end
  end

  # new TaskResult(pending) with the status, output and worker; the updated task's ID.
  defp update_pending(%Task{} = task, status, output, worker_id) do
    result = TaskResult.from_task(task)

    result = %{
      result
      | status: status,
        output_data: Map.merge(result.output_data, output),
        worker_id: worker_id
    }

    case update(result) do
      {:ok, %Task{task_id: id}} -> {:ok, id}
      {:ok, nil} -> {:ok, nil}
      {:error, :not_found} -> read_workflow(task.workflow_instance_id) |> missing_task(task)
      {:error, _reason} = error -> error
    end
  end

  # The workflow or the task went away between the read and the update: upstream's update reads
  # the workflow first, then the task.
  defp missing_task({:error, _reason} = error, _task), do: error

  defp missing_task({:ok, _workflow}, task),
    do: {:error, {:not_found, "No such task found by id: #{task.task_id}"}}

  # StringUtils.isBlank
  defp blank?(value), do: Validation.java_blank?(value)
end
