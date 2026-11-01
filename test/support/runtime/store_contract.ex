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
# atomicity, task order and internal fields were added, and the queue operations, outbox,
# re-evaluation times and limits of a commit (ADR 0021, decisions 3 to 6), and the queries by
# name and correlation ID (ADR 0025, decision 4).

defmodule Archon.Runtime.StoreContract do
  @moduledoc """
  Shared cases for `Archon.Runtime.Store` implementations (ADR 0018, decision 10).

      defmodule MyStoreTest do
        use ExUnit.Case, async: true
        use Archon.Runtime.StoreContract

        setup do
          %{impl: MyStore, server: ..., queue_impl: MyQueue, queue: ..., now: ..., advance: ...}
        end
      end

  The setup gives:

    * `:impl` - the module under test, and `:server`, an empty instance. Every callback is called
      as `impl.fun(server, args...)`.
    * `:queue_impl` and `:queue` - the `Archon.Runtime.Queue` the store applies a commit's queue
      operations to, empty, called the same way.
    * `:now` - a zero-arity function returning the queue's clock in epoch milliseconds, and
      `:advance` - a function moving that clock forward by some milliseconds. The cases only pop
      with a zero timeout, so the clock may stand still.

  Workflow IDs are compared in binary order (`"B" < "a"`), so a Postgres store orders them with
  `COLLATE "C"`.
  """

  defmacro __using__(_opts) do
    quote do
      unquote(helpers())
      unquote(commit_helpers())
      unquote(workflow_cases())
      unquote(task_cases())
      unquote(other_cases())
      unquote(query_cases())
      unquote(query_id_cases())
      unquote(queue_cases())
      unquote(outbox_cases())
      unquote(wake_cases())
      unquote(limit_cases())
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

  defp commit_helpers do
    quote do
      alias Archon.Runtime.Commit

      defp q(ctx, fun, args), do: apply(ctx.queue_impl, fun, [ctx.queue | args])

      defp commit(ctx, workflow_id, fields),
        do: s(ctx, :commit, [workflow_id, struct!(Commit, fields)])

      defp outbox_effects(ctx, workflow_id),
        do: Enum.map(s(ctx, :pending_outbox, [workflow_id]), &elem(&1, 1))

      defp outbox_ids(ctx, workflow_id),
        do: Enum.map(s(ctx, :pending_outbox, [workflow_id]), &elem(&1, 0))

      defp due(ctx, before_ms, cursor \\ nil, limit \\ 100),
        do: s(ctx, :due_workflow_ids, [before_ms, cursor, limit])
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

          # SqliteExecutionDAO#validate
          assert_raise ArgumentError, "Task id cannot be null", fn ->
            s(ctx, :commit, ["wf1", %Commit{upsert_tasks: [task("wf1", 1, task_id: nil)]}])
          end

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

          # SqlitePollDataDAO keys a nil domain as "DEFAULT".
          s(ctx, :put_poll_data, ["taskDef", "DEFAULT", "workerId3", 25])

          assert {:ok, %{domain: "DEFAULT", worker_id: "workerId3"}} =
                   s(ctx, :get_poll_data, ["taskDef", nil])

          s(ctx, :put_poll_data, ["taskDef", nil, "workerId2", 30])

          assert {:ok, %{worker_id: "workerId2", last_poll_time: 30}} =
                   s(ctx, :get_poll_data, ["taskDef", nil])
        end
      end
    end
  end

  defp query_cases do
    quote do
      describe "Store contract: queries by name and correlation ID" do
        defp named(id, name, version, overrides),
          do:
            workflow(
              id,
              [workflow_definition: %WorkflowDef{name: name, version: version}] ++ overrides
            )

        defp ids(workflows), do: Enum.map(workflows, & &1.workflow_id)

        test "correlated_workflows finds every version of the name, RUNNING only unless closed",
             ctx do
          create(
            ctx,
            named("c-paused", "flow", 1, correlation_id: "corr", status: :paused, create_time: 10)
          )

          create(
            ctx,
            named("c-done", "flow", 2,
              correlation_id: "corr",
              status: :completed,
              create_time: 30
            )
          )

          create(ctx, named("c-v2", "flow", 2, correlation_id: "corr", create_time: 20))
          # The same create time sorts by ID in binary order ("B" < "a").
          create(ctx, named("c-a", "flow", 1, correlation_id: "corr", create_time: 20))
          create(ctx, named("c-B", "flow", 1, correlation_id: "corr", create_time: 20))
          create(ctx, named("c-other", "other", 1, correlation_id: "corr"))
          create(ctx, named("c-corr2", "flow", 1, correlation_id: "corr2"))
          create(ctx, named("c-none", "flow", 1, correlation_id: nil))

          assert ids(s(ctx, :correlated_workflows, ["flow", "corr", false, false])) ==
                   ["c-B", "c-a", "c-v2"]

          assert ids(s(ctx, :correlated_workflows, ["flow", "corr", true, false])) ==
                   ["c-paused", "c-B", "c-a", "c-v2", "c-done"]

          assert s(ctx, :correlated_workflows, ["flow", "missing", true, false]) == []
          assert s(ctx, :correlated_workflows, ["missing", "corr", true, false]) == []
        end

        test "correlated_workflows reads the tasks in seq order only when asked", ctx do
          tasks = [task("c1", 2), task("c1", 1)]
          create(ctx, named("c1", "flow", 1, correlation_id: "corr", tasks: tasks))

          assert [%Workflow{tasks: []} = found] =
                   s(ctx, :correlated_workflows, ["flow", "corr", false, false])

          assert [%Workflow{tasks: [%Task{seq: 1}, %Task{seq: 2}]} = with_tasks] =
                   s(ctx, :correlated_workflows, ["flow", "corr", false, true])

          assert {:ok, with_tasks} == s(ctx, :get_workflow, ["c1", true])
          assert {:ok, found} == s(ctx, :get_workflow, ["c1", false])
        end
      end
    end
  end

  defp query_id_cases do
    quote do
      describe "Store contract: workflow IDs by name" do
        test "pending_workflow_ids are the RUNNING and PAUSED workflows of the name, any version",
             ctx do
          create(ctx, named("p3", "flow", 1, status: :running, create_time: 30))
          create(ctx, named("p1", "flow", 2, status: :paused, create_time: 10))
          create(ctx, named("p2", "flow", 7, status: :running, create_time: 20))

          for {status, n} <- Enum.with_index([:completed, :failed, :timed_out, :terminated]),
              do: create(ctx, named("p-end-#{n}", "flow", 1, status: status))

          create(ctx, named("p-other", "other", 1, status: :running))

          assert s(ctx, :pending_workflow_ids, ["flow"]) == ["p1", "p2", "p3"]
          assert s(ctx, :pending_workflow_ids, ["missing"]) == []
        end

        test "workflow_ids_created_between keeps the version and both bounds, any status", ctx do
          create(ctx, named("t-before", "flow", 1, create_time: 99))
          create(ctx, named("t-start", "flow", 1, status: :completed, create_time: 100))
          create(ctx, named("t-mid", "flow", 1, status: :paused, create_time: 150))
          create(ctx, named("t-end", "flow", 1, status: :terminated, create_time: 200))
          create(ctx, named("t-after", "flow", 1, create_time: 201))
          create(ctx, named("t-v2", "flow", 2, create_time: 150))
          create(ctx, named("t-other", "other", 1, create_time: 150))

          assert s(ctx, :workflow_ids_created_between, ["flow", 1, 100, 200]) ==
                   ["t-start", "t-mid", "t-end"]

          assert s(ctx, :workflow_ids_created_between, ["flow", 2, 100, 200]) == ["t-v2"]
          assert s(ctx, :workflow_ids_created_between, ["flow", 1, 200, 100]) == []
          assert s(ctx, :workflow_ids_created_between, ["flow", 3, 100, 200]) == []

          # Bounds and versions beyond the columns' ranges.
          assert length(s(ctx, :workflow_ids_created_between, ["flow", 1, -(2 ** 70), 2 ** 70])) ==
                   5

          assert s(ctx, :workflow_ids_created_between, ["flow", 2 ** 40, 0, 1_000]) == []
        end

        # The Postgres columns cannot hold these: a version outside int, a time outside bigint.
        test "a version or create time beyond the columns matches no range and sorts last", ctx do
          create(ctx, named("r-big-version", "flow", 2 ** 40, create_time: 10))
          create(ctx, named("r-big-time", "flow", 1, create_time: 2 ** 70))
          create(ctx, named("r-small", "flow", 1, create_time: 20))

          assert s(ctx, :workflow_ids_created_between, ["flow", 2 ** 40, 0, 100]) == []

          assert s(ctx, :workflow_ids_created_between, ["flow", 1, -(2 ** 80), 2 ** 80]) ==
                   ["r-small"]

          assert s(ctx, :pending_workflow_ids, ["flow"]) ==
                   ["r-big-version", "r-small", "r-big-time"]
        end

        test "the queries see a commit's new name, version, correlation ID and create time",
             ctx do
          create(ctx, named("u1", "flow", 1, correlation_id: "corr", create_time: 5))
          {:ok, wf} = s(ctx, :get_workflow, ["u1", false])

          updated = %{
            wf
            | workflow_definition: %WorkflowDef{name: "flow2", version: 4},
              correlation_id: "corr2",
              create_time: 50
          }

          assert s(ctx, :commit, ["u1", %Commit{workflow: updated}]) == :ok

          assert s(ctx, :correlated_workflows, ["flow", "corr", true, false]) == []
          assert ids(s(ctx, :correlated_workflows, ["flow2", "corr2", true, false])) == ["u1"]
          assert s(ctx, :pending_workflow_ids, ["flow"]) == []
          assert s(ctx, :pending_workflow_ids, ["flow2"]) == ["u1"]
          assert s(ctx, :workflow_ids_created_between, ["flow2", 4, 50, 50]) == ["u1"]

          assert s(ctx, :remove_workflow, ["u1"]) == :ok
          assert s(ctx, :pending_workflow_ids, ["flow2"]) == []
        end

        test "a name or correlation ID with NUL or invalid UTF-8 matches nothing", ctx do
          assert create(ctx, named("n1", "flow", 1, correlation_id: "c\u0000rr")) == :ok
          assert create(ctx, named("n2", "fl\u0000ow", 1, correlation_id: "corr")) == :ok

          for {name, correlation_id} <- [
                {"flow", "c\u0000rr"},
                {"fl\u0000ow", "corr"},
                {"flow", <<0xFF>>},
                {<<0xFF>>, "corr"}
              ],
              do: assert(s(ctx, :correlated_workflows, [name, correlation_id, true, true]) == [])

          assert s(ctx, :pending_workflow_ids, ["fl\u0000ow"]) == []
          assert s(ctx, :pending_workflow_ids, [<<0xFF>>]) == []
          assert s(ctx, :workflow_ids_created_between, ["fl\u0000ow", 1, 0, 1_000]) == []
          assert s(ctx, :pending_workflow_ids, ["flow"]) == ["n1"]
        end
      end
    end
  end

  defp queue_cases do
    quote do
      describe "Store contract: queue operations" do
        # ADR 0021, decision 3: deliver_on is a time of the queue's clock, not a delay.
        test "a commit applies its queue operations in order with their delivery times", ctx do
          now = ctx.now.()

          assert commit(ctx, "wf1",
                   create: workflow("wf1"),
                   queue: [
                     {:push, "q", "a", 0, now},
                     {:push, "q", "b", 0, now + 1_000},
                     {:push, "q", "c", 0, now},
                     {:remove, "q", "c"},
                     {:remove, "q", "d"},
                     {:push, "q", "d", 0, now}
                   ]
                 ) == :ok

          assert q(ctx, :size, ["q"]) == 3
          refute q(ctx, :contains?, ["q", "c"])
          assert Enum.sort(q(ctx, :pop, ["q", 10, 0])) == ["a", "d"]

          ctx.advance.(999)
          assert q(ctx, :pop, ["q", 10, 0]) == []
          ctx.advance.(1)
          assert q(ctx, :pop, ["q", 10, 0]) == ["b"]
        end

        test "remove and postpone in a commit act on existing messages", ctx do
          create(ctx, workflow("wf1"))
          now = ctx.now.()

          commit(ctx, "wf1", queue: [{:push, "q", "a", 0, now}, {:push, "q", "b", 0, now}])
          assert q(ctx, :contains?, ["q", "a"])

          assert commit(ctx, "wf1",
                   queue: [{:remove, "q", "a"}, {:postpone, "q", "b", 5, now + 500}]
                 ) == :ok

          refute q(ctx, :contains?, ["q", "a"])
          assert q(ctx, :contains?, ["q", "b"])
          assert q(ctx, :pop, ["q", 10, 0]) == []
          ctx.advance.(500)
          assert q(ctx, :pop, ["q", 10, 0]) == ["b"]
        end

        test "a refused commit applies no queue operation", ctx do
          create(ctx, workflow("wf1"))
          push = [queue: [{:push, "q", "x", 0, ctx.now.()}]]

          assert commit(ctx, "wf1", [create: workflow("wf1")] ++ push) == {:error, :conflict}
          assert commit(ctx, "nope", [workflow: workflow("nope")] ++ push) == {:error, :not_found}

          create(ctx, workflow("wf2", tasks: [task("wf2", 1)]))

          stolen = task("wf1", 1, task_id: "wf2_t1")
          assert commit(ctx, "wf1", [upsert_tasks: [stolen]] ++ push) == {:error, :conflict}
          refute q(ctx, :contains?, ["q", "x"])
          assert q(ctx, :size, ["q"]) == 0
        end
      end
    end
  end

  defp outbox_cases do
    quote do
      describe "Store contract: outbox" do
        test "entries come back in the order added, with growing IDs", ctx do
          assert commit(ctx, "wf1",
                   create: workflow("wf1"),
                   outbox: [{:retry_sub_workflow, "c1"}, {:revive_parent, "p", "pt"}]
                 ) == :ok

          create(ctx, workflow("wf2"))
          commit(ctx, "wf2", outbox: [{:retry_sub_workflow, "x"}])
          commit(ctx, "wf1", outbox: [{:retry_sub_workflow, "c2"}])

          assert outbox_effects(ctx, "wf1") == [
                   {:retry_sub_workflow, "c1"},
                   {:revive_parent, "p", "pt"},
                   {:retry_sub_workflow, "c2"}
                 ]

          ids = outbox_ids(ctx, "wf1")
          assert Enum.all?(ids, &(is_integer(&1) and &1 > 0))
          assert ids == Enum.sort(ids) and ids == Enum.uniq(ids)
          [wf2_id] = outbox_ids(ctx, "wf2")
          assert wf2_id > Enum.at(ids, 1) and wf2_id < Enum.at(ids, 2)

          assert s(ctx, :pending_outbox, ["nope"]) == []
        end

        test "ack_outbox deletes only the workflow's own entries", ctx do
          create(ctx, workflow("wf1"))
          create(ctx, workflow("wf2"))
          commit(ctx, "wf1", outbox: [{:retry_sub_workflow, "a"}, {:retry_sub_workflow, "b"}])
          commit(ctx, "wf2", outbox: [{:retry_sub_workflow, "c"}])
          [a, b] = outbox_ids(ctx, "wf1")
          [c] = outbox_ids(ctx, "wf2")

          assert s(ctx, :ack_outbox, ["wf1", [a, c, c + 1_000]]) == :ok
          assert outbox_ids(ctx, "wf1") == [b]
          assert outbox_ids(ctx, "wf2") == [c]

          assert s(ctx, :ack_outbox, ["wf1", [a]]) == :ok
          assert s(ctx, :ack_outbox, ["nope", [b]]) == :ok
          assert outbox_ids(ctx, "wf1") == [b]
        end

        # ADR 0021, decision 4: the commit that writes the failure workflow's output deletes its entry.
        test "outbox_ack in a commit deletes entries with the change, and new ones stay", ctx do
          create(ctx, workflow("wf1"))
          create(ctx, workflow("wf2"))
          commit(ctx, "wf1", outbox: [{:retry_sub_workflow, "a"}, {:retry_sub_workflow, "b"}])
          commit(ctx, "wf2", outbox: [{:retry_sub_workflow, "c"}])
          [a, b] = outbox_ids(ctx, "wf1")
          [c] = outbox_ids(ctx, "wf2")

          assert commit(ctx, "wf1",
                   workflow: workflow("wf1", output: %{"done" => true}),
                   outbox_ack: [a, c],
                   outbox: [{:retry_sub_workflow, "d"}]
                 ) == :ok

          assert {:ok, %Workflow{output: %{"done" => true}}} =
                   s(ctx, :get_workflow, ["wf1", false])

          assert [{^b, _}, {d, {:retry_sub_workflow, "d"}}] = s(ctx, :pending_outbox, ["wf1"])
          assert d > c
          assert outbox_ids(ctx, "wf2") == [c]
        end

        test "a refused commit adds and deletes no entry", ctx do
          create(ctx, workflow("wf1"))
          commit(ctx, "wf1", outbox: [{:retry_sub_workflow, "a"}])
          [a] = outbox_ids(ctx, "wf1")
          fields = [outbox_ack: [a], outbox: [{:retry_sub_workflow, "b"}]]

          assert commit(ctx, "wf1", [create: workflow("wf1")] ++ fields) == {:error, :conflict}
          assert commit(ctx, "nope", fields) == {:error, :not_found}
          assert outbox_ids(ctx, "wf1") == [a]
          assert s(ctx, :pending_outbox, ["nope"]) == []
          assert s(ctx, :outbox_workflow_ids, [nil, 10]) == ["wf1"]
        end

        test "outbox_workflow_ids pages the workflows with entries in binary order", ctx do
          for id <- ~w(b B a c) do
            create(ctx, workflow(id))
            commit(ctx, id, outbox: [{:retry_sub_workflow, "x"}])
          end

          create(ctx, workflow("empty"))

          assert s(ctx, :outbox_workflow_ids, [nil, 10]) == ~w(B a b c)
          assert s(ctx, :outbox_workflow_ids, [nil, 2]) == ~w(B a)
          assert s(ctx, :outbox_workflow_ids, ["a", 2]) == ~w(b c)
          assert s(ctx, :outbox_workflow_ids, ["aa", 10]) == ~w(b c)
          assert s(ctx, :outbox_workflow_ids, ["c", 10]) == []
          assert s(ctx, :outbox_workflow_ids, [nil, 0]) == []

          [id] = outbox_ids(ctx, "b")
          s(ctx, :ack_outbox, ["b", [id]])
          assert s(ctx, :outbox_workflow_ids, [nil, 10]) == ~w(B a c)
        end

        test "remove_workflow deletes its outbox", ctx do
          create(ctx, workflow("wf1"))
          commit(ctx, "wf1", outbox: [{:retry_sub_workflow, "a"}])
          assert s(ctx, :remove_workflow, ["wf1"]) == :ok
          assert s(ctx, :pending_outbox, ["wf1"]) == []
          assert s(ctx, :outbox_workflow_ids, [nil, 10]) == []

          create(ctx, workflow("wf1"))
          assert s(ctx, :pending_outbox, ["wf1"]) == []
        end
      end
    end
  end

  defp wake_cases do
    quote do
      describe "Store contract: re-evaluation times" do
        test "wake sets, keeps, moves earlier and clears the time", ctx do
          create(ctx, workflow("wf1"))
          assert due(ctx, 0) == [{0, "wf1"}]

          commit(ctx, "wf1", wake: {:at, 100})
          assert due(ctx, 99) == []
          assert due(ctx, 100) == [{100, "wf1"}]

          commit(ctx, "wf1", wake: {:before, 150})
          assert due(ctx, 1_000) == [{100, "wf1"}]
          commit(ctx, "wf1", wake: {:before, 50})
          assert due(ctx, 1_000) == [{50, "wf1"}]

          commit(ctx, "wf1", workflow: workflow("wf1", output: %{"x" => 1}))
          assert due(ctx, 1_000) == [{50, "wf1"}]

          commit(ctx, "wf1", wake: {:at, 500})
          assert due(ctx, 1_000) == [{500, "wf1"}]

          commit(ctx, "wf1", wake: :none)
          assert due(ctx, 0) == [{0, "wf1"}]

          commit(ctx, "wf1", wake: {:before, 70})
          assert due(ctx, 1_000) == [{70, "wf1"}]
        end

        test "a create can set the time, and a refused commit does not change it", ctx do
          assert commit(ctx, "wf1", create: workflow("wf1"), wake: {:at, 100}) == :ok
          assert due(ctx, 1_000) == [{100, "wf1"}]

          assert commit(ctx, "wf1", create: workflow("wf1"), wake: {:at, 5}) ==
                   {:error, :conflict}

          assert commit(ctx, "nope", wake: {:at, 5}) == {:error, :not_found}
          assert due(ctx, 1_000) == [{100, "wf1"}]
        end

        test "only RUNNING workflows are due", ctx do
          for {id, status} <- [a: :running, b: :paused, c: :completed, d: :failed] do
            create(ctx, workflow(Atom.to_string(id), status: status))
          end

          assert due(ctx, 0) == [{0, "a"}]

          commit(ctx, "a", workflow: workflow("a", status: :paused), wake: :none)
          commit(ctx, "b", workflow: workflow("b", status: :running))
          assert due(ctx, 0) == [{0, "b"}]
        end

        test "due_workflow_ids pages by time, then ID in binary order", ctx do
          for {id, at} <- [{"a", 20}, {"B", 20}, {"c", 10}, {"d", nil}, {"e", 30}, {"f", 31}] do
            commit(ctx, id, create: workflow(id), wake: if(at, do: {:at, at}, else: :keep))
          end

          all = [{0, "d"}, {10, "c"}, {20, "B"}, {20, "a"}, {30, "e"}]
          assert due(ctx, 30) == all
          assert due(ctx, 30, nil, 2) == Enum.take(all, 2)
          assert due(ctx, 30, {10, "c"}, 2) == [{20, "B"}, {20, "a"}]
          assert due(ctx, 30, {20, "B"}, 10) == [{20, "a"}, {30, "e"}]
          assert due(ctx, 30, {20, "Z"}, 10) == [{20, "a"}, {30, "e"}]
          assert due(ctx, 30, {30, "e"}, 10) == []
          assert due(ctx, 30, {0, "d"}, 1) == [{10, "c"}]
          assert due(ctx, 30, {0, "a"}, 1) == [{0, "d"}]
          assert due(ctx, 30, nil, 0) == []

          s(ctx, :remove_workflow, ["c"])
          assert due(ctx, 15) == [{0, "d"}]
        end
      end
    end
  end

  defp limit_cases do
    quote do
      describe "Store contract: concurrent execution limits" do
        defp in_progress(workflow_id, n, name),
          do: task(workflow_id, n, task_def_name: name, status: :in_progress)

        # ADR 0021, decision 5: the count after the change, over every workflow.
        test "a commit within its limits is applied", ctx do
          create(ctx, workflow("wf1", tasks: [in_progress("wf1", 1, "lim")]))
          create(ctx, workflow("wf2", tasks: [task("wf2", 1, task_def_name: "lim")]))

          assert commit(ctx, "wf2",
                   upsert_tasks: [in_progress("wf2", 1, "lim")],
                   limits: %{"lim" => 2, "other" => 1}
                 ) == :ok

          assert s(ctx, :in_progress_count, ["lim"]) == 2

          # A task leaving IN_PROGRESS in the same commit makes room.
          assert commit(ctx, "wf2",
                   upsert_tasks: [
                     task("wf2", 1, task_def_name: "lim", status: :completed),
                     in_progress("wf2", 2, "lim")
                   ],
                   limits: %{"lim" => 2}
                 ) == :ok

          # So does a deleted one.
          assert commit(ctx, "wf1",
                   upsert_tasks: [in_progress("wf1", 3, "lim")],
                   delete_task_ids: ["wf1_t1"],
                   limits: %{"lim" => 2}
                 ) == :ok
        end

        test "a commit over a limit is refused and changes nothing", ctx do
          create(ctx, workflow("wf1", tasks: [in_progress("wf1", 1, "lim")]))
          create(ctx, workflow("wf2", tasks: [task("wf2", 1, task_def_name: "lim")]))
          commit(ctx, "wf2", outbox: [{:retry_sub_workflow, "a"}], wake: {:at, 100})
          [a] = outbox_ids(ctx, "wf2")
          {:ok, before} = s(ctx, :get_workflow, ["wf2", true])

          over = [
            workflow: workflow("wf2", status: :completed),
            upsert_tasks: [in_progress("wf2", 1, "lim")],
            outbox_ack: [a],
            outbox: [{:retry_sub_workflow, "b"}],
            wake: {:at, 5},
            queue: [{:push, "q", "x", 0, ctx.now.()}],
            limits: %{"lim" => 1}
          ]

          assert commit(ctx, "wf2", over) == {:error, {:limit, "lim"}}
          assert s(ctx, :get_workflow, ["wf2", true]) == {:ok, before}
          assert outbox_ids(ctx, "wf2") == [a]
          assert due(ctx, 1_000) == [{0, "wf1"}, {100, "wf2"}]
          refute q(ctx, :contains?, ["q", "x"])
          assert s(ctx, :in_progress_count, ["lim"]) == 1
        end

        test "a create is checked too, and the first name over its limit is named", ctx do
          create(
            ctx,
            workflow("wf1", tasks: [in_progress("wf1", 1, "b"), in_progress("wf1", 2, "c")])
          )

          new =
            workflow("wf2",
              tasks: [
                in_progress("wf2", 1, "b"),
                in_progress("wf2", 2, "c"),
                in_progress("wf2", 3, "a")
              ]
            )

          assert commit(ctx, "wf2", create: new, limits: %{"c" => 1, "b" => 1, "a" => 1}) ==
                   {:error, {:limit, "b"}}

          assert s(ctx, :get_workflow, ["wf2", false]) == {:error, :not_found}
          assert s(ctx, :get_task, ["wf2_t3"]) == {:error, :not_found}

          assert commit(ctx, "wf2", create: new, limits: %{"a" => 1, "b" => 2, "c" => 2}) == :ok
        end

        # TaskModel#getTaskDefName falls back to the task type.
        test "limits count tasks by task definition name, falling back to the type", ctx do
          create(
            ctx,
            workflow("wf1",
              tasks: [
                task("wf1", 1, task_def_name: nil, task_type: "worker", status: :in_progress)
              ]
            )
          )

          extra = task("wf1", 2, task_def_name: nil, task_type: "worker", status: :in_progress)

          assert commit(ctx, "wf1", upsert_tasks: [extra], limits: %{"worker" => 1}) ==
                   {:error, {:limit, "worker"}}
        end
      end
    end
  end
end
