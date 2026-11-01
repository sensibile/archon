# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/service/MetadataService.java
# and MetadataServiceImpl.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the MVP operations only; the interface's method validation is done here,
# results are tagged tuples instead of exceptions, and definitions whose schemas cannot be checked
# are refused (ADR 0023, decisions 2 and 5).

defmodule Archon.Metadata do
  @moduledoc """
  The definition service (upstream `MetadataService`, ADR 0023 decision 2): what
  `ArchonWeb.MetadataController` calls to register and read definitions, on the store that
  `Archon.Runtime.metadata/0` configures.

  Each operation first does the method validation upstream's interface annotations ask for
  (`@NotNull`, `@Size(min = 1)`, `@Valid`): a failure is `{:error, {:invalid, errors}}` with
  `{path, message}` errors relative to the argument (`"[0].name"` for a list), which the caller
  writes with its upstream method and argument prefix (`ArchonWeb.Errors`). Then come the service
  checks, in upstream's order. A definition that enforces a schema Archon cannot check
  (`Archon.Domain.WorkflowDef.check_schema/1`, `Archon.Domain.TaskDef.check_schema/1`, embedded
  definitions included) is refused with `{:error, {:invalid, message}}` before it is stored.

  Audit fields follow `MetadataServiceImpl`: a registered task definition gets `createdBy` (the
  client app, `""` without one) and `createTime` and loses `updatedBy` and `updateTime`; an
  updated one gets `updatedBy` and `updateTime` and keeps the stored `createTime` and
  `createdBy`. A registered workflow definition gets `createTime`, an updated one `updateTime`;
  the other audit fields stay as given.
  """

  require Logger

  alias Archon.Domain.{BulkResponse, TaskDef, Validation, WorkflowDef}
  alias Archon.Runtime

  # WorkflowContext's client app; the server without one has "".
  @client_app ""

  @type error ::
          {:invalid, [{String.t(), String.t()}] | String.t()}
          | {:not_found, String.t()}
          | {:conflict, String.t()}
          | {:server_error, String.t()}

  ## Task definitions

  @doc """
  Upstream `registerTaskDef(List<TaskDef>)`: stores each definition in order.

  The list must not be empty and every definition must be valid, or nothing is stored. A `nil`
  element passes validation (upstream's `@Valid` skips it) and fails when its turn comes, after
  the ones before it are stored, with upstream's `NullPointerException` message (a 500).
  """
  @spec register_task_defs([TaskDef.t() | nil]) :: :ok | {:error, error()}
  def register_task_defs(task_defs) when is_list(task_defs) do
    with :ok <- validate_list(task_defs, "TaskDefList is empty", &task_def_element/1),
         :ok <- check_each(task_defs, &TaskDef.check_schema/1) do
      Enum.reduce_while(task_defs, :ok, fn
        nil, :ok ->
          {:halt,
           {:error,
            {:server_error,
             ~s|Cannot invoke "com.netflix.conductor.common.metadata.tasks.TaskDef.setCreatedBy(String)" | <>
               ~s|because "taskDefinition" is null|}}}

        task_def, :ok ->
          :ok =
            metadata().create_task_def(%{
              task_def
              | created_by: @client_app,
                create_time: Runtime.now(),
                updated_by: nil,
                # Auditable#getUpdateTime writes a null as 0.
                update_time: 0
            })

          {:cont, :ok}
      end)
    end
  end

  # @Valid skips a null element.
  defp task_def_element(nil), do: :ok
  defp task_def_element(task_def), do: TaskDef.validate(task_def)

  @doc """
  Upstream `updateTaskDef`: replaces a stored definition, keeping its `createTime` and
  `createdBy`. A name that is not stored is `{:error, {:not_found, "No such task by name <name>"}}`.
  """
  @spec update_task_def(TaskDef.t()) :: :ok | {:error, error()}
  def update_task_def(%TaskDef{} = task_def) do
    with :ok <- validate(task_def, &TaskDef.validate/1),
         {:ok, existing} <- existing_task_def(task_def.name),
         :ok <- TaskDef.check_schema(task_def) do
      metadata().update_task_def(%{
        task_def
        | updated_by: @client_app,
          update_time: Runtime.now(),
          create_time: existing.create_time,
          created_by: existing.created_by
      })
    end
  end

  defp existing_task_def(name) do
    case metadata().get_task_def(name) do
      {:ok, existing} -> {:ok, existing}
      {:error, :not_found} -> {:error, {:not_found, "No such task by name #{name}"}}
    end
  end

  @doc "Upstream `getTaskDef`: `{:error, {:not_found, message}}` when the name is not stored."
  @spec get_task_def(String.t()) :: {:ok, TaskDef.t()} | {:error, {:not_found, String.t()}}
  def get_task_def(name) when is_binary(name) do
    case metadata().get_task_def(name) do
      {:ok, task_def} -> {:ok, task_def}
      {:error, :not_found} -> {:error, {:not_found, "No such taskType found by name: #{name}"}}
    end
  end

  @doc "Upstream `getTaskDefs`: every task definition (ordered by name, see `Archon.Runtime.Metadata`)."
  @spec get_task_defs() :: [TaskDef.t()]
  def get_task_defs, do: metadata().get_all_task_defs()

  ## Workflow definitions

  @doc """
  Upstream `registerWorkflowDef`: adds the definition with its `createTime`;
  `{:error, {:conflict, "Workflow with <name>.<version> already exists!"}}` if that name and
  version are stored.
  """
  @spec register_workflow_def(WorkflowDef.t()) :: :ok | {:error, error()}
  def register_workflow_def(%WorkflowDef{} = definition) do
    with :ok <- validate(definition, &WorkflowDef.validate/1),
         :ok <- WorkflowDef.check_schema(definition) do
      case metadata().create_workflow_def(%{definition | create_time: Runtime.now()}) do
        :ok ->
          :ok

        {:error, :conflict} ->
          {:error,
           {:conflict,
            "Workflow with #{WorkflowDef.key(definition.name, definition.version)} already exists!"}}
      end
    end
  end

  @doc "Upstream `updateWorkflowDef(WorkflowDef)`: inserts or replaces it with its `updateTime`."
  @spec update_workflow_def(WorkflowDef.t()) :: :ok | {:error, error()}
  def update_workflow_def(%WorkflowDef{} = definition) do
    with :ok <- validate(definition, &WorkflowDef.validate/1),
         :ok <- WorkflowDef.check_schema(definition) do
      store_workflow_def(definition)
    end
  end

  @doc """
  Upstream `updateWorkflowDef(List<WorkflowDef>)`. The list must not be empty and hold no `nil`,
  and every definition must be valid, or the whole request fails. Then each definition is stored
  in order; one that fails at this stage (its schema is refused, or the store raises) is a
  failure in the `BulkResponse` under its name, and the others are still stored.
  """
  @spec update_workflow_defs([WorkflowDef.t() | nil]) ::
          {:ok, BulkResponse.t()} | {:error, error()}
  def update_workflow_defs(definitions) when is_list(definitions) do
    with :ok <- validate_list(definitions, "WorkflowDefList is empty", &workflow_def_element/1) do
      {:ok, Enum.reduce(definitions, %BulkResponse{}, &bulk_update/2)}
    end
  end

  # @NotNull(message = "WorkflowDef cannot be null") on the list's element type.
  defp workflow_def_element(nil),
    do: {:error, [{"<list element>", "WorkflowDef cannot be null"}]}

  defp workflow_def_element(definition), do: WorkflowDef.validate(definition)

  defp bulk_update(definition, response) do
    case WorkflowDef.check_schema(definition) do
      :ok ->
        :ok = store_workflow_def(definition)
        BulkResponse.success(response, definition.name)

      {:error, {:invalid, message}} ->
        BulkResponse.failure(response, definition.name, message)
    end
  rescue
    # Upstream catches any exception of one definition; its message would show Elixir terms.
    exception ->
      Logger.error(
        "bulk update workflow def failed, name #{inspect(definition.name)}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      BulkResponse.failure(response, definition.name, "Internal server error")
  catch
    # A store call that timed out or found its server down.
    :exit, reason ->
      Logger.error(
        "bulk update workflow def failed, name #{inspect(definition.name)}: " <>
          Exception.format_exit(reason)
      )

      BulkResponse.failure(response, definition.name, "Internal server error")
  end

  defp store_workflow_def(definition),
    do: metadata().update_workflow_def(%{definition | update_time: Runtime.now()})

  @doc """
  Upstream `getWorkflowDef`: the version asked for, or the latest with `nil`;
  `{:error, {:not_found, "No such workflow found by name: <name>, version: <version>"}}` when it
  is not stored (`null` for a missing version, as Java's `%d` writes it).
  """
  @spec get_workflow_def(String.t(), integer() | nil) ::
          {:ok, WorkflowDef.t()} | {:error, {:not_found, String.t()}}
  def get_workflow_def(name, version) when is_binary(name) do
    case find_workflow_def(name, version) do
      {:ok, definition} ->
        {:ok, definition}

      {:error, :not_found} ->
        {:error,
         {:not_found, "No such workflow found by name: #{name}, version: #{version || "null"}"}}
    end
  end

  @doc """
  Upstream `findWorkflowDef` (and `getLatestWorkflow` for a `nil` version), without a message:
  `{:error, :not_found}`.
  """
  @spec find_workflow_def(String.t(), integer() | nil) ::
          {:ok, WorkflowDef.t()} | {:error, :not_found}
  def find_workflow_def(name, nil) when is_binary(name),
    do: metadata().get_latest_workflow_def(name)

  def find_workflow_def(name, version) when is_binary(name) and is_integer(version),
    do: metadata().get_workflow_def(name, version)

  ## Validation

  defp validate(value, validate) do
    case validate.(value) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid, errors}}
    end
  end

  # @NotNull @Size(min = 1) on the list, the element check on each element.
  defp validate_list([], empty_message, _validate),
    do: {:error, {:invalid, [{"", empty_message}]}}

  defp validate_list(values, _empty_message, validate) do
    errors =
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, index} ->
        case validate.(value) do
          :ok -> []
          {:error, errors} -> Validation.nest(errors, "[#{index}]")
        end
      end)

    case errors do
      [] -> :ok
      errors -> {:error, {:invalid, errors}}
    end
  end

  defp check_each(values, check) do
    Enum.find_value(values, :ok, fn
      nil ->
        nil

      value ->
        case check.(value) do
          :ok -> nil
          error -> error
        end
    end)
  end

  defp metadata, do: Runtime.metadata()
end
