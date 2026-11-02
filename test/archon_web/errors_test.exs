defmodule ArchonWeb.ErrorsTest do
  @moduledoc """
  `ArchonWeb.Errors` against upstream's mappers (ADR 0023, decision 4). The validation cases
  decode a captured request with the domain codec, validate it and compare the error body with
  what upstream answered.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Archon.Contract
  alias Archon.Domain.{ErrorResponse, TaskDef, TaskResult, Validation, WorkflowDef}
  alias ArchonWeb.Errors

  defp json(reason, opts \\ []),
    do: reason |> Errors.error_response(opts) |> ErrorResponse.to_json()

  defp host do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  describe "application errors (ApplicationExceptionMapper)" do
    test "not found and conflict take the message the controller gives" do
      assert json(:not_found, message: "No such workflow found by id: x") == %{
               "status" => 404,
               "message" => "No such workflow found by id: x",
               "instance" => host(),
               "retryable" => false
             }

      assert %{"status" => 409, "message" => "Workflow with a.1 already exists!"} =
               json(:conflict, message: "Workflow with a.1 already exists!")

      assert %{"status" => 404, "message" => "m"} = json({:not_found, "m"})
      assert %{"status" => 409, "message" => "m"} = json({:conflict, "m"})
    end

    test "a message-less reason needs the message" do
      assert_raise KeyError, fn -> Errors.error_response(:not_found) end
    end

    test "IllegalArgumentException is 400" do
      assert %{"status" => 400, "message" => "bad", "retryable" => false, "instance" => _host} =
               json({:invalid, "bad"})
    end

    # The mapper looks the exception class up exactly: IllegalStateException and
    # TerminateWorkflowException have no entry.
    test "invalid state, terminate and framework errors are 500 and not retryable" do
      for tag <- [:invalid_state, :terminate, :server_error] do
        assert %{"status" => 500, "message" => "m", "retryable" => false} = json({tag, "m"})
      end
    end

    test "a body over the limit is 413" do
      assert %{"status" => 413, "message" => "big", "retryable" => false} =
               json({:payload_too_large, "big"})
    end

    test "a refused cross-origin request is 403 (ADR 0025, decision 3)" do
      assert %{"status" => 403, "message" => "no", "retryable" => false, "instance" => _host} =
               json({:forbidden, "no"})
    end

    test "isolated failures, exits and database errors are TransientException" do
      transient = [
        {:env, :boom},
        {:pre_effect, :boom},
        {:commit, {:limit, "x"}},
        {:post_effect, :boom},
        {:exit, {:timeout, {GenServer, :call, []}}},
        {:exit, :unavailable},
        :outbox_pending,
        %DBConnection.ConnectionError{message: "down"},
        %Postgrex.Error{message: "failed"}
      ]

      for reason <- transient do
        log = capture_log(fn -> send(self(), {:body, json(reason)}) end)
        assert_received {:body, body}

        assert body == %{
                 "status" => 500,
                 "message" => "Temporary server error, retry the request",
                 "instance" => host(),
                 "retryable" => true
               }

        assert log =~ "REST request failed"
      end
    end

    test "anything else is a 500 without Elixir terms in the message" do
      for reason <- [%RuntimeError{message: "secret detail"}, {:weird, self()}, :oops] do
        capture_log(fn -> send(self(), {:body, json(reason)}) end)
        assert_received {:body, body}

        assert %{"status" => 500, "message" => "Internal server error", "retryable" => false} =
                 body
      end
    end

    test "a 500 can carry upstream's message" do
      capture_log(fn ->
        send(self(), {:body, json(:oops, message: "No such task definition")})
      end)

      assert_received {:body, %{"status" => 500, "message" => "No such task definition"}}
    end
  end

  describe "exception_response/2" do
    test "a Plug exception below 500 keeps its status, not its message" do
      capture_log(fn ->
        query = %Plug.Conn.InvalidQueryError{message: "bad query"}

        assert %ErrorResponse{status: 400, message: "Bad Request", retryable: false} =
                 Errors.exception_response(:error, query)

        # Its message would show the params and the module.
        clause = %Phoenix.ActionClauseError{
          module: ArchonWeb.TaskController,
          function: :get,
          arity: 2,
          args: [%Plug.Conn{}, %{"secret" => "1"}]
        }

        assert %ErrorResponse{status: 400, message: "Bad Request"} =
                 Errors.exception_response(:error, clause)
      end)
    end

    test "other exceptions, exits and throws are 500" do
      capture_log(fn ->
        assert %ErrorResponse{status: 500, retryable: false} =
                 Errors.exception_response(:error, %RuntimeError{message: "x"})

        assert %ErrorResponse{status: 500, retryable: true} =
                 Errors.exception_response(:exit, :normal)

        assert %ErrorResponse{status: 500, retryable: false} =
                 Errors.exception_response(:throw, :x)
      end)
    end
  end

  describe "validation errors (ValidationExceptionMapper)" do
    test "no instance, and no invalidValue when the value is null" do
      result = %TaskResult{workflow_instance_id: "w", task_id: nil}
      {:error, errors} = TaskResult.validate(result)

      assert json({:invalid, errors}, path: "updateTask.arg0", value: result) == %{
               "status" => 400,
               "message" => "Validation failed, check below errors for detail.",
               "retryable" => false,
               "validationErrors" => [
                 %{
                   "path" => "updateTask.arg0.taskId",
                   "message" => "Task ID cannot be null or empty"
                 }
               ]
             }
    end

    # Fixtures: request -> what to validate, the method/argument prefix upstream wrote.
    test "matches upstream for a list argument, a string, a null primitive and a fraction" do
      for name <- ~w(metadata_register_taskdefs_no_name metadata_register_taskdefs_blank_name
                     metadata_register_taskdefs_coerced) do
        assert_fixture(name, "registerTaskDef.arg0", &list(&1, TaskDef))
      end
    end

    test "matches upstream for a workflow definition and a list of them" do
      assert_fixture(
        "metadata_register_workflow_no_tasks",
        "registerWorkflowDef.arg0",
        &one(&1, WorkflowDef)
      )

      assert_fixture(
        "metadata_update_workflows_invalid",
        "updateWorkflowDef.arg0",
        &list(&1, WorkflowDef)
      )
    end

    test "matches upstream for a task result with an empty string" do
      assert_fixture("task_update_invalid", "updateTask.arg0", &one(&1, TaskResult))
    end

    test "an empty path is the argument itself, a class-level violation has no invalidValue" do
      task_def = %TaskDef{name: "t", timeout_seconds: 10, response_timeout_seconds: 20}
      {:error, errors} = TaskDef.validate(task_def)
      errors = Validation.nest(errors, "[0]")

      assert %{"validationErrors" => [%{"path" => "registerTaskDef.arg0[0]"} = error]} =
               json({:invalid, errors}, path: "registerTaskDef.arg0", value: [task_def])

      refute Map.has_key?(error, "invalidValue")
    end

    test "an argument-level error has the prefix as its path" do
      assert %{
               "validationErrors" => [
                 %{"path" => "registerTaskDef.arg0", "message" => "TaskDefList is empty"}
               ]
             } =
               json({:invalid, [{"", "TaskDefList is empty"}]},
                 path: "registerTaskDef.arg0",
                 value: []
               )
    end

    test "invalidValue is the Java toString of strings, integers and booleans only" do
      value = %TaskResult{
        task_id: "t",
        callback_after_seconds: 7,
        extend_lease: true,
        status: :completed
      }

      errors = [
        {"taskId", "a"},
        {"callbackAfterSeconds", "b"},
        {"extendLease", "c"},
        {"status", "d"},
        {"outputData", "e"},
        {"nope", "f"}
      ]

      invalid =
        {:invalid, errors}
        |> json(value: value)
        |> Map.fetch!("validationErrors")
        |> Enum.map(&Map.get(&1, "invalidValue"))

      assert invalid == ["t", "7", "true", nil, nil, nil]
    end
  end

  defp one(body, module) do
    {:ok, value} = module.from_json(body)

    case module.validate(value) do
      {:error, errors} -> {value, errors}
    end
  end

  defp list(body, module) do
    values =
      Enum.map(body, fn item ->
        {:ok, value} = module.from_json(item)
        value
      end)

    errors =
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, index} ->
        case module.validate(value) do
          :ok -> []
          {:error, errors} -> Validation.nest(errors, "[#{index}]")
        end
      end)

    {values, errors}
  end

  defp assert_fixture(name, path, validate) do
    %{"request" => %{"body" => body}, "response" => %{"body" => expected}} =
      Contract.fixture(name)

    {value, errors} = validate.(body)
    actual = json({:invalid, errors}, path: path, value: value)
    sort = &Map.update!(&1, "validationErrors", fn errors -> Enum.sort(errors) end)
    assert sort.(actual) == sort.(expected), name
  end
end
