# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.DeciderReplay do
  @moduledoc """
  Plays the upstream runtime around `Archon.Decider.decide/2` so that captured scenarios can be
  replayed and compared with what the upstream server returned (ADR 0014, decision 8).

  Each step follows upstream at commit 1488804170d159021c7e62dce61514b8f31ef9ff:

    * `start/3` - `MetadataMapperService` embeds task definitions (registered ones, else an ad-hoc
      definition with no retries or response timeout for system tasks), then the first decide.
    * `decide/2` - the `WorkflowExecutorOps#decide` loop: persist `tasks_to_be_updated`, add new
      tasks deduplicated by reference name and retry count with `seq` and `firstScheduledTime`,
      start synchronous system tasks, `execute` them, and decide again while that changed state.
      On completion only the status and output are stored, so tasks keep `executed: false`.
    * `poll/3` and `update/3` - `ExecutionService#poll` and `#updateTask`. The update skips the
      decide like `isLazyEvaluateWorkflow` for a successful forked task a `JOIN` waits on.
    * `run_async/2` - `AsyncSystemTaskExecutor#execute` for each pending asynchronous system task
      (`JOIN`), deciding when one finished.

  Task IDs and time fields are compared as `Archon.Contract.normalize/1` leaves them.
  """

  import ExUnit.Assertions

  alias Archon.Contract
  alias Archon.Decider
  alias Archon.Decider.{Context, Outcome, SystemTask, SystemTasks}
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}

  @worker "archon-contract"
  @async ["JOIN"]

  @doc "A clock for the replay: every reading advances it by 10 ms."
  @spec clock() :: :counters.counters_ref()
  def clock do
    clock = :counters.new(1, [])
    :counters.put(clock, 1, 1_000)
    clock
  end

  @doc "The next clock reading."
  @spec tick(:counters.counters_ref()) :: integer()
  def tick(clock) do
    :counters.add(clock, 1, 10)
    :counters.get(clock, 1)
  end

  @doc """
  The server's stored definition (`metadata` fixture) with task definitions embedded as
  `MetadataMapperService#populateWorkflowWithDefinitions` does. Registered task definitions are
  the ones of `metadata_register_taskdefs` with the fields the server stamps on registration.
  """
  @spec populated_definition(String.t()) :: WorkflowDef.t()
  def populated_definition(fixture) do
    {:ok, definition} = WorkflowDef.from_json(Contract.fixture(fixture)["response"]["body"])
    task_defs = registered_task_defs()
    %{definition | tasks: Enum.map(definition.tasks, &populate(&1, task_defs))}
  end

  @doc "The registered task definitions by name, as the server stores them."
  @spec registered_task_defs() :: %{String.t() => TaskDef.t()}
  def registered_task_defs do
    stored_a = Contract.fixture("metadata_get_taskdef")["response"]["body"]

    task_defs =
      Map.new(Contract.fixture("metadata_register_taskdefs")["request"]["body"], fn json ->
        {:ok, task_def} = TaskDef.from_json(json)
        {task_def.name, %{task_def | created_by: "", create_time: stored_a["createTime"]}}
      end)

    assert Contract.normalize(TaskDef.to_json(task_defs["archon_task_a"])) ==
             Contract.normalize(stored_a)

    task_defs
  end

  defp populate(%WorkflowTask{} = wt, task_defs) do
    %{
      wt
      | task_definition: wt.task_definition || task_def(wt, task_defs),
        decision_cases:
          Map.new(wt.decision_cases, fn {name, tasks} ->
            {name, Enum.map(tasks, &populate(&1, task_defs))}
          end),
        default_case: Enum.map(wt.default_case, &populate(&1, task_defs)),
        fork_tasks:
          Enum.map(wt.fork_tasks, fn branch -> Enum.map(branch, &populate(&1, task_defs)) end),
        loop_over: Enum.map(wt.loop_over, &populate(&1, task_defs))
    }
  end

  defp task_def(%WorkflowTask{name: name, type: type}, task_defs) do
    case Map.get(task_defs, name) do
      nil when type == "SIMPLE" -> %TaskDef{name: name}
      nil -> %TaskDef{name: name, retry_count: 0, response_timeout_seconds: 0}
      task_def -> task_def
    end
  end

  @doc "A new running workflow with its first decide."
  @spec start(WorkflowDef.t(), keyword(), :counters.counters_ref()) :: Workflow.t()
  def start(%WorkflowDef{} = definition, fields, clock) do
    Workflow
    |> struct(
      Keyword.merge(
        [
          owner_app: "",
          status: :running,
          create_time: tick(clock),
          workflow_definition: definition
        ],
        fields
      )
    )
    |> decide(clock)
  end

  @doc "The `WorkflowExecutorOps#decide` loop and what it persists."
  @spec decide(Workflow.t(), :counters.counters_ref()) :: Workflow.t()
  def decide(workflow, clock) do
    now = tick(clock)
    assert {:ok, %Outcome{} = outcome} = Decider.decide(workflow, Context.new(now: now))

    if outcome.complete? do
      %{
        workflow
        | status: :completed,
          output: outcome.workflow.output,
          end_time: now,
          update_time: now
      }
    else
      {workflow, started?} = persist(workflow, outcome, now)
      {workflow, executed?} = execute_sync(workflow, outcome.tasks_to_be_scheduled, now)
      if started? or executed?, do: decide(workflow, clock), else: workflow
    end
  end

  defp persist(workflow, outcome, now) do
    updated = Map.new(outcome.tasks_to_be_updated, &{&1.task_id, &1})
    tasks = Enum.map(workflow.tasks, &Map.get(updated, &1.task_id, &1))
    in_workflow = MapSet.new(tasks, &{&1.reference_task_name, &1.retry_count})
    seq = tasks |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

    scheduled =
      outcome.tasks_to_be_scheduled
      |> Enum.reject(&MapSet.member?(in_workflow, {&1.reference_task_name, &1.retry_count}))
      |> Enum.with_index(seq + 1)
      |> Enum.map(fn {task, seq} -> schedule(task, seq, now) end)

    started? = Enum.any?(scheduled, &sync_system_task?/1)
    {%{workflow | tasks: tasks ++ scheduled, update_time: now}, started?}
  end

  # scheduleTask: seq, firstScheduledTime and a start time for system tasks still running.
  defp schedule(task, seq, now) do
    task = %{task | seq: seq, first_scheduled_time: now}

    if system_task?(task) and not Task.terminal?(task.status) and (task.start_time || 0) == 0,
      do: %{task | start_time: now},
      else: task
  end

  defp execute_sync(workflow, scheduled, now) do
    scheduled
    |> Enum.filter(&(sync_system_task?(&1) and not Task.terminal?(&1.status)))
    |> Enum.reduce({workflow, false}, fn %Task{task_id: id}, {workflow, changed?} ->
      task = Enum.find(workflow.tasks, &(&1.task_id == id))
      {executed?, task} = SystemTask.execute(workflow, task, now)
      if executed?, do: {replace(workflow, task), true}, else: {workflow, changed?}
    end)
  end

  @doc "`AsyncSystemTaskExecutor#execute` for every pending `JOIN`, then a decide if one finished."
  @spec run_async(Workflow.t(), :counters.counters_ref()) :: Workflow.t()
  def run_async(workflow, clock) do
    pending =
      Enum.filter(workflow.tasks, &(&1.task_type in @async and not Task.terminal?(&1.status)))

    {workflow, finished?} =
      Enum.reduce(pending, {workflow, false}, fn %Task{task_id: id}, {workflow, finished?} ->
        now = tick(clock)
        task = Enum.find(workflow.tasks, &(&1.task_id == id))
        task = %{task | poll_count: task.poll_count + 1}
        {_changed?, task} = SystemTask.execute(workflow, task, now)

        if Task.terminal?(task.status),
          do: {replace(workflow, %{task | end_time: now, update_time: now}), true},
          else:
            {replace(workflow, %{task | callback_after_seconds: 0, update_time: now}), finished?}
      end)

    if finished?, do: decide(workflow, clock), else: workflow
  end

  @doc "`ExecutionService#poll`: the worker takes the scheduled task with the reference name."
  @spec poll(Workflow.t(), String.t(), :counters.counters_ref()) :: Workflow.t()
  def poll(workflow, ref, clock) do
    now = tick(clock)

    update_task(workflow, &(&1.reference_task_name == ref and &1.status == :scheduled), fn task ->
      %{
        task
        | status: :in_progress,
          poll_count: task.poll_count + 1,
          start_time: now,
          update_time: now,
          worker_id: @worker
      }
    end)
  end

  @doc """
  `ExecutionService#updateTask` with the captured `TaskResult` for the in-progress task with the
  reference name, then a decide unless `isLazyEvaluateWorkflow` skips it.
  """
  @spec update(Workflow.t(), String.t(), map(), :counters.counters_ref()) :: Workflow.t()
  def update(workflow, ref, fixture, clock) do
    now = tick(clock)
    result = fixture["request"]["body"]
    assert result["workflowInstanceId"] == workflow.workflow_id
    {:ok, %Task{status: status}} = Task.from_json(%{"status" => result["status"]})

    workflow =
      update_task(
        workflow,
        &(&1.reference_task_name == ref and &1.status == :in_progress),
        fn task ->
          %{
            task
            | status: status,
              output_data: result["outputData"],
              worker_id: result["workerId"],
              end_time: now,
              update_time: now
          }
        end
      )

    task = Enum.find(workflow.tasks, &(&1.reference_task_name == ref))
    if lazy?(workflow.workflow_definition, task), do: workflow, else: decide(workflow, clock)
  end

  # isLazyEvaluateWorkflow, for tasks the definition names.
  defp lazy?(definition, %Task{reference_task_name: ref} = task) do
    tasks = WorkflowDef.collect_tasks(definition)
    forked? = Enum.any?(tasks, &(&1.type == "FORK_JOIN" and WorkflowTask.has?(&1, ref)))

    not Task.loop_over_task?(task) and forked? and
      Enum.any?(tasks, &(&1.type == "JOIN" and ref in &1.join_on)) and
      Task.successful?(task.status)
  end

  @doc "Compares the workflow with the response of a `GET /api/workflow/{id}` fixture."
  @spec assert_matches(Workflow.t(), String.t()) :: true
  def assert_matches(workflow, fixture) do
    expected = Contract.fixture(fixture)["response"]["body"]
    actual = workflow |> Workflow.to_json() |> JSON.encode!() |> JSON.decode!()
    assert Contract.normalize(actual) == Contract.normalize(expected)
  end

  defp update_task(workflow, match, fun) do
    assert [_task] = Enum.filter(workflow.tasks, match)
    %{workflow | tasks: Enum.map(workflow.tasks, &if(match.(&1), do: fun.(&1), else: &1))}
  end

  defp replace(workflow, %Task{task_id: id} = task),
    do: %{workflow | tasks: Enum.map(workflow.tasks, &if(&1.task_id == id, do: task, else: &1))}

  defp system_task?(%Task{task_type: type}),
    do: SystemTasks.system_task?(SystemTasks.default(), type)

  defp sync_system_task?(task), do: system_task?(task) and task.task_type not in @async
end
