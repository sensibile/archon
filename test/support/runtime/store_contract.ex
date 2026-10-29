# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/test/java/com/netflix/conductor/dao/ExecutionDAOTest.java,
# PollDataDAOTest.java and core/src/test/java/com/netflix/conductor/core/dal/ExecutionDAOFacadeTest.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: ported to ExUnit as a shared contract for every `Archon.Runtime.Store`
# implementation (ADR 0018, decision 10); writes go through `Archon.Runtime.Commit`, and cases for
# atomicity, task order and internal fields were added.

defmodule Archon.Runtime.StoreContract do
  @moduledoc """
  Shared cases for `Archon.Runtime.Store` implementations (ADR 0018, decision 10).

      defmodule MyStoreTest do
        use ExUnit.Case, async: true
        use Archon.Runtime.StoreContract

        setup do
          %{impl: MyStore, server: ...}
        end
      end

  The setup gives `:impl`, the module under test, and `:server`, an empty instance. Every
  callback is called as `impl.fun(server, args...)`.
  """

  defmacro __using__(_opts) do
    quote do
      unquote(helpers())
      unquote(workflow_cases())
      unquote(task_cases())
      unquote(other_cases())
    end
  end

  defp helpers do
    quote do
      alias Archon.Domain.{Task, Workflow, WorkflowDef}
      alias Archon.Runtime.Commit

      defp s(ctx, fun, args), do: apply(ctx.impl, fun, [ctx.server | args])

      defp workflow(id, overrides \\ []) do
        struct!(
          %Workflow{
            workflow_id: id,
            workflow_definition: %WorkflowDef{name: "Junit Workflow", version: 3},
            correlation_id: "correlationX",
            created_by: "junit_tester",
            input: %{"param1" => "param1 value", "param2" => 100},
            output: %{"ouput1" => "output 1 value", "op2" => 300},
            owner_app: "workflow",
            create_time: 90,
            update_time: 95,
            status: :running
          },
          overrides
        )
      end

      defp task(workflow_id, n, overrides \\ []) do
        struct!(
          %Task{
            task_id: "#{workflow_id}_t#{n}",
            workflow_instance_id: workflow_id,
            reference_task_name: "t#{n}",
            task_def_name: "task#{n}",
            task_type: "task#{n}",
            scheduled_time: n,
            seq: n,
            status: :scheduled
          },
          overrides
        )
      end

      defp create(ctx, %Workflow{} = workflow),
        do: s(ctx, :commit, [workflow.workflow_id, %Commit{create: workflow}])
    end
  end

  defp workflow_cases do
    quote do
      describe "Store contract: workflows" do
        # ExecutionDAOTest#complexExecutionTest
        test "create, read with and without tasks, update and running IDs", ctx do
          tasks = for n <- 1..3, do: task("wf1", n)
          wf = workflow("wf1", status: :failed, tasks: tasks)
          assert create(ctx, wf) == :ok

          assert {:ok, with_tasks} = s(ctx, :get_workflow, ["wf1", true])
          assert with_tasks == wf

          assert {:ok, found} = s(ctx, :get_workflow, ["wf1", false])
          assert found == %{wf | tasks: []}

          updated = %{found | input: Map.put(found.input, "updated", true)}
          assert s(ctx, :commit, ["wf1", %Commit{workflow: updated}]) == :ok

          assert {:ok, %Workflow{input: %{"updated" => true}}} =
                   s(ctx, :get_workflow, ["wf1", false])

          assert s(ctx, :running_workflow_ids, []) == []

          s(ctx, :commit, ["wf1", %Commit{workflow: %{updated | status: :running}}])
          assert s(ctx, :running_workflow_ids, []) == ["wf1"]

          s(ctx, :commit, ["wf1", %Commit{workflow: %{updated | status: :completed}}])
          assert s(ctx, :running_workflow_ids, []) == []
        end

        test "running IDs are the non-terminal workflows", ctx do
          for {id, status} <- [
                a: :running,
                b: :paused,
                c: :completed,
                d: :failed,
                e: :timed_out,
                f: :terminated
              ] do
            create(ctx, workflow(Atom.to_string(id), status: status))
          end

          assert Enum.sort(s(ctx, :running_workflow_ids, [])) == ["a", "b"]
        end

        test "creating an existing workflow is a conflict and changes nothing", ctx do
          create(ctx, workflow("wf1", tasks: [task("wf1", 1)]))
          again = workflow("wf1", correlation_id: "other", tasks: [task("wf1", 2)])
          assert create(ctx, again) == {:error, :conflict}

          assert {:ok, wf} = s(ctx, :get_workflow, ["wf1", true])
          assert wf.correlation_id == "correlationX"
          assert Enum.map(wf.tasks, & &1.task_id) == ["wf1_t1"]
        end

        test "changing a workflow that does not exist is not found", ctx do
          assert s(ctx, :commit, ["nope", %Commit{workflow: workflow("nope")}]) ==
                   {:error, :not_found}

          assert s(ctx, :commit, ["nope", %Commit{upsert_tasks: [task("nope", 1)]}]) ==
                   {:error, :not_found}

          assert s(ctx, :commit, ["nope", %Commit{}]) == {:error, :not_found}
          assert s(ctx, :get_workflow, ["nope", true]) == {:error, :not_found}
          assert s(ctx, :get_task, ["nope_t1"]) == {:error, :not_found}
        end

        # SqliteExecutionDAO#getWorkflow sorts tasks with Comparator.comparingInt(TaskModel::getSeq).
        test "tasks come back ordered by seq", ctx do
          tasks = [task("wf1", 3), task("wf1", 1), task("wf1", 2)]
          create(ctx, workflow("wf1", tasks: tasks))
          assert {:ok, wf} = s(ctx, :get_workflow, ["wf1", true])
          assert Enum.map(wf.tasks, & &1.seq) == [1, 2, 3]
        end

        # ADR 0018, decisions 2 and 3: internal fields are stored, and times are never stamped.
        test "internal fields and times are kept as given", ctx do
          wf =
            workflow("wf1",
              previous_status: :running,
              failed_task_id: "wf1_t1",
              update_time: 1,
              end_time: 0,
              tasks: [task("wf1", 1, callback_after_ms: 1_500, wait_timeout: 77, update_time: 2)]
            )

          create(ctx, wf)
          assert {:ok, ^wf} = s(ctx, :get_workflow, ["wf1", true])
        end

        # ExecutionDAOTest#testCreateTaskException, #testCreateTaskException2
        test "a commit with tasks of another or no workflow is refused before writing", ctx do
          create(ctx, workflow("wf1"))

          assert_raise ArgumentError, "Workflow instance id cannot be null", fn ->
            s(ctx, :commit, [
              "wf1",
              %Commit{upsert_tasks: [task("wf1", 1, workflow_instance_id: nil)]}
            ])
          end

          assert_raise ArgumentError, "Task reference name cannot be null", fn ->
            s(ctx, :commit, [
              "wf1",
              %Commit{upsert_tasks: [task("wf1", 1, reference_task_name: nil)]}
            ])
          end

          assert_raise ArgumentError, fn ->
            s(ctx, :commit, ["wf1", %Commit{upsert_tasks: [task("wf2", 1)]}])
          end

          assert_raise ArgumentError, fn ->
            s(ctx, :commit, ["wf1", %Commit{workflow: workflow("wf2")}])
          end

          assert {:ok, %Workflow{tasks: []}} = s(ctx, :get_workflow, ["wf1", true])
        end
      end
    end
  end

  defp task_cases do
    quote do
      describe "Store contract: tasks" do
        # ExecutionDAOTest#testTaskOps
        test "upserting tasks replaces them and get_task returns the owner", ctx do
          create(
            ctx,
            workflow("wf1", tasks: for(n <- 1..3, do: task("wf1", n, status: :in_progress)))
          )

          completed =
            for n <- 1..3,
                do: task("wf1", n, status: :completed, output_data: %{"updated" => true})

          assert s(ctx, :commit, ["wf1", %Commit{upsert_tasks: completed}]) == :ok

          for n <- 1..3 do
            assert {:ok, %Task{status: :completed, output_data: %{"updated" => true}}, "wf1"} =
                     s(ctx, :get_task, ["wf1_t#{n}"])
          end

          new = task("wf1", 4)
          assert s(ctx, :commit, ["wf1", %Commit{upsert_tasks: [new]}]) == :ok
          assert {:ok, ^new, "wf1"} = s(ctx, :get_task, ["wf1_t4"])
        end

        test "deleting task IDs removes only the workflow's own tasks", ctx do
          create(ctx, workflow("wf1", tasks: for(n <- 1..3, do: task("wf1", n))))
          create(ctx, workflow("wf2", tasks: [task("wf2", 1)]))

          commit = %Commit{delete_task_ids: ["wf1_t1", "wf1_t3", "wf2_t1", "unknown"]}
          assert s(ctx, :commit, ["wf1", commit]) == :ok

          assert {:ok, wf} = s(ctx, :get_workflow, ["wf1", true])
          assert Enum.map(wf.tasks, & &1.task_id) == ["wf1_t2"]
          assert s(ctx, :get_task, ["wf1_t1"]) == {:error, :not_found}
          assert {:ok, _task, "wf2"} = s(ctx, :get_task, ["wf2_t1"])
        end

        test "a commit applies create, workflow, upserts and deletes in that order", ctx do
          wf = workflow("wf1", tasks: [task("wf1", 1), task("wf1", 2)])

          commit = %Commit{
            create: wf,
            workflow: %{wf | status: :completed, tasks: []},
            upsert_tasks: [task("wf1", 2, status: :completed), task("wf1", 3)],
            delete_task_ids: ["wf1_t1"]
          }

          assert s(ctx, :commit, ["wf1", commit]) == :ok
          assert {:ok, stored} = s(ctx, :get_workflow, ["wf1", true])
          assert stored.status == :completed

          assert Enum.map(stored.tasks, &{&1.task_id, &1.status}) == [
                   {"wf1_t2", :completed},
                   {"wf1_t3", :scheduled}
                 ]
        end

        test "the tasks field of a changed workflow is ignored", ctx do
          create(ctx, workflow("wf1", tasks: [task("wf1", 1)]))

          assert s(ctx, :commit, [
                   "wf1",
                   %Commit{workflow: workflow("wf1", tasks: [task("wf1", 9)])}
                 ]) == :ok

          assert {:ok, wf} = s(ctx, :get_workflow, ["wf1", true])
          assert Enum.map(wf.tasks, & &1.task_id) == ["wf1_t1"]
          assert s(ctx, :get_task, ["wf1_t9"]) == {:error, :not_found}
        end

        test "a task ID owned by another workflow is a conflict and nothing is applied", ctx do
          create(ctx, workflow("wf1", tasks: [task("wf1", 1)]))
          create(ctx, workflow("wf2"))

          stolen = task("wf2", 1, task_id: "wf1_t1")

          commit = %Commit{
            workflow: workflow("wf2", status: :completed),
            upsert_tasks: [task("wf2", 2), stolen]
          }

          assert s(ctx, :commit, ["wf2", commit]) == {:error, :conflict}

          assert {:ok, %Workflow{status: :running, tasks: []}} =
                   s(ctx, :get_workflow, ["wf2", true])

          assert {:ok, _task, "wf1"} = s(ctx, :get_task, ["wf1_t1"])

          new = workflow("wf3", tasks: [task("wf3", 1, task_id: "wf1_t1")])
          assert create(ctx, new) == {:error, :conflict}
          assert s(ctx, :get_workflow, ["wf3", false]) == {:error, :not_found}
        end
      end
    end
  end

  defp other_cases do
    quote do
      describe "Store contract: removal, counts and poll data" do
        # ExecutionDAOFacadeTest#testRemoveWorkflow
        test "remove_workflow deletes the workflow and its tasks", ctx do
          create(ctx, workflow("wf1", tasks: [task("wf1", 1), task("wf1", 2)]))
          create(ctx, workflow("wf2", tasks: [task("wf2", 1)]))

          assert s(ctx, :remove_workflow, ["wf1"]) == :ok
          assert s(ctx, :get_workflow, ["wf1", true]) == {:error, :not_found}
          assert s(ctx, :get_task, ["wf1_t1"]) == {:error, :not_found}
          assert s(ctx, :get_task, ["wf1_t2"]) == {:error, :not_found}
          assert s(ctx, :running_workflow_ids, []) == ["wf2"]
          assert {:ok, _task, "wf2"} = s(ctx, :get_task, ["wf2_t1"])

          assert s(ctx, :remove_workflow, ["wf1"]) == {:error, :not_found}
          assert create(ctx, workflow("wf1")) == :ok
        end

        # ExecutionDAOTest#testTaskExceedsLimit (the count ConcurrentExecutionLimitDAO#exceedsLimit reads)
        test "in_progress_count counts IN_PROGRESS tasks of a task definition", ctx do
          tasks =
            for i <- 0..14 do
              task("wf#{i}", 1,
                task_id: "t_#{i}",
                task_def_name: "task1",
                reference_task_name: "task1"
              )
            end

          for t <- tasks, do: create(ctx, workflow(t.workflow_instance_id, tasks: [t]))
          assert s(ctx, :in_progress_count, ["task1"]) == 0

          [first | _] = tasks

          s(ctx, :commit, [
            first.workflow_instance_id,
            %Commit{upsert_tasks: [%{first | status: :in_progress}]}
          ])

          assert s(ctx, :in_progress_count, ["task1"]) == 1
          assert s(ctx, :in_progress_count, ["task2"]) == 0

          s(ctx, :commit, [
            first.workflow_instance_id,
            %Commit{upsert_tasks: [%{first | status: :completed}]}
          ])

          assert s(ctx, :in_progress_count, ["task1"]) == 0
        end

        # TaskModel#getTaskDefName falls back to the task type.
        test "in_progress_count uses the task type when there is no task definition name", ctx do
          create(
            ctx,
            workflow("wf1",
              tasks: [
                task("wf1", 1, task_def_name: nil, task_type: "worker", status: :in_progress)
              ]
            )
          )

          assert s(ctx, :in_progress_count, ["worker"]) == 1
        end

        # PollDataDAOTest#testPollData
        test "poll data per task type and domain", ctx do
          assert s(ctx, :put_poll_data, ["taskDef", nil, "workerId1", 10]) == :ok

          assert s(ctx, :get_poll_data, ["taskDef", nil]) ==
                   {:ok,
                    %{
                      queue_name: "taskDef",
                      domain: nil,
                      worker_id: "workerId1",
                      last_poll_time: 10
                    }}

          s(ctx, :put_poll_data, ["taskDef", "domain1", "workerId1", 20])

          assert s(ctx, :get_poll_data, ["taskDef", "domain1"]) ==
                   {:ok,
                    %{
                      queue_name: "taskDef",
                      domain: "domain1",
                      worker_id: "workerId1",
                      last_poll_time: 20
                    }}

          assert s(ctx, :get_poll_data, ["taskDef", "domain2"]) == {:error, :not_found}

          s(ctx, :put_poll_data, ["taskDef", nil, "workerId2", 30])

          assert {:ok, %{worker_id: "workerId2", last_poll_time: 30}} =
                   s(ctx, :get_poll_data, ["taskDef", nil])
        end
      end
    end
  end
end
