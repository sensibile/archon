# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/
# {TaskResource,WorkflowResource}.java (updateTask and updateTaskSync by reference,
# signalWorkflowTaskAsync, signalWorkflowTaskSync, executeWorkflow, markAsDynamicWorkflow) at
# commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: Phoenix actions; the synchronous answers wait in
# `ArchonWeb.SignalResponder`; Spring's conversion and JVM failure messages are written here.

defmodule ArchonWeb.SignalController do
  @moduledoc """
  Task updates by reference, signals and the synchronous start (upstream `TaskResource` and
  `WorkflowResource#executeWorkflow`, ADR 0025 decision 5) on `Archon.Runtime` and
  `Archon.Runtime.Tasks`.

  As in Spring, the handler arguments convert in their order (the path `status`, the queries,
  then the body), and a value that does not convert is a 500 with Spring's message. The
  `status` path value is a `TaskResult.Status` constant and the `returnStrategy` query a
  `WorkflowSignalReturnStrategy` constant, both after trimming; a blank `returnStrategy` is its
  default.

  The update by reference answers 200 without a body when no task is pending, and the signal
  when no task is blocked; their `/sync` variants answer 404. The synchronous signal and start
  wait in `ArchonWeb.SignalResponder` (100 ms polling).
  """

  use ArchonWeb, :controller

  alias Archon.Domain.{
    Codec,
    ErrorResponse,
    SignalResponse,
    StartWorkflowRequest,
    Validation,
    Workflow
  }

  alias Archon.Runtime
  alias Archon.Runtime.Tasks
  alias ArchonWeb.SignalResponder

  # Persisted and read back at run time, so the list may shrink to [] without a spec to change.
  Module.register_attribute(__MODULE__, :unimplemented, persist: true)

  @unimplemented []

  @task_resource "com.netflix.conductor.rest.controllers.TaskResource"
  @status_type "com.netflix.conductor.common.metadata.tasks.TaskResult$Status"
  @strategy_type "org.conductoross.conductor.model.WorkflowSignalReturnStrategy"
  @output_map "java.util.Map<java.lang.String, java.lang.Object>"
  @by_ref_args "(java.lang.String,java.lang.String,#{@status_type},java.lang.String,#{@output_map})"
  @update_handler "public java.lang.String #{@task_resource}.updateTask#{@by_ref_args}"
  @update_sync_handler "public com.netflix.conductor.common.run.Workflow " <>
                         "#{@task_resource}.updateTaskSync#{@by_ref_args}"
  @signal_handler "public void #{@task_resource}.signalWorkflowTaskAsync(" <>
                    "java.lang.String,#{@status_type},#{@output_map})"
  @mono "public reactor.core.publisher.Mono<org.conductoross.conductor.model.SignalResponse>"
  @signal_sync_handler "#{@mono} #{@task_resource}.signalWorkflowTaskSync(" <>
                         "java.lang.String,#{@status_type},#{@strategy_type},long,#{@output_map})"
  @execute_handler "#{@mono} com.netflix.conductor.rest.controllers.WorkflowResource." <>
                     "executeWorkflow(java.lang.String,java.lang.Integer,java.lang.String," <>
                     "java.lang.String,java.lang.Integer,java.lang.String,#{@strategy_type}," <>
                     "com.netflix.conductor.common.metadata.workflow.StartWorkflowRequest)"

  @statuses [:in_progress, :failed, :failed_with_terminal_error, :completed, :canceled]

  @doc "The actions not implemented yet."
  @spec unimplemented() :: [atom()]
  def unimplemented, do: Keyword.fetch!(__MODULE__.__info__(:attributes), :unimplemented)

  @doc """
  `POST /api/tasks/{workflowId}/{taskRefName}/{status}` (`updateTask`, `workerid` query, the output
  map as the body): the updated task's ID as text, or 200 without a body when the workflow has no
  pending task of that reference name (also for an unknown workflow).
  """
  @spec update_by_ref(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_by_ref(conn, %{"workflowId" => id, "taskRefName" => ref}) do
    with {:ok, status} <- task_status(conn),
         worker_id = Request.string(conn, "workerid"),
         {:ok, output, conn} <- output(conn, @update_handler) do
      case Tasks.update_by_ref(id, ref, status, worker_id, output) do
        {:ok, nil} -> Response.empty(conn)
        {:ok, task_id} -> Response.text(conn, task_id)
        {:error, reason} -> Errors.send_error(conn, reason)
      end
    end
  end

  @doc """
  `POST /api/tasks/{workflowId}/{taskRefName}/{status}/sync` (`updateTaskSync`): the workflow with
  its tasks after the update and the decide that follows it. Without a pending task, 404
  `"Found no running task <ref> of workflow <id> to update"`. A missing `workerid` clears the
  task's worker, as upstream.
  """
  @spec update_by_ref_sync(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_by_ref_sync(conn, %{"workflowId" => id, "taskRefName" => ref}) do
    with {:ok, status} <- task_status(conn),
         worker_id = Request.string(conn, "workerid"),
         {:ok, output, conn} <- output(conn, @update_sync_handler) do
      case Tasks.update_by_ref(id, ref, status, worker_id, output, keep_worker: false) do
        {:ok, nil} ->
          Errors.send_error(
            conn,
            {:not_found, "Found no running task #{ref} of workflow #{id} to update"}
          )

        {:ok, _task_id} ->
          send_workflow(conn, id)

        {:error, reason} ->
          Errors.send_error(conn, reason)
      end
    end
  end

  # WorkflowService#getExecutionStatus(id, true); a store failure raises (a 500).
  defp send_workflow(conn, id) do
    case Runtime.get_workflow(id, true) do
      {:ok, workflow} ->
        Response.json(conn, Workflow.to_json(workflow))

      {:error, :not_found} ->
        Errors.send_error(conn, {:not_found, "No such workflow found by id: #{id}"})
    end
  end

  @doc """
  `POST /api/tasks/{workflowId}/{status}/signal` (`signalWorkflowTaskAsync`): signals the blocked
  task (`Archon.Runtime.Tasks.signal/3`) and answers 200 without a body, also when no task is
  blocked. An unknown workflow is a 404.
  """
  @spec signal(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def signal(conn, %{"workflowId" => id}) do
    with {:ok, status} <- task_status(conn),
         {:ok, output, conn} <- output(conn, @signal_handler) do
      case Tasks.signal(id, status, output) do
        {:ok, _task_id} -> Response.empty(conn)
        {:error, reason} -> Errors.send_error(conn, reason)
      end
    end
  end

  @doc """
  `POST /api/tasks/{workflowId}/{status}/signal/sync` (`signalWorkflowTaskSync`, `returnStrategy`
  `TARGET_WORKFLOW`, `timeoutMillis` 5000): signals the blocked task, then waits
  (`ArchonWeb.SignalResponder`) and answers a `SignalResponse` with a new request ID. Without a
  blocked task, 404 `"Found no blocked task in workflow <id> to signal"` at once.
  """
  @spec signal_sync(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def signal_sync(conn, %{"workflowId" => id}) do
    with {:ok, status} <- task_status(conn),
         {:ok, strategy} <- strategy(conn),
         {:ok, timeout_ms} <- query(conn, Request.long(conn, "timeoutMillis", 5000, "long")),
         {:ok, output, conn} <- output(conn, @signal_sync_handler) do
      case Tasks.signal(id, status, output) do
        {:ok, nil} ->
          Errors.send_error(
            conn,
            {:not_found, "Found no blocked task in workflow #{id} to signal"}
          )

        {:ok, _task_id} ->
          send_response(
            conn,
            SignalResponder.await(id, [], strategy, Runtime.new_id(), timeout_ms)
          )

        {:error, reason} ->
          Errors.send_error(conn, reason)
      end
    end
  end

  @doc """
  `POST /api/workflow/execute/{name}/{version}` (`executeWorkflow`, a `StartWorkflowRequest` body):
  starts the workflow as `POST /api/workflow` does, with the path's name and version (`0` is the
  latest), then waits (`ArchonWeb.SignalResponder`, `waitForSeconds` 10, also for 0) and answers
  a `SignalResponse`. `requestId` is echoed, or a new one when blank; the comma-separated
  `waitUntilTaskRef` names tasks that block once terminal; `consistency` is read and not used, as
  upstream. With an inline definition that has tasks, the input gets
  `_systemMetadata.dynamic = true`.
  """
  @spec execute(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def execute(conn, %{"name" => name, "version" => version}) do
    with {:ok, version} <-
           query(conn, Request.convert_int("version", version, nil, "java.lang.Integer")),
         request_id = Request.string(conn, "requestId"),
         refs = Request.string(conn, "waitUntilTaskRef"),
         {:ok, wait_s} <-
           query(conn, Request.int(conn, "waitForSeconds", 10, "java.lang.Integer")),
         {:ok, strategy} <- strategy(conn),
         {:ok, json, conn} <- body(conn, @execute_handler),
         {:ok, request} <- decode(conn, StartWorkflowRequest.from_json(json)),
         {:ok, version} <- latest(conn, version),
         {:ok, request} <- mark_dynamic(conn, request),
         request = %{request | name: name, version: version},
         :ok <- validate(conn, request),
         :ok <- check_start(conn, request),
         {:ok, id} <- start(conn, request) do
      request_id = if Validation.java_blank?(request_id), do: Runtime.new_id(), else: request_id
      refs = if Validation.java_blank?(refs), do: [], else: String.split(refs, ",")
      wait_s = if wait_s in [nil, 0], do: 10, else: wait_s
      send_response(conn, SignalResponder.await(id, refs, strategy, request_id, wait_s * 1000))
    end
  end

  # `if (version == 0)` unboxes the path's Integer.
  defp latest(conn, nil),
    do:
      Errors.send_error(
        conn,
        {:server_error,
         ~s(Cannot invoke "java.lang.Integer.intValue\(\)" because "version" is null)}
      )

  defp latest(_conn, 0), do: {:ok, nil}
  defp latest(_conn, version), do: {:ok, version}

  # markAsDynamicWorkflow, with the JVM's messages for an input it cannot change.
  defp mark_dynamic(conn, %StartWorkflowRequest{workflow_def: %{tasks: [_ | _]}} = request) do
    case request.input do
      nil ->
        {:jvm,
         ~s(Cannot invoke "java.util.Map.containsKey\(Object\)" because "workflowInput" is null)}

      %{"_systemMetadata" => metadata} = input when is_map(metadata) ->
        {:ok, Map.put(input, "_systemMetadata", Map.put(metadata, "dynamic", true))}

      %{"_systemMetadata" => nil} ->
        {:jvm,
         ~s(Cannot invoke "java.util.Map.put\(Object, Object\)" because "systemMetadata" is null)}

      %{"_systemMetadata" => value} ->
        {:jvm, cast_message(java_class(value))}

      input ->
        {:ok, Map.put(input, "_systemMetadata", %{"dynamic" => true})}
    end
    |> case do
      {:ok, input} -> {:ok, %{request | input: input}}
      {:jvm, message} -> Errors.send_error(conn, {:server_error, message})
    end
  end

  defp mark_dynamic(_conn, request), do: {:ok, request}

  defp cast_message(class) do
    "class #{class} cannot be cast to class java.util.Map (#{class} and java.util.Map are in " <>
      "module java.base of loader 'bootstrap')"
  end

  # The class Jackson gives an untyped JSON value.
  defp java_class(value) when is_binary(value), do: "java.lang.String"
  defp java_class(value) when is_boolean(value), do: "java.lang.Boolean"
  defp java_class(value) when is_list(value), do: "java.util.ArrayList"
  defp java_class(value) when is_float(value), do: "java.lang.Double"
  defp java_class(value) when value in -2_147_483_648..2_147_483_647, do: "java.lang.Integer"

  defp java_class(value) when value in -9_223_372_036_854_775_808..9_223_372_036_854_775_807,
    do: "java.lang.Long"

  defp java_class(_value), do: "java.math.BigInteger"

  defp validate(conn, request) do
    case StartWorkflowRequest.validate(request) do
      :ok ->
        :ok

      {:error, errors} ->
        Errors.send_error(conn, {:invalid, errors}, path: "startWorkflow.arg0", value: request)
    end
  end

  # What `ArchonWeb.WorkflowController.start/2` refuses before a workflow exists, which the
  # runtime does not check.
  defp check_start(conn, %StartWorkflowRequest{} = request) do
    cond do
      # MetadataMapperService#lookupWorkflowDefinition: an IllegalArgumentException (400).
      request.workflow_def == nil and Validation.java_blank?(request.name) ->
        Errors.send_error(
          conn,
          {:invalid, "Workflow name must be specified when searching for a definition"}
        )

      # Without an input, upstream downloads the input from the external storage path, which
      # fails on a server without external payload storage.
      request.input in [nil, %{}] and
          not Validation.java_blank?(request.external_input_payload_storage_path) ->
        Errors.send_error(
          conn,
          {:server_error,
           "Unable to download payload from external storage path: " <>
             request.external_input_payload_storage_path}
        )

      true ->
        :ok
    end
  end

  defp start(conn, request) do
    case Runtime.start_workflow(StartWorkflowRequest.to_start_input(request)) do
      {:ok, id} -> {:ok, id}
      {:error, reason} -> Errors.send_error(conn, reason)
    end
  end

  defp send_response(conn, {:ok, response}),
    do: Response.json(conn, SignalResponse.to_json(response))

  # Tomcat's AsyncRequestTimeoutException: a 500 whose message is null.
  defp send_response(conn, {:error, :async_timeout}) do
    response = %{Errors.error_response({:server_error, ""}) | message: nil}
    Response.json(conn, 500, ErrorResponse.to_json(response))
  end

  defp send_response(conn, {:error, reason}), do: Errors.send_error(conn, reason)

  # The `status` path variable (StringToEnumConverterFactory: trimmed, blank is null).
  defp task_status(conn) do
    text = conn.path_params["status"]

    case enum_value(text, @statuses) do
      {:ok, nil} ->
        Errors.send_error(
          conn,
          {:server_error,
           "Required URI template variable 'status' for method parameter type Status is " <>
             "present but converted to null"}
        )

      {:ok, status} ->
        {:ok, status}

      :error ->
        Errors.send_error(
          conn,
          conversion_error("status", "java.lang.String", @status_type, "PathVariable", text)
        )
    end
  end

  # The `returnStrategy` query, `TARGET_WORKFLOW` when missing or blank. A repeated parameter
  # converts its first value.
  defp strategy(conn) do
    values = Request.values(conn, "returnStrategy")

    case enum_value(List.first(values), SignalResponse.strategies()) do
      {:ok, nil} ->
        {:ok, :target_workflow}

      {:ok, strategy} ->
        {:ok, strategy}

      :error ->
        source = if length(values) > 1, do: "java.lang.String[]", else: "java.lang.String"

        Errors.send_error(
          conn,
          conversion_error(
            "returnStrategy",
            source,
            @strategy_type,
            "RequestParam",
            List.first(values)
          )
        )
    end
  end

  defp enum_value(nil, _values), do: {:ok, nil}

  defp enum_value(text, values) do
    # Java's String#trim
    case String.replace(text, ~r/\A[\x00-\x20]+|[\x00-\x20]+\z/, "") do
      "" -> {:ok, nil}
      name -> Enum.find_value(values, :error, &(Codec.enum_name(&1) == name and {:ok, &1}))
    end
  end

  # MethodArgumentTypeMismatchException with ConversionFailedException's message
  # (`ObjectUtils.nullSafeConciseToString` cuts the value to 100 UTF-16 code units; a surrogate
  # pair the cut splits is left out, where Jackson writes its lone half as an escape).
  defp conversion_error(name, source, type, annotation, value) do
    value = concise(value)

    {:server_error,
     "Method parameter '#{name}': Failed to convert value of type '#{source}' to required type " <>
       "'#{type}'; Failed to convert from type [java.lang.String] to type " <>
       "[@org.springframework.web.bind.annotation.#{annotation} #{type}] for value [#{value}]"}
  end

  defp concise(value) do
    {kept, units} =
      value
      # Bytes that are not UTF-8 (`%FF` in the path) as U+FFFD, so the message can be written.
      |> String.replace_invalid()
      |> String.to_charlist()
      |> Enum.reduce_while({[], 0}, fn char, {kept, units} ->
        size = if char > 0xFFFF, do: 2, else: 1

        if units + size > 100,
          do: {:halt, {kept, :cut}},
          else: {:cont, {[char | kept], units + size}}
      end)

    text = kept |> Enum.reverse() |> List.to_string()
    if units == :cut, do: text <> " (truncated)...", else: text
  end

  # The output map body (`@RequestBody Map<String, Object>`).
  defp output(conn, handler) do
    with {:ok, json, conn} <- body(conn, handler),
         {:ok, output} <- decode(conn, Codec.cast(:object, json, [])) do
      {:ok, output, conn}
    end
  end

  # Every failure below is answered here, so a `with` falls through with the sent conn.
  defp body(conn, handler) do
    case Request.read_json(conn, handler: handler) do
      {:ok, json, conn} -> {:ok, json, conn}
      {:error, reason, conn} -> Errors.send_error(conn, reason)
    end
  end

  defp decode(_conn, {:ok, value}), do: {:ok, value}
  defp decode(conn, {:error, errors}), do: Errors.send_error(conn, Request.codec_error(errors))

  defp query(_conn, {:ok, value}), do: {:ok, value}
  defp query(conn, {:error, reason}), do: Errors.send_error(conn, reason)
end
