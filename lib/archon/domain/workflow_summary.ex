# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/run/WorkflowSummary.java
# and common/src/main/java/com/netflix/conductor/common/metadata/workflow/WorkflowClassifier.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as an Elixir struct built from Archon.Domain.Workflow, with an
# encoder that writes upstream's JSON key order (ADR 0027).

defmodule Archon.Domain.WorkflowSummary do
  @moduledoc """
  The search index's view of a workflow (`GET /api/workflow/search`, the `json_data` of
  `workflow_index`; ADR 0027, decision 3).

  `new/1` is upstream's `new WorkflowSummary(workflow)` on the REST `Workflow`. `encode/1` writes
  the JSON both the index and the search response use, in upstream's Jackson order (declared
  fields, then the `inputSize`/`outputSize` getters) without `null` fields (`NON_NULL`).

  `startTime` and `updateTime` are always written, the epoch when unset: upstream's getters
  give 0 for a `null` time.

  Differences from upstream, all in ADR 0027:

    * `input`/`output` are `Map#toString` with sorted keys, `taskToDomain` is written with sorted
      keys, and `failedTaskNames` and the comma-joined `failedReferenceTaskNames` are sorted;
      upstream keeps the input order and the `HashMap`/`HashSet` order.
    * Upstream throws without a workflow definition; here `workflowType` is left out and
      `version` is 0.
  """

  alias Archon.Domain.{Codec, SummaryUtil, Workflow, WorkflowDef}

  defstruct workflow_type: nil,
            version: 0,
            workflow_id: nil,
            correlation_id: nil,
            start_time: nil,
            update_time: nil,
            end_time: nil,
            status: nil,
            input: nil,
            output: nil,
            reason_for_incompletion: nil,
            execution_time: 0,
            event: nil,
            failed_reference_task_names: "",
            external_input_payload_storage_path: nil,
            external_output_payload_storage_path: nil,
            priority: 0,
            failed_task_names: [],
            created_by: nil,
            task_to_domain: %{},
            idempotency_key: nil,
            parent_workflow_id: "",
            classifier: nil

  @type t :: %__MODULE__{
          workflow_type: String.t() | nil,
          version: integer(),
          workflow_id: String.t() | nil,
          correlation_id: String.t() | nil,
          start_time: String.t() | nil,
          update_time: String.t() | nil,
          end_time: String.t() | nil,
          status: Workflow.status() | nil,
          input: String.t() | nil,
          output: String.t() | nil,
          reason_for_incompletion: String.t() | nil,
          execution_time: integer(),
          event: String.t() | nil,
          failed_reference_task_names: String.t(),
          external_input_payload_storage_path: String.t() | nil,
          external_output_payload_storage_path: String.t() | nil,
          priority: integer(),
          failed_task_names: [String.t() | nil] | nil,
          created_by: String.t() | nil,
          task_to_domain: %{optional(String.t()) => String.t() | nil} | nil,
          idempotency_key: String.t() | nil,
          parent_workflow_id: String.t(),
          classifier: String.t() | nil
        }

  @doc "Upstream `new WorkflowSummary(workflow)`."
  @spec new(Workflow.t()) :: t()
  def new(%Workflow{} = workflow) do
    {type, version} = name_and_version(workflow.workflow_definition)
    ended? = workflow.end_time > 0

    %__MODULE__{
      workflow_type: type,
      version: version,
      workflow_id: workflow.workflow_id,
      priority: workflow.priority,
      correlation_id: workflow.correlation_id,
      idempotency_key: workflow.idempotency_key,
      start_time: SummaryUtil.format_time(workflow.create_time),
      end_time: if(ended?, do: SummaryUtil.format_time(workflow.end_time)),
      update_time: SummaryUtil.format_time(workflow.update_time),
      status: workflow.status,
      input: SummaryUtil.serialize_input_output(workflow.input),
      output: SummaryUtil.serialize_input_output(workflow.output),
      reason_for_incompletion: workflow.reason_for_incompletion,
      execution_time: if(ended?, do: workflow.end_time - workflow.create_time, else: 0),
      event: workflow.event,
      failed_reference_task_names: joined(workflow.failed_reference_task_names),
      failed_task_names: workflow.failed_task_names && Enum.sort(workflow.failed_task_names),
      external_input_payload_storage_path: present(workflow.external_input_payload_storage_path),
      external_output_payload_storage_path:
        present(workflow.external_output_payload_storage_path),
      task_to_domain: workflow.task_to_domain || %{},
      created_by: workflow.created_by,
      parent_workflow_id: workflow.parent_workflow_id || "",
      classifier: classifier_of(workflow.workflow_definition)
    }
  end

  @doc """
  Upstream `WorkflowClassifier.classifierOf(def)`: a non-blank string `metadata.classifier`,
  else `"agent"` when `metadata.agent_sdk` or `metadata.agentDef` is non-null, else `"workflow"`.
  """
  @spec classifier_of(WorkflowDef.t() | nil) :: String.t()
  def classifier_of(%WorkflowDef{metadata: metadata}) when is_map(metadata) do
    case metadata do
      %{"classifier" => explicit} when is_binary(explicit) ->
        if SummaryUtil.blank?(explicit), do: agent_or_workflow(metadata), else: explicit

      _other ->
        agent_or_workflow(metadata)
    end
  end

  def classifier_of(_definition), do: "workflow"

  @doc """
  The summary's JSON text, shared by the index's `json_data` and the search response. Keys are
  in upstream's order and `nil` fields are left out.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = s) do
    [
      {"workflowType", s.workflow_type},
      {"version", s.version},
      {"workflowId", s.workflow_id},
      {"correlationId", s.correlation_id},
      {"startTime", s.start_time},
      {"updateTime", s.update_time},
      {"endTime", s.end_time},
      {"status", s.status && Codec.enum_name(s.status)},
      {"input", s.input},
      {"output", s.output},
      {"reasonForIncompletion", s.reason_for_incompletion},
      {"executionTime", s.execution_time},
      {"event", s.event},
      {"failedReferenceTaskNames", s.failed_reference_task_names},
      {"externalInputPayloadStoragePath", s.external_input_payload_storage_path},
      {"externalOutputPayloadStoragePath", s.external_output_payload_storage_path},
      {"priority", s.priority},
      {"failedTaskNames", s.failed_task_names},
      {"createdBy", s.created_by},
      {"taskToDomain", s.task_to_domain && sorted_object(s.task_to_domain)},
      {"idempotencyKey", s.idempotency_key},
      {"parentWorkflowId", s.parent_workflow_id},
      {"classifier", s.classifier},
      {"inputSize", size(s.input)},
      {"outputSize", size(s.output)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  defp agent_or_workflow(metadata) do
    if Map.get(metadata, "agent_sdk") != nil or Map.get(metadata, "agentDef") != nil,
      do: "agent",
      else: "workflow"
  end

  defp sorted_object(map), do: map |> Enum.sort() |> Jason.OrderedObject.new()

  defp name_and_version(%WorkflowDef{name: name, version: version}), do: {name, version}
  defp name_and_version(nil), do: {nil, 0}

  # Collectors.joining(",") over the set, with a null element as "null".
  defp joined(names), do: (names || []) |> Enum.sort() |> Enum.map_join(",", &(&1 || "null"))

  # StringUtils.isNotBlank
  defp present(nil), do: nil
  defp present(path), do: if(SummaryUtil.blank?(path), do: nil, else: path)

  defp size(nil), do: 0
  defp size(text), do: SummaryUtil.utf16_length(text)
end
