# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (pauseWorkflow, resumeWorkflow, retry, taskToBeRescheduled, clearRetriedTaskRuntimeState,
# clearLegacySubWorkflowId, isJoinOnFailedPermissive, restart, updateAndPushParents,
# adjustStateIfSubWorkflowChanged, findChangedSubWorkflowTask, resetUnsuccessfulJoinTasks) and
# core/.../model/WorkflowModel.java (toString, toShortString)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: each operation is an event of the workflow's own process; the parents
# are revived by a message to each parent in turn instead of one loop over the store, and the
# decider queue push became the step's decide (ADR 0018, decision 9).

defmodule Archon.Runtime.Step.Lifecycle do
  @moduledoc """
  The lifecycle operations of a workflow (ADR 0018, decision 9), each one event of its process.

    * `pause/1`, `resume/1` - upstream `pauseWorkflow`, `resumeWorkflow`.
    * `retry/2` - upstream `retry`: the last failed or canceled instance of each task is
      scheduled again (a new task, or in place for `JOIN`, `FORK_JOIN`, `DO_WHILE`), the workflow
      runs again and is decided. With `push_parents?` its parent is asked to revive
      (`updateAndPushParents`) before the decide's own effects.
    * `restart/2` - upstream `restart`: the tasks are deleted and the workflow starts over.
    * `child_revived/2` - one level of upstream `updateAndPushParents`, on the parent: the task of
      the child that runs again goes back to `IN_PROGRESS`, the workflow runs again, its other
      failed `SUB_WORKFLOW` children are retried and its canceled tasks scheduled again; then it
      asks its own parent to revive.
    * `adjust/1` - upstream `adjustStateIfSubWorkflowChanged`, run by every decide.

  Replies are `:ok` or `{:error, {kind, message}}` with upstream's exception as `kind`:
  `:conflict` (`ConflictException`), `:not_found` (`NotFoundException`) or `:invalid_state`
  (`IllegalStateException`), and its message.
  """

  alias Archon.Decider.Parameters
  alias Archon.Domain.{Task, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step.{Decide, Schedule, State}

  @type reply :: :ok | {:error, {:conflict | :not_found | :invalid_state, String.t()}}

  # Retried in place, with the same task ID (taskToBeRescheduled).
  @in_place ["DO_WHILE", "FORK_JOIN", "JOIN", "EXCLUSIVE_JOIN"]

  @doc """
  Upstream `pauseWorkflow`: a terminal workflow is a conflict, a paused one stays as it is. A
  paused workflow is not woken by its timer (ADR 0018, decision 9).
  """
  @spec pause(State.t()) :: {reply(), State.t()}
  def pause(%State{wf: wf} = state) do
    cond do
      Workflow.terminal?(wf.status) ->
        {{:error,
          {:conflict, "Workflow #{short_string(wf)} has ended, status cannot be updated."}},
         state}

      wf.status == :paused ->
        {:ok, state}

      true ->
        state =
          state
          |> State.put_workflow(State.set_status(wf, :paused))
          |> State.save_workflow()
          |> State.post(:cancel_wake)

        {:ok, state}
    end
  end

  @doc """
  Upstream `resumeWorkflow`: a running workflow stays as it is, one that is not paused is an
  invalid state; a paused one runs again with `lastRetriedTime` and is decided.
  """
  @spec resume(State.t()) :: {reply(), State.t()}
  def resume(%State{wf: wf, now: now} = state) do
    case wf.status do
      :running ->
        {:ok, state}

      :paused ->
        wf = %{State.set_status(wf, :running) | last_retried_time: now}
        {:ok, state |> State.put_workflow(wf) |> State.save_workflow() |> Decide.settle()}

      status ->
        {{:error,
          {:invalid_state,
           "The workflow #{wf.workflow_id} is not PAUSED so cannot resume. " <>
             "Current status is #{status_name(status)}"}}, state}
    end
  end

  @doc """
  Upstream `retry(workflowId, false)`: a running workflow and one without tasks are refused, the
  failed and canceled tasks are scheduled again, the parent is asked to revive when
  `push_parents?`, and the workflow is decided. A workflow without a task to retry is a conflict
  unless it timed out.
  """
  @spec retry(State.t(), boolean()) :: {reply(), State.t()}
  def retry(%State{wf: wf} = state, push_parents?) do
    cond do
      not Workflow.terminal?(wf.status) ->
        {{:error, {:not_found, "Workflow is still running.  status=#{status_name(wf.status)}"}},
         state}

      wf.tasks == [] ->
        {{:error, {:conflict, "Workflow has not started yet"}}, state}

      true ->
        case retriable(state) do
          {:ok, retried} ->
            state = retried |> push_parents(push_parents?) |> Decide.settle()
            {:ok, state}

          {:error, _reason} = error ->
            {error, state}
        end
    end
  end

  # retry(WorkflowModel): the last instance of each FAILED, FAILED_WITH_TERMINAL_ERROR, TIMED_OUT
  # or CANCELED task is retried; a canceled JOIN or DO_WHILE, and a FAILED JOIN whose permissive
  # task failed, run again in place.
  defp retriable(%State{wf: wf} = state) do
    {retriable, tasks, due} =
      Enum.reduce(wf.tasks, {%{}, [], []}, fn task, {retriable, tasks, due} ->
        ref = task.reference_task_name

        case retry_kind(task, wf) do
          :in_place -> {retriable, [%{task | status: :in_progress} | tasks], [task.task_id | due]}
          :retry -> {Map.put(retriable, ref, task), [task | tasks], due}
          :keep -> {Map.delete(retriable, ref), [task | tasks], due}
        end
      end)

    if map_size(retriable) == 0 and wf.status != :timed_out do
      {:error,
       {:conflict,
        "There are no retryable tasks! Use restart if you want to attempt entire workflow " <>
          "execution again."}}
    else
      wf = %{
        State.set_status(%{wf | tasks: Enum.reverse(tasks)}, :running)
        | last_retried_time: state.now,
          reason_for_incompletion: nil
      }

      state = state |> State.put_workflow(wf) |> State.save_workflow() |> State.due(due)
      {:ok, reschedule(state, retriable |> Map.values() |> Enum.sort_by(& &1.seq))}
    end
  end

  defp retry_kind(%Task{status: :failed, task_type: type} = task, wf)
       when type in ["JOIN", "EXCLUSIVE_JOIN"] do
    if join_on_failed_permissive?(task, wf), do: :in_place, else: :retry
  end

  defp retry_kind(%Task{status: status}, _wf)
       when status in [:failed, :failed_with_terminal_error, :timed_out],
       do: :retry

  defp retry_kind(%Task{status: :canceled, task_type: type}, _wf)
       when type in ["JOIN", "DO_WHILE"],
       do: :in_place

  defp retry_kind(%Task{status: :canceled}, _wf), do: :retry
  defp retry_kind(%Task{}, _wf), do: :keep

  # isJoinOnFailedPermissive: a task the JOIN waits on (its last instance) is permissive, not
  # optional, and FAILED.
  defp join_on_failed_permissive?(%Task{input_data: input}, %Workflow{tasks: tasks}) do
    (Map.get(input, "joinOn") || [])
    |> Enum.map(fn ref ->
      tasks |> Enum.filter(&(&1.reference_task_name == ref)) |> List.last()
    end)
    |> Enum.any?(fn
      %Task{workflow_task: %WorkflowTask{permissive: true, optional: false}, status: :failed} ->
        true

      _other ->
        false
    end)
  end

  # The rest of retry(WorkflowModel): taskToBeRescheduled for each task, dedupAndAddTasks,
  # updateTasks for every task of the workflow, then scheduleTask.
  defp reschedule(%State{} = state, tasks) do
    {rescheduled, state} = Enum.map_reduce(tasks, state, &reschedule_task(&2, &1))
    {state, _new} = Schedule.dedup_and_add(state, rescheduled)
    state = State.save_tasks(state, state.wf.tasks)
    {state, _started?} = Schedule.schedule(state, rescheduled)
    state
  end

  # taskToBeRescheduled
  defp reschedule_task(state, %Task{task_type: type} = task) when type in @in_place do
    task = %{task | retried: false, retry_count: task.retry_count + 1, status: :in_progress}
    {task, State.put_task(state, task)}
  end

  defp reschedule_task(%State{env: env, wf: wf} = state, %Task{} = task) do
    id = env.new_id.()

    copy = %{
      task
      | task_id: id,
        retried_task_id: task.task_id,
        status: :scheduled,
        retry_count: task.retry_count + 1,
        retried: false,
        poll_count: 0,
        callback_after_seconds: 0,
        callback_after_ms: 0,
        sub_workflow_id: nil,
        scheduled_time: 0,
        start_time: 0,
        end_time: 0,
        update_time: 0,
        worker_id: nil,
        reason_for_incompletion: nil,
        seq: 0,
        output_data: %{},
        external_output_payload_storage_path: nil
    }

    copy =
      case copy.workflow_task do
        %WorkflowTask{} = wt ->
          input = Parameters.task_input(wt.input_parameters, wf, id, wt.task_definition)
          %{copy | input_data: Map.merge(copy.input_data, input)}

        nil ->
          copy
      end

    # clearLegacySubWorkflowId
    copy = %{copy | input_data: Map.delete(copy.input_data, "subWorkflowId")}

    {copy, State.put_task(state, %{task | retried: true, executed: true})}
  end

  @doc """
  Upstream `restart`: a terminal workflow starts over with its stored definition, or with
  `definition` (the latest one, task definitions embedded) when given. A completed workflow
  whose definition is not restartable is refused. The tasks are deleted, the workflow is running
  again from now and decided, and its parent is asked to revive.
  """
  @spec restart(State.t(), WorkflowDef.t() | nil) :: {reply(), State.t()}
  def restart(%State{wf: wf} = state, definition) do
    definition = definition || wf.workflow_definition

    cond do
      not Workflow.terminal?(wf.status) ->
        {{:error,
          {:conflict, "Workflow: #{long_string(wf)} is not in terminal state, unable to restart."}},
         state}

      definition == nil ->
        {{:error, {:not_found, "Unable to find definition for #{wf.workflow_id}"}}, state}

      wf.status == :completed and not definition.restartable ->
        # upstream sets the latest definition before the check
        {{:error,
          {:not_found,
           "Workflow: #{long_string(%{wf | workflow_definition: definition})} is non-restartable"}},
         state}

      true ->
        state = State.delete_tasks(state, Enum.map(wf.tasks, & &1.task_id))

        wf = %{
          State.set_status(state.wf, :running)
          | workflow_definition: definition,
            reason_for_incompletion: nil,
            failed_task_id: nil,
            create_time: state.now,
            end_time: 0,
            last_retried_time: 0,
            output: %{},
            external_output_payload_storage_path: nil
        }

        state =
          state
          |> State.put_workflow(wf)
          |> State.save_workflow()
          |> push_parents(true)
          |> Decide.settle()

        {:ok, state}
    end
  end

  # updateAndPushParents starts at the parent: it gets a message once this workflow's commit is
  # saved (ADR 0018, decision 1: a child only casts to its parent).
  defp push_parents(state, false), do: state

  defp push_parents(%State{wf: %Workflow{parent_workflow_id: parent} = wf} = state, true)
       when parent not in [nil, ""],
       do: State.post(state, {:revive_parent, parent, wf.parent_workflow_task_id})

  defp push_parents(state, true), do: state

  @doc """
  One level of upstream `updateAndPushParents`, on the parent of a child that runs again. The
  walk stops when the task is gone (the parent restarted), is optional, or is a `SUB_WORKFLOW`
  task already retried. Otherwise the task goes back to `IN_PROGRESS` marked
  `subworkflowChanged`, the workflow runs again without its failure, each other `SUB_WORKFLOW`
  task that failed follows its child (one that runs again) or retries it, canceled `JOIN` and
  `DO_WHILE` tasks run again in place and other canceled tasks are scheduled again; then the
  workflow is decided and asks its own parent.
  """
  @spec child_revived(State.t(), String.t()) :: State.t()
  def child_revived(%State{} = state, task_id) do
    case State.task(state, task_id) do
      %Task{workflow_task: %WorkflowTask{optional: false}} = task ->
        if task.retried and task.task_type == "SUB_WORKFLOW",
          do: state,
          else: revive(state, task)

      _gone_or_optional ->
        state
    end
  end

  defp revive(%State{now: now} = state, task) do
    task = %{task | subworkflow_changed: true, status: :in_progress, reason_for_incompletion: nil}
    state = State.save_task(state, task)

    # A child that already ended again (a restart that finished in its first decide) is read
    # now instead of on the next :wake: its notice reached this workflow before the revival.
    state =
      case Map.get(state.env.workflows, Task.sub_workflow_id(task) || "") do
        %Workflow{status: status} = _child ->
          if Workflow.terminal?(status), do: State.due(state, [task.task_id]), else: state

        nil ->
          state
      end

    wf = %{
      State.set_status(state.wf, :running)
      | reason_for_incompletion: nil,
        failed_task_id: nil,
        failed_reference_task_names: [],
        failed_task_names: [],
        last_retried_time: now
    }

    state = State.put_workflow(state, wf)

    state.wf.tasks
    |> Enum.reduce(state, &repair(&2, &1))
    |> State.save_workflow()
    |> push_parents(true)
    |> Decide.settle()
  end

  # The sibling tasks of updateAndPushParents.
  defp repair(%State{} = state, %Task{task_type: "SUB_WORKFLOW"} = task) do
    case {Task.sub_workflow_id(task), unsuccessful_terminal?(task)} do
      {id, true} when is_binary(id) -> repair_child(state, task, id)
      _other -> repair_canceled(state, task)
    end
  end

  defp repair(state, task), do: repair_canceled(state, task)

  defp repair_child(%State{env: env} = state, task, id) do
    case Map.get(env.workflows, id) do
      %Workflow{status: :running} ->
        follow(state, task)

      %Workflow{tasks: tasks} ->
        if Enum.any?(tasks, &unsuccessful_terminal?/1),
          do: state |> State.post({:retry_sub_workflow, id}) |> follow(task),
          else: state

      nil ->
        state
    end
  end

  defp follow(state, task) do
    State.save_task(state, %{
      task
      | status: :in_progress,
        reason_for_incompletion: nil,
        subworkflow_changed: true
    })
  end

  defp repair_canceled(state, %Task{status: :canceled, task_type: type} = task)
       when type in ["JOIN", "DO_WHILE"],
       do: State.save_task(state, %{task | status: :in_progress})

  defp repair_canceled(%State{now: now, env: env} = state, %Task{status: :canceled} = task) do
    task = %{
      task
      | retry_count: task.retry_count + 1,
        reason_for_incompletion: nil,
        poll_count: 0,
        worker_id: nil,
        scheduled_time: now,
        start_time: 0,
        end_time: 0,
        retried: false,
        executed: false,
        status: :scheduled
    }

    state = State.save_task(state, task)

    # addTaskToQueue: worker tasks are queued, asynchronous system tasks evaluated when due.
    cond do
      not Schedule.system_task?(env, task) -> Schedule.push(state, task)
      Schedule.async?(task) and Schedule.delay_ms(task) == 0 -> State.due(state, [task.task_id])
      true -> state
    end
  end

  defp repair_canceled(state, _task), do: state

  @doc """
  Upstream `adjustStateIfSubWorkflowChanged`: the first `SUB_WORKFLOW` task marked
  `subworkflowChanged` (not retried) loses the mark, and the `JOIN`s that failed run again, as the
  task they wait on runs again. Only for a definition with `SUB_WORKFLOW` or `FORK_JOIN_DYNAMIC`
  tasks.
  """
  @spec adjust(State.t()) :: State.t()
  def adjust(%State{wf: %Workflow{workflow_definition: %WorkflowDef{} = definition} = wf} = state) do
    changed =
      if WorkflowDef.contains_type?(definition, "SUB_WORKFLOW") or
           WorkflowDef.contains_type?(definition, "FORK_JOIN_DYNAMIC"),
         do:
           Enum.find(
             wf.tasks,
             &(&1.task_type == "SUB_WORKFLOW" and &1.subworkflow_changed and not &1.retried)
           )

    case changed do
      nil ->
        state

      task ->
        state
        |> State.save_task(%{task | subworkflow_changed: false})
        |> reset_unsuccessful_joins(definition)
    end
  end

  def adjust(state), do: state

  defp reset_unsuccessful_joins(%State{wf: wf} = state, definition) do
    if WorkflowDef.contains_type?(definition, "JOIN") or
         WorkflowDef.contains_type?(definition, "FORK_JOIN_DYNAMIC") do
      joins =
        Enum.filter(wf.tasks, &(&1.task_type == "JOIN" and unsuccessful_terminal?(&1)))

      joins
      |> Enum.reduce(state, &State.save_task(&2, %{&1 | status: :in_progress}))
      |> State.due(Enum.map(joins, & &1.task_id))
    else
      state
    end
  end

  # UNSUCCESSFUL_TERMINAL_TASK
  defp unsuccessful_terminal?(%Task{status: status}),
    do: Task.terminal?(status) and not Task.successful?(status)

  @doc "Upstream `UNSUCCESSFUL_TERMINAL_TASK`."
  @spec unsuccessful_terminal_task?(Task.t()) :: boolean()
  def unsuccessful_terminal_task?(task), do: unsuccessful_terminal?(task)

  @doc """
  Whether a child runs again since its parent ended: it ended itself, and was retried or
  restarted no earlier than the parent's `endTime` (the same millisecond counts). The recovery
  checks leave such a child alone, as the parent is about to revive (`child_revived/2`) or chose
  not to. A child that never ended, or that ran again before its parent ended, is not one.
  """
  @spec revived_after?(Workflow.t(), Workflow.t()) :: boolean()
  def revived_after?(%Workflow{} = child, %Workflow{end_time: end_time}) do
    child.previous_status not in [nil, :running, :paused] and end_time > 0 and
      max(child.create_time, child.last_retried_time) >= end_time
  end

  # WorkflowModel#toShortString: name.version/id
  defp short_string(%Workflow{workflow_definition: definition, workflow_id: id}) do
    {name, version} = name_version(definition)
    "#{name}.#{version}/#{id}"
  end

  # WorkflowModel#toString: name.version/id.STATUS
  defp long_string(%Workflow{} = wf), do: "#{short_string(wf)}.#{status_name(wf.status)}"

  defp name_version(%WorkflowDef{name: name, version: version}),
    do: {Parameters.java_string(name), Parameters.java_string(version)}

  defp name_version(nil), do: {"null", "null"}

  defp status_name(status), do: status |> Atom.to_string() |> String.upcase()
end
