# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Decider.DoWhileReplayTest do
  @moduledoc """
  Runs `DO_WHILE` workflows through `Archon.Runtime.Step.run/3` (ADR 0014, slice 2e; ADR 0018,
  decision 10). No upstream server capture exists for `DO_WHILE`, so these check that decide and
  execute hand over to each other: the loop task is executed in the decide loop each time a body
  task finishes, schedules the next iteration and lets the task after it run once it completes.
  """

  use ExUnit.Case, async: true

  import Archon.StepReplay

  alias Archon.Domain.{Task, TaskDef, WorkflowDef, WorkflowTask}

  defp simple(ref, input \\ %{}) do
    %WorkflowTask{
      name: ref,
      task_reference_name: ref,
      type: "SIMPLE",
      input_parameters: input,
      task_definition: %TaskDef{name: ref, retry_count: 0}
    }
  end

  defp definition(loop) do
    %WorkflowDef{
      name: "archon_do_while",
      version: 1,
      schema_version: 2,
      tasks: [loop, simple("after", %{"loop" => "${loop.output}"})],
      output_parameters: %{"iterations" => "${loop.output.iteration}"}
    }
  end

  defp loop(fields) do
    struct!(
      %WorkflowTask{
        name: "loop",
        task_reference_name: "loop",
        type: "DO_WHILE",
        task_definition: %TaskDef{name: "loop", retry_count: 0, response_timeout_seconds: 0}
      },
      fields
    )
  end

  defp complete(workflow, ref, output, clock) do
    result = %{
      "workflowInstanceId" => workflow.workflow_id,
      "status" => "COMPLETED",
      "outputData" => output,
      "workerId" => "worker"
    }

    workflow
    |> poll(ref, clock)
    |> update(ref, %{"request" => %{"body" => result}}, clock)
  end

  defp summary(workflow),
    do: Enum.map(workflow.tasks, &{&1.reference_task_name, &1.status, &1.iteration})

  test "a counter loop runs its body until the condition is false, then the next task" do
    clock = clock()

    workflow =
      start(
        definition(loop(loop_over: [simple("a")], loop_condition: "$.loop['iteration'] < 2")),
        [workflow_id: "wf-counter", input: %{}],
        clock
      )

    assert summary(workflow) == [{"loop", :in_progress, 1}, {"a__1", :scheduled, 1}]

    workflow = complete(workflow, "a__1", %{"n" => 1}, clock)

    assert summary(workflow) == [
             {"loop", :in_progress, 2},
             {"a__1", :completed, 1},
             {"a__2", :scheduled, 2}
           ]

    workflow = complete(workflow, "a__2", %{"n" => 2}, clock)
    assert [%Task{status: :completed} = loop | _] = workflow.tasks

    assert loop.output_data == %{
             "1" => %{"a" => %{"n" => 1}},
             "2" => %{"a" => %{"n" => 2}},
             "iteration" => 2
           }

    assert [{"after", :scheduled, 0}] = workflow |> summary() |> Enum.drop(3)
    assert List.last(workflow.tasks).input_data == %{"loop" => loop.output_data}

    workflow = complete(workflow, "after", %{}, clock)
    assert {workflow.status, workflow.output} == {:completed, %{"iterations" => 2}}
  end

  test "a list loop hands each item to its body and keepLastN drops the old iterations" do
    clock = clock()

    loop =
      loop(
        items: "${workflow.input.items}",
        loop_over: [simple("a", %{"item" => "${loop.output.loopItem}"})],
        input_parameters: %{"keepLastN" => 1}
      )

    workflow =
      start(definition(loop), [workflow_id: "wf-list", input: %{"items" => ~w(x y z)}], clock)

    workflow =
      Enum.reduce(1..3, workflow, fn i, workflow ->
        task = Enum.find(workflow.tasks, &(&1.reference_task_name == "a__#{i}"))
        assert task.input_data == %{"item" => Enum.at(~w(x y z), i - 1)}
        complete(workflow, "a__#{i}", %{"seen" => task.input_data["item"]}, clock)
      end)

    assert summary(workflow) == [
             {"loop", :completed, 3},
             {"a__3", :completed, 3},
             {"after", :scheduled, 0}
           ]

    assert hd(workflow.tasks).output_data == %{
             "3" => %{"a" => %{"seen" => "z"}},
             "iteration" => 3,
             "loopIndex" => 2,
             "loopItem" => "z"
           }
  end

  test "an empty list completes the loop without running its body" do
    clock = clock()
    loop = loop(items: "${workflow.input.items}", loop_over: [simple("a")])
    workflow = start(definition(loop), [workflow_id: "wf-empty", input: %{"items" => []}], clock)

    assert summary(workflow) == [{"loop", :completed, 0}, {"after", :scheduled, 0}]
  end
end
