# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/SubWorkflow.java
# (start, attachToSubWorkflow), core/.../utils/IDGenerator.java (generateSubWorkflowId) and
# core/.../execution/WorkflowExecutorOps.java (updateParentWorkflowTask,
# validateIdempotentWorkflowOwnership) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: starting the child is an effect whose result comes back as an event,
# so the task is saved before and after it (ADR 0018, decision 5).

defmodule Archon.Runtime.Step.SubWorkflow do
  @moduledoc """
  The parent's side of a `SUB_WORKFLOW` task (ADR 0018, decision 5).

    * `start/2` - upstream `SubWorkflow#start` up to `startWorkflowIdempotent`: a
      `{:start_sub_workflow, task_id, start}` effect for the child, with the deterministic ID
      (`child_id/2`) or the one already in the task.
    * `started/3` - the effect's result: upstream `attachToSubWorkflow`, the retry with a new ID
      when the child already ended unsuccessfully, or the start errors.
    * `child_changed/3` - upstream `updateParentWorkflowTask`: the task follows its child.

  `owned_by?/2` is upstream `validateIdempotentWorkflowOwnership` for the child side.
  """

  alias Archon.Decider.Parameters
  alias Archon.Decider.SystemTask.SubWorkflow, as: SubWorkflowTask
  alias Archon.Domain.{Task, Workflow, WorkflowDef}
  alias Archon.Runtime.Step.{Event, State}

  @launch_error "subWorkflowLaunchError"

  @doc """
  Upstream `IDGenerator#generateSubWorkflowId`: the name-based (version 3) UUID of
  `subworkflow:<parent ID>:<task ID>:<retry count>`.
  """
  @spec child_id(String.t(), Task.t()) :: String.t()
  def child_id(parent_id, %Task{task_id: task_id, retry_count: retry_count}) do
    <<a::48, _::4, b::12, _::2, c::62>> =
      :crypto.hash(:md5, "subworkflow:#{parent_id}:#{task_id}:#{retry_count}")

    <<a::48, 3::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> ->
      Enum.join([p1, p2, p3, p4, p5], "-")
    end)
  end

  @doc """
  Upstream `SubWorkflow#start` for a `SCHEDULED` task: the child to start, or a `FAILED` task
  when the input names no workflow.
  """
  @spec start(State.t(), Task.t()) :: {:started, State.t()} | {:failed, Task.t()}
  def start(%State{wf: wf} = state, %Task{input_data: input} = task) do
    case definition(input["subWorkflowDefinition"]) do
      {:ok, definition} ->
        name = if definition, do: definition.name, else: java_string(input["subWorkflowName"])

        if name == nil do
          {:failed, failed(task, "SubWorkflow name is null and no workflowDefinition supplied")}
        else
          start = start_input(wf, task, definition, name)
          {:started, State.post(state, {:start_sub_workflow, task.task_id, start})}
        end

      {:error, reason} ->
        {:failed, failed(task, reason)}
    end
  end

  defp definition(nil), do: {:ok, nil}

  defp definition(json) do
    case WorkflowDef.from_json(json) do
      {:ok, definition} -> {:ok, definition}
      {:error, error} -> {:error, "Invalid subWorkflowDefinition: #{inspect(error)}"}
    end
  end

  defp start_input(wf, %Task{input_data: input} = task, definition, name) do
    %{
      workflow_id: start_id(task),
      name: name,
      version: version(input["subWorkflowVersion"]),
      definition: definition,
      input: workflow_input(input, definition),
      correlation_id: wf.correlation_id,
      priority: priority(input["priority"]),
      task_to_domain: task_to_domain(input["subWorkflowTaskToDomain"], wf),
      parent_workflow_id: task.workflow_instance_id,
      parent_workflow_task_id: task.task_id,
      triggering_workflow_id: nil,
      idempotency_key: java_string(input["idempotencyKey"]),
      idempotency_strategy: idempotency_strategy(input["idempotencyStrategy"])
    }
  end

  # `workflowInput`, else the whole task input; an inline definition marks it dynamic.
  defp workflow_input(input, definition) do
    workflow_input =
      case input["workflowInput"] do
        map when is_map(map) and map_size(map) > 0 -> map
        _empty -> input
      end

    if definition do
      metadata =
        case workflow_input["_systemMetadata"] do
          map when is_map(map) -> map
          _other -> %{}
        end

      Map.put(workflow_input, "_systemMetadata", Map.put(metadata, "dynamic", true))
    else
      workflow_input
    end
  end

  defp priority(priority) when is_number(priority), do: trunc(priority)
  defp priority(_priority), do: nil

  defp task_to_domain(mapping, _wf) when is_map(mapping), do: mapping
  defp task_to_domain(_mapping, wf), do: wf.task_to_domain

  defp version(version) when is_number(version) and trunc(version) != 0, do: trunc(version)
  defp version(_version), do: nil

  defp idempotency_strategy(strategy)
       when strategy in ["FAIL", "RETURN_EXISTING", "FAIL_ON_RUNNING"],
       do: strategy

  defp idempotency_strategy(_strategy), do: nil

  @doc """
  The result of starting the child. `{:ok, child}` attaches the task to it, unless the child
  with the task's ID already ended unsuccessfully: then the task takes a new ID from
  `new_id` and that one is started. A transient error leaves the task `SCHEDULED` to try again;
  any other error fails it. A child other than the one the task asks for now (the result of an
  earlier attempt) is ignored.
  """
  @spec started(State.t(), Task.t(), Event.sub_workflow_result()) ::
          {:retry, State.t()} | {:done, Task.t()} | :ignore
  def started(%State{env: env} = state, %Task{} = task, {:ok, %Workflow{} = child}) do
    cond do
      # The result of an earlier attempt, for a child the task no longer asks for.
      child.workflow_id != start_id(task) ->
        :ignore

      Workflow.terminal?(child.status) and not Workflow.successful?(child.status) and
          task.sub_workflow_id == nil ->
        task = %{task | sub_workflow_id: env.new_id.()}
        state = State.save_task(state, task)
        start = start_input(state.wf, task, start_definition(task), start_name(task))
        {:retry, State.post(state, {:start_sub_workflow, task.task_id, start})}

      true ->
        {:done, attach(task, child)}
    end
  end

  def started(_state, %Task{} = task, {:error, :transient, message}) do
    name = Parameters.java_string(start_name(task))

    {:done,
     %{
       task
       | status: :scheduled,
         reason_for_incompletion: "Transient error starting sub workflow #{name}: #{message}",
         output_data: Map.put(task.output_data, @launch_error, message)
     }}
  end

  def started(_state, %Task{} = task, {:error, message}), do: {:done, failed(task, message)}

  defp start_id(task), do: task.sub_workflow_id || child_id(task.workflow_instance_id, task)

  defp start_definition(%Task{input_data: input}) do
    case definition(input["subWorkflowDefinition"]) do
      {:ok, definition} -> definition
      {:error, _reason} -> nil
    end
  end

  defp start_name(%Task{input_data: input} = task) do
    case start_definition(task) do
      %WorkflowDef{name: name} -> name
      nil -> java_string(input["subWorkflowName"])
    end
  end

  # attachToSubWorkflow
  defp attach(task, %Workflow{workflow_id: id} = child) do
    output = task.output_data |> Map.put("subWorkflowId", id) |> Map.delete(@launch_error)

    SubWorkflowTask.update_task_status(child, %{
      task
      | reason_for_incompletion: nil,
        sub_workflow_id: id,
        output_data: output
    })
  end

  defp failed(task, reason), do: %{task | status: :failed, reason_for_incompletion: reason}

  @doc """
  Upstream `updateParentWorkflowTask` and `SubWorkflow#execute` for a child that changed: the
  task, if it is still one of the workflow's tasks (the generation fence) and the child is the
  one it is attached to now (upstream reads the child by the task's `subWorkflowId`), takes
  the child's status, output and reason once the child is terminal. `nil` when nothing changes.
  """
  @spec child_changed(State.t(), String.t(), Workflow.t()) :: Task.t() | nil
  def child_changed(state, task_id, %Workflow{workflow_id: child_id} = child) do
    with %Task{task_type: "SUB_WORKFLOW"} = task <- State.task(state, task_id),
         ^child_id <- Task.sub_workflow_id(task),
         {true, task} <- SubWorkflowTask.execute(task, child) do
      task
    else
      _unchanged -> nil
    end
  end

  @doc """
  The stored child when it may be the child the start asks for: upstream
  `validateIdempotentWorkflowOwnership`, with its message otherwise.
  """
  @spec owned_by?(Workflow.t(), Workflow.t()) :: :ok | {:error, String.t()}
  def owned_by?(%Workflow{} = existing, %Workflow{} = start) do
    blank? = &(&1 in [nil, ""])

    cond do
      blank?.(start.parent_workflow_id) and blank?.(start.parent_workflow_task_id) ->
        :ok

      existing.parent_workflow_id == start.parent_workflow_id and
          existing.parent_workflow_task_id == start.parent_workflow_task_id ->
        :ok

      true ->
        {:error,
         "Workflow id #{existing.workflow_id} already belongs to parent workflow " <>
           "#{Parameters.java_string(existing.parent_workflow_id)} task " <>
           "#{Parameters.java_string(existing.parent_workflow_task_id)}, cannot attach to " <>
           "parent workflow #{Parameters.java_string(start.parent_workflow_id)} task " <>
           Parameters.java_string(start.parent_workflow_task_id)}
    end
  end

  defp java_string(nil), do: nil
  defp java_string(value) when is_binary(value), do: value
  defp java_string(value), do: Parameters.java_string(value)
end
