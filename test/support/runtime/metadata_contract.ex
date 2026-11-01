# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss sqlite-persistence/src/test/java/com/netflix/conductor/sqlite/dao/SqliteMetadataDAOTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: ported to ExUnit as a shared contract for every `Archon.Runtime.Metadata`
# implementation (ADR 0018, decision 10), keeping the operations in the behaviour.

defmodule Archon.Runtime.MetadataContract do
  @moduledoc """
  Shared cases for `Archon.Runtime.Metadata` implementations (ADR 0018, decision 10).

      defmodule MyMetadataTest do
        use ExUnit.Case, async: true
        use Archon.Runtime.MetadataContract

        setup do
          %{impl: MyMetadata, server: ...}
        end
      end

  The setup gives `:impl`, the module under test, and `:server`, an empty instance. Every
  callback is called as `impl.fun(server, args...)`.
  """

  defmacro __using__(_opts) do
    quote do
      alias Archon.Domain.{TaskDef, WorkflowDef}

      defp m(ctx, fun, args), do: apply(ctx.impl, fun, [ctx.server | args])

      describe "Metadata contract" do
        # SqliteMetadataDAOTest#testDuplicateWorkflowDef
        test "creating an existing workflow definition is a conflict", ctx do
          definition = %WorkflowDef{name: "testDuplicate", version: 1}
          assert m(ctx, :create_workflow_def, [definition]) == :ok

          assert m(ctx, :create_workflow_def, [%{definition | description: "other"}]) ==
                   {:error, :conflict}

          assert m(ctx, :get_workflow_def, ["testDuplicate", 1]) == {:ok, definition}
        end

        # SqliteMetadataDAOTest#testWorkflowDefOperations (the operations in the behaviour)
        test "workflow definition versions", ctx do
          definition = %WorkflowDef{
            name: "test",
            version: 1,
            description: "description",
            created_by: "unit_test",
            create_time: 1,
            owner_app: "ownerApp",
            updated_by: "unit_test2",
            update_time: 2
          }

          m(ctx, :create_workflow_def, [definition])
          assert m(ctx, :get_workflow_def, ["test", 1]) == {:ok, definition}

          v3 = %{definition | version: 3}
          m(ctx, :create_workflow_def, [v3])
          assert m(ctx, :get_latest_workflow_def, ["test"]) == {:ok, v3}

          updated = %{v3 | description: "updated"}
          assert m(ctx, :update_workflow_def, [updated]) == :ok

          assert {:ok, %WorkflowDef{description: "updated"}} =
                   m(ctx, :get_workflow_def, ["test", 3])

          assert m(ctx, :get_workflow_def, ["test", 1]) == {:ok, definition}

          m(ctx, :create_workflow_def, [%{updated | version: 2}])
          assert {:ok, %WorkflowDef{version: 3}} = m(ctx, :get_latest_workflow_def, ["test"])
        end

        test "update_workflow_def adds a version that does not exist", ctx do
          definition = %WorkflowDef{name: "upsert", version: 4}
          assert m(ctx, :update_workflow_def, [definition]) == :ok
          assert m(ctx, :get_latest_workflow_def, ["upsert"]) == {:ok, definition}
        end

        test "missing workflow definitions are not found", ctx do
          m(ctx, :create_workflow_def, [%WorkflowDef{name: "present", version: 1}])
          assert m(ctx, :get_workflow_def, ["present", 2]) == {:error, :not_found}
          assert m(ctx, :get_workflow_def, ["absent", 1]) == {:error, :not_found}
          assert m(ctx, :get_latest_workflow_def, ["absent"]) == {:error, :not_found}
        end

        test "latest versions are per name", ctx do
          m(ctx, :create_workflow_def, [%WorkflowDef{name: "a", version: 7}])
          m(ctx, :create_workflow_def, [%WorkflowDef{name: "b", version: 2}])

          assert {:ok, %WorkflowDef{name: "b", version: 2}} =
                   m(ctx, :get_latest_workflow_def, ["b"])
        end

        # SqliteMetadataDAOTest#testTaskDefOperations (the operations in the behaviour)
        test "task definitions are inserted or replaced by name", ctx do
          definition = %TaskDef{
            name: "taskA",
            description: "description",
            created_by: "unit_test",
            create_time: 1,
            input_keys: ["a", "b", "c"],
            output_keys: ["01", "o2"],
            owner_app: "ownerApp",
            retry_count: 3,
            retry_delay_seconds: 100,
            retry_logic: :fixed,
            timeout_policy: :alert_only,
            updated_by: "unit_test2",
            update_time: 2,
            rate_limit_frequency_in_seconds: 1,
            rate_limit_per_frequency: 1
          }

          assert m(ctx, :create_task_def, [definition]) == :ok
          assert m(ctx, :get_task_def, ["taskA"]) == {:ok, definition}

          updated = %{definition | description: "updated description"}
          assert m(ctx, :update_task_def, [updated]) == :ok
          assert m(ctx, :get_task_def, ["taskA"]) == {:ok, updated}

          other = %TaskDef{name: "taskA0"}
          assert m(ctx, :create_task_def, [other]) == :ok
          assert m(ctx, :get_task_def, ["taskA0"]) == {:ok, other}
          assert m(ctx, :get_task_def, ["taskA"]) == {:ok, updated}

          replaced = %{updated | description: "created again"}
          assert m(ctx, :create_task_def, [replaced]) == :ok
          assert m(ctx, :get_task_def, ["taskA"]) == {:ok, replaced}
        end

        test "all task definitions, ordered by name", ctx do
          assert m(ctx, :get_all_task_defs, []) == []

          for name <- ["b", "a", "B", "a0"],
              do: m(ctx, :create_task_def, [%TaskDef{name: name, description: name}])

          m(ctx, :update_task_def, [%TaskDef{name: "a", description: "updated"}])

          assert m(ctx, :get_all_task_defs, []) == [
                   %TaskDef{name: "B", description: "B"},
                   %TaskDef{name: "a", description: "updated"},
                   %TaskDef{name: "a0", description: "a0"},
                   %TaskDef{name: "b", description: "b"}
                 ]
        end

        test "a missing task definition is not found", ctx do
          assert m(ctx, :get_task_def, ["absent"]) == {:error, :not_found}
        end
      end
    end
  end
end
