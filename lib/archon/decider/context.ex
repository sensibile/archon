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
  """

  alias Archon.Decider.SystemTasks
  alias Archon.Domain.TaskDef
  alias Archon.Script

  @enforce_keys [:now]
  defstruct [
    :now,
    :new_id,
    :jitter,
    :evaluate_script,
    task_defs: %{},
    latest_workflow_versions: %{},
    system_tasks: %{}
  ]

  @type t :: %__MODULE__{
          now: integer(),
          new_id: (-> String.t()),
          jitter: (non_neg_integer() -> non_neg_integer()),
          evaluate_script: Script.evaluator(),
          task_defs: %{optional(String.t()) => TaskDef.t()},
          latest_workflow_versions: %{optional(String.t()) => integer()},
          system_tasks: SystemTasks.t()
        }

  @doc """
  Builds a context. `now` is required; `new_id`, `jitter`, `evaluate_script` and `system_tasks`
  default to UUID v4, uniform jitter, `Archon.Script.evaluate/3` and
  `Archon.Decider.SystemTasks.default/0`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      now: Keyword.fetch!(opts, :now),
      new_id: Keyword.get(opts, :new_id, &uuid4/0),
      jitter: Keyword.get(opts, :jitter, &uniform_jitter/1),
      evaluate_script: Keyword.get(opts, :evaluate_script, &Script.evaluate/3),
      task_defs: Keyword.get(opts, :task_defs, %{}),
      latest_workflow_versions: Keyword.get(opts, :latest_workflow_versions, %{}),
      system_tasks: Keyword.get(opts, :system_tasks, SystemTasks.default())
    }
  end

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
