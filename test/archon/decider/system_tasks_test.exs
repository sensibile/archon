# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Decider.SystemTasksTest do
  @moduledoc """
  The two tables and the Decider context's injected functions (ADR 0026, decision 2).
  """

  use ExUnit.Case, async: true

  alias Archon.Decider
  alias Archon.Decider.{Context, Mapper, Outcome, SystemTasks}
  alias Archon.Domain.{Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}
  alias Archon.Runtime.Step.Env
  alias Archon.Script

  describe "the system task table" do
    test "registers the system tasks Archon runs, keyed by the task's type" do
      registry = SystemTasks.default()

      # The MVP types; each Phase 7 slice's own tests check the lines it adds (ADR 0026).
      for type <- ~w(DECISION DO_WHILE FORK JOIN SUB_WORKFLOW SWITCH WAIT),
          do: assert(SystemTasks.system_task?(registry, type), type)

      # FORK_JOIN is the workflow task's type; its task's is FORK.
      refute SystemTasks.system_task?(registry, "FORK_JOIN")
      assert SystemTasks.system_task?(registry, "FORK")
    end

    test "isAsync, isStartIdempotent and isAsyncComplete as the classes answer them" do
      registry = SystemTasks.default()

      assert Enum.filter(Map.keys(registry), &SystemTasks.async?(registry, &1)) |> Enum.sort() ==
               ~w(JOIN SUB_WORKFLOW WAIT)

      assert Enum.filter(Map.keys(registry), &SystemTasks.start_idempotent?(registry, &1)) ==
               ["SUB_WORKFLOW"]

      refute SystemTasks.async?(registry, "SIMPLE")
      assert SystemTasks.async_complete?(registry, %Task{task_type: "SUB_WORKFLOW"})
      refute SystemTasks.async_complete?(registry, %Task{task_type: "WAIT"})

      assert SystemTasks.async_complete?(registry, %Task{
               task_type: "WAIT",
               input_data: %{"asyncComplete" => true}
             })

      refute SystemTasks.async_complete?(registry, %Task{
               task_type: "SIMPLE",
               input_data: %{"asyncComplete" => true}
             })
    end

    test "built-in and in-place types are upstream's sets, registered or not" do
      for type <- ~w(DECISION SWITCH FORK JOIN EXCLUSIVE_JOIN DO_WHILE),
          do: assert(SystemTasks.built_in?(type), type)

      refute SystemTasks.built_in?("SUB_WORKFLOW")
      refute SystemTasks.built_in?("WAIT")

      for type <- ~w(DO_WHILE FORK_JOIN JOIN EXCLUSIVE_JOIN),
          do: assert(SystemTasks.in_place?(type), type)

      refute SystemTasks.in_place?("FORK")
    end
  end

  describe "the mapper table" do
    test "knows the MVP workflow task types and maps the rest as USER_DEFINED" do
      for type <- ~w(SIMPLE SWITCH DECISION FORK_JOIN JOIN DO_WHILE SUB_WORKFLOW WAIT),
          do: assert(Mapper.mapped?(type), type)

      refute Mapper.mapped?("HTTP")
      assert Mapper.module_for("HTTP") == Mapper.UserDefined
      refute Mapper.changes_definition?("SIMPLE")
      refute Mapper.changes_definition?("HTTP")
    end
  end

  describe "the context's injected functions" do
    test "default to finding nothing and to no jq evaluator" do
      context = Context.new(now: 0)

      assert context.task_def_lookup.("archon_task_a") == {:error, :not_found}
      assert context.workflow_def_lookup.("archon_simple", nil) == {:error, :not_found}
      assert context.workflow_def_lookup.("archon_simple", 1) == {:error, :not_found}
      assert {:error, %Script.Error{kind: :request}} = context.evaluate_jq.(".", %{})
      assert context.max_workflow_variables_payload_kb == 256
    end

    test "reach the context from the runtime's env" do
      lookup = fn "x" -> {:ok, %TaskDef{name: "x"}} end
      jq = fn _query, input -> {:ok, [input]} end

      context =
        Env.new(
          now: 0,
          task_def_lookup: lookup,
          evaluate_jq: jq,
          max_workflow_variables_payload_kb: 1
        )
        |> Env.context()

      assert context.task_def_lookup == lookup
      assert context.evaluate_jq == jq
      assert context.workflow_def_lookup == (&Context.no_workflow_def/2)
      assert context.max_workflow_variables_payload_kb == 1
    end
  end

  # ADR 0026, decision 4: a mapper that changes its workflow task changes the definition the
  # workflow holds; the decide outcome carries it.
  describe "change_definition/2" do
    defp definition do
      %WorkflowDef{
        name: "wf",
        tasks: [
          %WorkflowTask{
            name: "fork",
            task_reference_name: "fork",
            type: "FORK_JOIN",
            fork_tasks: [
              [%WorkflowTask{name: "dyn", task_reference_name: "dyn", type: "DYNAMIC"}]
            ]
          }
        ]
      }
    end

    defp outcome(tasks),
      do: %Outcome{
        workflow: %Workflow{workflow_definition: definition()},
        tasks_to_be_scheduled: tasks
      }

    test "writes a changed workflow task of a type whose mapper changes it into the definition" do
      changed = %WorkflowTask{name: "resolved", task_reference_name: "dyn", type: "DYNAMIC"}
      outcome = outcome([%Task{reference_task_name: "dyn", workflow_task: changed}])

      result = Decider.change_definition(outcome, &(&1 == "DYNAMIC"))

      assert result.changed_workflow_tasks == [changed]
      assert WorkflowDef.task_by_ref_name(result.workflow.workflow_definition, "dyn") == changed
    end

    test "leaves the definition alone otherwise" do
      unchanged = WorkflowDef.task_by_ref_name(definition(), "dyn")
      other = %WorkflowTask{name: "other", task_reference_name: "dyn", type: "DYNAMIC"}

      for {tasks, changes?} <- [
            {[%Task{reference_task_name: "dyn", workflow_task: unchanged}], &(&1 == "DYNAMIC")},
            {[%Task{reference_task_name: "dyn", workflow_task: other}], fn _type -> false end},
            {[
               %Task{reference_task_name: "x", workflow_task: %{other | task_reference_name: "x"}}
             ], fn _type -> true end}
          ] do
        outcome = outcome(tasks)
        assert Decider.change_definition(outcome, changes?) == outcome
      end

      no_definition = %Outcome{workflow: %Workflow{}, tasks_to_be_scheduled: []}
      assert Decider.change_definition(no_definition, fn _type -> true end) == no_definition
    end
  end
end
