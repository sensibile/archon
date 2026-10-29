# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/mapper/DoWhileTaskMapperTest.java
# and core/.../execution/tasks/DoWhileTest.java at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests against the pure mapper and execute; calls of
# the private helpers (removeIterations, injectLoopVariables, evaluateCondition) go through
# execute and its result; scripts run on the archon_js pool (ADR 0015). Not ported: the DAO
# failure case (deleting is the runtime's), the Java array case (JSON has lists only) and
# testListIteration_VerifiesLOCReduction, which repeats isListIteration cases (ADR 0014).

defmodule Archon.Decider.DoWhileTest do
  use ExUnit.Case, async: true

  alias Archon.Decider
  alias Archon.Decider.{Context, Termination}
  alias Archon.Decider.SystemTask.DoWhile
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}

  @now 1_800_000_000_000

  defp context(opts \\ []) do
    counter = :counters.new(1, [])

    Context.new(
      [
        now: @now,
        new_id: fn ->
          :counters.add(counter, 1, 1)
          "id-#{:counters.get(counter, 1)}"
        end
      ] ++ opts
    )
  end

  # DoWhileTest#createWorkflowWithDef
  defp workflow(tasks, input \\ %{}) do
    %Workflow{
      workflow_id: "test-workflow-1",
      workflow_definition: %WorkflowDef{name: "test-workflow", version: 1},
      input: input,
      tasks: tasks
    }
  end

  defp simple(ref), do: %WorkflowTask{name: ref, task_reference_name: ref, type: "SIMPLE"}

  # DoWhileTest#createDoWhileTask: five SIMPLE loop tasks and keepLastN 3.
  defp loop_wt(fields \\ []) do
    struct!(
      %WorkflowTask{
        name: "doWhileTask",
        task_reference_name: "doWhileTask",
        type: "DO_WHILE",
        loop_over: Enum.map(1..5, &simple("loopTask#{&1}")),
        input_parameters: %{"keepLastN" => 3}
      },
      fields
    )
  end

  defp loop_task(wt, iteration, output \\ %{}) do
    %Task{
      task_id: "do-while-task",
      reference_task_name: wt.task_reference_name,
      task_type: "DO_WHILE",
      status: :in_progress,
      iteration: iteration,
      workflow_task: wt,
      output_data: output
    }
  end

  defp body_task(ref, iteration, status \\ :completed, fields \\ []) do
    struct!(
      %Task{
        task_id: "#{ref}-#{iteration}",
        reference_task_name: "#{ref}__#{iteration}",
        task_type: "SIMPLE",
        status: status,
        iteration: iteration,
        workflow_task: simple(ref)
      },
      fields
    )
  end

  # DoWhileTest#createWorkflowWithIterations: the loop task and `per` completed tasks for each
  # iteration up to `iterations`, the loop task at the last one.
  defp iterations(iterations, per, wt) do
    loop = loop_task(wt, iterations)

    tasks =
      for i <- 1..iterations,
          n <- 1..per,
          do: body_task("loopTask#{n}", i, :completed, task_id: "task-#{i}-#{n}")

    {workflow([loop | tasks]), loop}
  end

  defp execute(workflow, loop, opts \\ []) do
    assert {:ok, %DoWhile{} = result} = DoWhile.execute(workflow, loop, context(opts))
    result
  end

  describe "mapper" do
    defp mapper_wt do
      %WorkflowTask{
        type: "DO_WHILE",
        task_reference_name: "Test",
        input_parameters: %{"value" => "${workflow.input.foo}"},
        loop_over: [simple("task1"), simple("task2")],
        loop_condition: "if ($.second_task + $.first_task > 10) { false; } else { true; }",
        task_definition: %TaskDef{}
      }
    end

    # DoWhileTaskMapperTest#getMappedTasks
    test "maps one in-progress DO_WHILE task with resolved input and no body task" do
      wt = mapper_wt()

      assert {:ok, [task]} =
               Decider.tasks_to_be_scheduled(
                 workflow([], %{"foo" => "bar"}),
                 wt,
                 0,
                 nil,
                 context()
               )

      assert {task.task_type, task.status, task.input_data} ==
               {"DO_WHILE", :in_progress, %{"value" => "bar"}}

      assert {task.start_time, task.scheduled_time, task.iteration} == {@now, @now, 0}
    end

    # DoWhileTaskMapperTest#shouldNotScheduleCompletedTask: a completed body task named like a
    # loopOver task is not the loop task.
    test "a completed task with another reference name does not stop the mapping" do
      wf = workflow([%Task{reference_task_name: "task1", status: :completed}], %{"foo" => "bar"})
      assert {:ok, [%Task{}]} = Decider.tasks_to_be_scheduled(wf, mapper_wt(), 0, nil, context())
    end

    test "a terminal loop task with the reference name is not scheduled again" do
      done = %Task{reference_task_name: "Test", task_type: "DO_WHILE", status: :completed}
      wf = workflow([done], %{"foo" => "bar"})
      assert {:ok, []} = Decider.tasks_to_be_scheduled(wf, mapper_wt(), 0, nil, context())
    end

    test "the task definition falls back to the context's task_defs, then to defaults" do
      wt = %{mapper_wt() | name: "loopDef", task_definition: nil}
      task_defs = %{"loopDef" => %TaskDef{name: "loopDef", rate_limit_per_frequency: 7}}

      assert {:ok, [%Task{rate_limit_per_frequency: 7}]} =
               Decider.tasks_to_be_scheduled(
                 workflow([]),
                 wt,
                 2,
                 nil,
                 context(task_defs: task_defs)
               )

      assert {:ok, [%Task{rate_limit_per_frequency: 0, retry_count: 2}]} =
               Decider.tasks_to_be_scheduled(workflow([]), wt, 2, nil, context())
    end
  end

  describe "keepLastN" do
    # DoWhileTest#testRemoveIterations_* through execute, which removes the old iterations.
    for {name, iterations, per, keep, removed} <- [
          {"WithKeepLastN_RemovesOldIterations", 10, 3, 3, 21},
          {"BelowThreshold_RemovesNothing", 3, 3, 5, 0},
          {"ExactBoundary_RemovesNothing", 5, 3, 5, 0},
          {"FirstIteration_RemovesNothing", 1, 3, 3, 0},
          {"KeepLastOne_RemovesAllButLast", 10, 3, 1, 27},
          {"WithMultipleTasksPerIteration", 5, 5, 2, 15}
        ] do
      test "testRemoveIterations_#{name}" do
        wt = loop_wt(input_parameters: %{"keepLastN" => unquote(keep)})
        {wf, loop} = iterations(unquote(iterations), unquote(per), wt)
        assert length(execute(wf, loop).removed_task_ids) == unquote(removed)
      end
    end

    # DoWhileTest#testRemoveIterations_DoesNotRemoveDoWhileTaskItself,
    # #testRemoveIterations_OnlyRemovesTasksFromOldIterations and
    # #testRemoveIterations_VerifiesCorrectTaskIdsRemoved
    test "removes exactly the body tasks of the dropped iterations" do
      {wf, loop} = iterations(5, 3, loop_wt(input_parameters: %{"keepLastN" => 2}))
      removed = execute(wf, loop).removed_task_ids

      assert Enum.sort(removed) ==
               Enum.sort(for i <- 1..3, n <- 1..3, do: "task-#{i}-#{n}")

      refute "do-while-task" in removed

      {wf, loop} = iterations(4, 2, loop_wt(input_parameters: %{"keepLastN" => 2}))

      assert MapSet.new(execute(wf, loop).removed_task_ids) ==
               MapSet.new(["task-1-1", "task-1-2", "task-2-1", "task-2-2"])
    end

    # DoWhileTest#testRemoveIterations_HandlesEmptyWorkflow
    test "a loop without body tasks removes nothing" do
      loop = loop_task(loop_wt(), 5)
      assert execute(workflow([loop]), loop).removed_task_ids == []
    end

    # DoWhileTest#testKeepLastN_OutputCleanup_RemovesCorrectKeys and #..._RemovesMultipleKeys
    test "drops the output keys of the iterations it no longer keeps" do
      for {iteration, kept} <- [{3, ["2", "3"]}, {5, ["4", "5"]}] do
        wt =
          loop_wt(
            items: "${workflow.input.items}",
            loop_over: [simple("t1")],
            input_parameters: %{"keepLastN" => 2}
          )

        earlier = Map.new(1..(iteration - 1), &{"#{&1}", %{"t1" => "r#{&1}"}})
        loop = loop_task(wt, iteration, earlier)
        wf = workflow([loop, body_task("t1", iteration)], %{"items" => ~w(a b c d e f)})

        keys = execute(wf, loop).task.output_data |> Map.keys() |> Enum.filter(&(&1 =~ ~r/^\d+$/))
        assert Enum.sort(keys) == kept
      end
    end

    test "a keepLastN that is not an int fails the task, where upstream's cast throws" do
      for keep <- ["2", 2.0, 2_147_483_648] do
        wt = loop_wt(loop_over: [simple("t1")], input_parameters: %{"keepLastN" => keep})
        loop = loop_task(wt, 1)
        result = execute(workflow([loop, body_task("t1", 1)]), loop)

        assert {result.changed?, result.task.status} == {true, :failed_with_terminal_error}
        assert result.task.reason_for_incompletion =~ "keepLastN must be an int, got: "
      end
    end
  end

  describe "iterations" do
    defp counter_wt(condition) do
      loop_wt(
        task_reference_name: "loop",
        loop_over: [simple("a"), simple("b")],
        loop_condition: condition,
        input_parameters: %{}
      )
    end

    test "the first call starts iteration 1 with the first loopOver task" do
      wt = counter_wt("$.loop['iteration'] < 2")
      loop = loop_task(wt, 0)
      result = execute(workflow([loop]), loop)

      assert {result.changed?, result.task.iteration, result.task.output_data} ==
               {true, 1, %{"iteration" => 1}}

      assert [%Task{reference_task_name: "a__1", iteration: 1, status: :scheduled}] =
               result.tasks_to_be_scheduled
    end

    test "an incomplete iteration changes nothing but stores the outputs so far" do
      wt = counter_wt("$.loop['iteration'] < 2")
      loop = loop_task(wt, 1, %{"iteration" => 1})

      a = body_task("a", 1, :completed, output_data: %{"x" => 1})
      result = execute(workflow([loop, a]), loop)
      assert {result.changed?, result.tasks_to_be_scheduled} == {false, []}
      assert result.task.output_data["1"] == %{"a" => %{"x" => 1}}

      b = body_task("b", 1, :in_progress)
      assert %DoWhile{changed?: false} = execute(workflow([loop, a, b]), loop)
    end

    test "a true condition starts the next iteration, a false one completes the loop" do
      wt = counter_wt("$.loop['iteration'] < 2")
      tasks = [body_task("a", 1, :completed, output_data: %{"x" => 1}), body_task("b", 1)]
      loop = loop_task(wt, 1, %{"iteration" => 1})
      result = execute(workflow([loop | tasks]), loop)

      assert {result.task.iteration, result.task.status} == {2, :in_progress}

      assert result.task.output_data == %{
               "iteration" => 2,
               "1" => %{"a" => %{"x" => 1}, "b" => %{}}
             }

      assert [%Task{reference_task_name: "a__2", iteration: 2}] = result.tasks_to_be_scheduled

      tasks = tasks ++ [body_task("a", 2), body_task("b", 2)]
      loop = loop_task(wt, 2, result.task.output_data)
      result = execute(workflow([loop | tasks]), loop)
      assert {result.changed?, result.task.status, result.task.iteration} == {true, :completed, 2}
      assert Map.keys(result.task.output_data) |> Enum.sort() == ["1", "2", "iteration"]
    end

    test "the next iteration is mapped with the updated loop output and the loop's retry count" do
      wt =
        loop_wt(
          task_reference_name: "loop",
          loop_over: [
            %{simple("a") | input_parameters: %{"i" => "${loop.output.iteration}"}}
          ],
          loop_condition: "true",
          input_parameters: %{}
        )

      loop = %{loop_task(wt, 1, %{"iteration" => 1}) | retry_count: 2}
      result = execute(workflow([loop, body_task("a", 1)]), loop)

      assert [%Task{input_data: %{"i" => 2}, retry_count: 2}] = result.tasks_to_be_scheduled
    end

    test "the condition sees the input parameters, the loop output and the latest body outputs" do
      wt = %{
        counter_wt("$.limit == 3 && $.loop['1'].a.x == 1 && $.a.x == 1 && $.b.y == 2")
        | input_parameters: %{"limit" => "${workflow.input.limit}"}
      }

      tasks = [
        body_task("a", 1, :completed, output_data: %{"x" => 1}),
        body_task("b", 1, :completed, output_data: %{"y" => 2})
      ]

      loop = loop_task(wt, 1, %{"iteration" => 1})

      assert %DoWhile{task: %Task{iteration: 2}} =
               execute(workflow([loop | tasks], %{"limit" => 3}), loop)
    end

    test "only the latest retry of each body task counts" do
      wt = counter_wt("false")

      tasks = [
        body_task("a", 1, :failed, task_id: "a-1-0", reason_for_incompletion: "boom"),
        body_task("b", 1),
        body_task("a", 1, :completed,
          task_id: "a-1-1",
          retry_count: 1,
          output_data: %{"ok" => true}
        )
      ]

      loop = loop_task(wt, 1, %{"iteration" => 1})
      result = execute(workflow([loop | tasks]), loop)

      assert result.task.status == :completed
      assert result.task.output_data["1"]["a"] == %{"ok" => true}
    end

    test "a failed body task fails the loop with its reason; the outputs stop there" do
      wt = counter_wt("true")

      tasks = [
        body_task("a", 1, :failed, reason_for_incompletion: "boom", output_data: %{"e" => 1}),
        body_task("b", 1, :completed, output_data: %{"y" => 2})
      ]

      loop = loop_task(wt, 1, %{"iteration" => 1})
      result = execute(workflow([loop | tasks]), loop)

      assert {result.changed?, result.task.status, result.task.reason_for_incompletion} ==
               {true, :failed, "boom "}

      assert result.task.output_data["1"] == %{"a" => %{"e" => 1}}

      tasks = [body_task("a", 1, :timed_out)]

      assert %DoWhile{task: %Task{reason_for_incompletion: "null "}} =
               execute(workflow([loop | tasks]), loop)
    end

    test "a condition that does not evaluate fails the loop with FAILED_WITH_TERMINAL_ERROR" do
      wt = counter_wt("$.nothing.here")
      loop = loop_task(wt, 1, %{"iteration" => 1})
      result = execute(workflow([loop, body_task("a", 1), body_task("b", 1)]), loop)

      assert result.task.status == :failed_with_terminal_error

      assert result.task.reason_for_incompletion =~
               ~r/^Unable to evaluate condition \$\.nothing\.here, exception Error evaluating the script `/
    end

    test "without a loopCondition a counter loop completes after one iteration" do
      wt = counter_wt(nil)
      loop = loop_task(wt, 1, %{"iteration" => 1})
      result = execute(workflow([loop, body_task("a", 1), body_task("b", 1)]), loop)
      assert result.task.status == :completed
    end

    test "a termination while mapping the next iteration ends the decide" do
      wt = %{
        counter_wt("true")
        | loop_over: [%WorkflowTask{name: "nope", task_reference_name: "x", type: "CUSTOM"}]
      }

      loop = loop_task(wt, 0)

      assert {:terminate, %Termination{reason: "Invalid task specified." <> _}} =
               DoWhile.execute(workflow([loop]), loop, context())
    end

    test "an empty loopOver fails the task instead of looping forever" do
      wt = %{counter_wt("true") | loop_over: [nil]}
      loop = loop_task(wt, 0)
      result = execute(workflow([loop]), loop)

      assert {result.task.status, result.task.reason_for_incompletion} ==
               {:failed_with_terminal_error, "DO_WHILE task loop has no loopOver tasks"}
    end
  end

  # DoWhileTest#testExecute_SwitchWithInlineTask_*: a terminal task whose successor inside the
  # body is not scheduled yet keeps the iteration open.
  describe "nested body" do
    defp switch_loop do
      switch = %WorkflowTask{
        task_reference_name: "switchTask",
        type: "SWITCH",
        evaluator_type: "value-param",
        expression: "case",
        default_case: [
          simple("task1"),
          %WorkflowTask{task_reference_name: "inline_task", type: "INLINE"},
          simple("task2")
        ]
      }

      wt = %WorkflowTask{
        task_reference_name: "loopTask",
        type: "DO_WHILE",
        loop_over: [switch],
        loop_condition: "$.loopTask['iteration'] < 2"
      }

      loop = %{loop_task(wt, 1, %{"iteration" => 1}) | task_id: "dw-task-id"}

      tasks = [
        %{
          body_task("switchTask", 1)
          | task_type: "SWITCH",
            input_data: %{"hasChildren" => "true"}
        },
        body_task("task1", 1),
        %{body_task("inline_task", 1) | task_type: "INLINE"}
      ]

      {loop, tasks}
    end

    test "testExecute_SwitchWithInlineTask_DoesNotAdvanceIterationUntilSuccessorScheduled" do
      {loop, tasks} = switch_loop()
      result = execute(workflow([loop | tasks]), loop)

      assert {result.changed?, result.task.iteration, result.tasks_to_be_scheduled} ==
               {false, 1, []}
    end

    test "testExecute_SwitchWithInlineTask_AdvancesIterationOnceAllCaseTasksComplete" do
      {loop, tasks} = switch_loop()
      result = execute(workflow([loop | tasks] ++ [body_task("task2", 1)]), loop)

      assert {result.changed?, result.task.iteration} == {true, 2}

      assert ["switchTask__2" | _] =
               Enum.map(result.tasks_to_be_scheduled, & &1.reference_task_name)
    end
  end

  describe "list iteration" do
    defp list_wt(fields) do
      loop_wt(Keyword.merge([loop_over: [simple("t1")], input_parameters: %{}], fields))
    end

    defp items(wt, input), do: DoWhile.items(workflow([], input), loop_task(wt, 0))

    # DoWhileTest#testIsListIteration_*
    test "isListIteration" do
      assert DoWhile.list_iteration?(loop_task(list_wt(items: "${workflow.input.myList}"), 0))
      refute DoWhile.list_iteration?(loop_task(list_wt([]), 0))
      refute DoWhile.list_iteration?(loop_task(list_wt(items: "   "), 0))

      orkes = list_wt(input_parameters: %{"_items" => "${workflow.input.myList}"})
      assert DoWhile.list_iteration?(loop_task(orkes, 0))
      assert DoWhile.list_iteration?(loop_task(list_wt(input_parameters: %{"_items" => []}), 0))
      refute DoWhile.list_iteration?(loop_task(list_wt(input_parameters: %{"_items" => " "}), 0))
      refute DoWhile.list_iteration?(loop_task(list_wt(input_parameters: %{"_items" => nil}), 0))
      refute DoWhile.list_iteration?(loop_task(list_wt(input_parameters: %{"_items" => %{}}), 0))
    end

    # DoWhileTest#testEvaluateItemsList_*, #testItemsPriority_OSSFieldOverOrkesParameter
    test "evaluateItemsList" do
      list = ~w(item1 item2 item3)
      assert items(list_wt(items: "${workflow.input.myList}"), %{"myList" => list}) == list
      assert items(list_wt(items: "${workflow.input.myList}"), %{"myList" => []}) == []
      assert items(list_wt(items: nil), %{}) == []

      orkes = list_wt(input_parameters: %{"_items" => "${workflow.input.myList}"})
      assert items(orkes, %{"myList" => list}) == list

      both = %{orkes | items: "${workflow.input.ossList}"}
      assert items(both, %{"ossList" => ~w(oss1 oss2), "myList" => list}) == ~w(oss1 oss2)

      # items that resolve to null fall back to _items
      assert items(both, %{"myList" => list}) == list

      direct = list_wt(input_parameters: %{"_items" => ~w(direct1 direct2 direct3)})
      assert items(direct, %{}) == ~w(direct1 direct2 direct3)

      assert items(list_wt(items: "${workflow.input.one}"), %{"one" => %{"k" => 1}}) == [
               %{"k" => 1}
             ]
    end

    # DoWhileTest#testExecute_NonEmptyItemsList_SchedulesFirstIteration and
    # #testInjectLoopVariables_FirstIteration
    test "a non-empty list starts iteration 1 with loopIndex 0 and the first item" do
      wt = list_wt(items: "${workflow.input.itemList}")
      loop = loop_task(wt, 0)
      result = execute(workflow([loop], %{"itemList" => [10, 20, 30]}), loop)

      assert {result.changed?, result.task.status, result.task.iteration} ==
               {true, :in_progress, 1}

      assert result.task.output_data == %{"iteration" => 1, "loopIndex" => 0, "loopItem" => 10}
      assert [%Task{reference_task_name: "t1__1"}] = result.tasks_to_be_scheduled
    end

    # DoWhileTest#testExecute_EmptyItemsList_* (items and _items)
    test "an empty list completes at once with iteration 0" do
      for fields <- [
            [items: "${workflow.input.itemList}"],
            [input_parameters: %{"_items" => "${workflow.input.itemList}"}]
          ] do
        loop = loop_task(list_wt(fields), 0)
        result = execute(workflow([loop], %{"itemList" => []}), loop)

        assert {result.changed?, result.task.status, result.task.output_data} ==
                 {true, :completed, %{"iteration" => 0}}

        assert result.tasks_to_be_scheduled == []
      end
    end

    # One iteration of a list loop, the loop task at `iteration` with its body task done.
    defp list_step(wt, iteration, input) do
      loop = loop_task(wt, iteration, %{"iteration" => iteration})
      execute(workflow([loop, body_task("t1", iteration)], input), loop)
    end

    # DoWhileTest#testInjectLoopVariables_InjectsCorrectValues and #..._WithOrkesItemsParameter
    test "the next iteration gets the next loopIndex and loopItem" do
      for {wt, input} <- [
            {list_wt(items: "${workflow.input.fruits}"), %{"fruits" => ~w(apple banana cherry)}},
            {list_wt(input_parameters: %{"_items" => "${workflow.input.items}"}),
             %{"items" => ~w(orkes-a orkes-b orkes-c)}}
          ] do
        result = list_step(wt, 1, input)
        assert result.task.output_data["loopIndex"] == 1
        assert result.task.output_data["loopItem"] == Enum.at(hd(Map.values(input)), 1)
      end
    end

    # DoWhileTest#testInjectLoopVariables_DoesNothingForCounterBased
    test "a counter loop gets no loopIndex or loopItem" do
      wt = %{list_wt([]) | loop_condition: "true"}
      result = list_step(wt, 1, %{})
      refute Map.has_key?(result.task.output_data, "loopIndex")
      refute Map.has_key?(result.task.output_data, "loopItem")
    end

    defp continues?(wt, iteration, input) do
      case list_step(wt, iteration, input).task do
        %Task{status: :in_progress, iteration: next} when next == iteration + 1 -> true
        %Task{status: :completed} -> false
      end
    end

    # DoWhileTest#testEvaluateCondition_ListIteration_ContinuesUntilEnd,
    # #testListIteration_WithSingleItem_WorksCorrectly and
    # #testListIteration_ExceedsListSize_StopsGracefully
    test "without a condition the loop continues until the last item" do
      wt = list_wt(items: "${workflow.input.items}")
      input = %{"items" => ~w(a b c)}
      assert Enum.map([1, 2, 3, 5], &continues?(wt, &1, input)) == [true, true, false, false]
      refute continues?(wt, 1, %{"items" => ["single-item"]})
    end

    # DoWhileTest#testEvaluateCondition_ListIteration_WithCustomCondition, #..._WithComplexObjects
    # and #..._WithLoopIndex
    test "a condition is evaluated with loopIndex and loopItem, and ends the loop early" do
      numbers = list_wt(items: "${workflow.input.numbers}", loop_condition: "$.loopItem < 15")
      input = %{"numbers" => [5, 10, 15, 20]}
      assert Enum.map(1..3, &continues?(numbers, &1, input)) == [true, true, false]

      objects =
        list_wt(items: "${workflow.input.tasks}", loop_condition: "$.loopItem.status != 'FAILED'")

      input = %{
        "tasks" => [
          %{"id" => 1, "status" => "PENDING"},
          %{"id" => 2, "status" => "ACTIVE"},
          %{"id" => 3, "status" => "FAILED"}
        ]
      }

      assert Enum.map(1..3, &continues?(objects, &1, input)) == [true, true, false]

      index = list_wt(items: "${workflow.input.items}", loop_condition: "$.loopIndex < 2")

      assert Enum.map(1..3, &continues?(index, &1, %{"items" => ~w(a b c d e)})) == [
               true,
               true,
               false
             ]
    end

    # DoWhileTest#testEvaluateCondition_CounterBased_BackwardCompatibility
    test "a counter condition reads the loop task's own output" do
      wt = %{list_wt([]) | loop_condition: "$.doWhileTask.iteration < 3"}
      assert continues?(wt, 1, %{})
      refute continues?(wt, 3, %{})
    end

    # DoWhileTest#testListIteration_WithKeepLastN_WorksTogether
    test "list iteration and keepLastN work together" do
      wt =
        loop_wt(
          items: "${workflow.input.items}",
          loop_over: Enum.map(1..3, &simple("loopTask#{&1}")),
          input_parameters: %{"keepLastN" => 3}
        )

      {wf, loop} = iterations(2, 3, wt)
      wf = %{wf | input: %{"items" => ~w(item1 item2 item3 item4 item5)}}
      result = execute(wf, loop)

      assert {result.task.output_data["loopIndex"], result.task.output_data["loopItem"]} ==
               {2, "item3"}

      {wf, loop} = iterations(10, 3, wt)
      wf = %{wf | input: %{"items" => ~w(item1 item2 item3 item4 item5)}}
      result = execute(wf, loop)
      assert length(result.removed_task_ids) == 21
      assert result.task.status == :completed
      assert length(DoWhile.items(wf, loop)) == 5
    end
  end
end
