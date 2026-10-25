# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/tasks/TaskDef.java,
# common/.../metadata/Auditable.java and common/.../constraints/TaskTimeoutConstraint.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; bean validation
# annotations ported to validate/2.

defmodule Archon.Domain.TaskDef do
  @moduledoc """
  Task definition: retry, timeout and rate-limit policy for a task name
  (`POST /api/metadata/taskdefs`, `WorkflowTask.taskDefinition`).

  Fields follow upstream `TaskDef` rather than `priv/contract/TaskDef.json`: the server also
  writes `runtimeMetadata`, `maxRetryDelaySeconds`, `backoffJitterMs` and
  `taskStatusListenerEnabled`, which the schema omits.
  """

  alias Archon.Domain.{Codec, SchemaDef, Validation}

  @type timeout_policy :: :retry | :time_out_wf | :alert_only
  @type retry_logic :: :fixed | :exponential_backoff | :linear_backoff

  @fields [
    {:owner_app, "ownerApp", :string, []},
    {:create_time, "createTime", :int, []},
    {:update_time, "updateTime", :int, []},
    {:created_by, "createdBy", :string, []},
    {:updated_by, "updatedBy", :string, []},
    {:name, "name", :string, []},
    {:description, "description", :string, []},
    {:retry_count, "retryCount", :int, default: 3},
    {:timeout_seconds, "timeoutSeconds", :int, []},
    {:input_keys, "inputKeys", {:list, :string}, default: []},
    {:output_keys, "outputKeys", {:list, :string}, default: []},
    {:runtime_metadata, "runtimeMetadata", {:list, :string}, default: []},
    {:timeout_policy, "timeoutPolicy", {:enum, [:retry, :time_out_wf, :alert_only]},
     default: :time_out_wf},
    {:retry_logic, "retryLogic", {:enum, [:fixed, :exponential_backoff, :linear_backoff]},
     default: :fixed},
    {:retry_delay_seconds, "retryDelaySeconds", :int, default: 60},
    {:response_timeout_seconds, "responseTimeoutSeconds", :int, default: 3600},
    {:concurrent_exec_limit, "concurrentExecLimit", :integer, []},
    {:input_template, "inputTemplate", :object, default: %{}},
    # getRateLimitPerFrequency/getRateLimitFrequencyInSeconds substitute 0 and 1 for null.
    {:rate_limit_per_frequency, "rateLimitPerFrequency", :int, []},
    {:rate_limit_frequency_in_seconds, "rateLimitFrequencyInSeconds", :int, default: 1, null: 1},
    {:isolation_group_id, "isolationGroupId", :string, []},
    {:execution_name_space, "executionNameSpace", :string, []},
    {:owner_email, "ownerEmail", :string, []},
    {:poll_timeout_seconds, "pollTimeoutSeconds", :integer, []},
    {:backoff_scale_factor, "backoffScaleFactor", :integer, default: 1},
    {:max_retry_delay_seconds, "maxRetryDelaySeconds", :int, []},
    {:backoff_jitter_ms, "backoffJitterMs", :int, []},
    {:base_type, "baseType", :string, []},
    {:total_timeout_seconds, "totalTimeoutSeconds", :int, []},
    {:task_status_listener_enabled, "taskStatusListenerEnabled", :bool, default: true},
    {:input_schema, "inputSchema", {:struct, SchemaDef}, []},
    {:output_schema, "outputSchema", {:struct, SchemaDef}, []},
    {:enforce_schema, "enforceSchema", :bool, []}
  ]

  defstruct Codec.defaults(@fields)

  @type t :: %__MODULE__{
          owner_app: String.t() | nil,
          create_time: integer(),
          update_time: integer(),
          created_by: String.t() | nil,
          updated_by: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          retry_count: integer(),
          timeout_seconds: integer(),
          input_keys: [String.t() | nil] | nil,
          output_keys: [String.t() | nil] | nil,
          runtime_metadata: [String.t() | nil] | nil,
          timeout_policy: timeout_policy() | nil,
          retry_logic: retry_logic() | nil,
          retry_delay_seconds: integer(),
          response_timeout_seconds: integer(),
          concurrent_exec_limit: integer() | nil,
          input_template: Codec.json_object() | nil,
          rate_limit_per_frequency: integer(),
          rate_limit_frequency_in_seconds: integer(),
          isolation_group_id: String.t() | nil,
          execution_name_space: String.t() | nil,
          owner_email: String.t() | nil,
          poll_timeout_seconds: integer() | nil,
          backoff_scale_factor: integer() | nil,
          max_retry_delay_seconds: integer(),
          backoff_jitter_ms: integer(),
          base_type: String.t() | nil,
          total_timeout_seconds: integer(),
          task_status_listener_enabled: boolean(),
          input_schema: SchemaDef.t() | nil,
          output_schema: SchemaDef.t() | nil,
          enforce_schema: boolean()
        }

  @doc "Decodes upstream JSON."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = task_def), do: Codec.encode(__MODULE__, @fields, task_def)

  @doc """
  Upstream `TaskDef#concurrencyLimit`: the concurrent execution limit, 0 meaning unlimited.
  """
  @spec concurrency_limit(t()) :: integer()
  def concurrency_limit(%__MODULE__{concurrent_exec_limit: nil}), do: 0
  def concurrency_limit(%__MODULE__{concurrent_exec_limit: limit}), do: limit

  @doc """
  Bean validation of a task definition. See `Archon.Domain.Validation` for `opts`.

  Ports the field annotations of `TaskDef` plus the class-level `@TaskTimeoutConstraint`.
  """
  @spec validate(t(), Validation.opts()) :: Validation.result()
  def validate(%__MODULE__{} = d, opts \\ []) do
    Validation.result(
      Validation.not_empty("name", d.name, "TaskDef name cannot be null or empty") ++
        Validation.min("retryCount", d.retry_count, 0, "TaskDef retryCount: 0 must be >= 0") ++
        Validation.min(
          "responseTimeoutSeconds",
          d.response_timeout_seconds,
          1,
          "TaskDef responseTimeoutSeconds: #{d.response_timeout_seconds} should be minimum 1 second"
        ) ++
        Validation.owner_email(d.owner_email, opts) ++
        Validation.min(
          "pollTimeoutSeconds",
          d.poll_timeout_seconds,
          0,
          "TaskDef pollTimeoutSeconds: 0 must be >= 0"
        ) ++
        Validation.min(
          "backoffScaleFactor",
          d.backoff_scale_factor,
          1,
          "Backoff scale factor. Applicable for LINEAR_BACKOFF"
        ) ++
        Validation.min(
          "maxRetryDelaySeconds",
          d.max_retry_delay_seconds,
          0,
          "TaskDef maxRetryDelaySeconds: 0 must be >= 0"
        ) ++
        Validation.min(
          "backoffJitterMs",
          d.backoff_jitter_ms,
          0,
          "TaskDef backoffJitterMs: 0 must be >= 0"
        ) ++
        Validation.min(
          "totalTimeoutSeconds",
          d.total_timeout_seconds,
          0,
          "TaskDef totalTimeoutSeconds: 0 must be >= 0"
        ) ++ timeout_errors(d)
    )
  end

  # @TaskTimeoutConstraint. Hibernate reports class-level violations on the bean itself, so the
  # path is empty.
  defp timeout_errors(%__MODULE__{timeout_seconds: timeout} = d) when timeout > 0 do
    response =
      if d.response_timeout_seconds > timeout do
        [
          {"",
           "TaskDef: #{d.name} responseTimeoutSeconds: #{d.response_timeout_seconds} " <>
             "must be less than timeoutSeconds: #{timeout}"}
        ]
      else
        []
      end

    total =
      if d.total_timeout_seconds > 0 and timeout > d.total_timeout_seconds do
        [
          {"",
           "TaskDef: #{d.name} timeoutSeconds: #{timeout} must be less than or equal to " <>
             "totalTimeoutSeconds: #{d.total_timeout_seconds}"}
        ]
      else
        []
      end

    response ++ total
  end

  defp timeout_errors(_task_def), do: []
end
