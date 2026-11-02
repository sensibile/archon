# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Domain.WorkflowTaskReplaceTest do
  @moduledoc """
  `WorkflowDef.replace_task/2`: a workflow task a mapper changed takes the place of the
  definition's task with its reference name, nested ones included (ADR 0026, decision 4).
  """

  use ExUnit.Case, async: true

  alias Archon.Domain.{WorkflowDef, WorkflowTask}

  defp wt(ref, type \\ "SIMPLE", fields \\ []),
    do: struct!(%WorkflowTask{name: ref, task_reference_name: ref, type: type}, fields)

  defp definition do
    %WorkflowDef{
      name: "wf",
      tasks: [
        wt("top"),
        wt("switch", "SWITCH",
          decision_cases: %{"a" => [wt("in_a")], "b" => [wt("in_b")]},
          default_case: [wt("in_default")]
        ),
        wt("fork", "FORK_JOIN", fork_tasks: [[wt("branch_1")], [wt("branch_2"), nil]]),
        wt("loop", "DO_WHILE", loop_over: [wt("in_loop")]),
        wt("last")
      ]
    }
  end

  test "replaces a top-level or nested task by reference name" do
    for ref <- ~w(top in_a in_b in_default branch_1 branch_2 in_loop last) do
      changed = wt(ref, "DYNAMIC", name: "changed")
      replaced = WorkflowDef.replace_task(definition(), changed)

      assert WorkflowDef.task_by_ref_name(replaced, ref) == changed

      # The tasks holding no others are the same; the ones holding the changed task hold it.
      others =
        for %WorkflowTask{type: "SIMPLE"} = task <- WorkflowDef.collect_tasks(definition()),
            task.task_reference_name != ref,
            do: task

      for task <- others,
          do: assert(WorkflowDef.task_by_ref_name(replaced, task.task_reference_name) == task)
    end
  end

  test "an unknown reference name leaves the definition as it is" do
    assert WorkflowDef.replace_task(definition(), wt("missing")) == definition()
  end

  test "the first task with the name, in collect_tasks order, is the one replaced" do
    twice = %WorkflowDef{name: "wf", tasks: [wt("x"), wt("x", "SIMPLE", name: "second")]}
    changed = wt("x", "DYNAMIC")

    assert WorkflowDef.replace_task(twice, changed).tasks ==
             [changed, wt("x", "SIMPLE", name: "second")]
  end
end
