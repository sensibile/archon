# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.StepReplay do
  @moduledoc """
  Replays captured scenarios through `Archon.Runtime.Step.run/3` without processes, to compare
  the stored workflow with what the upstream server returned (ADR 0014, decision 8; ADR 0018,
  decision 10).

  Each call reads the clock once (it advances 10 ms per reading) and checks that the returned
  commit, applied to the workflow given to the step, gives the workflow the step returned, as
  the store would. Task IDs and time fields are compared as `Archon.Contract.normalize/1` leaves
  them.
  """

  import ExUnit.Assertions

  alias Archon.Contract
  alias Archon.Domain.{Task, TaskDef, TaskResult, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Commit
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.Env

  @worker "archon-contract"

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

  @doc "An env at the next clock reading."
  @spec env(:counters.counters_ref(), keyword()) :: Env.t()
  def env(clock, opts \\ []), do: Env.new(Keyword.put(opts, :now, tick(clock)))

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

  @doc """
  Runs one event and returns `{reply, workflow, pre, post}`, after checking the commit against
  the returned workflow.
  """
  @spec run(Workflow.t() | nil, Step.Event.t(), Env.t()) ::
          {term(), Workflow.t(), [Step.Effect.t()], [Step.Effect.t()]}
  def run(workflow, event, %Env{} = env) do
    {reply, stored, pre, commit, post} = Step.run(workflow, event, env)
    assert apply_commit(workflow, commit) == stored
    {reply, stored, pre, post}
  end

  @doc "Applies a commit as the store does."
  @spec apply_commit(Workflow.t() | nil, Commit.t()) :: Workflow.t() | nil
  def apply_commit(_workflow, %Commit{create: %Workflow{} = created}), do: created

  def apply_commit(workflow, %Commit{} = commit) do
    base = if commit.workflow, do: %{commit.workflow | tasks: workflow.tasks}, else: workflow

    tasks =
      commit.upsert_tasks
      |> Enum.reduce(base.tasks, &upsert(&2, &1))
      |> Enum.reject(&(&1.task_id in commit.delete_task_ids))

    %{base | tasks: tasks}
  end

  defp upsert(tasks, %Task{task_id: id} = task) do
    if Enum.any?(tasks, &(&1.task_id == id)),
      do: Enum.map(tasks, &if(&1.task_id == id, do: task, else: &1)),
      else: tasks ++ [task]
  end

  @doc "A new running workflow created with its first decide (`{:start, workflow}`)."
  @spec start(WorkflowDef.t(), keyword(), :counters.counters_ref()) :: Workflow.t()
  def start(%WorkflowDef{} = definition, fields, clock) do
    workflow =
      struct(Workflow, Keyword.merge([owner_app: "", workflow_definition: definition], fields))

    {{:ok, id}, stored, _pre, _post} = run(nil, {:start, workflow}, env(clock))
    assert id == workflow.workflow_id
    stored
  end

  @doc "The worker polls the scheduled task with the reference name."
  @spec poll(Workflow.t(), String.t(), :counters.counters_ref()) :: Workflow.t()
  def poll(workflow, ref, clock) do
    assert [task] =
             Enum.filter(
               workflow.tasks,
               &(&1.reference_task_name == ref and &1.status == :scheduled)
             )

    {%Task{status: :in_progress}, stored, _pre, _post} =
      run(workflow, {:poll, task.task_id, @worker}, env(clock))

    stored
  end

  @doc """
  The worker updates the in-progress task with the reference name with the captured
  `TaskResult` (its task ID replaced by the replayed one).
  """
  @spec update(Workflow.t(), String.t(), map(), :counters.counters_ref()) :: Workflow.t()
  def update(workflow, ref, fixture, clock) do
    assert [task] =
             Enum.filter(
               workflow.tasks,
               &(&1.reference_task_name == ref and &1.status == :in_progress)
             )

    json = fixture["request"]["body"]
    assert json["workflowInstanceId"] == workflow.workflow_id
    {:ok, result} = TaskResult.from_json(Map.put(json, "taskId", task.task_id))
    {%Task{}, stored, _pre, _post} = run(workflow, {:update, result}, env(clock))
    stored
  end

  @doc "Compares the workflow with the response of a `GET /api/workflow/{id}` fixture."
  @spec assert_matches(Workflow.t(), String.t()) :: true
  def assert_matches(workflow, fixture) do
    expected = Contract.fixture(fixture)["response"]["body"]
    actual = workflow |> Workflow.to_json() |> JSON.encode!() |> JSON.decode!()
    assert Contract.normalize(actual) == Contract.normalize(expected)
  end
end
