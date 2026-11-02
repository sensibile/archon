# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/tasks/TestTerminate.java,
# core/src/test/.../execution/mapper/{HumanTaskMapperTest,SetVariableTaskMapperTest,NoopTaskMapperTest}.java,
# test-harness/src/test/groovy/.../integration/{SetVariableTaskSpec,ExclusiveJoinSpec}.groovy
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: the cases call the pure mappers and system tasks (ADR 0026, decision 3).

defmodule Archon.Decider.SyncSystemTasksTest do
  @moduledoc """
  The mappers and system tasks of `TERMINATE`, `SET_VARIABLE`, `NOOP`, `HUMAN` and
  `EXCLUSIVE_JOIN` (ADR 0026, decision 3), as upstream's unit tests and integration specs check
  them.
  """

  use ExUnit.Case, async: true

  alias Archon.Decider
  alias Archon.Decider.{Context, Mapper, SystemTask, SystemTasks}
  alias Archon.Decider.SystemTask.{ExclusiveJoin, SetVariable, Terminate}
  alias Archon.Domain.{Task, Workflow, WorkflowDef, WorkflowTask}

  @now 1_000_000

  defp context(opts \\ []),
    do: Context.new(Keyword.merge([now: @now, new_id: fn -> "t1" end], opts))

  defp workflow(fields \\ []) do
    struct!(
      %Workflow{
        workflow_id: "wf",
        status: :running,
        input: %{"status" => "COMPLETED", "value" => 7},
        variables: %{},
        workflow_definition: %WorkflowDef{name: "wf", version: 1}
      },
      fields
    )
  end

  defp map(wt, workflow \\ workflow()) do
    assert {:ok, tasks} = Decider.tasks_to_be_scheduled(workflow, wt, 0, nil, context())
    tasks
  end

  describe "the tables" do
    test "every type has its own mapper and a synchronous system task" do
      for type <- ~w(TERMINATE SET_VARIABLE NOOP HUMAN EXCLUSIVE_JOIN) do
        assert Mapper.mapped?(type)
        assert %SystemTasks.Spec{async?: false, module: module} = SystemTasks.default()[type]

        assert SystemTask in List.flatten(
                 Keyword.get_values(module.module_info(:attributes), :behaviour)
               )
      end

      # TaskType.isBuiltIn: EXCLUSIVE_JOIN is never retried; the others are.
      assert SystemTasks.built_in?("EXCLUSIVE_JOIN")
      refute Enum.any?(~w(TERMINATE SET_VARIABLE NOOP HUMAN), &SystemTasks.built_in?/1)
    end
  end

  describe "mappers" do
    test "TERMINATE: IN_PROGRESS with the resolved input and a start time" do
      wt = %WorkflowTask{
        name: "end",
        task_reference_name: "end",
        type: "TERMINATE",
        input_parameters: %{
          "terminationStatus" => "${workflow.input.status}",
          "id" => "${CPEWF_TASK_ID}"
        }
      }

      assert [%Task{} = task] = map(wt)

      assert %{
               task_type: "TERMINATE",
               task_def_name: "end",
               status: :in_progress,
               start_time: @now,
               input_data: %{"terminationStatus" => "COMPLETED", "id" => "t1"}
             } = task
    end

    test "SET_VARIABLE: IN_PROGRESS with the task input resolved without a task ID" do
      wt = %WorkflowTask{
        name: "set",
        task_reference_name: "set",
        type: "SET_VARIABLE",
        input_parameters: %{"v" => "${workflow.input.value}", "id" => "${CPEWF_TASK_ID}"}
      }

      assert [%Task{task_type: "SET_VARIABLE", status: :in_progress, start_time: @now} = task] =
               map(wt)

      assert task.input_data["v"] == 7
      refute task.input_data["id"] == "t1"
    end

    test "NOOP: IN_PROGRESS without input" do
      wt = %WorkflowTask{
        name: "noop",
        task_reference_name: "noop",
        type: "NOOP",
        input_parameters: %{"x" => 1}
      }

      assert [%Task{task_type: "NOOP", status: :in_progress, input_data: input}] = map(wt)
      assert input == %{}
    end

    test "HUMAN: IN_PROGRESS with the resolved input" do
      wt = %WorkflowTask{
        name: "human_task",
        task_reference_name: "human",
        type: "HUMAN",
        input_parameters: %{"v" => "${workflow.input.value}"}
      }

      assert [%Task{task_type: "HUMAN", status: :in_progress, input_data: %{"v" => 7}}] = map(wt)
    end

    test "EXCLUSIVE_JOIN: joinOn and defaultExclusiveJoinTask as input, named after the type" do
      wt = %WorkflowTask{
        name: "xjoin",
        task_reference_name: "xjoin",
        type: "EXCLUSIVE_JOIN",
        join_on: ["a", "b"],
        default_exclusive_join_task: ["c"]
      }

      assert [%Task{} = task] = map(wt)

      assert %{
               task_type: "EXCLUSIVE_JOIN",
               task_def_name: "EXCLUSIVE_JOIN",
               status: :in_progress,
               input_data: %{"joinOn" => ["a", "b"], "defaultExclusiveJoinTask" => ["c"]}
             } = task

      assert [%Task{input_data: %{"joinOn" => []} = input}] =
               map(%{wt | join_on: [], default_exclusive_join_task: nil})

      refute Map.has_key?(input, "defaultExclusiveJoinTask")
    end
  end

  describe "TERMINATE (TestTerminate)" do
    defp terminate(input), do: Terminate.execute(workflow(), %Task{input_data: input}, context())

    test "a status that is not valid, empty or missing fails the task and answers false" do
      for input <- [
            %{"terminationStatus" => "PAUSED"},
            %{"terminationStatus" => ""},
            %{"terminationStatus" => nil},
            %{"terminationStatus" => 5},
            %{}
          ] do
        assert %SystemTask.Result{changed?: false, task: task, workflow: nil} = terminate(input)

        assert %{
                 status: :failed,
                 reason_for_incompletion: "given termination status is not valid"
               } =
                 task
      end
    end

    test "a valid status completes the task with the workflow output" do
      for status <- ~w(COMPLETED FAILED TERMINATED) do
        result = terminate(%{"terminationStatus" => status, "workflowOutput" => %{"a" => 1}})
        assert %SystemTask.Result{changed?: true, task: %{status: :completed}} = result
        assert result.task.output_data == %{"a" => 1}
      end
    end

    test "a workflowOutput that is not a map is under output, a missing one is empty" do
      unresolved = terminate(%{"terminationStatus" => "COMPLETED", "workflowOutput" => "${x}"})
      assert unresolved.task.output_data == %{"output" => "${x}"}

      listed = terminate(%{"terminationStatus" => "FAILED", "workflowOutput" => [1, 2]})
      assert listed.task.output_data == %{"output" => [1, 2]}

      assert terminate(%{"terminationStatus" => "FAILED"}).task.output_data == %{}

      none = terminate(%{"terminationStatus" => "FAILED", "workflowOutput" => nil})
      assert none.task.output_data == %{}
    end
  end

  describe "SET_VARIABLE" do
    test "puts the input into the variables, overwriting, and completes" do
      workflow = workflow(variables: %{"a" => "init", "keep" => true})
      task = %Task{input_data: %{"a" => "over", "b" => 1}}

      assert %SystemTask.Result{changed?: true, task: %{status: :completed}, workflow: changed} =
               SetVariable.execute(workflow, task, context())

      assert changed.variables == %{"a" => "over", "b" => 1, "keep" => true}
    end

    test "an empty input completes and still answers the workflow (upstream updates it)" do
      workflow = workflow(variables: %{"a" => 1})

      assert %SystemTask.Result{task: %{status: :completed}, workflow: %{variables: %{"a" => 1}}} =
               SetVariable.execute(workflow, %Task{input_data: %{}}, context())
    end

    # SetVariableTaskSpec: a 2 KB threshold and `{"var": <2,056 characters>}`.
    test "variables over the threshold stay as they were and fail the task terminally" do
      value = String.duplicate("01234567", 1 + div(2 * 1024, 8))
      workflow = workflow(variables: %{})
      task = %Task{input_data: %{"var" => value}}
      context = context(max_workflow_variables_payload_kb: 2)

      assert %SystemTask.Result{changed?: true, task: failed, workflow: nil} =
               SetVariable.execute(workflow, task, context)

      assert failed.status == :failed_with_terminal_error

      assert failed.reason_for_incompletion ==
               "The variables payload size: #{17 + 2 * 1024 + 1} of workflow: wf is greater " <>
                 "than the permissible limit: 2 kilobytes"

      # The same value under the default threshold.
      assert %SystemTask.Result{task: %{status: :completed}} =
               SetVariable.execute(workflow, task, context())
    end

    test "the size counts the merged variables, so an existing key's old value does not count" do
      workflow = workflow(variables: %{"var" => String.duplicate("x", 4000)})
      task = %Task{input_data: %{"var" => "small"}}

      assert %SystemTask.Result{task: %{status: :completed}} =
               SetVariable.execute(workflow, task, context(max_workflow_variables_payload_kb: 2))
    end

    test "json_size/1 counts the bytes Jackson writes" do
      sizes = [
        {%{}, "{}"},
        {%{"a" => "init", "big" => ""}, ~s({"a":"init","big":""})},
        {[1, 2.5, nil, true, false], "[1,2.5,null,true,false]"},
        {%{"q" => ~s(a"b\\c/d)}, ~s({"q":"a\\"b\\\\c/d"})},
        {"\n\t\b\f\r", ~s("\\n\\t\\b\\f\\r")},
        {"\u0001\u001F", ~s("\\u0001\\u001F")},
        {"é한" <> <<0x2028::utf8>>, "\"é한" <> <<0x2028::utf8>> <> "\""},
        # Double#toString
        {1.0e7, "1.0E7"},
        {123_456_789.0, "1.23456789E8"},
        {0.001, "0.001"},
        {1.0e-4, "1.0E-4"},
        {-0.0, "-0.0"},
        {%{"n" => [%{"m" => []}]}, ~s({"n":[{"m":[]}]})}
      ]

      for {value, written} <- sizes,
          do: assert(SetVariable.json_size(value) == byte_size(written), inspect(value))
    end
  end

  describe "NOOP and HUMAN" do
    test "NOOP completes" do
      task = %Task{task_type: "NOOP", status: :in_progress}

      assert %SystemTask.Result{changed?: true, task: %{status: :completed}} =
               SystemTask.execute(workflow(), task, context())
    end

    test "HUMAN starts IN_PROGRESS and its execute changes nothing" do
      task = %Task{task_type: "HUMAN", status: :scheduled}

      assert %SystemTask.Result{changed?: true, task: %{status: :in_progress} = started} =
               SystemTask.start(workflow(), task, context())

      assert SystemTask.execute(workflow(), started, context()) ==
               %SystemTask.Result{changed?: false, task: started}
    end
  end

  describe "EXCLUSIVE_JOIN (ExclusiveJoinSpec)" do
    defp joined(ref, status, fields \\ []) do
      struct!(
        %Task{
          reference_task_name: ref,
          status: status,
          output_data: %{"from" => ref},
          workflow_task: %WorkflowTask{task_reference_name: ref}
        },
        fields
      )
    end

    defp xjoin(tasks, input, fields \\ []) do
      task =
        struct!(
          %Task{task_type: "EXCLUSIVE_JOIN", status: :in_progress, input_data: input},
          fields
        )

      ExclusiveJoin.execute(workflow(tasks: tasks), task, context())
    end

    @input %{"joinOn" => ["a", "b"], "defaultExclusiveJoinTask" => ["c"]}

    test "the first joined task that ran decides: its output when it completed" do
      assert %SystemTask.Result{changed?: true, task: task} =
               xjoin([joined("b", :completed)], @input)

      assert %{status: :completed, output_data: %{"from" => "b"}} = task
    end

    test "a skipped or missing joined task is passed over" do
      assert %{task: %{status: :completed, output_data: %{"from" => "b"}}} =
               xjoin([joined("a", :skipped), joined("b", :completed)], @input)
    end

    test "a joined task that is not terminal waits, unless a default task is terminal" do
      assert %SystemTask.Result{changed?: false, task: %{status: :in_progress}} =
               xjoin([joined("a", :in_progress)], @input)

      assert %{task: %{status: :completed, output_data: %{"from" => "c"}}} =
               xjoin([joined("a", :in_progress), joined("c", :completed)], @input)
    end

    test "the default task decides when no joined task ran (the default decision is run)" do
      assert %{changed?: false} = xjoin([joined("c", :in_progress)], @input)
      assert %{changed?: false} = xjoin([], @input)
      assert %{changed?: false} = xjoin([joined("c", :completed)], %{"joinOn" => ["a"]})

      assert %{task: %{status: :completed, output_data: %{"from" => "c"}}} =
               xjoin([joined("c", :completed)], @input)
    end

    test "a failed default task fails the join with its reason and a space" do
      assert %{task: task} =
               xjoin([joined("c", :failed, reason_for_incompletion: "boom")], @input)

      assert %{status: :failed, reason_for_incompletion: "boom "} = task

      assert %{task: %{reason_for_incompletion: "null "}} =
               xjoin([joined("c", :canceled)], @input)
    end

    test "a failed joined task fails the join with the failed joined tasks' reasons" do
      tasks = [
        joined("a", :failed, reason_for_incompletion: "first"),
        joined("b", :timed_out, reason_for_incompletion: "second")
      ]

      assert %{task: %{status: :failed, reason_for_incompletion: "first second"}} =
               xjoin(tasks, @input)

      assert %{task: %{reason_for_incompletion: "first null"}} =
               xjoin([hd(tasks), joined("b", :canceled)], @input)
    end

    # Upstream throws a NullPointerException when a joined reference never ran (ADR 0026,
    # decision 3): such a reference is not terminal, as upstream's Join has it.
    test "a failed permissive task waits for every joined task, a missing one counting as running" do
      permissive = %WorkflowTask{task_reference_name: "b", permissive: true}
      failed = joined("b", :failed, workflow_task: permissive)

      assert %{task: %{status: :completed, output_data: %{"from" => "b"}}} =
               xjoin([failed], @input)

      # A SKIPPED task is terminal.
      assert %{task: %{status: :failed, reason_for_incompletion: "null"}} =
               xjoin([joined("a", :skipped), failed], @input)

      assert %{task: %{status: :failed, reason_for_incompletion: "null"}} =
               xjoin([joined("a", :completed), failed], %{"joinOn" => ["b", "a"]})
    end

    test "the latest task of a reference counts, with the iteration suffix inside a loop" do
      tasks = [joined("a", :failed), joined("a", :completed, output_data: %{"try" => 2})]
      assert %{task: %{status: :completed, output_data: %{"try" => 2}}} = xjoin(tasks, @input)

      looped = [joined("a__1", :completed), joined("a__2", :in_progress)]
      loop = [iteration: 2]

      assert %{changed?: false} = xjoin(looped, %{"joinOn" => ["a"]}, loop)

      assert %{task: %{output_data: %{"from" => "a__1"}}} =
               xjoin(looped, %{"joinOn" => ["a"]}, Keyword.put(loop, :iteration, 1))
    end
  end
end
