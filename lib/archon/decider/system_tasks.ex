# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/SystemTaskRegistry.java,
# core/.../execution/tasks/WorkflowSystemTask.java and core/.../execution/tasks/SubWorkflow.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the registry became a map from task type to its isAsyncComplete rule;
# only the Archon MVP system tasks are registered by default.

defmodule Archon.Decider.SystemTasks do
  @moduledoc """
  The system task registry as the Decider sees it: which task types are system tasks and how
  each answers upstream `WorkflowSystemTask#isAsyncComplete`.

  A rule is `:by_task` (upstream's default: the task's `asyncComplete` input when that key is
  present, else `workflowTask.asyncComplete`) or a fixed boolean (`SubWorkflow` always answers
  `true`).

  `default/0` registers the system tasks of the Archon MVP (ADR 0014, decision 5): `DECISION`,
  `SWITCH`, `FORK`, `JOIN`, `DO_WHILE`, `SUB_WORKFLOW` and `WAIT`. `FORK` is the type of the task
  the `FORK_JOIN` mapper schedules.
  """

  alias Archon.Domain.{Task, WorkflowTask}

  @type rule :: :by_task | boolean()
  @type t :: %{optional(String.t()) => rule()}

  @doc "The Archon MVP registry."
  @spec default() :: t()
  def default do
    %{
      "DECISION" => :by_task,
      "SWITCH" => :by_task,
      "FORK" => :by_task,
      "JOIN" => :by_task,
      "DO_WHILE" => :by_task,
      "SUB_WORKFLOW" => true,
      "WAIT" => :by_task
    }
  end

  @doc "Upstream `SystemTaskRegistry#isSystemTask`."
  @spec system_task?(t(), String.t() | nil) :: boolean()
  def system_task?(registry, type), do: is_map_key(registry, type)

  @doc """
  Upstream `DeciderService#isAyncCompleteSystemTask`: a registered system task whose
  `isAsyncComplete` answers `true`.
  """
  @spec async_complete?(t(), Task.t()) :: boolean()
  def async_complete?(registry, %Task{task_type: type} = task) do
    case Map.get(registry, type) do
      nil -> false
      :by_task -> by_task(task)
      fixed -> fixed
    end
  end

  defp by_task(%Task{input_data: %{"asyncComplete" => value}}), do: value == true

  defp by_task(%Task{workflow_task: %WorkflowTask{async_complete: value}}), do: value == true
  defp by_task(%Task{}), do: false
end
