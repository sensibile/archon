# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.RuntimeCase do
  @moduledoc """
  A case for tests of the running runtime (`Archon.Runtime.Supervisor` under the application):
  not `async`, hooks reset around each test (`Archon.RuntimeHooks`), and the captured
  definitions `archon_simple`, `archon_task_a` and `archon_task_b` registered in the metadata.
  """

  use ExUnit.CaseTemplate

  alias Archon.Contract
  alias Archon.Domain.{Task, WorkflowDef}
  alias Archon.Runtime
  alias Archon.Runtime.{Recovery, Waker, WorkflowServer}

  using do
    quote do
      import Archon.RuntimeCase

      alias Archon.Runtime
      alias Archon.Runtime.WorkflowServer
      alias Archon.RuntimeHooks
    end
  end

  setup do
    Archon.RuntimeHooks.reset()
    on_exit(&Archon.RuntimeHooks.reset/0)
    register_definitions()
    :ok
  end

  @doc "Registers the captured workflow and task definitions (`metadata_*` fixtures)."
  @spec register_definitions() :: :ok
  def register_definitions do
    for {_name, task_def} <- Archon.StepReplay.registered_task_defs(),
        do: :ok = Runtime.metadata().update_task_def(task_def)

    {:ok, definition} =
      WorkflowDef.from_json(Contract.fixture("metadata_get_workflow")["response"]["body"])

    :ok = Runtime.metadata().update_workflow_def(definition)
  end

  @doc "Starts `archon_simple` with the input."
  @spec start_simple(map(), keyword()) :: String.t()
  def start_simple(input, fields \\ []) do
    {:ok, id} =
      Runtime.start_workflow(Map.merge(%{name: "archon_simple", input: input}, Map.new(fields)))

    id
  end

  @doc "The stored task with the reference name."
  @spec task(String.t(), String.t()) :: Task.t()
  def task(workflow_id, ref) do
    {:ok, workflow} = Runtime.get_workflow(workflow_id)
    Enum.find(workflow.tasks, &(&1.reference_task_name == ref))
  end

  @doc "Waits until `fun` returns a truthy value, and returns it."
  @spec eventually((-> term()), non_neg_integer()) :: term()
  def eventually(fun, attempts \\ 100) do
    case fun.() do
      falsy when falsy in [nil, false] and attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      falsy when falsy in [nil, false] ->
        flunk("condition not met")

      value ->
        value
    end
  end

  @doc """
  Empties `queues`, shared with other tests, for a test that polls them, and keeps them so: a
  workflow left by another test that is activated would have its recovery or wake check queue its
  scheduled task again. So `Archon.Runtime.Waker` is suspended until the test exits, the
  `Archon.Runtime.Recovery` run of a runtime restart is waited for, and the workflow processes
  and outbox runners left running are stopped before the messages are removed.
  """
  @spec isolate_queues([String.t()]) :: :ok
  def isolate_queues(queues) do
    :ok = :sys.suspend(Waker)

    ExUnit.Callbacks.on_exit(fn ->
      with(pid when is_pid(pid) <- Process.whereis(Waker), do: :sys.resume(pid))
    end)

    eventually(fn -> not recovery_running?() end, 3_000)
    stop_workflows()
    for queue <- queues, id <- pop_all(queue), do: Runtime.queue().remove(queue, id)
    :ok
  end

  defp recovery_running? do
    Archon.Runtime.Supervisor
    |> Supervisor.which_children()
    |> Enum.any?(&match?({Recovery, pid, _type, _modules} when is_pid(pid), &1))
  end

  # A runner may activate a workflow and a process may start a runner, so until neither is left.
  defp stop_workflows do
    runners = Elixir.Task.Supervisor.children(Archon.Runtime.TaskSupervisor)

    servers =
      for {_id, pid, _type, _modules} <-
            DynamicSupervisor.which_children(Archon.Runtime.WorkflowSupervisor),
          is_pid(pid),
          do: pid

    if runners != [] or servers != [] do
      for pid <- runners,
          do: Elixir.Task.Supervisor.terminate_child(Archon.Runtime.TaskSupervisor, pid)

      for pid <- servers,
          do: DynamicSupervisor.terminate_child(Archon.Runtime.WorkflowSupervisor, pid)

      stop_workflows()
    end
  end

  defp pop_all(queue) do
    case Runtime.queue().pop(queue, 100, 0) do
      [] -> []
      ids -> ids ++ pop_all(queue)
    end
  end

  @doc "Waits until the workflow's process is gone."
  @spec await_down(String.t()) :: true
  def await_down(id), do: eventually(fn -> WorkflowServer.whereis(id) == nil end)
end
