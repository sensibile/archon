# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/model/WorkflowModel.java
# and core/src/main/java/com/netflix/conductor/model/TaskModel.java at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the Jackson shape of the internal models written from the REST encoding
# of Archon.Domain.Workflow and Archon.Domain.Task.

defmodule Archon.Domain.WorkflowModelJson do
  @moduledoc """
  The JSON of upstream's internal `WorkflowModel` and `TaskModel`, which
  `POST /api/workflow/bulk/search` answers (ADR 0027, decision 5) instead of the REST `Workflow`
  and `Task`.

  Both are written from `Archon.Domain.Workflow.to_json/2` and `Archon.Domain.Task.to_json/2`
  with the differences of their getters:

    * `WorkflowModel` has `updatedTime` (not `updateTime`), `previousStatus` and `failedTaskId`,
      writes `failedReferenceTaskNames` and `failedTaskNames` only when not empty (`NON_EMPTY`),
      and has no `startTime`, `history`, `idempotencyKey`, `rateLimitKey`, `rateLimited` or
      `aggregateTokenUsage`.
    * `TaskModel` has `callbackAfterMs`, `firstScheduledTime`, `waitTimeout`, `loopTaskId`,
      `onStateChange` (copied from its workflow task by the task mappers, so not on the `JOIN`
      that a `FORK_JOIN_DYNAMIC` creates itself, `ForkJoinDynamicTaskMapper#createJoinTask`), `idempotent`,
      `cachedOutput`, `notifications`, `nonWorkflowEventTask`, `asyncComplete` and
      `idempotentExecution`, and has no `firstStartTime`, `executionMetadata` or
      `runtimeMetadata`. Its `reasonForIncompletion` is not cut and its output is the stored one
      (the 500-character cut and the `subWorkflowId` copy are `TaskModel#toTask`'s). A task
      `skiptask` created has no `workflowTask`: upstream stores none, and the name and reference
      stub Archon stores for it is `toTask`'s too.
  """

  alias Archon.Domain.{Codec, Task, Workflow, WorkflowDef, WorkflowTask}

  @workflow_only ~w(startTime updateTime history idempotencyKey rateLimitKey rateLimited
                    aggregateTokenUsage)
  @task_only ~w(firstStartTime executionMetadata runtimeMetadata)

  @doc "Upstream `WorkflowModel` JSON. `now_ms` is each task's `queueWaitTime` clock."
  @spec workflow(Workflow.t(), integer()) :: Codec.json_object()
  def workflow(%Workflow{} = workflow, now_ms) when is_integer(now_ms) do
    workflow
    |> Workflow.to_json(now_ms)
    |> Map.drop(@workflow_only)
    |> non_empty("failedReferenceTaskNames")
    |> non_empty("failedTaskNames")
    |> put_present("updatedTime", workflow.update_time)
    |> put_present("previousStatus", enum(workflow.previous_status))
    |> put_present("failedTaskId", workflow.failed_task_id)
    |> put_tasks(workflow.tasks, dynamic_joins(workflow), now_ms)
  end

  @doc """
  Upstream `TaskModel` JSON. `now_ms` is the `queueWaitTime` clock. With `mapped?` false (the
  `JOIN` of a `FORK_JOIN_DYNAMIC`, which no task mapper created) there is no `onStateChange`.
  """
  @spec task(Task.t(), integer(), boolean()) :: Codec.json_object()
  def task(%Task{} = task, now_ms, mapped? \\ true) when is_integer(now_ms) do
    json = task |> Task.to_json(now_ms) |> drop_skip_stub(task)
    async_complete? = async_complete?(task)

    json
    |> Map.drop(@task_only)
    |> Map.put("outputData", task.output_data)
    |> put_present("reasonForIncompletion", task.reason_for_incompletion)
    |> Map.merge(%{
      "callbackAfterMs" => task.callback_after_ms,
      "firstScheduledTime" => task.first_scheduled_time,
      "waitTimeout" => task.wait_timeout,
      "idempotent" => false,
      "cachedOutput" => false,
      "notifications" => %{},
      "nonWorkflowEventTask" => false,
      "asyncComplete" => async_complete?,
      # !isAsyncComplete() && idempotent, and nothing sets idempotent.
      "idempotentExecution" => false
    })
    |> put_present("loopTaskId", task.loop_task_id)
    |> put_present("onStateChange", mapped? && get_in(json, ["workflowTask", "onStateChange"]))
  end

  # The reference names of the JOINs right after a FORK_JOIN_DYNAMIC: the dynamic fork's mapper
  # creates that JOIN task (and a retry copies it), so it never gets the workflow task's
  # onStateChange.
  # Only a dynamic fork that ran made its JOIN: after a skipped one (whose workflow task is a SIMPLE
  # stub) the JOIN mapper schedules the JOIN. The JOIN is found as ForkJoin.next_join/2 finds it.
  defp dynamic_joins(%Workflow{workflow_definition: %WorkflowDef{} = definition, tasks: tasks}) do
    for %Task{workflow_task: %WorkflowTask{type: "FORK_JOIN_DYNAMIC", task_reference_name: ref}} <-
          tasks || [],
        %WorkflowTask{type: "JOIN", task_reference_name: join} <-
          [WorkflowDef.next_task(definition, ref)],
        into: MapSet.new(),
        do: join
  end

  defp dynamic_joins(%Workflow{}), do: MapSet.new()

  # WorkflowExecutorOps#skipTaskFromWorkflow sets no workflow task; Archon stores the stub that
  # TaskModel#toTask gives the REST Task (Archon.Runtime.Step.Lifecycle.skip_task/2).
  defp drop_skip_stub(json, %Task{status: :skipped, reference_task_name: ref} = task) do
    case task.workflow_task do
      %WorkflowTask{name: name} = stub
      when stub == %WorkflowTask{name: name, task_reference_name: ref} ->
        Map.delete(json, "workflowTask")

      _other ->
        json
    end
  end

  defp drop_skip_stub(json, %Task{}), do: json

  # TaskModel#isAsyncComplete: the input's `asyncComplete` when the key is there, else the
  # workflow task's.
  defp async_complete?(%Task{input_data: %{"asyncComplete" => value}}), do: value == true

  defp async_complete?(%Task{workflow_task: %WorkflowTask{async_complete: value}}),
    do: value == true

  defp async_complete?(%Task{}), do: false

  defp put_tasks(json, nil, _joins, _now_ms), do: json

  defp put_tasks(json, tasks, joins, now_ms),
    do: Map.put(json, "tasks", Enum.map(tasks, &(&1 && task(&1, now_ms, mapped?(&1, joins)))))

  defp mapped?(
         %Task{task_type: "JOIN", workflow_task: %WorkflowTask{task_reference_name: ref}},
         joins
       ),
       do: not MapSet.member?(joins, ref)

  defp mapped?(%Task{}, _joins), do: true

  defp non_empty(json, key) do
    case json do
      %{^key => value} when value in [nil, []] -> Map.delete(json, key)
      _other -> json
    end
  end

  defp put_present(json, key, value) when value in [nil, false], do: Map.delete(json, key)
  defp put_present(json, key, value), do: Map.put(json, key, value)

  defp enum(nil), do: nil
  defp enum(status), do: Codec.enum_name(status)
end
