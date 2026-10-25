defmodule Archon.ContractTest do
  use ExUnit.Case, async: true

  alias Archon.Contract

  # Which part of each captured exchange is checked against which schema. Every fixture must be
  # listed here or in @unschematized, so a newly captured fixture cannot be skipped silently.
  @schematized %{
    "metadata_register_taskdefs" => {:request, {:list, :task_def}},
    "metadata_register_workflow_simple" => {:request, :workflow_def},
    "metadata_register_workflow_switch" => {:request, :workflow_def},
    "metadata_register_workflow_fork" => {:request, :workflow_def},
    "metadata_get_taskdef" => {:response, :task_def},
    "metadata_get_workflow" => {:response, :workflow_def},
    "metadata_get_workflow_switch" => {:response, :workflow_def},
    "metadata_get_workflow_fork" => {:response, :workflow_def},
    "task_poll_simple_a" => {:response, :task},
    "task_poll_simple_b" => {:response, :task},
    "task_poll_switch_b" => {:response, :task},
    "task_poll_fork_b" => {:response, :task},
    "task_batch_poll_fork_a" => {:response, {:list, :task}},
    "task_get" => {:response, :task},
    "workflow_get_running" => {:response, :workflow},
    "workflow_get_completed_simple" => {:response, :workflow},
    "workflow_get_completed_switch" => {:response, :workflow},
    "workflow_get_completed_fork" => {:response, :workflow},
    "workflow_get_without_tasks" => {:response, :workflow},
    "workflow_get_terminated" => {:response, :workflow}
  }

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
    "workflow_get_status" => :workflow_status
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

      result =
        case unquote(schema) do
          {:list, schema} -> Contract.validate_each(schema, body)
          schema -> Contract.validate(schema, body)
        end

      assert result == :ok
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
    assert Map.keys(body) |> Enum.sort() == ~w(correlationId output status workflowId)
  end
end
