# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/DeciderService.java
# (decide, startWorkflow, filterNextLoopOverTasks, checkForWorkflowCompletion, getNextTask,
# getNextTasksToBeScheduled, getTasksToBeScheduled, isTaskSkipped)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: a pure function that returns the updated workflow in its outcome
# instead of mutating it, and a termination value instead of throwing; the clock, ID generator,
# task definitions and system task registry come from Archon.Decider.Context (ADR 0014).

defmodule Archon.Decider do
  @moduledoc """
  Evaluates a workflow against its definition and says what to do next (upstream
  `DeciderService`), as a pure function (ADR 0014, decision 1).

  `decide/2` never changes its input. Every change upstream made in place (task `executed`,
  `retried` and timeout markings, `COMPLETED_WITH_ERRORS`, the workflow output when complete) is
  in `Outcome.workflow`. Where upstream throws `TerminateWorkflowException`, `decide/2` returns
  `{:terminate, termination, outcome}` with the state reached so far. Persisting, queueing and
  notifying are the runtime's job (Phase 3).

  One call reads the clock once (`Context.now`), where upstream reads it per check.
  """

  alias Archon.Decider.{Context, Mapper, Outcome, Parameters, Retry, SystemTasks, Termination}
  alias Archon.Decider.Timeouts
  alias Archon.Domain.{Task, Workflow, WorkflowDef, WorkflowTask}

  @type result :: {:ok, Outcome.t()} | {:terminate, Termination.t(), Outcome.t()}

  # A task the outcome points at: one of the workflow's tasks by position, so that later
  # changes to it show (as upstream's shared references do), or a newly created task.
  @typep entry :: {:task, non_neg_integer()} | {:new, Task.t()}

  @doc """
  Upstream `DeciderService#decide`.

  A workflow whose tasks are all executed or skipped (a new one has none) is started first: the
  first task of the definition that is not skipped is scheduled, or for a re-run the first task
  is rescheduled. Then, unless the workflow is terminal or paused, each pending task is checked
  for timeouts, retried or marked when it failed, and marked executed with its next tasks
  scheduled once it is terminal. The workflow is complete when a `TERMINATE` task succeeded or
  nothing is left to schedule and `workflow_complete?/1` holds.
  """
  @spec decide(Workflow.t(), Context.t()) :: result()
  def decide(%Workflow{} = workflow, %Context{} = context) do
    if Enum.any?(workflow.tasks, &(&1.status != :skipped and not &1.executed)) do
      evaluate(workflow, [], context)
    else
      case start_workflow(workflow, context) do
        {:ok, entries, workflow} -> evaluate(workflow, entries, context)
        {:terminate, termination, workflow} -> {:terminate, termination, Outcome.new(workflow)}
      end
    end
  end

  defp start_workflow(%Workflow{tasks: tasks} = workflow, context)
       when tasks == [] or workflow.re_run_from_workflow_id == nil do
    case workflow.workflow_definition.tasks do
      [first | _rest] ->
        schedule_first(workflow, unskipped(workflow, first), context)

      _empty ->
        {:terminate, Termination.new("No tasks found to be executed", :completed), workflow}
    end
  end

  defp start_workflow(%Workflow{tasks: [first | _rest]} = workflow, _context) do
    first = %{first | status: :scheduled, retried: true, retry_count: 0}
    {:ok, [{:task, 0}], put_task(workflow, 0, first)}
  end

  # Upstream throws a NullPointerException when every task of the definition is skipped; nothing
  # is scheduled here.
  defp schedule_first(workflow, nil, _context), do: {:ok, [], workflow}

  defp schedule_first(workflow, %WorkflowTask{} = wt, context) do
    case tasks_to_be_scheduled(workflow, wt, 0, nil, context) do
      {:ok, new} -> {:ok, Enum.map(new, &{:new, &1}), workflow}
      {:terminate, termination} -> {:terminate, termination, workflow}
    end
  end

  defp evaluate(workflow, entries, context) do
    if Workflow.terminal?(workflow.status) do
      {:ok, Outcome.new(workflow)}
    else
      case Timeouts.check_workflow(workflow, context.now) do
        {:terminate, termination} -> {:terminate, termination, Outcome.new(workflow)}
        :ok when workflow.status == :paused -> {:ok, Outcome.new(workflow)}
        :ok -> process(workflow, entries, context)
      end
    end
  end

  defp process(workflow, entries, context) do
    pending =
      for {task, index} <- Enum.with_index(workflow.tasks),
          not task.retried and task.status != :skipped and not task.executed,
          do: index

    pending
    |> Enum.reduce_while({:ok, initial_state(workflow, entries)}, fn index, {:ok, state} ->
      case process_pending(state, index, context) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:terminate, termination, state} -> {:halt, {:terminate, termination, state}}
      end
    end)
    |> case do
      {:ok, state} -> finish(state)
      {:terminate, termination, state} -> {:terminate, termination, outcome(state)}
    end
  end

  defp initial_state(workflow, entries) do
    indexed = Enum.with_index(workflow.tasks)

    terminate_task =
      indexed
      |> Enum.filter(fn {task, _index} -> Retry.successful_terminate?(task) end)
      |> List.last()

    %{
      workflow: workflow,
      scheduled: Enum.reduce(entries, [], &put(&2, ref(workflow, &1), &1)),
      updated: [],
      executed:
        for({task, _} <- indexed, task.executed, into: MapSet.new(), do: task.reference_task_name),
      terminate_task: if(terminate_task, do: {:task, elem(terminate_task, 1)})
    }
  end

  defp process_pending(state, index, context) do
    task = task_at(state.workflow, index)
    ref = task.reference_task_name

    state =
      if SystemTasks.system_task?(context.system_tasks, task.task_type) and
           not Task.terminal?(task.status) do
        %{
          state
          | scheduled: put_new(state.scheduled, ref, {:task, index}),
            executed: MapSet.delete(state.executed, ref)
        }
      else
        state
      end

    task_def =
      Task.task_definition(task) ||
        case definition_task(state.workflow, ref) do
          %WorkflowTask{task_definition: task_def} -> task_def
          nil -> nil
        end

    with {:ok, state} <- check_timeouts(state, index, task_def, context),
         {:ok, state} <- handle_failure(state, index, task_def, context) do
      mark_executed(state, index, context)
    end
  end

  defp check_timeouts(state, _index, nil, _context), do: {:ok, state}

  defp check_timeouts(state, index, task_def, %Context{now: now} = context) do
    result =
      with {:ok, task} <- Timeouts.check_total(task_def, task_at(state.workflow, index), now),
           {:ok, task} <- Timeouts.check_task(task_def, task, now),
           {:ok, task} <- Timeouts.check_poll(task_def, task, now) do
        if Timeouts.response_timed_out?(task_def, task, now, context.system_tasks),
          do: {:ok, Timeouts.timeout_response(task_def, task)},
          else: {:ok, task}
      end

    case result do
      {:ok, task} -> {:ok, put_task(state, index, task)}
      {:terminate, termination, task} -> {:terminate, termination, put_task(state, index, task)}
    end
  end

  defp handle_failure(state, index, task_def, context) do
    task = task_at(state.workflow, index)

    if Task.terminal?(task.status) and not Task.successful?(task.status) do
      workflow_task =
        task.workflow_task || definition_task(state.workflow, task.reference_task_name)

      task_def
      |> Retry.retry(workflow_task, task, state.workflow, context)
      |> apply_retry(state, index, task)
    else
      {:ok, state}
    end
  end

  defp apply_retry({:retry, rescheduled, original}, state, index, _task) do
    ref = rescheduled.reference_task_name

    {:ok,
     %{
       put_task(state, index, original)
       | scheduled: put(state.scheduled, ref, {:new, rescheduled}),
         executed: MapSet.delete(state.executed, ref),
         updated: state.updated ++ [{:task, index}]
     }}
  end

  defp apply_retry(:no_retry, state, _index, %Task{
         workflow_task: %WorkflowTask{permissive: true, optional: false}
       }),
       do: {:ok, state}

  defp apply_retry(:no_retry, state, index, task),
    do: {:ok, put_task(state, index, %{task | status: :completed_with_errors})}

  defp apply_retry({:terminate, termination, workflow}, state, _index, _task),
    do: {:terminate, termination, %{state | workflow: workflow}}

  defp mark_executed(state, index, context) do
    task = task_at(state.workflow, index)

    if not task.executed and not task.retried and Task.terminal?(task.status) do
      task = %{task | executed: true}
      state = put_task(state, index, task)

      case next_tasks(state.workflow, task, context) do
        {:ok, next} -> {:ok, schedule_next(state, index, task, next)}
        {:terminate, termination} -> {:terminate, termination, state}
      end
    else
      {:ok, state}
    end
  end

  defp schedule_next(state, index, task, next) do
    next =
      if Task.loop_over_task?(task) and task.task_type != "DO_WHILE" and next != [],
        do: filter_next_loop_over_tasks(next, task, state.workflow),
        else: next

    scheduled =
      Enum.reduce(next, state.scheduled, &put_new(&2, &1.reference_task_name, {:new, &1}))

    %{state | scheduled: scheduled, updated: state.updated ++ [{:task, index}]}
  end

  defp finish(state) do
    outcome = outcome(state)

    if state.terminate_task != nil or
         (outcome.tasks_to_be_scheduled == [] and workflow_complete?(state.workflow)) do
      complete(outcome, permissive_failures(state.workflow))
    else
      {:ok, outcome}
    end
  end

  defp complete(outcome, []),
    do: {:ok, %{outcome | complete?: true, workflow: Retry.update_output(outcome.workflow, nil)}}

  defp complete(outcome, failures) do
    reason =
      Enum.map_join(failures, ". ", fn task ->
        "Task #{java_string(task.task_id)} failed with status: #{status_name(task.status)} " <>
          "and reason: '#{java_string(task.reason_for_incompletion)}'"
      end)

    {:terminate, Termination.new(reason), outcome}
  end

  # Permissive (and not optional) tasks whose latest attempt failed. Upstream collects them in a
  # HashMap, so with several failures the order of the joined message follows Java hashing; here
  # it follows the workflow's task order (ADR 0014).
  defp permissive_failures(%Workflow{tasks: tasks}) do
    tasks
    |> Enum.filter(fn
      %Task{workflow_task: %WorkflowTask{permissive: true, optional: false}} -> true
      %Task{} -> false
    end)
    |> Enum.reduce([], fn task, latest ->
      ref = task.reference_task_name

      case List.keyfind(latest, ref, 0) do
        {^ref, kept} when kept.retry_count > task.retry_count -> latest
        {^ref, _kept} -> List.keyreplace(latest, ref, 0, {ref, task})
        nil -> latest ++ [{ref, task}]
      end
    end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(Task.terminal?(&1.status) and not Task.successful?(&1.status)))
  end

  defp outcome(state) do
    scheduled =
      state.scheduled
      |> Enum.map(fn {_ref, entry} -> resolve(state.workflow, entry) end)
      |> Enum.reject(&MapSet.member?(state.executed, &1.reference_task_name))

    %Outcome{
      workflow: state.workflow,
      tasks_to_be_scheduled: scheduled,
      tasks_to_be_updated: Enum.map(state.updated, &resolve(state.workflow, &1)),
      terminate_task: state.terminate_task && resolve(state.workflow, state.terminate_task)
    }
  end

  @doc """
  Upstream `filterNextLoopOverTasks`: names the next tasks of a `DO_WHILE` body for the iteration
  of `pending` (`ref__<iteration>`) and drops those already in progress or terminal.
  """
  @spec filter_next_loop_over_tasks([Task.t()], Task.t(), Workflow.t()) :: [Task.t()]
  def filter_next_loop_over_tasks(tasks, %Task{iteration: iteration}, %Workflow{} = workflow) do
    in_workflow = started_refs(workflow)

    tasks
    |> Enum.map(
      &%{
        &1
        | reference_task_name: "#{&1.reference_task_name}__#{iteration}",
          iteration: iteration
      }
    )
    |> Enum.reject(&MapSet.member?(in_workflow, &1.reference_task_name))
  end

  @doc """
  Upstream `checkForWorkflowCompletion`: every task is terminal, every top-level task of the
  definition has run to a terminal state and no task still has an unscheduled successor. A
  successful `TERMINATE` task completes the workflow at once; a workflow without tasks is not
  complete.
  """
  @spec workflow_complete?(Workflow.t()) :: boolean()
  def workflow_complete?(%Workflow{tasks: tasks} = workflow) do
    case Enum.reduce_while(tasks, {%{}, []}, &collect_status/2) do
      decided when is_boolean(decided) ->
        decided

      {statuses, _unexecuted} when map_size(statuses) == 0 ->
        false

      {statuses, unexecuted} ->
        Enum.all?(workflow.workflow_definition.tasks, &terminal_in?(statuses, &1)) and
          not Enum.any?(unexecuted, &unscheduled_successor?(workflow, statuses, &1))
    end
  end

  defp collect_status(task, {statuses, unexecuted}) do
    statuses = Map.put(statuses, task.reference_task_name, task.status)

    cond do
      not Task.terminal?(task.status) -> {:halt, false}
      Retry.successful_terminate?(task) -> {:halt, true}
      not task.retried or not task.executed -> {:cont, {statuses, [task | unexecuted]}}
      true -> {:cont, {statuses, unexecuted}}
    end
  end

  defp terminal_in?(statuses, %WorkflowTask{task_reference_name: ref}) do
    status = Map.get(statuses, ref)
    status != nil and Task.terminal?(status)
  end

  # getNextTasksToBeScheduled: unlike getNextTask, the iteration suffix is kept.
  defp unscheduled_successor?(workflow, statuses, task) do
    case unskipped(workflow, next_definition_task(workflow, task.reference_task_name)) do
      %WorkflowTask{task_reference_name: next} -> not Map.has_key?(statuses, next)
      nil -> false
    end
  end

  @doc """
  Upstream `getNextTask`: the tasks to schedule after `task` finished. A `DECISION`/`SWITCH`
  system task that scheduled its branch (`hasChildren` input) has none, skipped tasks are passed
  over and a `DO_WHILE` already in the workflow is not scheduled again.
  """
  @spec next_tasks(Workflow.t(), Task.t(), Context.t()) ::
          {:ok, [Task.t()]} | {:terminate, Termination.t()}
  def next_tasks(%Workflow{} = workflow, %Task{} = task, %Context{} = context) do
    if SystemTasks.system_task?(context.system_tasks, task.task_type) and
         task.task_type in ["DECISION", "SWITCH"] and
         Map.get(task.input_data, "hasChildren") != nil do
      {:ok, []}
    else
      ref =
        if Task.loop_over_task?(task),
          do: Parameters.remove_iteration(task.reference_task_name),
          else: task.reference_task_name

      schedule_after(workflow, unskipped(workflow, next_definition_task(workflow, ref)), context)
    end
  end

  defp schedule_after(_workflow, nil, _context), do: {:ok, []}

  defp schedule_after(
         workflow,
         %WorkflowTask{type: "DO_WHILE", task_reference_name: ref} = wt,
         context
       ) do
    if Enum.any?(workflow.tasks, &(&1.reference_task_name == ref)),
      do: {:ok, []},
      else: tasks_to_be_scheduled(workflow, wt, 0, nil, context)
  end

  defp schedule_after(workflow, wt, context),
    do: tasks_to_be_scheduled(workflow, wt, 0, nil, context)

  @doc """
  Upstream `getTasksToBeScheduled`: maps `workflow_task` with its type's mapper
  (`Archon.Decider.Mapper`) and drops tasks whose reference name is already in progress or
  terminal in the workflow.
  """
  @spec tasks_to_be_scheduled(
          Workflow.t(),
          WorkflowTask.t(),
          integer(),
          String.t() | nil,
          Context.t()
        ) :: {:ok, [Task.t()]} | {:terminate, Termination.t()}
  def tasks_to_be_scheduled(workflow, %WorkflowTask{} = wt, retry_count, retried_task_id, context) do
    mapper_context = %Mapper.Context{
      workflow: workflow,
      task_definition: wt.task_definition,
      workflow_task: wt,
      task_input: Parameters.task_input(wt.input_parameters, workflow, nil, nil),
      retry_count: retry_count,
      retry_task_id: retried_task_id,
      task_id: context.new_id.(),
      decider: context
    }

    case Mapper.module_for(wt.type).map(wt, mapper_context) do
      {:ok, tasks} ->
        in_workflow = started_refs(workflow)
        {:ok, Enum.reject(tasks, &MapSet.member?(in_workflow, &1.reference_task_name))}

      {:terminate, reason} ->
        {:terminate, Termination.new(reason)}
    end
  end

  # Reference names of tasks in progress or terminal.
  defp started_refs(%Workflow{tasks: tasks}) do
    for task <- tasks,
        task.status == :in_progress or Task.terminal?(task.status),
        into: MapSet.new(),
        do: task.reference_task_name
  end

  # isTaskSkipped, applied until a task that is not skipped (or nil) is reached.
  defp unskipped(_workflow, nil), do: nil

  defp unskipped(workflow, %WorkflowTask{task_reference_name: ref} = wt) do
    case workflow.tasks |> Enum.filter(&(&1.reference_task_name == ref)) |> List.last() do
      %Task{status: :skipped} -> unskipped(workflow, next_definition_task(workflow, ref))
      _other -> wt
    end
  end

  defp next_definition_task(%Workflow{workflow_definition: definition}, ref),
    do: WorkflowDef.next_task(definition, ref)

  defp definition_task(%Workflow{workflow_definition: definition}, ref),
    do: WorkflowDef.task_by_ref_name(definition, ref)

  defp task_at(%Workflow{tasks: tasks}, index), do: Enum.at(tasks, index)

  defp put_task(%Workflow{tasks: tasks} = workflow, index, task),
    do: %{workflow | tasks: List.replace_at(tasks, index, task)}

  defp put_task(%{workflow: workflow} = state, index, task),
    do: %{state | workflow: put_task(workflow, index, task)}

  defp resolve(workflow, {:task, index}), do: task_at(workflow, index)
  defp resolve(_workflow, {:new, task}), do: task

  defp ref(workflow, entry), do: resolve(workflow, entry).reference_task_name

  # LinkedHashMap#put: replaces the value in place, or appends.
  @spec put([{String.t(), entry()}], String.t(), entry()) :: [{String.t(), entry()}]
  defp put(entries, ref, entry) do
    if List.keymember?(entries, ref, 0),
      do: List.keyreplace(entries, ref, 0, {ref, entry}),
      else: entries ++ [{ref, entry}]
  end

  # LinkedHashMap#putIfAbsent
  defp put_new(entries, ref, entry) do
    if List.keymember?(entries, ref, 0), do: entries, else: entries ++ [{ref, entry}]
  end

  defp status_name(status), do: status |> Atom.to_string() |> String.upcase()

  defp java_string(nil), do: "null"
  defp java_string(value), do: value
end
