# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.MetadataTest do
  @moduledoc """
  `Archon.Metadata` (ADR 0023, decision 2) and the schema refusal of decision 5, on the runtime's
  metadata store. The REST answers are `ArchonWeb.MetadataControllerTest`'s.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Archon.Domain.{
    BulkResponse,
    SchemaDef,
    SubWorkflowParams,
    TaskDef,
    WorkflowDef,
    WorkflowTask
  }

  alias Archon.Metadata
  alias Archon.Runtime

  @prefix "archon_metadata_test_"

  defp name(suffix), do: @prefix <> suffix

  defp workflow(suffix, fields \\ []) do
    struct!(
      %WorkflowDef{
        name: name(suffix),
        tasks: [%WorkflowTask{name: "t", task_reference_name: "t", type: "SIMPLE"}]
      },
      fields
    )
  end

  describe "task definitions" do
    test "registration stamps createdBy and createTime and clears the update fields" do
      given = %TaskDef{
        name: name("a"),
        created_by: "client",
        create_time: 1,
        updated_by: "someone",
        update_time: 2
      }

      before = Runtime.now()
      assert Metadata.register_task_defs([given]) == :ok
      assert {:ok, stored} = Metadata.get_task_def(name("a"))
      assert %TaskDef{created_by: "", updated_by: nil, update_time: 0} = stored
      assert stored.create_time >= before
    end

    test "an update keeps the stored createTime and createdBy" do
      :ok = Metadata.register_task_defs([%TaskDef{name: name("b")}])
      {:ok, %TaskDef{create_time: created}} = Metadata.get_task_def(name("b"))

      assert Metadata.update_task_def(%TaskDef{
               name: name("b"),
               description: "new",
               created_by: "x",
               create_time: 5
             }) == :ok

      assert {:ok, %TaskDef{description: "new", created_by: "", create_time: ^created} = stored} =
               Metadata.get_task_def(name("b"))

      assert stored.updated_by == ""
      assert stored.update_time >= created
    end

    test "errors" do
      assert Metadata.register_task_defs([]) ==
               {:error, {:invalid, [{"", "TaskDefList is empty"}]}}

      assert Metadata.register_task_defs([%TaskDef{name: name("c")}, %TaskDef{name: ""}]) ==
               {:error, {:invalid, [{"[1].name", "TaskDef name cannot be null or empty"}]}}

      assert Metadata.get_task_def(name("c")) ==
               {:error, {:not_found, "No such taskType found by name: #{name("c")}"}}

      assert Metadata.update_task_def(%TaskDef{name: name("none")}) ==
               {:error, {:not_found, "No such task by name #{name("none")}"}}
    end

    test "the list holds every stored definition" do
      :ok = Metadata.register_task_defs([%TaskDef{name: name("l2")}, %TaskDef{name: name("l1")}])
      names = for %TaskDef{name: @prefix <> _ = n} <- Metadata.get_task_defs(), do: n
      assert [name("l1"), name("l2")] == Enum.filter(names, &(&1 in [name("l1"), name("l2")]))
    end
  end

  describe "workflow definitions" do
    test "registration stamps createTime, an update updateTime" do
      assert Metadata.register_workflow_def(workflow("w", update_time: 3)) == :ok

      assert {:ok, %WorkflowDef{update_time: 3} = created} =
               Metadata.get_workflow_def(name("w"), 1)

      assert created.create_time > 0

      assert Metadata.register_workflow_def(workflow("w")) ==
               {:error, {:conflict, "Workflow with #{name("w")}.1 already exists!"}}

      assert Metadata.update_workflow_def(workflow("w", create_time: 0)) == :ok

      assert {:ok, %WorkflowDef{create_time: 0} = updated} =
               Metadata.get_workflow_def(name("w"), nil)

      assert updated.update_time >= created.create_time
    end

    test "not found names the version, null for the latest" do
      assert Metadata.get_workflow_def(name("none"), nil) ==
               {:error,
                {:not_found, "No such workflow found by name: #{name("none")}, version: null"}}

      assert Metadata.get_workflow_def(name("none"), 2) ==
               {:error,
                {:not_found, "No such workflow found by name: #{name("none")}, version: 2"}}

      assert Metadata.find_workflow_def(name("none"), 2) == {:error, :not_found}
    end

    test "a bulk update validates the whole list first" do
      assert Metadata.update_workflow_defs([]) ==
               {:error, {:invalid, [{"", "WorkflowDefList is empty"}]}}

      assert Metadata.update_workflow_defs([workflow("ok"), nil, workflow("bad", tasks: [])]) ==
               {:error,
                {:invalid,
                 [
                   {"[1].<list element>", "WorkflowDef cannot be null"},
                   {"[2].tasks", "WorkflowTask list cannot be empty"}
                 ]}}

      assert Metadata.find_workflow_def(name("ok"), 1) == {:error, :not_found}
    end

    test "a bulk update fails a refused schema or a store exception per definition" do
      refused = workflow("refused", output_schema: %SchemaDef{data: %{}})

      log =
        capture_log(fn ->
          with_metadata(Archon.MetadataTest.RaisingMetadata, fn ->
            assert {:ok, response} =
                     Metadata.update_workflow_defs([workflow("raise"), refused, workflow("ok2")])

            send(self(), {:response, response})
          end)
        end)

      assert_received {:response, response}

      assert response == %BulkResponse{
               bulk_successful_results: [name("ok2")],
               bulk_error_results: %{
                 name("raise") => "Internal server error",
                 name("refused") =>
                   "Schema validation is not supported yet: #{name("refused")} outputSchema"
               }
             }

      assert log =~ "bulk update workflow def failed"
      assert {:ok, _definition} = Metadata.find_workflow_def(name("ok2"), 1)
    end
  end

  describe "schema refusal" do
    test "what is a reference by name" do
      assert SchemaDef.name_reference?(%SchemaDef{name: "s"})
      # A no-break space is not Java whitespace.
      assert SchemaDef.name_reference?(%SchemaDef{name: " "})
      refute SchemaDef.name_reference?(%SchemaDef{name: " \t "})
      refute SchemaDef.name_reference?(%SchemaDef{})
      refute SchemaDef.name_reference?(%SchemaDef{name: "s", data: %{}})
      refute SchemaDef.name_reference?(%SchemaDef{name: "s", external_ref: ""})
    end

    test "a task definition enforces no schema by default" do
      assert %TaskDef{}.enforce_schema == false
      assert TaskDef.check_schema(%TaskDef{name: "t", input_schema: %SchemaDef{data: %{}}}) == :ok

      assert TaskDef.check_schema(%TaskDef{
               enforce_schema: true,
               output_schema: %SchemaDef{external_ref: "r"}
             }) ==
               {:error, {:invalid, "Schema validation is not supported yet: null outputSchema"}}
    end

    test "a workflow definition checks itself first, then the tasks in order" do
      inline = %SchemaDef{data: %{}}
      refused_task_def = %TaskDef{name: "td", enforce_schema: true, input_schema: inline}

      task = fn fields ->
        struct!(%WorkflowTask{name: "t", task_reference_name: "t", type: "SIMPLE"}, fields)
      end

      both =
        workflow("both",
          output_schema: inline,
          tasks: [task.(task_definition: refused_task_def)]
        )

      assert WorkflowDef.check_schema(both) ==
               {:error,
                {:invalid, "Schema validation is not supported yet: #{name("both")} outputSchema"}}

      not_enforced = %{both | enforce_schema: false}

      assert WorkflowDef.check_schema(not_enforced) ==
               {:error, {:invalid, "Schema validation is not supported yet: td inputSchema"}}

      # Every nested list is walked, whatever the task's type.
      nested =
        for field <- [:default_case, :loop_over] do
          task.([{field, [task.(task_definition: refused_task_def)]}])
        end ++
          [
            task.(fork_tasks: [[], [task.(task_definition: refused_task_def)]]),
            task.(decision_cases: %{"x" => [nil, task.(task_definition: refused_task_def)]}),
            task.(
              sub_workflow_param: %SubWorkflowParams{
                workflow_definition:
                  workflow("sub", tasks: [task.(task_definition: refused_task_def)])
              }
            )
          ]

      for container <- nested do
        assert WorkflowDef.check_schema(workflow("n", tasks: [nil, container])) ==
                 {:error, {:invalid, "Schema validation is not supported yet: td inputSchema"}}
      end

      expression = task.(sub_workflow_param: %SubWorkflowParams{workflow_definition: "${x}"})
      assert WorkflowDef.check_schema(workflow("e", tasks: [expression])) == :ok
    end

    test "registration refuses before storing" do
      refused = workflow("r", input_schema: %SchemaDef{external_ref: "x"})
      message = "Schema validation is not supported yet: #{name("r")} inputSchema"

      assert Metadata.register_workflow_def(refused) == {:error, {:invalid, message}}
      assert Metadata.update_workflow_def(refused) == {:error, {:invalid, message}}
      assert Metadata.find_workflow_def(name("r"), 1) == {:error, :not_found}
    end
  end

  # Runs `fun` with another `Archon.Runtime.Metadata` configured.
  defp with_metadata(module, fun) do
    config = Application.get_env(:archon, Runtime, [])
    Application.put_env(:archon, Runtime, Keyword.put(config, :metadata, module))

    try do
      fun.()
    after
      Application.put_env(:archon, Runtime, config)
    end
  end

  defmodule RaisingMetadata do
    @moduledoc false
    # The runtime's metadata, except that storing a definition named "..._raise" raises. Other
    # processes may read the configuration while it is swapped, so every callback delegates.
    @behaviour Archon.Runtime.Metadata

    @real Archon.Runtime.metadata()

    @impl true
    def update_workflow_def(%WorkflowDef{name: "archon_metadata_test_raise"}),
      do: raise("store down")

    def update_workflow_def(definition), do: @real.update_workflow_def(definition)

    @impl true
    defdelegate create_task_def(task_def), to: @real
    @impl true
    defdelegate update_task_def(task_def), to: @real
    @impl true
    defdelegate get_task_def(name), to: @real
    @impl true
    defdelegate get_all_task_defs(), to: @real
    @impl true
    defdelegate create_workflow_def(definition), to: @real
    @impl true
    defdelegate get_workflow_def(name, version), to: @real
    @impl true
    defdelegate get_latest_workflow_def(name), to: @real
  end
end
