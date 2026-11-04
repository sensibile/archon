# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.Step.SearchIndexStepTest do
  @moduledoc """
  The search index rows `Archon.Runtime.Step` puts in its commits (ADR 0027, decision 2): where
  upstream's `ExecutionDAOFacade` indexes (`createWorkflow`, `updateWorkflow`, `updateTask`) and
  where it does not (`createTasks`, `extendLease`), as the 8a captures (`p8_index_*`, ADR 0027
  decision 7) showed it.
  """

  use ExUnit.Case, async: true

  alias Archon.Domain.{TaskDef, TaskResult, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.{Commit, SearchIndex}
  alias Archon.Runtime.Step
  alias Archon.Runtime.Step.Env

  @now 1_000_000

  defp env, do: Env.new(now: @now, new_id: fn -> "id-#{System.unique_integer([:positive])}" end)

  defp task(type, ref, fields \\ []) do
    struct!(
      %WorkflowTask{
        name: ref,
        task_reference_name: ref,
        type: type,
        task_definition: %TaskDef{name: ref, retry_count: 0, response_timeout_seconds: 0}
      },
      fields
    )
  end

  defp new_workflow(tasks) do
    definition = %WorkflowDef{name: "wf", version: 1, tasks: tasks}

    %Workflow{
      workflow_id: "wf",
      status: :running,
      owner_app: "",
      create_time: @now,
      workflow_definition: definition
    }
  end

  defp run(workflow, event) do
    {reply, stored, _pre, commit, _post} = Step.run(workflow, event, env())
    check_rows!(commit, stored)
    {reply, stored, commit}
  end

  # The workflow row is the stored workflow's whenever the commit writes the workflow, and each
  # task row is that of a task the commit wrote or deleted after saving (keepLastN).
  defp check_rows!(%Commit{} = commit, stored) do
    if commit.create || commit.workflow,
      do: assert(commit.index_workflow == SearchIndex.workflow_row(stored)),
      else: assert(commit.index_workflow == nil)

    written =
      Enum.map((commit.create && commit.create.tasks) || commit.upsert_tasks, & &1.task_id) ++
        commit.delete_task_ids

    for row <- commit.index_tasks, do: assert(row.task_id in written)
  end

  defp indexed(%Commit{index_tasks: rows}), do: Map.new(rows, &{&1.task_id, &1.status})

  defp by_ref(workflow, ref), do: Enum.find(workflow.tasks, &(&1.reference_task_name == ref))

  defp result(workflow, ref, fields) do
    struct!(
      %TaskResult{workflow_instance_id: "wf", task_id: by_ref(workflow, ref).task_id},
      fields
    )
  end

  test "a start indexes the workflow and the system tasks it ran, not a task only scheduled" do
    {{:ok, "wf"}, stored, commit} =
      run(nil, {:start, new_workflow([task("SET_VARIABLE", "set"), task("SIMPLE", "worker")])})

    assert commit.index_workflow.status == "RUNNING"
    assert indexed(commit) == %{by_ref(stored, "set").task_id => "COMPLETED"}
  end

  test "a poll and an update index the task, an extendLease does not" do
    {_reply, workflow, _commit} = run(nil, {:start, new_workflow([task("SIMPLE", "worker")])})
    id = by_ref(workflow, "worker").task_id

    {_task, workflow, commit} = run(workflow, {:poll, id, "w"})
    assert indexed(commit) == %{id => "IN_PROGRESS"}

    lease = result(workflow, "worker", status: :in_progress, extend_lease: true)
    {nil, workflow, commit} = run(workflow, {:update, lease})
    assert [%{task_id: ^id}] = commit.upsert_tasks
    assert commit.index_tasks == []

    # callbackAfterSeconds puts the task back to SCHEDULED, and so does its row.
    callback = result(workflow, "worker", status: :in_progress, callback_after_seconds: 5)
    {_task, workflow, commit} = run(workflow, {:update, callback})
    assert indexed(commit) == %{id => "SCHEDULED"}

    {_task, stored, commit} =
      run(workflow, {:update, result(workflow, "worker", status: :completed)})

    assert stored.status == :completed
    assert indexed(commit) == %{id => "COMPLETED"}
    assert commit.index_workflow.status == "COMPLETED"
  end

  test "a FORK is indexed once it runs after the task before it" do
    fork =
      task("FORK_JOIN", "fork", fork_tasks: [[task("SIMPLE", "left")], [task("SIMPLE", "right")]])

    tasks = [task("SIMPLE", "first"), fork, task("JOIN", "join", join_on: ["left", "right"])]
    {_reply, workflow, commit} = run(nil, {:start, new_workflow(tasks)})
    assert indexed(commit) == %{}

    first = by_ref(workflow, "first").task_id
    {_task, workflow, _commit} = run(workflow, {:poll, first, "w"})

    {_task, workflow, commit} =
      run(workflow, {:update, result(workflow, "first", status: :completed)})

    assert indexed(commit)[by_ref(workflow, "fork").task_id] == "COMPLETED"
    # The branches are only scheduled.
    refute Map.has_key?(indexed(commit), by_ref(workflow, "left").task_id)
  end

  test "a task skiptask makes is not indexed, then or when the workflow ends" do
    {_reply, workflow, _commit} =
      run(nil, {:start, new_workflow([task("SIMPLE", "first"), task("SIMPLE", "second")])})

    {:ok, workflow, commit} = run(workflow, {:skip_task, "second"})
    skipped = by_ref(workflow, "second").task_id
    refute Map.has_key?(indexed(commit), skipped)

    first = by_ref(workflow, "first").task_id
    {_task, workflow, _commit} = run(workflow, {:poll, first, "w"})

    {_task, stored, commit} =
      run(workflow, {:update, result(workflow, "first", status: :completed)})

    assert stored.status == :completed
    assert indexed(commit) == %{first => "COMPLETED"}
  end
end
