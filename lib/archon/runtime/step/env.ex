# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/config/ConductorProperties.java
# (workflowOffsetTimeout, maxPostponeDurationSeconds, activeWorkerLastPollTimeout,
# taskExecutionPostponeDuration, systemTaskWorkerCallbackDuration, systemTaskPostponeThreshold)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the settings and every outside value the runtime reads became one struct
# passed to Archon.Runtime.Step (ADR 0018, decision 2).

defmodule Archon.Runtime.Step.Env do
  @moduledoc """
  The outside values one `Archon.Runtime.Step.run/3` call reads (ADR 0018, decision 2).
  `Archon.Runtime.WorkflowServer` fills it for each event from the store, the queue and the
  metadata.

    * `now`, `new_id`, `jitter`, `evaluate_script`, `task_defs`, `latest_workflow_versions` and
      `system_tasks` - as in `Archon.Decider.Context`, which `context/1` builds from them.
    * `poll_data` - the last poll time (epoch ms) by `{task_type, domain}`, for
      `getActiveDomain`. A missing key is upstream's missing `PollData`.
    * `in_progress` - the number of `IN_PROGRESS` tasks by task definition name, for the
      concurrent execution limit of a poll.
    * `queued` - the IDs of tasks that have a queue message, for the recovery check.
    * `workflows` - other workflows the step reads, by ID: the children of `SUB_WORKFLOW`
      tasks, the parent and the failure workflow. `nil` means the store has no such workflow; a
      missing key means it was not looked up, and the check that needs it is skipped.

  The settings default to upstream's `ConductorProperties`:

    * `workflow_offset_timeout_ms` - 30 s, the default re-evaluation interval
      (`workflowOffsetTimeout`).
    * `max_postpone_ms` - 3600 s, the cap of one re-evaluation interval
      (`maxPostponeDurationSeconds`).
    * `active_worker_last_poll_ms` - 10 s (`activeWorkerLastPollTimeout`).
    * `task_execution_postpone_ms` - 60 s, how long a poll over the concurrent execution limit
      puts the task back (`taskExecutionPostponeDuration`).
    * `system_task_callback_seconds` - 30 (`systemTaskWorkerCallbackDuration`), the evaluation
      offset of an asynchronous system task that has none of its own.
    * `system_task_postpone_threshold` - 200 (`systemTaskPostponeThreshold`), the `JOIN` poll
      count after which its evaluation offset grows.
    * `max_decide_iterations` - 100, the decide loop iterations of one event (ADR 0018,
      decision 4).
  """

  alias Archon.Decider.{Context, SystemTasks}
  alias Archon.Domain.{TaskDef, Workflow}
  alias Archon.Script

  @enforce_keys [:now]
  defstruct [
    :now,
    :new_id,
    :jitter,
    :evaluate_script,
    task_defs: %{},
    latest_workflow_versions: %{},
    system_tasks: %{},
    poll_data: %{},
    in_progress: %{},
    queued: MapSet.new(),
    workflows: %{},
    workflow_offset_timeout_ms: 30_000,
    max_postpone_ms: 3_600_000,
    active_worker_last_poll_ms: 10_000,
    task_execution_postpone_ms: 60_000,
    system_task_callback_seconds: 30,
    system_task_postpone_threshold: 200,
    max_decide_iterations: 100
  ]

  @type t :: %__MODULE__{
          now: integer(),
          new_id: (-> String.t()),
          jitter: (non_neg_integer() -> non_neg_integer()),
          evaluate_script: Script.evaluator(),
          task_defs: %{optional(String.t()) => TaskDef.t()},
          latest_workflow_versions: %{optional(String.t()) => integer()},
          system_tasks: SystemTasks.t(),
          poll_data: %{optional({String.t(), String.t()}) => integer()},
          in_progress: %{optional(String.t()) => non_neg_integer()},
          queued: MapSet.t(String.t()),
          workflows: %{optional(String.t()) => Workflow.t() | nil},
          workflow_offset_timeout_ms: non_neg_integer(),
          max_postpone_ms: non_neg_integer(),
          active_worker_last_poll_ms: non_neg_integer(),
          task_execution_postpone_ms: non_neg_integer(),
          system_task_callback_seconds: non_neg_integer(),
          system_task_postpone_threshold: non_neg_integer(),
          max_decide_iterations: pos_integer()
        }

  @doc """
  Builds an env. `now` is required; `new_id`, `jitter`, `evaluate_script` and `system_tasks`
  default as in `Archon.Decider.Context.new/1`, the rest as the struct does.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts =
      opts
      |> Keyword.put_new(:new_id, &Context.uuid4/0)
      |> Keyword.put_new(:jitter, &Context.uniform_jitter/1)
      |> Keyword.put_new(:evaluate_script, &Script.evaluate/3)
      |> Keyword.put_new(:system_tasks, SystemTasks.default())

    struct!(__MODULE__, opts)
  end

  @doc "The Decider context for the env."
  @spec context(t()) :: Context.t()
  def context(%__MODULE__{} = env) do
    %Context{
      now: env.now,
      new_id: env.new_id,
      jitter: env.jitter,
      evaluate_script: env.evaluate_script,
      task_defs: env.task_defs,
      latest_workflow_versions: env.latest_workflow_versions,
      system_tasks: env.system_tasks
    }
  end
end
