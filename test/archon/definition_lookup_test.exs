# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.DefinitionLookupTest do
  @moduledoc """
  The task and workflow definition lookups of ADR 0026, decision 2: the type rules' lookup in
  validation (`Archon.Metadata.validation_opts/0`), the Decider's in the runtime's env, and the
  replay's fixed ones (`Archon.StepReplay`).
  """

  use ExUnit.Case, async: false

  alias Archon.Domain.{TaskDef, TaskTypeConstraint, WorkflowDef, WorkflowTask}
  alias Archon.Metadata
  alias Archon.Runtime.WorkflowServer
  alias Archon.StepReplay

  @task "archon_definition_lookup_task"
  @workflow "archon_definition_lookup_wf"

  setup do
    remove = fn -> ArchonWeb.ContractCase.remove_definitions([@task, @workflow]) end
    remove.()
    on_exit(remove)

    :ok = Metadata.register_task_defs([%TaskDef{name: @task, retry_count: 2}])

    for version <- [1, 2] do
      :ok =
        Metadata.register_workflow_def(%WorkflowDef{
          name: @workflow,
          version: version,
          tasks: [%WorkflowTask{name: @task, task_reference_name: "t", type: "SIMPLE"}]
        })
    end

    :ok
  end

  test "the type rules read task definitions from the store" do
    opts = Metadata.validation_opts()
    named = %WorkflowTask{name: @task, task_reference_name: "t", type: "HTTP"}

    assert %TaskDef{name: @task, retry_count: 2} = TaskTypeConstraint.task_definition(named, opts)
    assert TaskTypeConstraint.task_definition(%{named | name: "archon_missing"}, opts) == nil
    assert TaskTypeConstraint.task_definition(named, []) == nil

    embedded = %{named | task_definition: %TaskDef{name: "embedded"}}
    assert %TaskDef{name: "embedded"} = TaskTypeConstraint.task_definition(embedded, opts)
  end

  test "the runtime's env reads the store" do
    env = WorkflowServer.env(nil, :wake)

    assert {:ok, %TaskDef{name: @task}} = env.task_def_lookup.(@task)
    assert env.task_def_lookup.("archon_missing") == {:error, :not_found}
    assert {:ok, %WorkflowDef{version: 2}} = env.workflow_def_lookup.(@workflow, nil)
    assert {:ok, %WorkflowDef{version: 1}} = env.workflow_def_lookup.(@workflow, 1)
    assert env.workflow_def_lookup.(@workflow, 3) == {:error, :not_found}
  end

  test "the replay reads the definitions the fixtures registered" do
    env = StepReplay.env(StepReplay.clock())

    assert {:ok, %TaskDef{name: "archon_task_a"}} = env.task_def_lookup.("archon_task_a")
    assert {:ok, %TaskDef{name: "archon_p7_worker"}} = env.task_def_lookup.("archon_p7_worker")
    assert env.task_def_lookup.("archon_missing") == {:error, :not_found}

    # archon_ops is registered as version 1 and 2, and version 2 is deleted at the end; the
    # lookup knows registrations only.
    assert {:ok, %WorkflowDef{version: 2}} = env.workflow_def_lookup.("archon_ops", nil)
    assert {:ok, %WorkflowDef{version: 1}} = env.workflow_def_lookup.("archon_ops", 1)

    assert {:ok, %WorkflowDef{name: "archon_p7_noop"}} =
             env.workflow_def_lookup.("archon_p7_noop", nil)

    assert env.workflow_def_lookup.("archon_missing", nil) == {:error, :not_found}
  end
end
