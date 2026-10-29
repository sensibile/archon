# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (terminate, terminateWorkflow, cancelNonTerminalTasks, completeWorkflow) and
# core/.../execution/tasks/SubWorkflow.java (cancel, terminateSubWorkflow)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the child termination, queue clean-up, parent notification and failure
# workflow start became effects around one commit (ADR 0018, decision 8).

defmodule Archon.Runtime.Step.Terminate do
  @moduledoc """
  The two ways a workflow is terminated (ADR 0018, decision 8), both in the order "cancel the
  remaining tasks (with the child terminations), commit the workflow, clean up the queues and
  notify the parent":

    * `by_decider/2` - upstream `terminate(workflow, TerminateWorkflowException)`: the status the
      Decider named, `failedTaskId`, and the definition's failure workflow.
    * `by_request/2` - upstream `terminateWorkflow(String, String)`: `TERMINATED` with neither.

  `by_parent/2` is upstream `SubWorkflow#terminateSubWorkflow` on the child side: `TERMINATED`
  whatever the status was, without a failure workflow.
  """

  alias Archon.Decider.{Retry, Termination}
  alias Archon.Domain.{Task, Workflow}
  alias Archon.Runtime.Step.{Effect, Schedule, State, SubWorkflow}

  @doc "Upstream `terminate(workflow, TerminateWorkflowException)`."
  @spec by_decider(State.t(), Termination.t()) :: State.t()
  def by_decider(%State{wf: wf} = state, %Termination{} = termination) do
    wf = if Workflow.terminal?(wf.status), do: wf, else: State.set_status(wf, termination.status)

    wf =
      if termination.task != nil and wf.failed_task_id == nil,
        do: %{wf | failed_task_id: termination.task.task_id},
        else: wf

    state = State.put_workflow(state, wf)

    state =
      case termination.task do
        nil -> state
        task -> State.save_task(state, State.task(state, task.task_id) || task)
      end

    definition = wf.workflow_definition

    terminate_workflow(
      state,
      termination.reason,
      failure_workflow(definition.failure_workflow, wf),
      definition.failure_workflow_version
    )
  end

  # A failure workflow name starting with `$` names a workflow input parameter
  # (`${workflow.input.<name>}`).
  defp failure_workflow("$" <> _rest = expression, wf) do
    case expression |> String.split(".") |> Enum.at(2) do
      nil -> nil
      name -> wf.input |> Map.get(name) |> string_or_nil()
    end
  end

  defp failure_workflow(name, _wf), do: name

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  @doc """
  Upstream `terminateWorkflow(String, String)`: a `COMPLETED` workflow is a conflict, a
  `TERMINATED` one stays as it is, anything else becomes `TERMINATED`.
  """
  @spec by_request(State.t(), String.t() | nil) :: {:ok | {:error, :conflict}, State.t()}
  def by_request(%State{wf: %Workflow{status: :completed}} = state, _reason),
    do: {{:error, :conflict}, state}

  def by_request(%State{wf: %Workflow{status: :terminated}} = state, _reason), do: {:ok, state}

  def by_request(%State{wf: wf} = state, reason) do
    state = State.put_workflow(state, State.set_status(wf, :terminated))
    {:ok, terminate_workflow(state, reason, nil, nil)}
  end

  @doc """
  The child side of upstream `SubWorkflow#terminateSubWorkflow`: `TERMINATED` whatever the
  status, unless it already is.
  """
  @spec by_parent(State.t(), String.t()) :: State.t()
  def by_parent(%State{wf: %Workflow{status: :terminated}} = state, _reason), do: state

  def by_parent(%State{wf: wf} = state, reason) do
    state
    |> State.put_workflow(State.set_status(wf, :terminated))
    |> terminate_workflow(reason, nil, nil)
  end

  # terminateWorkflow(WorkflowModel, reason, failureWorkflow, failureWorkflowVersion)
  defp terminate_workflow(%State{wf: wf} = state, reason, failure_workflow, version) do
    wf = if Workflow.terminal?(wf.status), do: wf, else: State.set_status(wf, :terminated)

    wf =
      wf
      |> Retry.update_output(nil)
      |> add_failed_task_names()
      |> Map.put(:reason_for_incompletion, reason)

    state
    |> State.put_workflow(wf)
    |> cancel_non_terminal(:pre)
    |> State.save_workflow()
    |> remove_from_queues()
    |> notify_parent()
    |> start_failure_workflow(failure_workflow, version)
  end

  defp remove_from_queues(%State{wf: wf, env: env} = state) do
    wf.tasks
    |> Enum.reject(&Schedule.system_task?(env, &1))
    |> Enum.reduce(state, &State.post(&2, {:queue_remove, Schedule.queue_name(&1), &1.task_id}))
  end

  defp start_failure_workflow(state, name, _version) when name in [nil, ""], do: state

  defp start_failure_workflow(%State{wf: wf, env: env} = state, name, version) do
    id = if String.trim(name) != "", do: env.new_id.()

    case failure_start(wf, id, name, version, state.now) do
      {:ok, start} ->
        state
        |> State.put_workflow(%{
          wf
          | output: Map.put(wf.output, "conductor.failure_workflow", id)
        })
        |> State.save_workflow()
        |> State.post({:start_failure_workflow, start})

      :none ->
        state
    end
  end

  @doc """
  The start of the failure workflow the definition names, with the given ID, or `:none`. Its
  input is the workflow's with `workflowId`, `reason`, `failureStatus`, `failureTaskId` and
  `failedWorkflow` (the workflow as JSON).
  """
  @spec failure_start(Workflow.t(), String.t()) :: {:ok, Effect.start()} | :none
  def failure_start(%Workflow{workflow_definition: definition} = wf, id) do
    name = failure_workflow(definition.failure_workflow, wf)
    failure_start(wf, id, name, definition.failure_workflow_version, wf.update_time)
  end

  defp failure_start(wf, id, name, version, now) do
    if id == nil or name == nil or String.trim(name) == "" do
      :none
    else
      input =
        wf.input
        |> Map.merge(%{
          "workflowId" => wf.workflow_id,
          "reason" => wf.reason_for_incompletion,
          "failureStatus" => wf.status |> Atom.to_string() |> String.upcase()
        })
        |> put_present("failureTaskId", wf.failed_task_id)
        |> Map.put("failedWorkflow", Workflow.to_json(wf, now))

      {:ok,
       %{
         workflow_id: id,
         name: name,
         version: version,
         definition: nil,
         input: input,
         correlation_id: wf.correlation_id,
         priority: nil,
         task_to_domain: wf.task_to_domain,
         parent_workflow_id: nil,
         parent_workflow_task_id: nil,
         triggering_workflow_id: wf.workflow_id,
         idempotency_key: nil,
         idempotency_strategy: nil
       }}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  The output upstream stores when the failure workflow does not start:
  `Error workflow <name> failed to start.  reason: <reason>`.
  """
  @spec failure_workflow_failed(State.t(), String.t()) :: State.t()
  def failure_workflow_failed(%State{wf: wf} = state, reason) do
    name = failure_workflow(wf.workflow_definition.failure_workflow, wf)
    message = "Error workflow #{name} failed to start.  reason: #{reason}"

    state
    |> State.put_workflow(%{
      wf
      | output: Map.put(wf.output, "conductor.failure_workflow", message)
    })
    |> State.save_workflow()
  end

  @doc """
  Upstream `cancelNonTerminalTasks`: every task that is not terminal is saved `CANCELED`, and the
  child of a `SUB_WORKFLOW` task is terminated by a `pre` or `post` effect.
  """
  @spec cancel_non_terminal(State.t(), :pre | :post) :: State.t()
  def cancel_non_terminal(%State{wf: wf} = state, timing) do
    wf.tasks
    |> Enum.reject(&Task.terminal?(&1.status))
    |> Enum.reduce(state, fn task, state ->
      task = %{task | status: :canceled}

      state =
        if task.task_type == "SUB_WORKFLOW",
          do: effect(state, timing, cancel_child(wf, task)),
          else: state

      State.save_task(state, task)
    end)
  end

  @doc """
  Upstream `SubWorkflow#cancel`: terminates the child (the deterministic ID when the task has
  none) with the parent's reason.
  """
  @spec cancel_child(Workflow.t(), Task.t()) :: Effect.t()
  def cancel_child(%Workflow{} = wf, %Task{} = task) do
    reason =
      if wf.reason_for_incompletion in [nil, ""],
        do:
          "Parent workflow has been terminated with status " <>
            (wf.status |> Atom.to_string() |> String.upcase()),
        else: "Parent workflow has been terminated with reason: " <> wf.reason_for_incompletion

    id = Task.sub_workflow_id(task) || SubWorkflow.child_id(wf.workflow_id, task)
    {:terminate_sub_workflow, id, reason}
  end

  defp effect(state, :pre, effect), do: State.pre(state, effect)
  defp effect(state, :post, effect), do: State.post(state, effect)

  @doc """
  Adds the reference and definition names of the `FAILED` and `FAILED_WITH_TERMINAL_ERROR`
  tasks to the workflow's sets (`completeWorkflow`, `terminateWorkflow`).
  """
  @spec add_failed_task_names(Workflow.t()) :: Workflow.t()
  def add_failed_task_names(%Workflow{tasks: tasks} = wf) do
    failed = Enum.filter(tasks, &(&1.status in [:failed, :failed_with_terminal_error]))

    %{
      wf
      | failed_reference_task_names:
          union(wf.failed_reference_task_names, Enum.map(failed, & &1.reference_task_name)),
        failed_task_names: union(wf.failed_task_names, Enum.map(failed, &Task.task_def_name/1))
    }
  end

  defp union(set, names), do: Enum.uniq((set || []) ++ names)

  @doc """
  A workflow with a parent notifies it once the commit is saved (upstream
  `updateParentWorkflowTask` and `expediteLazyWorkflowEvaluation`). The effect carries the
  stored workflow, filled in when the step finishes.
  """
  @spec notify_parent(State.t()) :: State.t()
  def notify_parent(%State{wf: %Workflow{parent_workflow_id: nil}} = state), do: state

  def notify_parent(%State{wf: wf} = state),
    do:
      State.post(state, {:notify_parent, wf.parent_workflow_id, wf.parent_workflow_task_id, nil})
end
