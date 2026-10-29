# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss common/src/test/java/com/netflix/conductor/common/
# workflow/WorkflowDefValidatorTest.java, tasks/TaskDefTest.java, workflow/WorkflowTaskTest.java
# and constraints/NameValidatorTest.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests against the Elixir structs; tests of Java
# accessors and equals/hashCode that have no Elixir counterpart were dropped.

defmodule Archon.Domain.DefinitionValidationTest do
  # Not async: some tests set OS environment variables, which upstream reads for ${ENV} inputs.
  use ExUnit.Case, async: false

  alias Archon.Domain.{StateChangeEvent, TaskDef, WorkflowDef, WorkflowTask}

  # The upstream tests run with name validation on and ownerEmail mandatory (test defaults).
  @strict [owner_email_mandatory: true, name_validation: true]

  defp messages({:error, errors}), do: Enum.map(errors, &elem(&1, 1))
  defp messages(:ok), do: []

  defp simple(name, input \\ %{}) do
    %WorkflowTask{name: name, task_reference_name: name, type: "SIMPLE", input_parameters: input}
  end

  defp workflow(tasks, attrs \\ []) do
    struct!(%WorkflowDef{name: "test_env", owner_email: "owner@test.com", tasks: tasks}, attrs)
  end

  describe "WorkflowDefValidatorTest" do
    setup do
      for {key, value} <- [{"NETFLIX_ENVIRONMENT", "test"}, {"TEST_ENV", "test"}],
          System.get_env(key) == nil do
        System.put_env(key, value)
        on_exit(fn -> System.delete_env(key) end)
      end

      :ok
    end

    test "testWorkflowDefConstraints" do
      errors = messages(WorkflowDef.validate(%WorkflowDef{}, @strict))

      assert length(errors) == 3
      assert "WorkflowDef name cannot be null or empty" in errors
      assert "WorkflowTask list cannot be empty" in errors
      assert "ownerEmail cannot be empty" in errors
    end

    test "testWorkflowDefConstraintsWithMultipleEnvVariable" do
      input = %{
        "taskId" => "${CPEWF_TASK_ID}",
        "entryPoint" =>
          "${NETFLIX_ENVIRONMENT} ${NETFLIX_STACK} ${CPEWF_TASK_ID} ${workflow.input.status}"
      }

      definition = workflow([simple("task_1", input), simple("task_2", %{"env" => input})])
      assert WorkflowDef.validate(definition, @strict) == :ok
    end

    test "testWorkflowDefConstraintsSingleEnvVariable" do
      definition = workflow([simple("task_1", %{"taskId" => "${CPEWF_TASK_ID}"})])
      assert WorkflowDef.validate(definition, @strict) == :ok
    end

    test "testWorkflowDefConstraintsDualEnvVariable" do
      definition =
        workflow([simple("task_1", %{"taskId" => "${CPEWF_TASK_ID} ${NETFLIX_STACK}"})])

      assert WorkflowDef.validate(definition, @strict) == :ok
    end

    test "testWorkflowDefConstraintsWithMapAsInputParam" do
      input = %{
        "taskId" => "${CPEWF_TASK_ID} ${NETFLIX_STACK}",
        "env" => %{
          "packageId" => "${workflow.input.packageId}",
          "taskId" => "${CPEWF_TASK_ID}",
          "NETFLIX_STACK" => "${NETFLIX_STACK}",
          "NETFLIX_ENVIRONMENT" => "${NETFLIX_ENVIRONMENT}"
        }
      }

      assert WorkflowDef.validate(workflow([simple("task_1", input)]), @strict) == :ok
    end

    test "testWorkflowTaskInputParamInvalid" do
      definition = workflow([simple("t1", %{"blabla" => "${workflow.input.Space Value}"})])

      assert messages(WorkflowDef.validate(definition, @strict)) == [
               "key: blabla input parameter value: workflow.input.Space Value is not valid"
             ]
    end

    test "testWorkflowTaskEmptyStringInputParamValue" do
      assert WorkflowDef.validate(workflow([simple("t1", %{"blabla" => ""})]), @strict) == :ok
    end

    test "testWorkflowTasklistInputParamWithEmptyString" do
      definition = workflow([simple("t1", %{"blabla" => "", "foo" => [""]})])
      assert WorkflowDef.validate(definition, @strict) == :ok
    end

    test "testWorkflowSchemaVersion1" do
      definition = workflow([simple("t1", %{"blabla" => ""})], schema_version: 3)

      assert messages(WorkflowDef.validate(definition, @strict)) == [
               "workflowDef schemaVersion: 2 is only supported"
             ]
    end

    test "testWorkflowOwnerInvalidEmail (no format check upstream)" do
      definition = workflow([simple("t1")], owner_email: "owner")
      assert WorkflowDef.validate(definition, @strict) == :ok
    end

    test "testWorkflowWithFailureDefinition" do
      definition =
        workflow([simple("simple_task", %{"param" => "value"})],
          failure_workflow: "failure_workflow",
          failure_workflow_version: 1
        )

      assert WorkflowDef.validate(definition, @strict) == :ok
    end
  end

  describe "WorkflowDef validation beyond the upstream tests" do
    test "server defaults do not require ownerEmail or check names" do
      definition = workflow([simple("t1")], owner_email: nil, name: "bad@name")
      assert WorkflowDef.validate(definition) == :ok
    end

    test "name validation rejects characters outside the allowed set" do
      assert {:error, [{"name", message}]} =
               WorkflowDef.validate(workflow([simple("t1")], name: "bad@name"), @strict)

      assert message =~ "Invalid name 'bad@name'."
    end

    test "null tasks fail @NotNull and @NotEmpty" do
      assert {:error, errors} = WorkflowDef.validate(workflow(nil))

      assert errors == [
               {"tasks", "must not be null"},
               {"tasks", "WorkflowTask list cannot be empty"}
             ]
    end

    test "task reference names must be unique across nested branches" do
      switch = %WorkflowTask{
        name: "s",
        task_reference_name: "s",
        type: "SWITCH",
        evaluator_type: "value-param",
        expression: "x",
        decision_cases: %{"a" => [simple("dup")]},
        default_case: [simple("dup")]
      }

      assert {:error, [{"", message}]} = WorkflowDef.validate(workflow([switch]))

      assert message ==
               "taskReferenceName: dup should be unique across tasks for a given " <>
                 "workflowDefinition: test_env"
    end

    test "input references must name a task of the definition" do
      definition =
        workflow([
          simple("a", %{"x" => "${b.output.y}", "z" => "${missing.output.y}"}),
          simple("b")
        ])

      assert messages(WorkflowDef.validate(definition)) == [
               "taskReferenceName: missing for given task: a input value: z of input parameter: " <>
                 "${missing.output.y} is not defined in workflow definition."
             ]
    end

    test "nested task violations carry the branch path" do
      fork = %WorkflowTask{
        name: "f",
        task_reference_name: "f",
        type: "FORK_JOIN",
        fork_tasks: [[simple("ok")], [%WorkflowTask{name: "n", start_delay: -1}]]
      }

      assert {:error, errors} = WorkflowDef.validate(workflow([fork]))

      assert errors == [
               {"tasks[0].forkTasks[1][0].taskReferenceName",
                "WorkflowTask taskReferenceName name cannot be empty or null"},
               {"tasks[0].forkTasks[1][0].startDelay", "must be greater than or equal to 0"}
             ]
    end

    test "loopOver children are not cascaded, as upstream leaves them without @Valid" do
      loop = %WorkflowTask{
        name: "l",
        task_reference_name: "l",
        type: "DO_WHILE",
        loop_condition: "false",
        loop_over: [%WorkflowTask{name: "child", task_reference_name: "child", start_delay: -1}]
      }

      assert WorkflowDef.validate(workflow([loop])) == :ok
    end

    test "onStateChange events need a type" do
      task = %{simple("t") | on_state_change: %{"onFailed" => [%StateChangeEvent{}]}}

      assert {:error, [{"tasks[0].onStateChange[onFailed][0].type", "must not be null"}]} =
               WorkflowDef.validate(workflow([task]))
    end

    test "input path syntax approximation" do
      assert WorkflowDef.input_path_valid?("workflow.input.x")
      assert WorkflowDef.input_path_valid?("task.output['a key'][0]")
      refute WorkflowDef.input_path_valid?("workflow.input.Space Value")
      refute WorkflowDef.input_path_valid?("workflow.input.")
      refute WorkflowDef.input_path_valid?("workflow.input[0")
      refute WorkflowDef.input_path_valid?(" ")
    end
  end

  describe "TaskDefTest" do
    test "test (defaults)" do
      definition = %TaskDef{
        name: "test1",
        description: "desc",
        retry_count: 10,
        timeout_seconds: 100
      }

      assert definition.response_timeout_seconds == 3600
    end

    test "testTaskDef" do
      definition = %TaskDef{
        name: "task1",
        retry_count: -1,
        timeout_seconds: 1000,
        response_timeout_seconds: 1001
      }

      errors = messages(TaskDef.validate(definition, @strict))
      assert length(errors) == 3

      assert "TaskDef: task1 responseTimeoutSeconds: 1001 must be less than timeoutSeconds: 1000" in errors

      assert "TaskDef retryCount: 0 must be >= 0" in errors
      assert "ownerEmail cannot be empty" in errors
    end

    test "testTaskDefTotalTimeOutSeconds" do
      definition = %TaskDef{
        name: "test-task",
        retry_count: 1,
        timeout_seconds: 1000,
        total_timeout_seconds: 900,
        response_timeout_seconds: 1,
        owner_email: "blah@gmail.com"
      }

      assert messages(TaskDef.validate(definition, @strict)) == [
               "TaskDef: test-task timeoutSeconds: 1000 must be less than or equal to totalTimeoutSeconds: 900"
             ]
    end

    test "testTaskDefInvalidEmail" do
      definition = %TaskDef{
        name: "test-task",
        retry_count: 1,
        timeout_seconds: 1000,
        response_timeout_seconds: 1
      }

      assert messages(TaskDef.validate(definition, @strict)) == ["ownerEmail cannot be empty"]
    end

    test "testTaskDefValidEmail" do
      definition = %TaskDef{
        name: "test-task",
        retry_count: 1,
        timeout_seconds: 1000,
        response_timeout_seconds: 1,
        owner_email: "owner@test.com"
      }

      assert TaskDef.validate(definition, @strict) == :ok
    end

    test "testRuntimeMetadataGetterSetterRoundTrip" do
      assert %TaskDef{}.runtime_metadata == []

      assert {:ok, decoded} =
               TaskDef.from_json(%{"runtimeMetadata" => ["OPENAI_API_KEY", "REGION"]})

      assert TaskDef.to_json(decoded)["runtimeMetadata"] == ["OPENAI_API_KEY", "REGION"]
    end
  end

  describe "TaskDef validation beyond the upstream tests" do
    test "minimum checks report the validated value where upstream's message does" do
      definition = %TaskDef{
        name: "t",
        response_timeout_seconds: 0,
        poll_timeout_seconds: -1,
        backoff_scale_factor: 0
      }

      assert {:error, errors} = TaskDef.validate(definition)

      assert errors == [
               {"responseTimeoutSeconds",
                "TaskDef responseTimeoutSeconds: 0 should be minimum 1 second"},
               {"pollTimeoutSeconds", "TaskDef pollTimeoutSeconds: 0 must be >= 0"},
               {"backoffScaleFactor", "Backoff scale factor. Applicable for LINEAR_BACKOFF"}
             ]
    end

    test "concurrency_limit treats nil as unlimited" do
      assert TaskDef.concurrency_limit(%TaskDef{}) == 0
      assert TaskDef.concurrency_limit(%TaskDef{concurrent_exec_limit: 4}) == 4
    end
  end

  describe "WorkflowTaskTest" do
    test "test (type)" do
      assert %WorkflowTask{}.type == "SIMPLE"
    end

    test "testOptional" do
      refute %WorkflowTask{}.optional
    end

    test "testWorkflowTaskName" do
      errors = messages(WorkflowTask.validate(%WorkflowTask{}))

      assert errors == [
               "WorkflowTask name cannot be empty or null",
               "WorkflowTask taskReferenceName name cannot be empty or null"
             ]
    end

    test "testAgentMetadataJsonRoundTrip" do
      metadata = %{
        "agent" => %{
          "schemaVersion" => 1,
          "agentType" => "conductor",
          "resolved" => true,
          "conductor" => %{
            "name" => "researcher",
            "resolvedVersion" => 7,
            "agentConfig" => %{"model" => "openai/gpt-5", "tools" => [%{"name" => "search"}]}
          }
        }
      }

      task = %WorkflowTask{
        name: "invoke_agent",
        task_reference_name: "invoke_agent_ref",
        type: "AGENT",
        metadata: metadata
      }

      json = task |> WorkflowTask.to_json() |> JSON.encode!() |> JSON.decode!()
      assert {:ok, %WorkflowTask{metadata: ^metadata}} = WorkflowTask.from_json(json)
    end

    test "testWorkflowTaskWithoutMetadataRemainsValid" do
      json = %{"name" => "legacy", "taskReferenceName" => "legacy_ref", "type" => "SIMPLE"}
      assert {:ok, %WorkflowTask{metadata: %{}}} = WorkflowTask.from_json(json)

      assert {:ok, %WorkflowTask{metadata: %{}}} =
               WorkflowTask.from_json(Map.put(json, "metadata", nil))
    end
  end

  describe "NameValidatorTest" do
    test "nameWithAllowedCharactersIsValid / nonAllowedCharactersInNameIsInvalid / nullIsValid" do
      on = [name_validation: true]
      assert WorkflowDef.validate(workflow([simple("t")], name: "workflowDef"), on) == :ok

      assert {:error, [{"name", _}]} =
               WorkflowDef.validate(workflow([simple("t")], name: "workflowDef@"), on)

      assert {:error, errors} = WorkflowDef.validate(workflow([simple("t")], name: nil), on)
      refute Enum.any?(errors, fn {_path, message} -> message =~ "Invalid name" end)
    end
  end
end
