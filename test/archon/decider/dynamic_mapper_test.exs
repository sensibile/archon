# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/mapper/DynamicTaskMapperTest.java
# and ForkJoinDynamicTaskMapperTest.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests that schedule through
# Archon.Decider.tasks_to_be_scheduled/5 instead of a mocked DeciderService; mocked
# ParametersUtils and MetadataDAO results are replaced by inputs that resolve to them and the
# context's task_def_lookup; cases for the input forms and messages archon reads leniently added.

defmodule Archon.Decider.DynamicMapperTest do
  use ExUnit.Case, async: true

  alias Archon.Decider
  alias Archon.Decider.{Context, Outcome, SystemTasks, Termination}
  alias Archon.Domain.{SubWorkflowParams, Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}

  @now 1_800_000_000_000

  defp context(opts) do
    counter = :counters.new(1, [])

    Context.new(
      [
        now: @now,
        new_id: fn ->
          :counters.add(counter, 1, 1)
          "id-#{:counters.get(counter, 1)}"
        end,
        task_def_lookup: fn
          "missing" -> {:error, :not_found}
          name -> {:ok, %TaskDef{name: name, response_timeout_seconds: 7}}
        end
      ] ++ opts
    )
  end

  defp workflow(tasks, input, extra \\ []) do
    struct!(
      %Workflow{
        workflow_id: "wf",
        workflow_definition: %WorkflowDef{name: "wf", version: 2, tasks: tasks},
        input: input
      },
      extra
    )
  end

  defp schedule(workflow, wt, opts \\ []),
    do: Decider.tasks_to_be_scheduled(workflow, wt, 0, nil, context(opts))

  defp reason({:terminate, %Termination{reason: reason}}), do: reason

  describe "DYNAMIC" do
    defp dynamic(extra \\ []) do
      struct!(
        %WorkflowTask{
          name: "DynoTask",
          task_reference_name: "dyno",
          type: "DYNAMIC",
          dynamic_task_name_param: "dynamicTaskName",
          input_parameters: %{"dynamicTaskName" => "${workflow.input.name}", "x" => 1}
        },
        extra
      )
    end

    # DynamicTaskMapperTest#getMappedTasks
    test "schedules one task of the resolved name with the embedded task definition" do
      task_def = %TaskDef{name: "DynoTask", response_timeout_seconds: 30}
      wt = dynamic(task_definition: task_def)

      assert {:ok, [task]} = schedule(workflow([wt], %{"name" => "Resolved"}), wt)

      assert %Task{
               task_id: "id-1",
               task_type: "Resolved",
               task_def_name: "Resolved",
               reference_task_name: "dyno",
               status: :scheduled,
               response_timeout_seconds: 30,
               input_data: %{"dynamicTaskName" => "Resolved", "x" => 1}
             } = task

      # the changed workflow task (setName, setTaskDefinition)
      assert task.workflow_task == %{wt | name: "Resolved", task_definition: task_def}
      assert Decider.Mapper.changes_definition?("DYNAMIC")
    end

    # DynamicTaskMapperTest#getDynamicTaskName: String.valueOf of the value
    test "the name is the Java string of the input value" do
      wt = dynamic(task_definition: %TaskDef{name: "d"})
      assert {:ok, [%Task{task_type: "42"}]} = schedule(workflow([wt], %{"name" => 42}), wt)
    end

    # DynamicTaskMapperTest#getDynamicTaskNameNotAvailable
    test "a name that resolves to nothing terminates the workflow" do
      wt = dynamic(task_definition: %TaskDef{name: "d"})

      assert reason(schedule(workflow([wt], %{}), wt)) ==
               "Cannot map a dynamic task based on the parameter and input. " <>
                 "Parameter= dynamicTaskName, input= {dynamicTaskName=null, x=1}"
    end

    # DynamicTaskMapperTest#getDynamicTaskDefinition, getDynamicTaskDefinitionNull
    test "without an embedded definition the lookup's by the resolved name, else termination" do
      wt = dynamic()

      assert {:ok, [task]} = schedule(workflow([wt], %{"name" => "Found"}), wt)

      assert task.workflow_task.task_definition == %TaskDef{
               name: "Found",
               response_timeout_seconds: 7
             }

      assert task.response_timeout_seconds == 7

      assert reason(schedule(workflow([wt], %{"name" => "missing"}), wt)) ==
               "Invalid task specified.  Cannot find task by name missing in the task definitions"
    end

    test "the decide outcome writes the changed workflow task into the definition" do
      wt = dynamic(task_definition: %TaskDef{name: "DynoTask"})
      workflow = workflow([wt], %{"name" => "Resolved"})

      assert {:ok, %Outcome{} = outcome} = Decider.decide(workflow, context([]))
      assert [%Task{task_type: "Resolved"} = task] = outcome.tasks_to_be_scheduled
      assert outcome.changed_workflow_tasks == [task.workflow_task]
      assert [%WorkflowTask{name: "Resolved"}] = outcome.workflow.workflow_definition.tasks
    end

    test "a retry copy or a task already in the workflow does not change the definition" do
      wt = dynamic(task_definition: %TaskDef{name: "DynoTask"})
      changed = %{wt | name: "Other"}

      outcome = %Outcome{
        workflow: workflow([wt], %{}, tasks: [%Task{task_id: "t1"}]),
        tasks_to_be_scheduled: [
          %Task{task_id: "t1", reference_task_name: "dyno", workflow_task: changed},
          %Task{
            task_id: "t2",
            retried_task_id: "t0",
            reference_task_name: "dyno",
            workflow_task: changed
          }
        ]
      }

      assert Decider.change_definition(outcome) == outcome
    end
  end

  describe "FORK_JOIN_DYNAMIC" do
    defp join(extra \\ []),
      do: struct!(%WorkflowTask{name: "join", task_reference_name: "join", type: "JOIN"}, extra)

    defp fjd(input_parameters, extra \\ []) do
      struct!(
        %WorkflowTask{
          name: "fjd",
          task_reference_name: "fjd",
          type: "FORK_JOIN_DYNAMIC",
          input_parameters: input_parameters
        },
        extra
      )
    end

    defp param_form(extra \\ []) do
      fjd(
        %{
          "dynamicTasks" => "${workflow.input.tasks}",
          "dynamicTasksInput" => "${workflow.input.inputs}"
        },
        [
          dynamic_fork_tasks_param: "dynamicTasks",
          dynamic_fork_tasks_input_param_name: "dynamicTasksInput"
        ] ++
          extra
      )
    end

    defp branch(ref, type \\ "SIMPLE"),
      do: %{"name" => "w_#{ref}", "taskReferenceName" => ref, "type" => type}

    defp summary({:ok, tasks}),
      do: Enum.map(tasks, &{&1.reference_task_name, &1.task_type, &1.status})

    # ForkJoinDynamicTaskMapperTest#getMappedTasks, getDynamicForkTasksAndInput
    test "dynamicForkTasksParam: a FORK, each branch through its mapper and a JOIN on the last tasks" do
      wt = param_form()

      input = %{
        "tasks" => [branch("xdt1"), branch("xdt2")],
        "inputs" => %{"xdt1" => %{"k1" => "v1"}, "xdt2" => %{"k2" => "v2"}}
      }

      result = schedule(workflow([wt, join()], input), wt)

      assert summary(result) == [
               {"fjd", "FORK", :completed},
               {"xdt1", "w_xdt1", :scheduled},
               {"xdt2", "w_xdt2", :scheduled},
               {"join", "JOIN", :in_progress}
             ]

      {:ok, [fork, xdt1, xdt2, join_task]} = result
      assert fork.executed
      assert fork.input_data["forkedTasks"] == ["xdt1", "xdt2"]

      assert [%{"taskReferenceName" => "xdt1", "inputParameters" => %{"k1" => "v1"}} | _] =
               fork.input_data["forkedTaskDefs"]

      assert fork.input_data["dynamicTasksInput"] == input["inputs"]
      assert xdt1.input_data == %{"k1" => "v1"}
      assert xdt2.input_data == %{"k2" => "v2"}
      # metadataDAO.getTaskDef for a branch without a definition
      assert xdt1.workflow_task.task_definition.name == "w_xdt1"
      assert join_task.input_data == %{"joinOn" => ["xdt1", "xdt2"]}
      assert join_task.task_id == "id-4"
    end

    # ForkJoinDynamicTaskMapperTest#testJoinInputPreservation
    test "the JOIN keeps its own input parameters as they are" do
      wt = param_form()

      join =
        join(input_parameters: %{"existingParam1" => "value1", "expr" => "${workflow.input.x}"})

      {:ok, tasks} =
        schedule(workflow([wt, join], %{"tasks" => [branch("a")], "inputs" => %{}}), wt)

      assert List.last(tasks).input_data ==
               %{"existingParam1" => "value1", "expr" => "${workflow.input.x}", "joinOn" => ["a"]}
    end

    # ForkJoinDynamicTaskMapperTest#getDynamicForkJoinTasksAndInput
    test "the old dynamicForkJoinTasksParam form" do
      wt =
        fjd(%{"dynamic" => "${workflow.input.dynamic}"}, dynamic_fork_join_tasks_param: "dynamic")

      input = %{
        "dynamic" => %{
          "dynamicTasks" => [
            %{"taskName" => "w1", "referenceName" => "r1", "input" => %{"a" => 1}},
            %{
              "taskName" => "w2",
              "referenceName" => "r2",
              "input" => %{"a" => 2},
              "type" => "SIMPLE"
            }
          ]
        }
      }

      assert {:ok, [_fork, r1, r2, _join]} = schedule(workflow([wt, join()], input), wt)
      assert {r1.task_type, r1.input_data} == {"w1", %{"a" => 1}}
      assert {r2.task_type, r2.input_data} == {"w2", %{"a" => 2}}
    end

    # ForkJoinDynamicTaskMapperTest#getDynamicForkJoinTasksAndInputException
    test "the old form without a list terminates the workflow" do
      wt =
        fjd(%{"dynamic" => "${workflow.input.dynamic}"}, dynamic_fork_join_tasks_param: "dynamic")

      assert reason(schedule(workflow([wt, join()], %{}), wt)) ==
               "Dynamic tasks could not be created. The value of dynamic from task's input " <>
                 "{dynamic=null} has no dynamic tasks to be scheduled"
    end

    test "the old form whose task or input is not an object terminates it, a number name is looked up" do
      wt =
        fjd(%{"dynamic" => "${workflow.input.dynamic}"}, dynamic_fork_join_tasks_param: "dynamic")

      for tasks <- [[%{"taskName" => "w", "referenceName" => "r", "input" => "s"}], ["x"]] do
        assert reason(
                 schedule(workflow([wt, join()], %{"dynamic" => %{"dynamicTasks" => tasks}}), wt)
               ) =~
                 ~r/^Dynamic tasks could not be created. The value of dynamic from task's input /
      end

      input = %{"dynamic" => %{"dynamicTasks" => [%{"taskName" => 5, "referenceName" => "r"}]}}
      assert {:ok, [_fork, r, _join]} = schedule(workflow([wt, join()], input), wt)
      assert {r.task_type, r.workflow_task.task_definition.name} == {"5", "5"}
    end

    test "a null forkTaskInputs element is a branch with a null input" do
      wt = fjd(%{"forkTaskName" => "w", "forkTaskInputs" => [nil]})
      assert {:ok, [_fork, branch, _join]} = schedule(workflow([wt, join()], %{}), wt)
      assert branch.input_data == %{"input" => nil, "__index" => 0}
    end

    # ForkJoinDynamicTaskMapperTest#getDynamicForkTasksAndInputException
    test "inputs that are not a map terminate the workflow" do
      wt = param_form()

      assert reason(
               schedule(workflow([wt, join()], %{"tasks" => [branch("a")], "inputs" => 5}), wt)
             ) ==
               "Input to the dynamically forked tasks is not a map -> expecting a map of K,V  but found 5"
    end

    test "tasks that are not a list of workflow tasks, or lack a reference name, terminate it" do
      wt = param_form()

      for tasks <- [5, [%{"name" => "x"}], [nil]] do
        assert reason(schedule(workflow([wt, join()], %{"tasks" => tasks, "inputs" => %{}}), wt)) =~
                 ~r/^Input 'dynamicTasks' is invalid. Cannot deserialize a list of Workflow Tasks from '/
      end
    end

    test "a branch input that is not a map terminates it" do
      wt = param_form()
      input = %{"tasks" => [branch("a")], "inputs" => %{"a" => "x"}}

      assert reason(schedule(workflow([wt, join()], input), wt)) ==
               "Tasks could not be dynamically forked due to invalid input: x is not a map"
    end

    # ForkJoinDynamicTaskMapperTest#testDynamicTaskDuplicateTaskRefName
    test "a branch already in progress in the workflow terminates it" do
      wt = param_form()
      running = %Task{reference_task_name: "a", status: :in_progress}

      workflow =
        workflow([wt, join()], %{"tasks" => [branch("a")], "inputs" => %{}}, tasks: [running])

      assert reason(schedule(workflow, wt)) ==
               "No dynamic tasks could be created for the Workflow: wf.2/wf, Dynamic Fork Task: " <>
                 "w_a/a attempted to create a duplicate task reference name: a"
    end

    test "a definition whose next task is not a JOIN terminates it" do
      wt = param_form()

      assert reason(schedule(workflow([wt], %{"tasks" => [branch("a")], "inputs" => %{}}), wt)) ==
               "Dynamic join definition is not followed by a join task.  Check the workflow definition."
    end

    test "with the fork already in the workflow no branch is made again" do
      wt = param_form()
      fork = %Task{reference_task_name: "fjd", status: :completed}

      workflow =
        workflow([wt, join()], %{"tasks" => [branch("a")], "inputs" => %{}}, tasks: [fork])

      assert {:ok, [%Task{task_type: "JOIN", input_data: %{"joinOn" => []}}]} =
               schedule(workflow, wt)
    end

    # ForkJoinDynamicTaskMapperTest#testSimpleDynamicForkTaskReferenceNaming,
    # dynamicForkInputsRemainUnwrappedWhenMapsProvided
    test "forkTaskInputs: one branch per element named _<name>_<i>, with __index" do
      wt =
        fjd(%{
          "forkTaskName" => "my_task",
          "forkTaskInputs" => [%{"param1" => "value1"}, "plain"]
        })

      assert {:ok, [_fork, first, second, join_task]} = schedule(workflow([wt, join()], %{}), wt)
      assert {first.reference_task_name, first.task_type} == {"_my_task_0", "my_task"}
      assert first.input_data == %{"param1" => "value1", "__index" => 0}
      assert second.input_data == %{"input" => "plain", "__index" => 1}
      assert join_task.input_data["joinOn"] == ["_my_task_0", "_my_task_1"]
    end

    # ForkJoinDynamicTaskMapperTest#testNestedDynamicForkTaskReferenceNaming
    test "a workflow that already has a dynamic fork names the branches after the fork too" do
      wt = fjd(%{"forkTaskName" => "my_task", "forkTaskInputs" => [%{}, %{}]})

      other = %Task{
        reference_task_name: "other",
        status: :completed,
        workflow_task: %{wt | task_reference_name: "other"}
      }

      assert {:ok, [_fork, first, second, _join]} =
               schedule(workflow([wt, join()], %{}, tasks: [other]), wt)

      assert [first.reference_task_name, second.reference_task_name] ==
               ["_fjd_my_task_0", "_fjd_my_task_1"]
    end

    test "forkTaskType: a system type names the branch, the reference name otherwise, optional carried" do
      system_tasks =
        Map.put(SystemTasks.default(), "MY_SYSTEM", %SystemTasks.Spec{module: __MODULE__})

      wt = fjd(%{"forkTaskType" => "MY_SYSTEM", "forkTaskInputs" => [%{}]}, optional: true)

      assert {:ok, [_fork, branch, _join]} =
               schedule(workflow([wt, join()], %{}), wt, system_tasks: system_tasks)

      assert branch.reference_task_name == "_MY_SYSTEM_0"
      assert branch.workflow_task.optional

      wt = fjd(%{"forkTaskInputs" => [%{}]})
      assert {:ok, [_fork, branch, _join]} = schedule(workflow([wt, join()], %{}), wt)
      assert {branch.reference_task_name, branch.task_type} == {"_fjd_0", "fjd"}
    end

    test "forkTaskWorkflow: SUB_WORKFLOW branches of that workflow and version" do
      wt =
        fjd(%{
          "forkTaskName" => "child",
          "forkTaskWorkflow" => "child_wf",
          "forkTaskWorkflowVersion" => "3",
          "forkTaskInputs" => [%{"taskToDomain" => %{"*" => "d"}, "a" => 1}]
        })

      assert {:ok, [_fork, sub, _join]} = schedule(workflow([wt, join()], %{}), wt)
      assert sub.task_type == "SUB_WORKFLOW"
      assert sub.reference_task_name == "_child_0"

      assert sub.workflow_task.sub_workflow_param ==
               %SubWorkflowParams{name: "child_wf", version: 3, task_to_domain: %{"*" => "d"}}

      assert sub.input_data["subWorkflowVersion"] == 3
      assert sub.input_data["workflowInput"]["a"] == 1
    end

    test "a DYNAMIC branch shows its resolved name in the FORK input, not in the definition" do
      wt = param_form()

      dyn = %{
        "name" => "d",
        "taskReferenceName" => "d_ref",
        "type" => "DYNAMIC",
        "dynamicTaskNameParam" => "n",
        "inputParameters" => %{"n" => "resolved"}
      }

      workflow = workflow([wt, join()], %{"tasks" => [dyn], "inputs" => %{}})

      assert {:ok, outcome} = Decider.decide(workflow, context([]))
      [fork, branch, _join] = outcome.tasks_to_be_scheduled
      assert branch.task_type == "resolved"
      assert [%{"name" => "resolved"}] = fork.input_data["forkedTaskDefs"]
      assert outcome.changed_workflow_tasks == []
    end
  end
end
