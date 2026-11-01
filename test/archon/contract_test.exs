defmodule Archon.ContractTest do
  use ExUnit.Case, async: true

  alias Archon.Contract

  # Which part of each captured exchange is checked against which schema
  # (Archon.Contract.fixture_schemas/0). Every fixture must be listed there or in @unschematized,
  # so a newly captured fixture cannot be skipped silently.
  @schematized Contract.fixture_schemas()

  # Exchanges whose bodies have no upstream JSON schema, with the response shape upstream returned.
  @unschematized %{
    "metadata_get_taskdef_not_found" => :error,
    "metadata_get_workflow_not_found" => :error,
    "metadata_register_workflow_conflict" => :error,
    "workflow_get_not_found" => :error,
    "workflow_start_simple" => :text_id,
    "workflow_start_request_switch" => :text_id,
    "workflow_start_fork" => :text_id,
    "workflow_start_to_terminate" => :text_id,
    "task_update_simple_a" => :text_id,
    "task_update_switch_b" => :text_id,
    "task_update_fork_a" => :text_id,
    "task_update_fork_b" => :text_id,
    "metadata_register_taskdefs" => :empty,
    "metadata_register_workflow_simple" => :empty,
    "metadata_register_workflow_switch" => :empty,
    "metadata_register_workflow_fork" => :empty,
    "workflow_terminate" => :empty,
    "task_poll_empty" => :no_content,
    "task_update_v2_simple_b" => :no_content,
    "workflow_get_status" => :workflow_status,
    # Added for Phase 5 (ADR 0023, decision 6).
    "health" => :health,
    "health_api" => :health,
    "metadata_register_taskdefs_single" => :empty,
    "metadata_update_taskdef" => :empty,
    "metadata_update_taskdef_not_found" => :error,
    "metadata_register_taskdefs_empty" => :validation,
    "metadata_register_taskdefs_no_name" => :validation,
    "metadata_register_taskdefs_blank_name" => :validation,
    "metadata_register_taskdefs_coerced" => :validation,
    "metadata_register_workflow_no_tasks" => :validation,
    "metadata_register_workflow_overwrite" => :empty,
    "metadata_get_workflow_version_not_found" => :error,
    "metadata_update_workflows" => :bulk_response,
    "metadata_update_workflows_invalid" => :validation,
    "metadata_get_workflow_bulk_rejected" => :error,
    "metadata_update_workflows_empty" => :validation,
    "workflow_start_not_found" => :error,
    "workflow_start_request_not_found" => :error,
    "workflow_start_inline" => :text_id,
    "workflow_start_inline_second" => :text_id,
    "workflow_get_status_default" => :workflow_status,
    "workflow_get_status_all" => :workflow_status,
    "workflow_get_status_not_found" => :error,
    "workflow_terminate_completed" => :error,
    "workflow_terminate_not_found" => :error,
    "task_get_not_found" => :error,
    "task_update_not_found" => :error,
    "task_update_workflow_not_found" => :error,
    "task_update_v2_not_found" => :error,
    "task_update_invalid" => :validation,
    "task_update_v2_invalid" => :server_error,
    "route_not_found" => :error,
    "route_later_workflow_search" => :json,
    "route_later_workflow_running" => :json,
    "route_later_workflow_test" => :validation,
    "route_later_metadata_names" => :json,
    "route_later_tasks_search" => :json,
    "route_method_patch_workflow" => :error,
    "route_method_put_task" => :error,
    "request_body_not_json" => :server_error,
    "request_query_not_number" => :server_error,
    "request_query_not_boolean" => :server_error
  }

  test "every fixture is classified" do
    classified = MapSet.new(Map.keys(@schematized) ++ Map.keys(@unschematized))
    assert Contract.fixture_names() != []
    assert MapSet.new(Contract.fixture_names()) == classified
  end

  for {name, {side, schema}} <- @schematized do
    test "#{name} #{side} matches #{inspect(schema)}" do
      exchange = Contract.fixture(unquote(name))
      body = get_in(exchange, [Atom.to_string(unquote(side)), "body"])

      assert Contract.validate_schema(unquote(Macro.escape(schema)), body) == :ok
    end
  end

  for {name, shape} <- @unschematized do
    test "#{name} response is #{shape}" do
      assert_shape(unquote(shape), Contract.fixture(unquote(name))["response"])
    end
  end

  describe "validate/2" do
    test "rejects a task without required fields" do
      assert {:error, errors} = Contract.validate(:task, %{"taskType" => "SIMPLE"})
      assert Enum.any?(errors, fn {_path, msg} -> msg =~ "taskId" end)
    end

    test "rejects an unknown workflow status" do
      workflow = Contract.fixture("workflow_get_running")["response"]["body"]

      assert {:error, [{"#/status", _msg}]} =
               Contract.validate(:workflow, Map.put(workflow, "status", "SLEEPING"))
    end
  end

  describe "normalize/1" do
    test "masks timestamps and UUIDs, keeps everything else" do
      id = "f3e36c49-45f2-4a16-bb2e-8c2898ab44b2"

      input = %{
        "workflowId" => id,
        "path" => "/api/workflow/#{id}",
        "tasks" => [%{"startTime" => 1, "endTime" => nil, "seq" => 1}]
      }

      assert Contract.normalize(input) == %{
               "workflowId" => "<uuid>",
               "path" => "/api/workflow/<uuid>",
               "tasks" => [%{"startTime" => "<volatile>", "endTime" => nil, "seq" => 1}]
             }
    end
  end

  defp assert_shape(:error, response) do
    assert %{"status" => status, "body" => body} = response
    assert status in 400..499
    assert %{"status" => ^status, "message" => message, "retryable" => false} = body
    assert is_binary(message)
    assert Map.has_key?(body, "instance")
  end

  # ValidationExceptionMapper: no instance, one entry per violation.
  defp assert_shape(:validation, response) do
    assert %{"status" => 400, "content_type" => "application/json", "body" => body} = response

    assert %{
             "status" => 400,
             "message" => "Validation failed, check below errors for detail.",
             "retryable" => false,
             "validationErrors" => [_ | _] = errors
           } = body

    refute Map.has_key?(body, "instance")
    assert Enum.all?(errors, &(is_binary(&1["path"]) and is_binary(&1["message"])))
  end

  # An exception class upstream's mapper has no status for.
  defp assert_shape(:server_error, response) do
    assert %{"status" => 500, "body" => body} = response
    assert %{"status" => 500, "message" => message, "retryable" => false} = body
    assert is_binary(message)
  end

  defp assert_shape(:health, response) do
    assert %{"status" => 200, "content_type" => "application/json", "body" => body} = response
    assert body == %{"healthResults" => [], "suppressedHealthResults" => [], "healthy" => true}
  end

  defp assert_shape(:bulk_response, response) do
    assert %{"status" => 200, "content_type" => "application/json", "body" => body} = response
    assert %{"bulkErrorResults" => %{}, "bulkSuccessfulResults" => [_ | _]} = body
  end

  # A Later route's upstream answer, kept to show it is not an MVP parameter route.
  defp assert_shape(:json, response) do
    assert %{"status" => 200, "content_type" => "application/json"} = response
  end

  defp assert_shape(:text_id, response) do
    assert %{"status" => 200, "content_type" => "text/plain" <> _, "body" => body} = response
    assert body =~ ~r/\A[0-9a-f-]{36}\z/
  end

  defp assert_shape(:empty, response) do
    assert %{"status" => 200, "body" => nil} = response
  end

  defp assert_shape(:no_content, response) do
    assert %{"status" => 204, "body" => nil} = response
  end

  defp assert_shape(:workflow_status, response) do
    assert %{"status" => 200, "body" => body} = response
    keys = Map.keys(body)
    assert "workflowId" in keys and "status" in keys
    assert keys -- ~w(correlationId output status variables workflowId) == []
  end
end
