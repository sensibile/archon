# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/StartWorkflow.java
# (start, getRequest, startWorkflow), core/.../execution/WorkflowExecutorOps.java
# (startWorkflow, validateWorkflow) and core/.../metadata/MetadataMapperService.java
# (lookupWorkflowDefinition) at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: starting the workflow is an effect whose result comes back as an event,
# with an ID the task determines so that the start is idempotent (ADR 0026, decision 7).

defmodule Archon.Runtime.Step.StartWorkflow do
  @moduledoc """
  A `START_WORKFLOW` task (ADR 0026, decision 7).

    * `start/2` - upstream `StartWorkflow#start` up to `startWorkflow`: the input `startWorkflow`
      read as a `StartWorkflowRequest` and validated, then a `{:start_workflow, task_id, start}`
      effect with the ID `workflow_id/2`.
    * `started/3` - the effect's result: the task `COMPLETED` with the started workflow's ID,
      left `SCHEDULED` after a transient error, or `FAILED`.

  The started workflow is not a child: it has no parent fields and the task does not follow it
  (upstream sets only `triggeringWorkflowId`, which neither stores). Its `taskToDomain` and
  `correlationId` default to the starting workflow's. The request's `idempotencyKey` and
  `idempotencyStrategy` are read but not used, as upstream's `startWorkflow`.

  The ID makes the start idempotent: an effect run again (after a crash, or when the recovery
  starts the task again) gets the workflow it started. A task run again in place (a rerun keeps
  its ID and retry count) is scheduled anew, so its `scheduledTime` gives it another workflow.
  """

  alias Archon.Domain.{StartWorkflowRequest, Task, Validation, Workflow}
  alias Archon.Runtime.Step.{Event, State, SubWorkflow}

  @parameter "startWorkflow"

  @doc """
  The ID of the workflow a task starts: the name-based UUID of
  `startworkflow:<workflow ID>:<task ID>:<retry count>:<scheduledTime>`.
  """
  @spec workflow_id(String.t(), Task.t()) :: String.t()
  def workflow_id(workflow_id, %Task{} = task) do
    SubWorkflow.name_uuid(
      "startworkflow:#{workflow_id}:#{task.task_id}:#{task.retry_count}:#{task.scheduled_time}"
    )
  end

  @doc """
  Upstream `StartWorkflow#start` for a `SCHEDULED` task: the workflow to start, or a `FAILED`
  task when the input has no valid request.
  """
  @spec start(State.t(), Task.t()) :: {:started, State.t()} | {:failed, Task.t()}
  def start(%State{wf: wf} = state, %Task{} = task) do
    case request(state, task) do
      {:ok, request} ->
        start = start_input(wf, request, workflow_id(wf.workflow_id, task))
        {:started, State.post(state, {:start_workflow, task.task_id, start})}

      {:error, reason} ->
        {:failed, failed(task, reason)}
    end
  end

  # getRequest, then what upstream's startWorkflow refuses before a workflow exists that the
  # runtime does not check (as ArchonWeb.WorkflowController's check_start).
  defp request(%State{env: env}, %Task{input_data: input}) do
    case Map.get(input, @parameter) do
      nil ->
        {:error, "Missing '#{@parameter}' in input data."}

      json ->
        with {:ok, request} <- decode(json),
             :ok <- validate(request, task_def_lookup: env.task_def_lookup) do
          refuse(request)
        end
    end
  end

  # objectMapper.convertValue; Jackson's message is not reproduced (ADR 0026, decision 7).
  defp decode(json) do
    case StartWorkflowRequest.from_json(json) do
      {:ok, request} ->
        {:ok, request}

      {:error, [{path, message} | _rest]} ->
        {:error, "Error reading StartWorkflowRequest. " <> String.trim("#{path} #{message}")}
    end
  end

  # Upstream joins the violations in the order of a Java Set; here they are in path order.
  defp validate(request, opts) do
    case StartWorkflowRequest.validate(request, opts) do
      :ok ->
        :ok

      {:error, errors} ->
        violations =
          errors
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map_join(fn {path, message} -> "'#{path}' -> #{message}. " end)

        {:error, "#{@parameter} validation failed. " <> violations}
    end
  end

  defp refuse(%StartWorkflowRequest{} = request) do
    cond do
      # lookupWorkflowDefinition's Utils.checkArgument.
      request.workflow_def == nil and Validation.java_blank?(request.name) ->
        {:error, "Workflow name must be specified when searching for a definition"}

      # Without an input upstream downloads it from the path, which a server without external
      # payload storage (as Archon) cannot.
      request.input in [nil, %{}] and
          not Validation.java_blank?(request.external_input_payload_storage_path) ->
        {:error,
         "Unable to download payload from external storage path: " <>
           request.external_input_payload_storage_path}

      true ->
        {:ok, request}
    end
  end

  # new StartWorkflowInput(request) with the starting workflow's defaults and
  # triggeringWorkflowId.
  defp start_input(%Workflow{} = wf, %StartWorkflowRequest{} = request, id) do
    %{
      workflow_id: id,
      name: request.name,
      version: request.version,
      definition: request.workflow_def,
      input: request.input,
      correlation_id:
        if(Validation.java_blank?(request.correlation_id),
          do: wf.correlation_id,
          else: request.correlation_id
        ),
      priority: request.priority,
      task_to_domain:
        if(request.task_to_domain in [nil, %{}],
          do: wf.task_to_domain,
          else: request.task_to_domain
        ),
      parent_workflow_id: nil,
      parent_workflow_task_id: nil,
      triggering_workflow_id: wf.workflow_id,
      idempotency_key: nil,
      idempotency_strategy: nil
    }
  end

  @doc """
  The result of starting the workflow. `{:ok, workflow}` completes the task with its ID. A
  transient error leaves the task `SCHEDULED` to try again; any other error fails it. A workflow
  other than the one the task asks for is ignored.
  """
  @spec started(State.t(), Task.t(), Event.sub_workflow_result()) ::
          {:done, Task.t()} | :ignore
  def started(%State{wf: wf}, %Task{} = task, {:ok, %Workflow{} = started}) do
    if started.workflow_id == workflow_id(wf.workflow_id, task) do
      output = Map.put(task.output_data, "workflowId", started.workflow_id)
      {:done, %{task | status: :completed, output_data: output}}
    else
      :ignore
    end
  end

  # TransientException: the task stays as it is and is started again later.
  def started(_state, %Task{} = task, {:error, :transient, _message}), do: {:done, task}

  def started(_state, %Task{} = task, {:error, message}), do: {:done, failed(task, message)}

  defp failed(task, reason), do: %{task | status: :failed, reason_for_incompletion: reason}
end
