# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.RuntimeTest do
  @moduledoc """
  `Archon.Runtime` with the application's process tree: the captured start, terminate and get
  exchanges replayed through processes (ADR 0018, decisions 7 and 10), and the start errors of
  upstream `startWorkflow`.
  """

  use Archon.RuntimeCase

  alias Archon.Contract
  alias Archon.Domain.{Task, WorkflowDef, WorkflowTask}

  import Archon.StepReplay, only: [assert_matches: 2]

  describe "golden fixtures through processes" do
    test "workflow_start_to_terminate, workflow_terminate, workflow_get_terminated" do
      start = Contract.fixture("workflow_start_to_terminate")
      assert start["request"]["path"] == "/api/workflow/archon_simple"

      id = start_simple(start["request"]["body"])
      assert Contract.normalize(id) == Contract.normalize(start["response"]["body"])
      assert Runtime.queue().contains?("archon_task_a", task(id, "task_a_ref").task_id)

      terminate = Contract.fixture("workflow_terminate")
      %URI{query: query} = URI.parse(terminate["request"]["path"])
      %{"reason" => reason} = URI.decode_query(query)

      assert Runtime.terminate_workflow(id, reason) == :ok
      assert terminate["response"]["body"] == nil

      {:ok, workflow} = Runtime.get_workflow(id)
      assert_matches(workflow, "workflow_get_terminated")
      refute Runtime.queue().contains?("archon_task_a", task(id, "task_a_ref").task_id)
      await_down(id)
    end

    test "workflow_start_simple, a poll, workflow_get_running" do
      start = Contract.fixture("workflow_start_simple")
      %URI{query: query} = URI.parse(start["request"]["path"])
      %{"correlationId" => correlation_id} = URI.decode_query(query)

      id = start_simple(start["request"]["body"], correlation_id: correlation_id)
      task_id = task(id, "task_a_ref").task_id

      assert %Task{status: :in_progress, task_id: ^task_id} =
               WorkflowServer.poll(id, task_id, "archon-contract")

      assert Runtime.queue().ack("archon_task_a", task_id)

      {:ok, workflow} = Runtime.get_workflow(id)
      assert_matches(workflow, "workflow_get_running")
      assert WorkflowServer.whereis(id)
    end
  end

  describe "start_workflow/1" do
    test "embeds the registered task definitions and stamps the workflow" do
      id = start_simple(%{"x" => 1}, priority: 3, task_to_domain: %{"a" => "b"})
      {:ok, workflow} = Runtime.get_workflow(id)

      assert %{priority: 3, owner_app: "", status: :running, task_to_domain: %{"a" => "b"}} =
               workflow

      assert [%WorkflowTask{task_definition: %{retry_count: 0, timeout_seconds: 300}} | _rest] =
               workflow.workflow_definition.tasks

      assert workflow.create_time > 0
    end

    test "an unknown definition and a nil input are refused before anything is created" do
      assert Runtime.start_workflow(%{name: "archon_none", input: %{}}) ==
               {:error, {:not_found, "No such workflow defined. name=archon_none, version=null"}}

      assert Runtime.start_workflow(%{name: "archon_simple", version: 7, input: %{}}) ==
               {:error, {:not_found, "No such workflow defined. name=archon_simple, version=7"}}

      assert Runtime.start_workflow(%{name: "archon_simple", workflow_id: "none-input"}) ==
               {:error, {:invalid, "NULL input passed when starting workflow"}}

      assert Runtime.get_workflow("none-input") == {:error, :not_found}
      assert WorkflowServer.whereis("none-input") == nil
    end

    test "a SUB_WORKFLOW without a registered definition is refused" do
      definition = %WorkflowDef{
        name: "archon_parent",
        tasks: [
          %WorkflowTask{
            name: "sub",
            task_reference_name: "sub_ref",
            type: "SUB_WORKFLOW",
            sub_workflow_param: %Archon.Domain.SubWorkflowParams{name: "archon_missing"}
          }
        ]
      }

      assert Runtime.start_workflow(%{definition: definition, input: %{}}) ==
               {:error,
                {:terminate,
                 "The Task archon_missing defined as a sub-workflow has no workflow definition available "}}
    end

    # MetadataMapperService#populateTaskDefinitions walks WorkflowDef#collectTasks, which takes
    # the decision cases, the default case, the fork branches and the loop body too. The
    # containers are minimal: only the population of the definition runs before the refusal.
    test "a nested SUB_WORKFLOW without a registered definition is refused" do
      sub = %WorkflowTask{
        name: "sub",
        task_reference_name: "sub_ref",
        type: "SUB_WORKFLOW",
        sub_workflow_param: %Archon.Domain.SubWorkflowParams{name: "archon_missing"}
      }

      containers = [
        %WorkflowTask{
          name: "switch",
          task_reference_name: "switch_ref",
          type: "SWITCH",
          decision_cases: %{"a" => [sub]}
        },
        %WorkflowTask{
          name: "switch",
          task_reference_name: "switch_ref",
          type: "SWITCH",
          default_case: [sub]
        },
        %WorkflowTask{
          name: "fork",
          task_reference_name: "fork_ref",
          type: "FORK_JOIN",
          fork_tasks: [[sub]]
        },
        %WorkflowTask{
          name: "loop",
          task_reference_name: "loop_ref",
          type: "DO_WHILE",
          loop_over: [sub]
        }
      ]

      for container <- containers do
        definition = %WorkflowDef{name: "archon_parent", tasks: [container]}

        assert Runtime.start_workflow(%{definition: definition, input: %{}}) ==
                 {:error,
                  {:terminate,
                   "The Task archon_missing defined as a sub-workflow has no workflow definition available "}},
               container.type
      end
    end

    test "a SUB_WORKFLOW start runs after the answer and its result is saved" do
      definition = %WorkflowDef{
        name: "archon_parent",
        tasks: [
          %WorkflowTask{
            name: "sub",
            task_reference_name: "sub_ref",
            type: "SUB_WORKFLOW",
            sub_workflow_param: %Archon.Domain.SubWorkflowParams{name: "archon_simple"}
          }
        ]
      }

      assert {:ok, id} = Runtime.start_workflow(%{definition: definition, input: %{}})

      task =
        eventually(fn ->
          t = task(id, "sub_ref")
          t.status == :in_progress and t
        end)

      assert task.input_data["subWorkflowVersion"] == 1

      assert {:ok, %{status: :running, parent_workflow_id: ^id}} =
               Runtime.get_workflow(task.sub_workflow_id)

      assert Runtime.terminate_workflow(id, "stop") == :ok
      assert task(id, "sub_ref").status == :canceled
      assert {:ok, %{status: :terminated}} = Runtime.get_workflow(task.sub_workflow_id)
    end

    test "an ID that exists is a conflict" do
      id = start_simple(%{"x" => 1})

      assert Runtime.start_workflow(%{name: "archon_simple", workflow_id: id, input: %{}}) ==
               {:error, :conflict}
    end

    test "an empty input is stored as an empty map" do
      id = start_simple(%{})
      assert {:ok, %{input: %{}}} = Runtime.get_workflow(id)
    end
  end

  describe "start_workflow_idempotent/1" do
    test "creates once, decides after answering and returns the stored one again" do
      id = "idem-" <> Runtime.new_id()
      input = %{name: "archon_simple", workflow_id: id, input: %{"x" => 2}}

      assert {:ok, %{workflow_id: ^id, tasks: []}} = Runtime.start_workflow_idempotent(input)
      eventually(fn -> task(id, "task_a_ref") end)

      assert {:ok, %{workflow_id: ^id, tasks: [_task]}} =
               Runtime.start_workflow_idempotent(input)
    end

    test "needs a workflow ID and the same parent" do
      assert Runtime.start_workflow_idempotent(%{name: "archon_simple", input: %{}}) ==
               {:error, {:invalid, "workflowId must be present for idempotent workflow start"}}

      id = "idem-" <> Runtime.new_id()
      input = %{name: "archon_simple", workflow_id: id, input: %{}}
      assert {:ok, _created} = Runtime.start_workflow_idempotent(input)
      message = "Workflow id #{id} already belongs to parent workflow null task null"

      assert {:error, ^message <> _} =
               Runtime.start_workflow_idempotent(
                 Map.merge(input, %{parent_workflow_id: "p", parent_workflow_task_id: "t"})
               )
    end
  end

  describe "get_workflow/2 and terminate_workflow/2" do
    test "read the store and refuse unknown IDs" do
      assert Runtime.get_workflow("unknown") == {:error, :not_found}
      assert Runtime.terminate_workflow("unknown", "r") == {:error, :not_found}
      assert WorkflowServer.whereis("unknown") == nil

      id = start_simple(%{"x" => 1})
      assert {:ok, %{tasks: []}} = Runtime.get_workflow(id, false)
    end

    test "terminating a terminated workflow is a no-op" do
      id = start_simple(%{"x" => 1})
      assert Runtime.terminate_workflow(id, "first") == :ok
      await_down(id)
      assert Runtime.terminate_workflow(id, "second") == :ok
      assert {:ok, %{reason_for_incompletion: "first"}} = Runtime.get_workflow(id)
      await_down(id)
    end
  end
end
