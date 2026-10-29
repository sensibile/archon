# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/SubWorkflowTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour; the
# MetadataDAO lookup of the latest version reads the Decider context.

defmodule Archon.Decider.Mapper.SubWorkflow do
  @moduledoc """
  Upstream `SubWorkflowTaskMapper`: one `SCHEDULED` `SUB_WORKFLOW` task whose input says which
  workflow the runtime starts (Phase 3).

  The `subWorkflowParam` fields are resolved like task inputs. A `workflowDefinition` expression
  is resolved with them; an inline definition is added afterwards, so its own `${...}` strings
  stay as they are. Without an inline definition and a version, the version is the latest one
  in the context's `latest_workflow_versions` (upstream `MetadataDAO.getLatestWorkflowDef`),
  and the workflow terminates when there is none. A name that resolves to `null` also
  terminates it, where upstream throws a `NullPointerException` (ADR 0014).
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.Mapper.Context
  alias Archon.Decider.Parameters
  alias Archon.Domain.{SubWorkflowParams, WorkflowDef, WorkflowTask}

  @impl true
  def map(%WorkflowTask{sub_workflow_param: nil} = wt, %Context{}) do
    {:terminate,
     "Task #{Parameters.java_string(wt.name)} is defined as sub-workflow and is missing subWorkflowParams. " <>
       "Please check the workflow definition"}
  end

  def map(
        %WorkflowTask{sub_workflow_param: %SubWorkflowParams{} = params} = wt,
        %Context{} = context
      ) do
    resolved = resolve(params, context)
    definition = resolved["workflowDefinition"]

    with {:ok, name} <- name(resolved, wt),
         {:ok, version} <- version(resolved, definition, name, context) do
      task = Context.create_task(context)

      {:ok,
       [
         %{
           task
           | task_type: "SUB_WORKFLOW",
             input_data: %{
               "subWorkflowName" => name,
               "priority" => resolved["priority"],
               "subWorkflowVersion" => version,
               "subWorkflowTaskToDomain" => task_to_domain(resolved["taskToDomain"]),
               "subWorkflowDefinition" => definition,
               "idempotencyKey" => resolved["idempotencyKey"],
               "idempotencyStrategy" => resolved["idempotencyStrategy"],
               "workflowInput" => context.task_input
             },
             status: :scheduled,
             callback_after_seconds: wt.start_delay,
             workflow_priority: priority(params.priority, task.workflow_priority)
         }
       ]}
    end
  end

  # getSubWorkflowInputParameters
  defp resolve(%SubWorkflowParams{} = params, context) do
    unresolved =
      %{"name" => SubWorkflowParams.name(params), "priority" => params.priority}
      |> put_present("version", params.version)
      |> put_present("taskToDomain", params.task_to_domain)
      |> put_present("idempotencyKey", params.idempotency_key)
      |> put_present("idempotencyStrategy", strategy(params.idempotency_strategy))

    case params.workflow_definition do
      expression when is_binary(expression) ->
        unresolved |> Map.put("workflowDefinition", expression) |> task_input(context)

      %WorkflowDef{} = definition ->
        unresolved
        |> task_input(context)
        |> Map.put("workflowDefinition", WorkflowDef.to_json(definition))

      nil ->
        task_input(unresolved, context)
    end
  end

  defp task_input(input, context), do: Parameters.task_input(input, context.workflow, nil, nil)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp strategy(nil), do: nil
  defp strategy(strategy), do: strategy |> Atom.to_string() |> String.upcase()

  defp name(%{"name" => nil}, wt) do
    {:terminate,
     "Task #{Parameters.java_string(wt.name)} is defined as sub-workflow and its subWorkflowParams name resolved to null"}
  end

  defp name(%{"name" => name}, _wt), do: {:ok, Parameters.java_string(name)}

  # Only looked up without an inline definition, which the runtime starts as it is.
  defp version(_resolved, definition, _name, _context) when not is_nil(definition),
    do: {:ok, nil}

  defp version(%{"version" => version}, nil, _name, _context) when is_number(version),
    do: {:ok, trunc(version)}

  defp version(_resolved, nil, name, context) do
    case Map.fetch(context.decider.latest_workflow_versions, name) do
      {:ok, version} ->
        {:ok, version}

      :error ->
        {:terminate,
         "The Task #{name} defined as a sub-workflow has no workflow definition available "}
    end
  end

  defp task_to_domain(map) when is_map(map), do: map
  defp task_to_domain(_other), do: nil

  # Upstream reads the unresolved priority: only a number overrides the workflow's priority.
  defp priority(priority, _default) when is_number(priority), do: trunc(priority)
  defp priority(_priority, default), do: default
end
