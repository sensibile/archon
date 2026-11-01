# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss rest/src/main/java/com/netflix/conductor/rest/controllers/TaskResource.java
# and core/src/main/java/com/netflix/conductor/core/execution/WorkflowExecutorOps.java
# (updateTask, extendLease: the not-found messages) at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: Phoenix actions for the MVP handlers only; Spring's
# MethodArgumentNotValidException message is written from the TaskResult validation errors.

defmodule ArchonWeb.TaskController do
  @moduledoc """
  The worker loop (upstream `TaskResource`, ADR 0023 decisions 2 and 4, slice 5e) on
  `Archon.Runtime.Tasks`. A `TaskResult` body is decoded and handed to the runtime as it is: the
  fields a worker may not set are the runtime's to ignore (ADR 0024, decision 1).

  The same invalid result fails differently on the two update paths, as upstream:

    * `POST /api/tasks` - the service method validation (`TaskService.updateTask(@Valid ...)`):
      400 with `validationErrors` under `updateTask.arg0`.
    * `POST /api/tasks/update-v2` - `@Valid` on the controller argument, checked before the
      service: Spring's `MethodArgumentNotValidException`, which upstream's mapper does not know,
      so a 500 whose message is Spring's (`spring_validation_message/1`).
  """

  use ArchonWeb, :controller

  alias Archon.Domain.{Task, TaskResult}
  alias Archon.Runtime
  alias Archon.Runtime.Tasks

  @update_handler "public java.lang.String com.netflix.conductor.rest.controllers.TaskResource." <>
                    "updateTask(com.netflix.conductor.common.metadata.tasks.TaskResult)"
  @update_v2_handler "public org.springframework.http.ResponseEntity" <>
                       "<com.netflix.conductor.common.metadata.tasks.Task> " <>
                       "com.netflix.conductor.rest.controllers.TaskResource." <>
                       "updateTaskV2(com.netflix.conductor.common.metadata.tasks.TaskResult)"

  @doc "`GET /api/tasks/poll/{tasktype}` (`poll`, `workerid`, `domain`): a task or 204."
  @spec poll(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def poll(conn, %{"tasktype" => task_type}) do
    {:ok, task} =
      Tasks.poll(task_type, Request.string(conn, "workerid"), Request.string(conn, "domain"))

    send_task(conn, task)
  end

  @doc "`GET /api/tasks/poll/batch/{tasktype}` (`batchPoll`, `count` 1, `timeout` 100)."
  @spec batch_poll(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def batch_poll(conn, %{"tasktype" => task_type}) do
    with {:ok, count} <- Request.int(conn, "count", 1),
         {:ok, timeout} <- Request.int(conn, "timeout", 100),
         {:ok, tasks} <-
           Tasks.batch_poll(
             task_type,
             Request.string(conn, "workerid"),
             Request.string(conn, "domain"),
             count,
             timeout
           ) do
      Response.json(conn, Enum.map(tasks, &Task.to_json/1))
    else
      {:error, reason} -> Errors.send_error(conn, reason)
    end
  end

  @doc "`POST /api/tasks` (`updateTask`, a `TaskResult` body): the task ID as text."
  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, _params), do: with_result(conn, @update_handler, &update_result/2)

  defp update_result(conn, result) do
    case TaskResult.validate(result) do
      :ok ->
        send_updated(conn, Tasks.update(result), result)

      {:error, errors} ->
        Errors.send_error(conn, {:invalid, errors}, path: "updateTask.arg0", value: result)
    end
  end

  defp send_updated(conn, {:ok, _task}, result), do: Response.text(conn, result.task_id)
  defp send_updated(conn, {:error, reason}, result), do: send_update_error(conn, reason, result)

  @doc "`POST /api/tasks/update-v2` (`updateTaskV2`): the next task or 204."
  @spec update_v2(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_v2(conn, _params), do: with_result(conn, @update_v2_handler, &update_v2_result/2)

  defp update_v2_result(conn, result) do
    case TaskResult.validate(result) do
      :ok ->
        send_next(conn, Tasks.update_v2(result), result)

      {:error, errors} ->
        Errors.send_error(conn, {:server_error, spring_validation_message(errors, result)})
    end
  end

  defp send_next(conn, {:ok, task}, _result), do: send_task(conn, task)
  defp send_next(conn, {:error, reason}, result), do: send_update_error(conn, reason, result)

  @doc "`GET /api/tasks/{taskId}` (`getTask`)."
  @spec get(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def get(conn, %{"taskId" => task_id}) do
    case Tasks.get(task_id) do
      {:ok, task} ->
        Response.json(conn, Task.to_json(task))

      {:error, :not_found} ->
        Errors.send_error(conn, {:not_found, "Task not found for taskId: #{task_id}"})
    end
  end

  # Upstream's 2.x compatibility: no task is a 204, not a `null` body.
  defp send_task(conn, nil), do: Response.no_content(conn)
  defp send_task(conn, %Task{} = task), do: Response.json(conn, Task.to_json(task))

  # Reads the `TaskResult` body; `fun` gets the conn that read it and the result, and sends the
  # response.
  defp with_result(conn, handler, fun) do
    case Request.read_json(conn, handler: handler) do
      {:ok, json, conn} ->
        case TaskResult.from_json(json) do
          {:ok, result} -> fun.(conn, result)
          {:error, errors} -> Errors.send_error(conn, {:server_error, parse_error(errors)})
        end

      {:error, reason, conn} ->
        Errors.send_error(conn, reason)
    end
  end

  # Jackson's type errors are 500 "JSON parse error: ..." upstream; the prefix and status are
  # kept, the rest of Jackson's message is not reproduced (ADR 0023, decisions 3 and 4).
  defp parse_error([{path, message} | _rest]),
    do: "JSON parse error: " <> String.trim("#{path} #{message}")

  defp send_update_error(conn, :not_found, result),
    do: Errors.send_error(conn, {:not_found, not_found_message(result, workflow_exists?(result))})

  defp send_update_error(conn, reason, _result), do: Errors.send_error(conn, reason)

  # `Archon.Runtime.Tasks.update/1` answers `:not_found` for a missing workflow and a missing
  # task alike. Upstream reads the workflow first ("No such workflow found by id"), then the task
  # ("No such task found by id"); `extendLease` reads only the task. A store failure while
  # reading the workflow raises, a 500 as upstream's own read would fail (`Plug.ErrorHandler`).
  defp workflow_exists?(%TaskResult{extend_lease: true}), do: true

  defp workflow_exists?(%TaskResult{workflow_instance_id: id}),
    do: Runtime.get_workflow(id, false) != {:error, :not_found}

  defp not_found_message(result, false),
    do: "No such workflow found by id: #{result.workflow_instance_id}"

  defp not_found_message(result, true), do: "No such task found by id: #{result.task_id}"

  @doc """
  The message of Spring's `MethodArgumentNotValidException` for `updateTaskV2`'s `@Valid
  TaskResult` (`MethodArgumentNotValidException#getMessage` with `FieldError#toString`), checked
  against the upstream server. Both constraints are `@NotEmpty` on a `String` field. Upstream
  reports `taskId` before `workflowInstanceId` when both fail; Hibernate does not define that
  order, so it is the observed one.
  """
  @spec spring_validation_message([{String.t(), String.t()}], TaskResult.t()) :: String.t()
  def spring_validation_message(errors, %TaskResult{} = result) do
    errors = Enum.sort_by(errors, fn {field, _message} -> field != "taskId" end)
    count = if length(errors) > 1, do: " with #{length(errors)} errors", else: ""

    "Validation failed for argument [0] in #{@update_v2_handler}#{count}: " <>
      Enum.map_join(errors, &"[#{field_error(&1, result)}] ")
  end

  defp field_error({field, message}, result) do
    "Field error in object 'taskResult' on field '#{field}': " <>
      "rejected value [#{rejected_value(field, result)}]; " <>
      "codes [NotEmpty.taskResult.#{field},NotEmpty.#{field},NotEmpty.java.lang.String,NotEmpty]; " <>
      "arguments [org.springframework.context.support.DefaultMessageSourceResolvable: " <>
      "codes [taskResult.#{field},#{field}]; arguments []; default message [#{field}]]; " <>
      "default message [#{message}]"
  end

  # ObjectUtils.nullSafeToString: the string itself, or "null".
  defp rejected_value("taskId", result), do: result.task_id || "null"
  defp rejected_value("workflowInstanceId", result), do: result.workflow_instance_id || "null"
end
