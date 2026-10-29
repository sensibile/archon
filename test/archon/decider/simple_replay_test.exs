# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Decider.SimpleReplayTest do
  @moduledoc """
  Replays the captured SIMPLE scenario (`workflow_start_simple`, `task_poll_simple_*`,
  `task_update_simple_a`, `task_update_v2_simple_b`) through `Archon.Decider.decide/2` and compares
  the workflow with what the upstream server returned (ADR 0014, decision 8).

  The test plays the runtime the way upstream `WorkflowExecutorOps` does: it embeds task
  definitions into the definition at start, assigns `seq` and `firstScheduledTime` to scheduled
  tasks, persists only `tasks_to_be_updated` and new tasks, and on completion stores the status
  and output without updating tasks. That last step is why the server keeps `executed: false` on
  the final task. Task IDs and time fields are compared as `Archon.Contract.normalize/1` leaves
  them.
  """

  use ExUnit.Case, async: true

  alias Archon.Contract
  alias Archon.Decider
  alias Archon.Decider.{Context, Outcome, Parameters}
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}

  @worker "archon-contract"

  test "the SIMPLE scenario ends as the upstream server's workflow" do
    start = Contract.fixture("workflow_start_simple")
    workflow_id = start["response"]["body"]
    [_path, query] = String.split(start["request"]["path"], "?")
    %{"correlationId" => correlation_id} = URI.decode_query(query)

    definition = populated_definition()
    clock = :counters.new(1, [])
    :counters.put(clock, 1, 1_000)

    workflow =
      %Workflow{
        workflow_id: workflow_id,
        correlation_id: correlation_id,
        owner_app: "",
        status: :running,
        create_time: tick(clock),
        input: Parameters.workflow_input(definition, start["request"]["body"]),
        workflow_definition: definition
      }
      |> decide(clock)

    workflow = poll(workflow, "archon_task_a", clock)
    assert_matches(workflow, "workflow_get_running")

    workflow =
      workflow
      |> update(Contract.fixture("task_update_simple_a"), clock)
      |> decide(clock)
      |> poll("archon_task_b", clock)
      |> update(Contract.fixture("task_update_v2_simple_b"), clock)
      |> decide(clock)

    assert workflow.status == :completed
    assert_matches(workflow, "workflow_get_completed_simple")
  end

  # The server's stored definition (GET /api/metadata/workflow) with each task's definition
  # embedded, as MetadataMapperService does when a workflow starts. Task definitions are the
  # registered ones with the fields the server stamps on registration.
  defp populated_definition do
    {:ok, definition} =
      WorkflowDef.from_json(Contract.fixture("metadata_get_workflow")["response"]["body"])

    stored_a = Contract.fixture("metadata_get_taskdef")["response"]["body"]

    task_defs =
      Map.new(Contract.fixture("metadata_register_taskdefs")["request"]["body"], fn json ->
        {:ok, task_def} = TaskDef.from_json(json)
        {task_def.name, %{task_def | created_by: "", create_time: stored_a["createTime"]}}
      end)

    assert Contract.normalize(TaskDef.to_json(task_defs["archon_task_a"])) ==
             Contract.normalize(stored_a)

    tasks =
      Enum.map(definition.tasks, fn %WorkflowTask{name: name} = wt ->
        %{wt | task_definition: Map.fetch!(task_defs, name)}
      end)

    %{definition | tasks: tasks}
  end

  # One decider pass and what WorkflowExecutorOps#decide persists from it.
  defp decide(workflow, clock) do
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
      updated = Map.new(outcome.tasks_to_be_updated, &{&1.task_id, &1})
      tasks = Enum.map(workflow.tasks, &Map.get(updated, &1.task_id, &1))
      seq = tasks |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

      scheduled =
        outcome.tasks_to_be_scheduled
        |> Enum.with_index(seq + 1)
        |> Enum.map(fn {task, seq} -> %{task | seq: seq, first_scheduled_time: now} end)

      %{workflow | tasks: tasks ++ scheduled, update_time: now}
    end
  end

  # ExecutionService#poll: the worker takes the scheduled task.
  defp poll(workflow, task_type, clock) do
    now = tick(clock)

    update_task(workflow, &(&1.task_type == task_type and &1.status == :scheduled), fn task ->
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

  # ExecutionService#updateTask with the captured TaskResult.
  defp update(workflow, fixture, clock) do
    now = tick(clock)
    result = fixture["request"]["body"]
    assert result["workflowInstanceId"] == workflow.workflow_id
    {:ok, task} = Task.from_json(%{"status" => result["status"]})

    update_task(workflow, &(&1.status == :in_progress), fn in_progress ->
      %{
        in_progress
        | status: task.status,
          output_data: result["outputData"],
          worker_id: result["workerId"],
          end_time: now,
          update_time: now
      }
    end)
  end

  defp update_task(workflow, match, fun) do
    assert [_task] = Enum.filter(workflow.tasks, match)
    %{workflow | tasks: Enum.map(workflow.tasks, &if(match.(&1), do: fun.(&1), else: &1))}
  end

  defp assert_matches(workflow, fixture) do
    expected = Contract.fixture(fixture)["response"]["body"]
    actual = workflow |> Workflow.to_json() |> JSON.encode!() |> JSON.decode!()
    assert Contract.normalize(actual) == Contract.normalize(expected)
  end

  defp tick(clock) do
    :counters.add(clock, 1, 10)
    :counters.get(clock, 1)
  end
end
