# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (startWorkflow, startWorkflowIdempotent, resolveWorkflowDefinition, createWorkflowModel,
# validateWorkflow, terminateWorkflow) and core/.../metadata/MetadataMapperService.java
# (lookupForWorkflowDefinition, populateTaskDefinitions) at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the caller resolves the definition and builds the workflow, and the
# workflow's own process creates and decides it (ADR 0018, decisions 1 and 7).

defmodule Archon.Runtime do
  @moduledoc """
  The runtime API for workflows (ADR 0018, decision 7). Phase 5 REST calls these functions;
  the worker API is `Archon.Runtime.Tasks`.

    * `start_workflow/1` - upstream `startWorkflow`: resolves the definition, embeds the task
      definitions and builds the workflow here, then the workflow's process creates it and runs
      its first decide before answering.
    * `start_workflow_idempotent/1` - upstream `startWorkflowIdempotent` (a `SUB_WORKFLOW`
      child): the process creates the workflow, answers, and decides after the answer.
    * `get_workflow/2` - reads the store; no process is involved.
    * `terminate_workflow/2` - upstream `terminateWorkflow(String, String)`.

  Pause, resume, retry and restart are `Archon.Runtime.Lifecycle`.

  Every message to a workflow goes through `Archon.Runtime.WorkflowServer`, which starts the
  workflow's process when it is not running (activation).

  Configuration (`config :archon, Archon.Runtime`):

    * `:store`, `:queue`, `:metadata` - the implementations of `Archon.Runtime.Store`,
      `Archon.Runtime.Queue` and `Archon.Runtime.Metadata`, started by
      `Archon.Runtime.Supervisor` (the memory ones by default).
    * `:clock` - epoch milliseconds; `:new_id` - workflow and task IDs; `:timer` - sets the
      `:wake` timer, called with `(pid, message, delay_ms)` and returning a reference. Each is a
      function or `{module, function, args}` (the arguments are appended).
    * `:call_timeout` - the `GenServer.call` timeout to a workflow process, 30 s.
    * `:idle_timeout` - how long a process whose workflow is terminal waits for a request before
      it ends, 5 s.
    * `:hibernate_after` - idle time after which a running workflow's process hibernates, 15 s.
    * `:settings` - `Archon.Runtime.Step.Env` settings (`workflow_offset_timeout_ms`, ...).
    * `:hook` - for tests only: called with `(point, workflow_id, data)` at the points
      `Archon.Runtime.WorkflowServer` documents, so a test can fail or kill the process there.
  """

  alias Archon.Decider.{Context, Parameters}
  alias Archon.Domain.{SubWorkflowParams, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step.Effect
  alias Archon.Runtime.WorkflowServer

  @typedoc """
  What to start, as upstream's `StartWorkflowInput` (`t:Archon.Runtime.Step.Effect.start/0`).
  Only `:name` (or `:definition`) is required; `:workflow_id` is generated when missing, and a
  `nil` `:input` is upstream's `NULL input` error.
  """
  @type start_input :: Effect.start() | map()

  @typedoc "Why a start was refused before any workflow was created."
  @type start_error ::
          {:not_found, String.t()} | {:invalid, String.t()} | {:terminate, String.t()}

  @doc """
  Upstream `startWorkflow`. Returns the workflow ID once the workflow is created and its first
  decide is saved.

  Errors: `{:error, {:not_found, message}}` without a definition, `{:error, {:invalid, message}}`
  for a `nil` input, `{:error, {:terminate, message}}` when a `SUB_WORKFLOW` task names a workflow
  that has no definition, `{:error, :conflict}` when the ID exists, or `{:error, reason}` when the
  start failed (nothing is left in the store).
  """
  @spec start_workflow(start_input()) :: {:ok, String.t()} | {:error, term()}
  def start_workflow(input) when is_map(input) do
    with {:ok, workflow} <- new_workflow(input, Map.get(input, :workflow_id) || new_id()) do
      WorkflowServer.start(workflow)
    end
  end

  @doc """
  Upstream `startWorkflowIdempotent`: creates the workflow with `:workflow_id`, or returns the
  stored one with that ID. The stored one must belong to the same parent workflow and task
  (`{:error, message}` otherwise, upstream `validateIdempotentWorkflowOwnership`). A created
  workflow runs its first decide after this returns.
  """
  @spec start_workflow_idempotent(start_input()) :: {:ok, Workflow.t()} | {:error, term()}
  def start_workflow_idempotent(input) when is_map(input) do
    with id when is_binary(id) <- Map.get(input, :workflow_id),
         false <- String.trim(id) == "",
         {:ok, workflow} <- new_workflow(input, id) do
      WorkflowServer.start_idempotent(workflow)
    else
      {:error, _reason} = error ->
        error

      _blank ->
        {:error, {:invalid, "workflowId must be present for idempotent workflow start"}}
    end
  end

  @doc "Upstream `getExecutionStatus`: the stored workflow, with its tasks when asked."
  @spec get_workflow(String.t(), boolean()) :: {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow(id, include_tasks? \\ true) when is_binary(id),
    do: store().get_workflow(id, include_tasks?)

  @doc """
  Upstream `terminateWorkflow(String, String)` (ADR 0018, decision 8 (b)): `:ok`, also for a
  workflow already `TERMINATED`; `{:error, :conflict}` for a `COMPLETED` one and
  `{:error, :not_found}` for an unknown ID.
  """
  @spec terminate_workflow(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def terminate_workflow(id, reason) when is_binary(id),
    do: WorkflowServer.terminate_workflow(id, reason)

  # resolveWorkflowDefinition + createWorkflowModel
  defp new_workflow(input, id) do
    with {:ok, definition} <- definition(input),
         {:ok, definition} <- populate(definition),
         :ok <- validate_input(Map.get(input, :input)) do
      {:ok,
       %Workflow{
         workflow_id: id,
         correlation_id: Map.get(input, :correlation_id),
         priority: Map.get(input, :priority) || 0,
         workflow_definition: definition,
         status: :running,
         parent_workflow_id: Map.get(input, :parent_workflow_id),
         parent_workflow_task_id: Map.get(input, :parent_workflow_task_id),
         # WorkflowContext's client app; the server without one stores "".
         owner_app: "",
         create_time: now(),
         event: Map.get(input, :event),
         task_to_domain: Map.get(input, :task_to_domain) || %{},
         variables: definition.variables || %{},
         input: workflow_input(definition, Map.get(input, :input))
       }}
    end
  end

  defp definition(%{definition: %WorkflowDef{} = definition}), do: {:ok, definition}

  defp definition(input) do
    name = Map.get(input, :name)
    version = Map.get(input, :version)

    result =
      cond do
        name in [nil, ""] -> {:error, :not_found}
        version == nil -> metadata().get_latest_workflow_def(name)
        true -> metadata().get_workflow_def(name, version)
      end

    case result do
      {:ok, definition} ->
        {:ok, definition}

      {:error, :not_found} ->
        {:error,
         {:not_found, "No such workflow defined. name=#{java(name)}, version=#{java(version)}"}}
    end
  end

  defp java(nil), do: "null"
  defp java(value), do: to_string(value)

  @doc false
  # MetadataMapperService#populateTaskDefinitions: every task without a definition gets the
  # registered one, or an ad-hoc one (no retries or response timeout unless SIMPLE), and a
  # SUB_WORKFLOW without a version gets the latest one.
  @spec populate(WorkflowDef.t()) :: {:ok, WorkflowDef.t()} | {:error, start_error()}
  def populate(%WorkflowDef{tasks: tasks} = definition) do
    result =
      Enum.reduce_while(tasks, {:ok, []}, fn task, {:ok, acc} ->
        case populate_task(task) do
          {:ok, task} -> {:cont, {:ok, [task | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, tasks} <- result, do: {:ok, %{definition | tasks: Enum.reverse(tasks)}}
  end

  defp populate_task(nil), do: {:ok, nil}

  defp populate_task(%WorkflowTask{} = wt) do
    with {:ok, decision_cases} <- populate_map(wt.decision_cases),
         {:ok, default_case} <- populate_list(wt.default_case),
         {:ok, fork_tasks} <- populate_branches(wt.fork_tasks),
         {:ok, loop_over} <- populate_list(wt.loop_over),
         {:ok, sub_workflow_param} <- sub_workflow_version(wt) do
      {:ok,
       %{
         wt
         | task_definition: task_definition(wt),
           decision_cases: decision_cases,
           default_case: default_case,
           fork_tasks: fork_tasks,
           loop_over: loop_over,
           sub_workflow_param: sub_workflow_param
       }}
    end
  end

  defp populate_list(tasks) do
    Enum.reduce_while(tasks || [], {:ok, []}, fn task, {:ok, acc} ->
      case populate_task(task) do
        {:ok, task} -> {:cont, {:ok, acc ++ [task]}}
        error -> {:halt, error}
      end
    end)
  end

  defp populate_branches(branches) do
    Enum.reduce_while(branches || [], {:ok, []}, fn branch, {:ok, acc} ->
      case populate_list(branch) do
        {:ok, branch} -> {:cont, {:ok, acc ++ [branch]}}
        error -> {:halt, error}
      end
    end)
  end

  defp populate_map(cases) do
    Enum.reduce_while(cases || %{}, {:ok, %{}}, fn {name, tasks}, {:ok, acc} ->
      case populate_list(tasks) do
        {:ok, tasks} -> {:cont, {:ok, Map.put(acc, name, tasks)}}
        error -> {:halt, error}
      end
    end)
  end

  defp task_definition(%WorkflowTask{task_definition: %TaskDef{} = task_def}), do: task_def

  defp task_definition(%WorkflowTask{name: name, type: type}) when is_binary(name) do
    if String.trim(name) == "" do
      nil
    else
      case metadata().get_task_def(name) do
        {:ok, task_def} -> task_def
        {:error, :not_found} when type == "SIMPLE" -> %TaskDef{name: name}
        {:error, :not_found} -> %TaskDef{name: name, retry_count: 0, response_timeout_seconds: 0}
      end
    end
  end

  defp task_definition(%WorkflowTask{}), do: nil

  # populateVersionForSubWorkflow
  defp sub_workflow_version(%WorkflowTask{
         type: "SUB_WORKFLOW",
         sub_workflow_param: %SubWorkflowParams{} = params
       }) do
    if SubWorkflowParams.version(params) == nil do
      name = SubWorkflowParams.name(params)

      case latest_version(name) do
        {:ok, version} ->
          {:ok, %{params | version: version}}

        :error ->
          {:error,
           {:terminate,
            "The Task #{java(name)} defined as a sub-workflow has no workflow definition available "}}
      end
    else
      {:ok, params}
    end
  end

  defp sub_workflow_version(%WorkflowTask{sub_workflow_param: params}), do: {:ok, params}

  defp latest_version(name) when is_binary(name) do
    case metadata().get_latest_workflow_def(name) do
      {:ok, %WorkflowDef{version: version}} -> {:ok, version}
      {:error, :not_found} -> :error
    end
  end

  defp latest_version(_name), do: :error

  # validateWorkflow (external payload storage is out of scope)
  defp validate_input(nil),
    do: {:error, {:invalid, "NULL input passed when starting workflow"}}

  defp validate_input(_input), do: :ok

  defp workflow_input(definition, input) when is_map(input) and map_size(input) > 0,
    do: Parameters.workflow_input(definition, input)

  defp workflow_input(_definition, _input), do: %{}

  ## Configuration

  @doc false
  @spec config() :: keyword()
  def config, do: Application.get_env(:archon, __MODULE__, [])

  @doc false
  @spec store() :: module()
  def store, do: Keyword.get(config(), :store, Archon.Runtime.Store.Memory)

  @doc false
  @spec queue() :: module()
  def queue, do: Keyword.get(config(), :queue, Archon.Runtime.Queue.Memory)

  @doc false
  @spec metadata() :: module()
  def metadata, do: Keyword.get(config(), :metadata, Archon.Runtime.Metadata.Memory)

  @doc false
  @spec now() :: integer()
  def now do
    case Keyword.get(config(), :clock) do
      nil -> System.system_time(:millisecond)
      fun -> invoke(fun, [])
    end
  end

  @doc false
  @spec new_id() :: String.t()
  def new_id do
    case Keyword.get(config(), :new_id) do
      nil -> Context.uuid4()
      fun -> invoke(fun, [])
    end
  end

  @doc false
  @spec setting(atom(), term()) :: term()
  def setting(key, default), do: Keyword.get(config(), key, default)

  @doc false
  # A configured function: a fun, or `{module, function, args}` with `args` appended.
  @spec invoke(function() | {module(), atom(), list()}, list()) :: term()
  def invoke(fun, args) when is_function(fun), do: apply(fun, args)
  def invoke({module, function, extra}, args), do: apply(module, function, extra ++ args)
end
