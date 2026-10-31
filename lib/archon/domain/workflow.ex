# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/run/Workflow.java
# common/.../metadata/Auditable.java and core/src/main/java/com/netflix/conductor/model/WorkflowModel.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct with a JSON codec; derived getters
# became functions; bean validation annotations ported to validate/1.

defmodule Archon.Domain.Workflow do
  @moduledoc """
  Execution state of a workflow instance (`GET /api/workflow/{workflowId}`).

  Upstream getters add derived keys on the wire, reproduced by `to_json/1`: `startTime` (an
  alias of `createTime`; decoding accepts it when `createTime` is absent), and `workflowName` /
  `workflowVersion` from the embedded definition. Upstream throws when serializing those two
  without a definition; `to_json/1` omits them instead.

  `failedReferenceTaskNames` and `failedTaskNames` are Java `Set`s: decoding drops duplicates
  and their order carries no meaning.

  `previous_status` and `failed_task_id` are internal execution state from upstream's
  `WorkflowModel` (ADR 0014). `end_count` (how many times the workflow went from a non-terminal
  to a terminal status) and `revived_parent_end_count` (the parent's `end_count` read when this
  terminal child was retried or restarted, 0 if none) are Archon's own internal state that orders
  a child's revival after its parent's end (ADR 0021, decision 10, L2). None of them is part of
  the wire JSON; `to_storage/1` keeps them.
  """

  alias Archon.Domain.{AggregateTokenUsage, Codec, Task, Validation, WorkflowDef}

  @type status :: :running | :completed | :failed | :timed_out | :terminated | :paused

  @statuses [:running, :completed, :failed, :timed_out, :terminated, :paused]

  @fields [
    {:owner_app, "ownerApp", :string, []},
    {:create_time, "createTime", :int, []},
    {:update_time, "updateTime", :int, []},
    {:created_by, "createdBy", :string, []},
    {:updated_by, "updatedBy", :string, []},
    {:status, "status", {:enum, @statuses}, default: :running},
    {:end_time, "endTime", :int, []},
    {:workflow_id, "workflowId", :string, []},
    {:parent_workflow_id, "parentWorkflowId", :string, []},
    {:parent_workflow_task_id, "parentWorkflowTaskId", :string, []},
    {:tasks, "tasks", {:list, {:struct, Task}}, default: []},
    {:input, "input", :object, default: %{}, null: :default},
    {:output, "output", :object, default: %{}, null: :default},
    {:correlation_id, "correlationId", :string, []},
    {:re_run_from_workflow_id, "reRunFromWorkflowId", :string, []},
    {:reason_for_incompletion, "reasonForIncompletion", :string, []},
    {:event, "event", :string, []},
    {:task_to_domain, "taskToDomain", :string_map, default: %{}},
    {:failed_reference_task_names, "failedReferenceTaskNames", {:list, :string}, default: []},
    {:workflow_definition, "workflowDefinition", {:struct, WorkflowDef}, []},
    {:external_input_payload_storage_path, "externalInputPayloadStoragePath", :string, []},
    {:external_output_payload_storage_path, "externalOutputPayloadStoragePath", :string, []},
    {:priority, "priority", :int, []},
    {:variables, "variables", :object, default: %{}},
    {:last_retried_time, "lastRetriedTime", :int, []},
    {:failed_task_names, "failedTaskNames", {:list, :string}, default: []},
    {:history, "history", {:list, {:struct, __MODULE__}}, default: []},
    {:idempotency_key, "idempotencyKey", :string, []},
    {:rate_limit_key, "rateLimitKey", :string, []},
    {:rate_limited, "rateLimited", :bool, []},
    {:aggregate_token_usage, "aggregateTokenUsage", {:struct, AggregateTokenUsage}, []},
    {:previous_status, "previousStatus", {:enum, @statuses}, wire: false},
    {:failed_task_id, "failedTaskId", :string, wire: false},
    {:end_count, "endCount", :int, wire: false},
    {:revived_parent_end_count, "revivedParentEndCount", :int, wire: false}
  ]

  defstruct Codec.defaults(@fields)

  @doc false
  @spec __fields__() :: [Codec.field()]
  def __fields__, do: @fields

  @type t :: %__MODULE__{
          owner_app: String.t() | nil,
          create_time: integer(),
          update_time: integer(),
          created_by: String.t() | nil,
          updated_by: String.t() | nil,
          status: status() | nil,
          end_time: integer(),
          workflow_id: String.t() | nil,
          parent_workflow_id: String.t() | nil,
          parent_workflow_task_id: String.t() | nil,
          tasks: [Task.t() | nil] | nil,
          input: Codec.json_object(),
          output: Codec.json_object(),
          correlation_id: String.t() | nil,
          re_run_from_workflow_id: String.t() | nil,
          reason_for_incompletion: String.t() | nil,
          event: String.t() | nil,
          task_to_domain: %{optional(String.t()) => String.t() | nil} | nil,
          failed_reference_task_names: [String.t() | nil] | nil,
          workflow_definition: WorkflowDef.t() | nil,
          external_input_payload_storage_path: String.t() | nil,
          external_output_payload_storage_path: String.t() | nil,
          priority: integer(),
          variables: Codec.json_object() | nil,
          last_retried_time: integer(),
          failed_task_names: [String.t() | nil] | nil,
          history: [t() | nil] | nil,
          idempotency_key: String.t() | nil,
          rate_limit_key: String.t() | nil,
          rate_limited: boolean(),
          aggregate_token_usage: AggregateTokenUsage.t() | nil,
          previous_status: status() | nil,
          failed_task_id: String.t() | nil,
          end_count: non_neg_integer(),
          revived_parent_end_count: non_neg_integer()
        }

  @doc "All workflow statuses, in upstream declaration order."
  @spec statuses() :: [status(), ...]
  def statuses, do: @statuses

  @doc "Upstream `WorkflowStatus#isTerminal`."
  @spec terminal?(status()) :: boolean()
  def terminal?(status) when status in [:running, :paused], do: false
  def terminal?(status) when status in @statuses, do: true

  @doc "Upstream `WorkflowStatus#isSuccessful`."
  @spec successful?(status()) :: boolean()
  def successful?(status) when status in [:completed, :paused], do: true
  def successful?(status) when status in @statuses, do: false

  @doc "Decodes upstream JSON. Derived keys other than `startTime` are ignored."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ [])

  def from_json(%{"startTime" => start} = json, path) when not is_map_key(json, "createTime"),
    do: from_json(json |> Map.delete("startTime") |> Map.put("createTime", start), path)

  def from_json(json, path) do
    with {:ok, workflow} <- Codec.decode(__MODULE__, @fields, json, path) do
      {:ok,
       %{
         workflow
         | failed_reference_task_names: uniq(workflow.failed_reference_task_names),
           failed_task_names: uniq(workflow.failed_task_names)
       }}
    end
  end

  @doc """
  Encodes to upstream JSON with the derived getter keys. `now_ms` is passed to
  `Archon.Domain.Task.to_json/2` for each task's `queueWaitTime`.
  """
  @spec to_json(t(), integer()) :: Codec.json_object()
  def to_json(%__MODULE__{} = workflow, now_ms \\ System.system_time(:millisecond)) do
    json =
      __MODULE__
      |> Codec.encode(@fields, %{workflow | tasks: nil, history: nil})
      |> Map.put("startTime", workflow.create_time)
      |> put_list("tasks", workflow.tasks, &Task.to_json(&1, now_ms))
      |> put_list("history", workflow.history, &to_json(&1, now_ms))

    case workflow.workflow_definition do
      %WorkflowDef{name: name, version: version} ->
        json |> Map.put("workflowName", name) |> Map.put("workflowVersion", version)

      nil ->
        json
    end
  end

  @doc """
  The storage encoding (ADR 0021, decision 2): every field, internal ones included, so that
  `from_storage/1` gives back the same struct. Not the wire shape; REST uses `to_json/1`.
  """
  @spec to_storage(t()) :: Codec.json_object()
  def to_storage(%__MODULE__{} = workflow),
    do: Codec.encode(__MODULE__, @fields, workflow, internal: true)

  @doc "Decodes `to_storage/1` output. Keys missing from older rows decode to the field default."
  @spec from_storage(Codec.json()) :: Codec.result(t())
  def from_storage(json), do: Codec.decode(__MODULE__, @fields, json, [], internal: true)

  @doc "Upstream `getWorkflowName`: the embedded definition's name."
  @spec workflow_name(t()) :: String.t() | nil
  def workflow_name(%__MODULE__{workflow_definition: %WorkflowDef{name: name}}), do: name
  def workflow_name(%__MODULE__{}), do: nil

  @doc "Upstream `getWorkflowVersion`: the embedded definition's version."
  @spec workflow_version(t()) :: integer() | nil
  def workflow_version(%__MODULE__{workflow_definition: %WorkflowDef{version: version}}),
    do: version

  def workflow_version(%__MODULE__{}), do: nil

  @doc "Bean validation: `priority` is `@Min(0) @Max(99)`."
  @spec validate(t()) :: Validation.result()
  def validate(%__MODULE__{priority: priority}) do
    Validation.result(
      Validation.min(
        "priority",
        priority,
        0,
        "workflow priority: #{priority} should be minimum 0"
      ) ++
        Validation.max(
          "priority",
          priority,
          99,
          "workflow priority: #{priority} should be maximum 99"
        )
    )
  end

  defp put_list(json, _key, nil, _fun), do: json

  defp put_list(json, key, list, fun) do
    Map.put(json, key, Enum.map(list, fn item -> if item, do: fun.(item) end))
  end

  defp uniq(nil), do: nil
  defp uniq(list), do: Enum.uniq(list)
end
