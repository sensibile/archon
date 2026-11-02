# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Decider.Context do
  @moduledoc """
  Outside state the Decider reads, passed in instead of looked up (ADR 0014, decision 2).

    * `now` - epoch milliseconds, read once per `Archon.Decider.decide/2` call. Replaces every
      `System.currentTimeMillis()` of upstream `DeciderService` and the mappers.
    * `new_id` - generates task IDs (upstream `IDGenerator.generate()`). UUID v4 by default.
    * `task_defs` - task definitions by name, filled by the caller for the names the workflow
      definition uses. Replaces `MetadataDAO.getTaskDef`; a missing name is upstream's `null`.
    * `latest_workflow_versions` - the latest version of each workflow definition name, filled by
      the caller for the sub-workflows the definition starts. Replaces
      `MetadataDAO.getLatestWorkflowDef` in the `SUB_WORKFLOW` mapper; a missing name is
      upstream's empty result.
    * `system_tasks` - the system task registry, see `Archon.Decider.SystemTasks`.
    * `jitter` - given the configured `backoffJitterMs`, returns a value in `0..max`. Replaces
      upstream's `ThreadLocalRandom` in `retry`; uniform by default.
    * `evaluate_script` - runs a script operation (`t:Archon.Script.evaluator/0`). Replaces
      upstream's static `ScriptEvaluator`; `Archon.Script.evaluate/3` (the worker pool) by
      default. It is the one call the Decider makes that sends a process message: a computation
      that changes no state, allowed by ADR 0015 (decision 3).
    * `task_def_lookup` - reads a task definition `task_defs` does not hold, for a name only the
      input gives (`DYNAMIC`, `FORK_JOIN_DYNAMIC`). Replaces the mappers' `MetadataDAO#getTaskDef`;
      answers `{:error, :not_found}` by default, and the runtime reads the metadata store.
    * `workflow_def_lookup` - reads a workflow definition by name and version (`nil`: the
      latest), for a sub-workflow name only the input gives (`FORK_JOIN_DYNAMIC`). Replaces
      `MetadataDAO#getWorkflowDef`/`getLatestWorkflowDef`; `{:error, :not_found}` by default.
    * `evaluate_jq` - runs a jq query over a JSON value and answers its results
      (`JSON_JQ_TRANSFORM`); `Archon.Jq.evaluate/2` (the `archon_jq` pool) by default. Like
      `evaluate_script`, a computation that changes no state (ADR 0026, decision 6).

    The two lookups read the store as upstream's mappers do, without remembering an answer
    within a decide, and like `evaluate_script` change no state (ADR 0026, decision 2, which
    widens ADR 0014 decision 2 and ADR 0015 decision 3 to metadata reads).

  Settings the system tasks read:

    * `max_workflow_variables_payload_kb` - 256, the cap of a workflow's `variables` serialized
      as JSON (upstream `conductor.app.maxWorkflowVariablesPayloadSizeThresholdKB`).
  """

  alias Archon.Decider.SystemTasks
  alias Archon.Domain.{Codec, TaskDef, WorkflowDef}
  alias Archon.{Jq, Script}

  @typedoc "The `task_def_lookup` function."
  @type task_def_lookup :: (String.t() -> {:ok, TaskDef.t()} | {:error, :not_found})

  @typedoc "The `workflow_def_lookup` function."
  @type workflow_def_lookup ::
          (String.t(), integer() | nil -> {:ok, WorkflowDef.t()} | {:error, :not_found})

  @typedoc "The `evaluate_jq` function: a query and its input to the query's results."
  @type jq_evaluator :: (String.t(), Codec.json() ->
                           {:ok, [Codec.json()]} | {:error, Script.Error.t()})

  @enforce_keys [:now]
  defstruct [
    :now,
    :new_id,
    :jitter,
    :evaluate_script,
    :task_def_lookup,
    :workflow_def_lookup,
    :evaluate_jq,
    task_defs: %{},
    latest_workflow_versions: %{},
    system_tasks: %{},
    max_workflow_variables_payload_kb: 256
  ]

  @type t :: %__MODULE__{
          now: integer(),
          new_id: (-> String.t()),
          jitter: (non_neg_integer() -> non_neg_integer()),
          evaluate_script: Script.evaluator(),
          task_def_lookup: task_def_lookup(),
          workflow_def_lookup: workflow_def_lookup(),
          evaluate_jq: jq_evaluator(),
          task_defs: %{optional(String.t()) => TaskDef.t()},
          latest_workflow_versions: %{optional(String.t()) => integer()},
          system_tasks: SystemTasks.t(),
          max_workflow_variables_payload_kb: non_neg_integer()
        }

  @doc """
  Builds a context. `now` is required; `new_id`, `jitter`, `evaluate_script`, `evaluate_jq` and
  `system_tasks` default to UUID v4, uniform jitter, `Archon.Script.evaluate/3`,
  `Archon.Jq.evaluate/2` and `Archon.Decider.SystemTasks.default/0`; the lookups find nothing.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      now: Keyword.fetch!(opts, :now),
      new_id: Keyword.get(opts, :new_id, &uuid4/0),
      jitter: Keyword.get(opts, :jitter, &uniform_jitter/1),
      evaluate_script: Keyword.get(opts, :evaluate_script, &Script.evaluate/3),
      task_def_lookup: Keyword.get(opts, :task_def_lookup, &no_task_def/1),
      workflow_def_lookup: Keyword.get(opts, :workflow_def_lookup, &no_workflow_def/2),
      evaluate_jq: Keyword.get(opts, :evaluate_jq, &Jq.evaluate/2),
      task_defs: Keyword.get(opts, :task_defs, %{}),
      latest_workflow_versions: Keyword.get(opts, :latest_workflow_versions, %{}),
      system_tasks: Keyword.get(opts, :system_tasks, SystemTasks.default()),
      max_workflow_variables_payload_kb:
        Keyword.get(opts, :max_workflow_variables_payload_kb, 256)
    }
  end

  @doc "A `task_def_lookup` that finds nothing."
  @spec no_task_def(String.t()) :: {:error, :not_found}
  def no_task_def(_name), do: {:error, :not_found}

  @doc "A `workflow_def_lookup` that finds nothing."
  @spec no_workflow_def(String.t(), integer() | nil) :: {:error, :not_found}
  def no_workflow_def(_name, _version), do: {:error, :not_found}

  @doc "A random (version 4) UUID in its canonical lowercase form."
  @spec uuid4() :: String.t()
  def uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> ->
      Enum.join([p1, p2, p3, p4, p5], "-")
    end)
  end

  @doc "A uniformly random integer in `0..max`."
  @spec uniform_jitter(non_neg_integer()) :: non_neg_integer()
  def uniform_jitter(max) when is_integer(max) and max >= 0, do: :rand.uniform(max + 1) - 1
end
