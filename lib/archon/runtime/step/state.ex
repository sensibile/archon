# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/dal/ExecutionDAOFacade.java
# (createTasks, updateTask, updateWorkflow) and core/.../model/WorkflowModel.java (setStatus)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: saving collects an Archon.Runtime.Commit instead of writing to a DAO
# and stamps times from the step's clock (ADR 0018, decision 2).

defmodule Archon.Runtime.Step.State do
  @moduledoc false

  # The working state of one step.
  #
  #   * `wf` - the workflow in memory, with the changes upstream makes in place whether or not it
  #     saves them (the Decider's `executed` markings, for one).
  #   * `stored` - the workflow as the store holds it once the commit is applied: what upstream
  #     wrote through `ExecutionDAOFacade`.
  #   * `upserts`/`order`, `deletes`, `workflow_dirty?`, `created?` - the commit.
  #   * `pre`/`post` - effects, newest first.
  #   * `iterations` - decide loop iterations so far (ADR 0018, decision 4); `halted?` once the
  #     limit stopped the loop.
  #   * `changed?` - a task was added or changed status (the `:wake` recovery check).
  #   * `decided?` - a decide ran, so the step sets the timer instead of only pulling it.
  #   * `due` - asynchronous system tasks to evaluate next; `terminated_refs` - reference names
  #     of tasks a save made terminal, which the `JOIN`s waiting on them are evaluated after.
  #   * `pull` - the earliest `:wake` asked by an event that did not decide.

  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.Commit
  alias Archon.Runtime.Step.{Effect, Env}

  defstruct [
    :env,
    :now,
    :stored,
    :wf,
    :pull,
    created?: false,
    upserts: %{},
    order: [],
    deletes: [],
    workflow_dirty?: false,
    pre: [],
    post: [],
    iterations: 0,
    halted?: false,
    changed?: false,
    decided?: false,
    due: MapSet.new(),
    terminated_refs: MapSet.new()
  ]

  @type t :: %__MODULE__{
          env: Env.t(),
          now: integer(),
          stored: Workflow.t() | nil,
          wf: Workflow.t() | nil,
          pull: integer() | nil,
          created?: boolean(),
          upserts: %{optional(String.t() | nil) => Task.t() | map()},
          order: [String.t() | nil],
          deletes: [String.t() | nil],
          workflow_dirty?: boolean(),
          pre: [Effect.t()],
          post: [Effect.t()],
          iterations: non_neg_integer(),
          halted?: boolean(),
          changed?: boolean(),
          decided?: boolean(),
          due: MapSet.t(String.t() | nil),
          terminated_refs: MapSet.t(String.t() | nil)
        }

  @spec new(Workflow.t() | nil, Env.t()) :: t()
  def new(workflow, %Env{} = env),
    do: %__MODULE__{env: env, now: env.now, stored: workflow, wf: workflow}

  @doc "Creates the workflow (`ExecutionDAOFacade#createWorkflow`), stamping nothing."
  @spec create(t(), Workflow.t()) :: t()
  def create(state, %Workflow{} = workflow),
    do: %{state | created?: true, stored: workflow, wf: workflow, changed?: true}

  @doc "The task in memory with the ID, or `nil`."
  @spec task(t(), String.t() | nil) :: Task.t() | nil
  def task(%__MODULE__{wf: wf}, id), do: Enum.find(wf.tasks, &(&1.task_id == id))

  @doc "Replaces the task in memory by ID, or appends it."
  @spec put_task(t(), Task.t()) :: t()
  def put_task(%__MODULE__{wf: wf} = state, %Task{} = task),
    do: %{state | wf: %{wf | tasks: replace(wf.tasks, task)}}

  @doc "Puts the workflow in memory without saving it."
  @spec put_workflow(t(), Workflow.t()) :: t()
  def put_workflow(state, %Workflow{} = workflow), do: %{state | wf: workflow}

  @doc "`ExecutionDAOFacade#createTasks`: saves new tasks as they are."
  @spec create_tasks(t(), [Task.t()]) :: t()
  def create_tasks(state, tasks), do: Enum.reduce(tasks, state, &write(&2, &1))

  @doc """
  `ExecutionDAOFacade#updateTask`: `updateTime` becomes now unless the task is terminal and
  already has one, and a terminal task without an `endTime` gets now.
  """
  @spec save_task(t(), Task.t()) :: t()
  def save_task(%__MODULE__{now: now} = state, %Task{status: status} = task) do
    terminal? = Task.terminal?(status)

    task =
      if not terminal? or task.update_time == 0, do: %{task | update_time: now}, else: task

    task = if terminal? and task.end_time == 0, do: %{task | end_time: now}, else: task
    write(state, task)
  end

  @spec save_tasks(t(), [Task.t()]) :: t()
  def save_tasks(state, tasks), do: Enum.reduce(tasks, state, &save_task(&2, &1))

  @doc "Saves the task in memory with the ID, if it is still there."
  @spec save_current(t(), String.t()) :: t()
  def save_current(state, id) do
    case task(state, id) do
      nil -> state
      task -> save_task(state, task)
    end
  end

  @doc "Deletes tasks (DO_WHILE `keepLastN`, upstream `removeTask`)."
  @spec delete_tasks(t(), [String.t()]) :: t()
  def delete_tasks(state, []), do: state

  def delete_tasks(%__MODULE__{wf: wf, stored: stored} = state, ids) do
    drop = MapSet.new(ids)
    keep = fn tasks -> Enum.reject(tasks, &MapSet.member?(drop, &1.task_id)) end

    %{
      state
      | wf: %{wf | tasks: keep.(wf.tasks)},
        stored: %{stored | tasks: keep.(stored.tasks)},
        upserts: Map.drop(state.upserts, ids),
        deletes: state.deletes ++ Enum.reject(ids, &(&1 in state.deletes))
    }
  end

  @doc """
  `ExecutionDAOFacade#updateWorkflow`: `updateTime` becomes now and so does `endTime` when the
  workflow is terminal. Tasks are not saved with it.
  """
  @spec save_workflow(t()) :: t()
  def save_workflow(%__MODULE__{now: now, wf: wf, stored: stored} = state) do
    wf = %{wf | update_time: now}
    wf = if Workflow.terminal?(wf.status), do: %{wf | end_time: now}, else: wf
    %{state | wf: wf, stored: %{wf | tasks: stored.tasks}, workflow_dirty?: true}
  end

  @doc "`WorkflowModel#setStatus`: a change of status records the previous one."
  @spec set_status(Workflow.t(), Workflow.status()) :: Workflow.t()
  def set_status(%Workflow{status: status} = workflow, status), do: workflow

  def set_status(%Workflow{status: previous} = workflow, status),
    do: %{workflow | status: status, previous_status: previous}

  @spec pre(t(), Effect.t()) :: t()
  def pre(state, effect), do: %{state | pre: [effect | state.pre]}

  @spec post(t(), Effect.t()) :: t()
  def post(state, effect), do: %{state | post: [effect | state.post]}

  @doc "Asks for a `:wake` no later than `ms`, for an event that did not decide."
  @spec pull(t(), integer()) :: t()
  def pull(%__MODULE__{pull: nil} = state, ms), do: %{state | pull: ms}
  def pull(%__MODULE__{pull: pull} = state, ms), do: %{state | pull: min(pull, ms)}

  @doc "Marks tasks to evaluate as asynchronous system tasks."
  @spec due(t(), [String.t()]) :: t()
  def due(state, ids), do: %{state | due: Enum.into(ids, state.due)}

  @doc "The commit the step collected."
  @spec commit(t()) :: Commit.t()
  def commit(%__MODULE__{created?: true, stored: stored}), do: %Commit{create: stored}

  def commit(%__MODULE__{} = state) do
    %Commit{
      workflow: if(state.workflow_dirty?, do: state.stored),
      upsert_tasks:
        state.order
        |> Enum.reverse()
        |> Enum.filter(&Map.has_key?(state.upserts, &1))
        |> Enum.map(&Map.fetch!(state.upserts, &1)),
      delete_task_ids: state.deletes
    }
  end

  # Saves a task: in memory, in the stored workflow and in the commit.
  defp write(%__MODULE__{stored: stored} = state, %Task{task_id: id} = task) do
    previous = Enum.find(stored.tasks, &(&1.task_id == id))

    state
    |> track(previous, task)
    |> put_task(task)
    |> Map.update!(:stored, &%{&1 | tasks: replace(&1.tasks, task)})
    |> Map.update!(:upserts, &Map.put(&1, id, task))
    |> Map.update!(:order, &if(Map.has_key?(state.upserts, id), do: &1, else: [id | &1]))
  end

  defp track(state, previous, %Task{status: status} = task) do
    state =
      if previous == nil or previous.status != status,
        do: %{state | changed?: true},
        else: state

    if Task.terminal?(status) and (previous == nil or not Task.terminal?(previous.status)),
      do: %{state | terminated_refs: MapSet.put(state.terminated_refs, task.reference_task_name)},
      else: state
  end

  defp replace(tasks, %Task{task_id: id} = task) do
    if Enum.any?(tasks, &(&1.task_id == id)),
      do: Enum.map(tasks, &if(&1.task_id == id, do: task, else: &1)),
      else: tasks ++ [task]
  end
end
