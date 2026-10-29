# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (setTaskDomains, getActiveDomain, dedupAndAddTasks, scheduleTask, addTaskToQueue) and
# core/.../utils/QueueUtils.java (getQueueName) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: pure functions over the step state; poll data comes from the env, queue
# pushes become effects, and asynchronous system tasks are marked for evaluation by the workflow
# process instead of being queued (ADR 0018, decisions 4 and 6).

defmodule Archon.Runtime.Step.Schedule do
  @moduledoc """
  How new tasks join a workflow (upstream `WorkflowExecutorOps`): their domains, deduplication,
  `seq`, `firstScheduledTime`, the start of synchronous system tasks and the queue push of
  worker tasks.
  """

  alias Archon.Decider.SystemTasks
  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.Step.{Env, State}

  # WorkflowSystemTask#isAsync
  @async ~w(JOIN WAIT SUB_WORKFLOW)

  @doc "A registered system task type."
  @spec system_task?(Env.t(), Task.t()) :: boolean()
  def system_task?(%Env{system_tasks: registry}, %Task{task_type: type}),
    do: SystemTasks.system_task?(registry, type)

  @doc "Upstream `WorkflowSystemTask#isAsync` for a system task."
  @spec async?(Task.t()) :: boolean()
  def async?(%Task{task_type: type}), do: type in @async

  @doc "A system task the decide loop runs in place (not `isAsync`)."
  @spec sync_system_task?(Env.t(), Task.t()) :: boolean()
  def sync_system_task?(env, task), do: system_task?(env, task) and not async?(task)

  @doc """
  Upstream `QueueUtils#getQueueName` without the execution namespace and isolation group
  (ADR 0018, decision 3): `domain:taskType`, or the task type without a domain.
  """
  @spec queue_name(Task.t()) :: String.t()
  def queue_name(%Task{domain: nil, task_type: type}), do: type
  def queue_name(%Task{domain: domain, task_type: type}), do: "#{domain}:#{type}"

  @doc """
  Upstream `setTaskDomains`: with a `taskToDomain` mapping, every task that is not a system task
  takes the active domain of the `*` entry, then of the entry for its task type.
  """
  @spec set_task_domains([Task.t()], Workflow.t(), Env.t()) :: [Task.t()]
  def set_task_domains(tasks, %Workflow{task_to_domain: mapping}, _env)
      when mapping in [nil, %{}],
      do: tasks

  def set_task_domains(tasks, %Workflow{task_to_domain: mapping}, env) do
    tasks =
      case Map.get(mapping, "*") do
        all when is_binary(all) ->
          if String.trim(all) == "",
            do: tasks,
            else: map_worker(tasks, env, &%{&1 | domain: active_domain(&1, split(all), env)})

        _none ->
          tasks
      end

    map_worker(tasks, env, fn task ->
      case Map.get(mapping, task.task_type) do
        nil -> task
        domains -> %{task | domain: active_domain(task, split(domains), env)}
      end
    end)
  end

  defp map_worker(tasks, env, fun),
    do: Enum.map(tasks, &if(system_task?(env, &1), do: &1, else: fun.(&1)))

  @doc """
  Upstream `getActiveDomain`: the first domain other than `NO_DOMAIN` where a worker polled in
  the last `active_worker_last_poll_ms`, else the last domain, or `nil` when that is
  `NO_DOMAIN` or there are none.
  """
  @spec active_domain(Task.t() | String.t(), [String.t()] | nil, Env.t()) :: String.t() | nil
  def active_domain(%Task{task_type: type}, domains, env), do: active_domain(type, domains, env)
  def active_domain(_type, domains, _env) when domains in [nil, []], do: nil

  def active_domain(type, domains, %Env{} = env) do
    since = env.now - env.active_worker_last_poll_ms

    active =
      domains
      |> Enum.reject(&no_domain?/1)
      |> Enum.map(&String.trim/1)
      |> Enum.find(fn domain ->
        case Map.fetch(env.poll_data, {type, domain}) do
          {:ok, last_poll} -> last_poll > since
          :error -> false
        end
      end)

    last = domains |> List.last() |> String.trim()

    cond do
      active != nil -> active
      no_domain?(last) -> nil
      true -> last
    end
  end

  defp no_domain?(domain), do: String.downcase(domain) == "no_domain"

  # Java String#split(","): trailing empty strings are dropped, but "" splits into [""].
  defp split(""), do: [""]

  defp split(string) do
    string
    |> String.split(",")
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  @doc """
  Upstream `dedupAndAddTasks`: the tasks whose reference name and retry count are not in the
  workflow yet, which are appended to it in memory.
  """
  @spec dedup_and_add(State.t(), [Task.t()]) :: {State.t(), [Task.t()]}
  def dedup_and_add(%State{wf: wf} = state, tasks) do
    in_workflow = MapSet.new(wf.tasks, &key/1)
    new = Enum.reject(tasks, &MapSet.member?(in_workflow, key(&1)))
    {State.put_workflow(state, %{wf | tasks: wf.tasks ++ new}), new}
  end

  defp key(%Task{reference_task_name: ref, retry_count: retry_count}), do: {ref, retry_count}

  @doc """
  Upstream `scheduleTask`: numbers the tasks after the highest `seq`, stamps
  `firstScheduledTime`, saves them, gives system tasks that are not terminal a `startTime`,
  starts the synchronous ones and pushes worker tasks to their queues. Asynchronous system tasks
  without a delay are marked for evaluation (ADR 0018, decision 6). Returns whether a
  synchronous system task started.
  """
  @spec schedule(State.t(), [Task.t()]) :: {State.t(), boolean()}
  def schedule(state, []), do: {state, false}

  def schedule(%State{wf: wf, now: now, env: env} = state, tasks) do
    seq = wf.tasks |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

    {tasks, _seq} =
      Enum.map_reduce(tasks, seq, fn task, seq ->
        {task, seq} = if task.seq == 0, do: {%{task | seq: seq + 1}, seq + 1}, else: {task, seq}

        task =
          if task.first_scheduled_time == 0, do: %{task | first_scheduled_time: now}, else: task

        {start_time(task, env, now), seq}
      end)

    state = State.create_tasks(state, tasks)

    Enum.reduce(tasks, {state, false}, fn task, {state, started?} ->
      cond do
        sync_system_task?(env, task) ->
          # The synchronous system tasks have no `start` of their own.
          {State.save_task(state, task), true}

        system_task?(env, task) ->
          {if(delay_ms(task) == 0, do: State.due(state, [task.task_id]), else: state), started?}

        true ->
          {push(state, task), started?}
      end
    end)
  end

  defp start_time(task, env, now) do
    if system_task?(env, task) and not Task.terminal?(task.status) and task.start_time == 0,
      do: %{task | start_time: now},
      else: task
  end

  @doc "Upstream `addTaskToQueue`: pushes a worker task with its callback delay."
  @spec push(State.t(), Task.t()) :: State.t()
  def push(state, task),
    do:
      State.post(
        state,
        {:queue_push, queue_name(task), task.task_id, task.workflow_priority, delay_ms(task)}
      )

  @doc "The delay a task is queued with: `callbackAfterMs`, else `callbackAfterSeconds`."
  @spec delay_ms(Task.t()) :: non_neg_integer()
  def delay_ms(%Task{callback_after_ms: ms}) when ms > 0, do: ms
  def delay_ms(%Task{callback_after_seconds: seconds}) when seconds > 0, do: seconds * 1000
  def delay_ms(%Task{}), do: 0
end
