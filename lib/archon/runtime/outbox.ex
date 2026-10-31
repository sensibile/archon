# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (updateAndPushParents, updateParentWorkflowTask, terminateWorkflow's failure workflow start) and
# core/.../execution/tasks/SubWorkflow.java (cancel) at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the work a workflow does on other workflows is saved with its commit and
# run at least once, in order, by one runner per workflow outside its process (ADR 0021,
# decision 4).

defmodule Archon.Runtime.Outbox do
  @moduledoc """
  The outbox runner of one workflow (ADR 0021, decision 4).

  A workflow's commit saves the work it does on other workflows (`Commit.outbox`): a child
  termination after the commit, a notice or a revival request to its parent, the retry of a
  failed child and the start of its failure workflow. `Archon.Runtime.WorkflowServer` starts one
  runner for it with `start/1` (`Task.Supervisor.async_nolink/3` under
  `Archon.Runtime.TaskSupervisor`) and gets its result back.

  The runner first registers as `{:outbox, workflow_id}` in `Archon.Runtime.Registry`. When that
  key is taken (the runner of an earlier process of the workflow still runs), it runs nothing and
  returns `{:already_registered, pid}`. Otherwise it reads `pending_outbox/1` and runs the
  entries in ID order, acking each one that is done (`ack_outbox/2`). It stops before the next
  entry once the workflow's process is gone, so a new process's runner never overlaps it on more
  than the entry it is running, which is idempotent.

  Each result is classified by an allow list, not by its shape:

    * `:ok`, or the other workflow does not exist (`{:error, :not_found}`) - acked.
    * The business errors `{:error, :conflict}` and `{:error, {kind, message}}` with `kind` one of
      `:conflict`, `:not_found` and `:invalid_state` (ADR 0018, decision 9) - logged and acked.
    * A failure workflow that could not start for a business reason (`{:error, message}`) - the
      runner stops and returns `{:feedback, id, {:failure_workflow_started, {:error, message}}}`;
      the process runs that event and deletes the entry in its commit (`Commit.outbox_ack`).
    * Anything else (a call timeout, an exit, an exception, an isolated failure
      `{:error, {:env | :pre_effect | :commit | :post_effect, _}}`, a store failure) - the runner
      stops and returns `{:retry, reason}`; later entries wait for it.

  Returns `:done` when every entry it read is acked. For tests, the `hook` configuration is
  called at `:outbox` (before an entry runs, with `{id, effect}`) and `:outbox_ack` (before it is
  acked, with the ID).
  """

  require Logger

  alias Archon.Domain.Workflow
  alias Archon.Runtime
  alias Archon.Runtime.Step.{Effect, Event}
  alias Archon.Runtime.{Store, SubWorkflows}

  @registry Archon.Runtime.Registry
  @supervisor Archon.Runtime.TaskSupervisor

  @business [:conflict, :not_found, :invalid_state]

  @type result ::
          :done
          | :owner_down
          | {:retry, term()}
          | {:feedback, Store.outbox_id(), Event.t()}
          | {:already_registered, pid()}

  @doc "Starts the runner of the calling workflow process's `workflow_id`."
  @spec start(String.t()) :: Elixir.Task.t()
  def start(workflow_id) when is_binary(workflow_id),
    do: Elixir.Task.Supervisor.async_nolink(@supervisor, __MODULE__, :run, [workflow_id, self()])

  @doc false
  @spec run(String.t(), pid()) :: result()
  def run(workflow_id, owner) do
    case Registry.register(@registry, {:outbox, workflow_id}, nil) do
      {:ok, _owner} ->
        ref = Process.monitor(owner)
        result = drain(workflow_id, ref, Runtime.store().pending_outbox(workflow_id))
        # The registry drops an ended process asynchronously; the owner's next runner must not
        # find the key still taken.
        Registry.unregister(@registry, {:outbox, workflow_id})
        result

      {:error, {:already_registered, pid}} ->
        {:already_registered, pid}
    end
  end

  defp drain(_id, _ref, []), do: :done

  defp drain(id, ref, [{entry, effect} | rest]) do
    if owner_down?(ref) do
      :owner_down
    else
      case classify(effect, execute(id, entry, effect)) do
        :ack ->
          hook(:outbox_ack, id, entry)
          :ok = Runtime.store().ack_outbox(id, [entry])
          drain(id, ref, rest)

        {:feedback, event} ->
          {:feedback, entry, event}

        {:retry, reason} ->
          {:retry, reason}
      end
    end
  end

  defp owner_down?(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> true
    after
      0 -> false
    end
  end

  defp execute(id, entry, effect) do
    hook(:outbox, id, {entry, effect})
    run_effect(id, effect)
  rescue
    exception -> {:raised, {exception, __STACKTRACE__}}
  catch
    :exit, reason -> {:exit, reason}
    :throw, value -> {:throw, value}
  end

  @doc false
  # One entry, as the runner of `owner_id` runs it.
  @spec run_effect(String.t(), Effect.t()) :: term()
  def run_effect(owner_id, {:terminate_sub_workflow, child_id, reason}),
    do: SubWorkflows.terminate_child(owner_id, child_id, reason)

  def run_effect(owner_id, {:terminate_sub_workflow, child_id, reason, parent_end_count}),
    do: SubWorkflows.terminate_child(owner_id, child_id, reason, end_count: parent_end_count)

  # The entry names the child (the owner); it is read when the notice is sent.
  def run_effect(owner_id, {:notify_parent, parent_id, parent_task_id, nil}) do
    case Runtime.store().get_workflow(owner_id, true) do
      {:ok, child} -> SubWorkflows.notify_parent(parent_id, parent_task_id, child)
      {:error, :not_found} -> :ok
    end
  end

  def run_effect(_owner_id, {:notify_parent, parent_id, parent_task_id, %Workflow{} = child}),
    do: SubWorkflows.notify_parent(parent_id, parent_task_id, child)

  def run_effect(_owner_id, {:revive_parent, parent_id, parent_task_id}),
    do: SubWorkflows.revive_parent(parent_id, parent_task_id)

  def run_effect(owner_id, {:retry_sub_workflow, child_id}),
    do: SubWorkflows.retry_child(owner_id, child_id)

  def run_effect(_owner_id, {:start_failure_workflow, start}),
    do: SubWorkflows.start_failure_workflow(start)

  defp classify({:start_failure_workflow, _start}, {:error, message}) when is_binary(message),
    do: {:feedback, {:failure_workflow_started, {:error, message}}}

  defp classify(_effect, :ok), do: :ack
  defp classify(_effect, {:error, :not_found}), do: :ack

  defp classify(effect, {:error, :conflict} = error), do: business(effect, error)

  defp classify(effect, {:error, {kind, _message}} = error) when kind in @business,
    do: business(effect, error)

  defp classify(_effect, other), do: {:retry, other}

  defp business(effect, error) do
    Logger.info("outbox entry #{inspect(effect)} ended with #{inspect(error)}")
    :ack
  end

  defp hook(point, workflow_id, data) do
    case Runtime.setting(:hook, nil) do
      nil -> :ok
      fun -> Runtime.invoke(fun, [point, workflow_id, data])
    end
  end
end
