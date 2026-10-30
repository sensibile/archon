# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Ported from conductor-oss core/src/test/java/com/netflix/conductor/core/execution/TestDeciderService.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: rewritten as ExUnit tests against the pure Decider; clocks, IDs and
# jitter come from the context; external payload storage cases were dropped (ADR 0014).

defmodule Archon.DeciderTest do
  use ExUnit.Case, async: true

  alias Archon.Decider
  alias Archon.Decider.{Context, Outcome, Parameters, Retry, Termination, Timeouts}
  alias Archon.Domain.{SubWorkflowParams, Task, TaskDef, Workflow, WorkflowDef, WorkflowTask}

  @now 1_800_000_000_000
  @int_max 2_147_483_647

  defp context(opts \\ []) do
    counter = :counters.new(1, [])

    new_id = fn ->
      :counters.add(counter, 1, 1)
      "id-#{:counters.get(counter, 1)}"
    end

    Context.new(Keyword.merge([now: @now, new_id: new_id], opts))
  end

  # TestDeciderService#createDefaultWorkflow
  defp default_workflow do
    names = [%{"name" => "The Who", "year" => 1970}, %{"name" => "The Doors", "year" => 1975}]

    %Workflow{
      workflow_definition: %WorkflowDef{name: "TestDeciderService", version: 1},
      input: %{"requestId" => "request id 001", "hasAwards" => true, "channelMapping" => 5},
      output: %{"name" => hd(names), "names" => names, "awards" => 200},
      tasks: [
        %Task{
          reference_task_name: "task2",
          output_data: %{"location" => "http://location"},
          status: :completed
        },
        %Task{
          reference_task_name: "task3",
          output_data: %{"refId" => "abcddef_1234_7890_aaffcc"},
          status: :scheduled
        }
      ]
    }
  end

  # TestDeciderService#createLinearWorkflow
  defp linear_definition do
    params = %{"p1" => "workflow.input.param1", "p2" => "workflow.input.param2"}

    %WorkflowDef{
      name: "Linear Workflow",
      schema_version: 2,
      input_parameters: ["param1", "param2"],
      tasks: [
        %WorkflowTask{
          name: "junit_task_l1",
          task_reference_name: "s1",
          input_parameters: params,
          task_definition: %TaskDef{name: "junit_task_l1"}
        },
        %WorkflowTask{
          name: "junit_task_l2",
          task_reference_name: "s2",
          input_parameters: params,
          task_definition: %TaskDef{name: "junit_task_l2"}
        }
      ]
    }
  end

  defp failed(task_id, extra \\ []), do: struct!(%Task{status: :failed, task_id: task_id}, extra)

  defp retry!(task_def, workflow_task, task, workflow \\ default_workflow(), ctx \\ context()) do
    {:retry, rescheduled, _original} = Retry.retry(task_def, workflow_task, task, workflow, ctx)
    rescheduled
  end

  defp by_ref(%Workflow{tasks: tasks}, ref),
    do: tasks |> Enum.filter(&(&1.reference_task_name == ref)) |> List.last()

  describe "timeouts" do
    # TestDeciderService#testTaskTimeout
    test "task timeout follows the timeout policy" do
      task_def = %TaskDef{name: "test", timeout_policy: :retry, timeout_seconds: 1}
      task = %Task{task_type: "test", start_time: @now - 2_000, status: :in_progress}

      assert {:ok, %Task{status: :timed_out, reason_for_incompletion: reason}} =
               Timeouts.check_task(task_def, task, @now)

      assert reason ==
               "Task timed out after 2 seconds. Timeout configured as 1 seconds. " <>
                 "Timeout policy configured to RETRY"

      assert {:ok, ^task} =
               Timeouts.check_task(%{task_def | timeout_policy: :alert_only}, task, @now)

      assert {:terminate, %Termination{status: :timed_out, task: timed_out},
              %Task{status: :timed_out}} =
               Timeouts.check_task(%{task_def | timeout_policy: :time_out_wf}, task, @now)

      assert timed_out.reason_for_incompletion =~ "TIME_OUT_WF"
      assert {:ok, ^task} = Timeouts.check_task(nil, task, @now)
    end

    test "task timeout counts from the start delay and skips unstarted or terminal tasks" do
      task_def = %TaskDef{timeout_policy: :retry, timeout_seconds: 1}
      task = %Task{start_time: @now - 2_000, start_delay_in_seconds: 2, status: :in_progress}

      assert {:ok, ^task} = Timeouts.check_task(task_def, task, @now)
      unstarted = %{task | start_time: 0, start_delay_in_seconds: 0}
      assert {:ok, ^unstarted} = Timeouts.check_task(task_def, unstarted, @now)
      done = %{task | start_delay_in_seconds: 0, status: :completed}
      assert {:ok, ^done} = Timeouts.check_task(task_def, done, @now)
    end

    # TestDeciderService#testCheckTaskPollTimeout
    test "poll timeout marks a scheduled task" do
      task_def = %TaskDef{name: "test", timeout_policy: :retry, poll_timeout_seconds: 1}
      task = %Task{task_type: "test", scheduled_time: @now - 2_000, status: :scheduled}

      assert {:ok, %Task{status: :timed_out, reason_for_incompletion: reason}} =
               Timeouts.check_poll(task_def, task, @now)

      assert reason ==
               "Task poll timed out after 2 seconds. Poll timeout configured as 1 seconds. " <>
                 "Timeout policy configured to RETRY"

      fresh = %{task | scheduled_time: @now}
      assert {:ok, ^fresh} = Timeouts.check_poll(task_def, fresh, @now)
      delayed = %{task | callback_after_seconds: 5}
      assert {:ok, ^delayed} = Timeouts.check_poll(task_def, delayed, @now)
    end

    # TestDeciderService#testIsResponseTimedOut
    test "response timeout skips asynchronously completed system tasks" do
      task_def = %TaskDef{name: "test_rt", response_timeout_seconds: 10}

      task = %Task{
        task_def_name: "test_rt",
        status: :in_progress,
        task_id: "aa",
        task_type: "SIMPLE",
        update_time: @now - 11_000
      }

      registry = Map.put(Context.new(now: @now).system_tasks, "asyncCompleteSystemTask", true)

      assert Timeouts.response_timed_out?(task_def, task, @now, registry)

      refute Timeouts.response_timed_out?(
               task_def,
               %{task | task_type: "SUB_WORKFLOW"},
               @now,
               registry
             )

      refute Timeouts.response_timed_out?(
               task_def,
               %{task | task_type: "asyncCompleteSystemTask"},
               @now,
               registry
             )

      assert %Task{status: :timed_out, reason_for_incompletion: reason} =
               Timeouts.timeout_response(task_def, task)

      assert reason ==
               "responseTimeout: 10 exceeded for the taskId: aa with Task Definition: test_rt"
    end

    test "a system task's asyncComplete input decides whether it can time out" do
      task_def = %TaskDef{response_timeout_seconds: 10}
      registry = Context.new(now: @now).system_tasks
      task = %Task{task_type: "WAIT", status: :in_progress, update_time: @now - 11_000}

      assert Timeouts.response_timed_out?(task_def, task, @now, registry)

      refute Timeouts.response_timed_out?(
               task_def,
               %{task | input_data: %{"asyncComplete" => true}},
               @now,
               registry
             )

      refute Timeouts.response_timed_out?(
               task_def,
               %{task | workflow_task: %WorkflowTask{async_complete: true}},
               @now,
               registry
             )

      refute Timeouts.response_timed_out?(
               %{task_def | response_timeout_seconds: 0},
               task,
               @now,
               registry
             )
    end

    # TestDeciderService#testCheckWorkflowTimeout
    test "workflow timeout" do
      workflow = %Workflow{
        owner_app: "junit",
        create_time: @now - 10_000,
        workflow_id: "workflow_id",
        workflow_definition: nil
      }

      assert :ok = Timeouts.check_workflow(workflow, @now)

      definition = %WorkflowDef{name: "test"}
      assert :ok = Timeouts.check_workflow(%{workflow | workflow_definition: definition}, @now)

      definition = %{definition | timeout_policy: :alert_only, timeout_seconds: 2}
      assert :ok = Timeouts.check_workflow(%{workflow | workflow_definition: definition}, @now)

      definition = %{definition | timeout_policy: :time_out_wf}
      workflow = %{workflow | workflow_definition: definition}

      assert {:terminate, %Termination{status: :timed_out, reason: reason}} =
               Timeouts.check_workflow(workflow, @now)

      assert reason ==
               "Workflow timed out after 10 seconds. Timeout configured as 2 seconds. " <>
                 "Timeout policy configured to TIME_OUT_WF"

      retried = %{workflow | last_retried_time: @now - 5_000}

      assert {:terminate, %Termination{reason: "Workflow timed out after 5 seconds" <> _rest}} =
               Timeouts.check_workflow(retried, @now)

      assert :ok = Timeouts.check_workflow(%{retried | last_retried_time: @now - 1_000}, @now)
    end
  end

  describe "total timeout" do
    defp total_task(first_scheduled_time) do
      %Task{
        status: :in_progress,
        task_id: "t1",
        task_def_name: "test",
        first_scheduled_time: first_scheduled_time
      }
    end

    # TestDeciderService#testCheckTotalTimeout_notExceeded_noTimeout
    test "not exceeded" do
      task = total_task(@now)
      assert {:ok, ^task} = Timeouts.check_total(%TaskDef{total_timeout_seconds: 60}, task, @now)
    end

    # TestDeciderService#testCheckTotalTimeout_exceeded_timesOutTask
    test "exceeded with RETRY times the task out" do
      task_def = %TaskDef{total_timeout_seconds: 60, timeout_policy: :retry}

      assert {:ok, %Task{status: :timed_out, reason_for_incompletion: reason}} =
               Timeouts.check_total(task_def, total_task(@now - 120_000), @now)

      assert reason ==
               "Task test/t1 exceeded total timeout of 60 seconds (elapsed 120 seconds across " <>
                 "all attempts including retry delays). Timeout policy: RETRY"
    end

    # TestDeciderService#testCheckTotalTimeout_exceeded_timeOutWfPolicy_terminatesWorkflow
    test "exceeded with TIME_OUT_WF terminates" do
      task_def = %TaskDef{total_timeout_seconds: 60, timeout_policy: :time_out_wf}

      assert {:terminate, %Termination{status: :timed_out}, %Task{status: :timed_out}} =
               Timeouts.check_total(task_def, total_task(@now - 120_000), @now)
    end

    # TestDeciderService#testCheckTotalTimeout_zeroDisabled_noTimeout
    test "zero disables it" do
      task = total_task(@now - 120_000)
      assert {:ok, ^task} = Timeouts.check_total(%TaskDef{total_timeout_seconds: 0}, task, @now)
    end

    # TestDeciderService#testCheckTotalTimeout_firstScheduledTimeZero_skipped
    test "tasks without a first scheduled time are skipped" do
      task = total_task(0)
      assert {:ok, ^task} = Timeouts.check_total(%TaskDef{total_timeout_seconds: 1}, task, @now)
    end

    # TestDeciderService#testCheckTotalTimeout_alertOnlyPolicy_onlyLogs
    test "ALERT_ONLY changes nothing" do
      task = total_task(@now - 120_000)
      task_def = %TaskDef{total_timeout_seconds: 60, timeout_policy: :alert_only}
      assert {:ok, ^task} = Timeouts.check_total(task_def, task, @now)
    end

    # TestDeciderService#testRetry_totalTimeoutExceeded_preventsRetry
    test "an exhausted budget prevents a retry" do
      task =
        failed("t1",
          reason_for_incompletion: "test failure",
          first_scheduled_time: @now - 200_000
        )

      task_def = %TaskDef{
        retry_count: 10,
        retry_delay_seconds: 1,
        retry_logic: :fixed,
        total_timeout_seconds: 60
      }

      assert {:terminate, %Termination{status: :failed, reason: reason, task: ^task}, workflow} =
               Retry.retry(task_def, %WorkflowTask{}, task, default_workflow(), context())

      assert reason ==
               "Task t1/null exceeded total timeout of 60 seconds (elapsed 200 seconds across " <>
                 "all attempts). No further retries will be attempted."

      assert workflow.output == %{}

      timed_out = %{task | status: :timed_out}

      assert {:terminate, %Termination{status: :timed_out}, _workflow} =
               Retry.retry(task_def, %WorkflowTask{}, timed_out, default_workflow(), context())
    end

    # TestDeciderService#testRetry_totalTimeoutNotYetExceeded_retriesNormally
    test "a budget not yet exhausted allows the retry" do
      task = failed("t1", reason_for_incompletion: "test failure", first_scheduled_time: @now)

      task_def = %TaskDef{
        retry_count: 10,
        retry_delay_seconds: 1,
        retry_logic: :fixed,
        total_timeout_seconds: 3600
      }

      assert %Task{retry_count: 1, first_scheduled_time: @now} =
               retry!(task_def, %WorkflowTask{}, task)
    end

    # TestDeciderService#testRetry_totalTimeoutExceeded_alertOnlyPolicy_stillTerminates
    test "the budget terminates regardless of ALERT_ONLY" do
      task =
        failed("t1",
          reason_for_incompletion: "worker failure",
          first_scheduled_time: @now - 200_000
        )

      task_def = %TaskDef{
        retry_count: 10,
        retry_delay_seconds: 1,
        total_timeout_seconds: 60,
        timeout_policy: :alert_only
      }

      assert {:terminate, %Termination{}, _workflow} =
               Retry.retry(task_def, %WorkflowTask{}, task, default_workflow(), context())
    end

    # TestDeciderService#testRetry_totalTimeoutZero_doesNotPreventRetry
    test "a disabled budget leaves the retry count in charge" do
      task =
        failed("t1", reason_for_incompletion: "failure", first_scheduled_time: @now - 200_000)

      task_def = %TaskDef{retry_count: 0, total_timeout_seconds: 0}

      assert {:terminate,
              %Termination{reason: "Task t1 failed with status: FAILED and reason: 'failure'"},
              _workflow} =
               Retry.retry(task_def, %WorkflowTask{}, task, default_workflow(), context())
    end
  end

  describe "retry" do
    # TestDeciderService#testTaskRetry
    test "a retried task gets a new ID and re-resolves its input" do
      workflow = put_in(default_workflow().workflow_definition.schema_version, 2)
      env = %{"env_task_id" => "${CPEWF_TASK_ID}"}

      input_params = %{
        "workflowInputParam" => "${workflow.input.requestId}",
        "taskOutputParam" => "${task2.output.location}",
        "constParam" => "Some String value",
        "nullValue" => nil,
        "task2Status" => "${task2.status}",
        "null" => nil,
        "task_id" => "${CPEWF_TASK_ID}",
        "env" => env
      }

      task_input = Parameters.task_input(input_params, workflow, "t1", nil)
      task = failed("t1", input_data: task_input)
      wt = %WorkflowTask{input_parameters: %{"task_id" => "${CPEWF_TASK_ID}", "env" => env}}

      assert {:retry, task2, original} = Retry.retry(%TaskDef{}, wt, task, workflow, context())
      assert original.input_data["task_id"] == "t1"
      assert original.input_data["env"]["env_task_id"] == "t1"
      assert original.retried
      assert task2.task_id == "id-1"
      assert task2.input_data["task_id"] == "id-1"
      assert task2.input_data["env"]["env_task_id"] == "id-1"
      assert task2.retried_task_id == "t1"

      task3 = %{task | status: :failed_with_terminal_error}

      assert {:terminate, %Termination{status: :failed, task: ^task3}, _workflow} =
               Retry.retry(%TaskDef{}, wt, task3, workflow, context())
    end

    # TestDeciderService#testWorkflowTaskRetry
    test "the WorkflowTask retry count overrides the task definition's" do
      workflow = put_in(default_workflow().workflow_definition.schema_version, 2)
      task = failed("t1")
      task_def = %TaskDef{}
      assert task_def.retry_count == 3
      wt = %WorkflowTask{input_parameters: %{"task_id" => "${CPEWF_TASK_ID}"}, retry_count: 1}

      task2 = retry!(task_def, wt, task, workflow)
      assert task2.input_data["task_id"] == task2.task_id

      assert {:terminate, %Termination{status: :failed}, _workflow} =
               Retry.retry(task_def, wt, %{task2 | status: :failed}, workflow, context())
    end

    test "exhausted retries map the task status to the workflow status" do
      workflow = default_workflow()
      task_def = %TaskDef{retry_count: 0}

      for {status, expected} <- [canceled: :terminated, timed_out: :timed_out, failed: :failed] do
        assert {:terminate, %Termination{status: ^expected}, _workflow} =
                 Retry.retry(task_def, nil, failed("t1", status: status), workflow, context())
      end
    end

    test "optional and permissive tasks are not retried past their count, without terminating" do
      task = failed("t1", retry_count: 3)

      for wt <- [%WorkflowTask{optional: true}, %WorkflowTask{permissive: true}] do
        assert :no_retry = Retry.retry(%TaskDef{}, wt, task, default_workflow(), context())
      end
    end

    test "built-in system tasks and missing task definitions are never retried" do
      workflow = default_workflow()

      assert {:terminate, _termination, _workflow} =
               Retry.retry(%TaskDef{}, nil, failed("t1", task_type: "JOIN"), workflow, context())

      assert {:terminate, _termination, _workflow} =
               Retry.retry(nil, nil, failed("t1", task_def_name: "unknown"), workflow, context())

      ctx = context(task_defs: %{"known" => %TaskDef{name: "known"}})

      assert {:retry, %Task{retry_count: 1}, _original} =
               Retry.retry(nil, nil, failed("t1", task_def_name: "known"), workflow, ctx)
    end

    # TestDeciderService#testLinearBackoff
    test "linear backoff" do
      task_def = %TaskDef{
        retry_delay_seconds: 60,
        retry_logic: :linear_backoff,
        backoff_scale_factor: 2
      }

      task2 = retry!(task_def, %WorkflowTask{}, failed("t1"))
      assert task2.callback_after_seconds == 120
      task3 = retry!(task_def, %WorkflowTask{}, task2)
      assert task3.callback_after_seconds == 240
      task4 = retry!(task_def, %WorkflowTask{}, task3)
      assert task4.callback_after_seconds == 360
      assert task4.start_delay_in_seconds == 360

      task_def = %{task_def | retry_count: @int_max}
      task5 = retry!(task_def, %WorkflowTask{}, %{task4 | retry_count: @int_max - 100})
      assert task5.callback_after_seconds == @int_max
    end

    # TestDeciderService#testExponentialBackoff
    test "exponential backoff" do
      task_def = %TaskDef{retry_delay_seconds: 60, retry_logic: :exponential_backoff}
      task2 = retry!(task_def, %WorkflowTask{}, failed("t1"))
      assert task2.callback_after_seconds == 60
      task3 = retry!(task_def, %WorkflowTask{}, task2)
      assert task3.callback_after_seconds == 120
      task4 = retry!(task_def, %WorkflowTask{}, task3)
      assert task4.callback_after_seconds == 240

      task_def = %{task_def | retry_count: @int_max}
      task5 = retry!(task_def, %WorkflowTask{}, %{task4 | retry_count: @int_max - 100})
      assert task5.callback_after_seconds == @int_max
    end

    test "Java int arithmetic wraps before the overflow check" do
      # 3 * 2^30 wraps to -1073741824 in Java `int`, so the delay becomes Integer.MAX_VALUE;
      # 5 * 2^30 wraps to the positive 1073741824 and is kept as is.
      task_def = %TaskDef{retry_count: 100, retry_logic: :exponential_backoff}

      assert retry!(
               %{task_def | retry_delay_seconds: 3},
               %WorkflowTask{},
               failed("t1", retry_count: 30)
             ).callback_after_seconds ==
               @int_max

      assert retry!(
               %{task_def | retry_delay_seconds: 5},
               %WorkflowTask{},
               failed("t1", retry_count: 30)
             ).callback_after_seconds ==
               1_073_741_824
    end

    # TestDeciderService#testExponentialBackoffWithMaxDelayCap
    test "exponential backoff with a delay cap" do
      task_def = %TaskDef{
        retry_count: 10,
        retry_delay_seconds: 60,
        retry_logic: :exponential_backoff,
        max_retry_delay_seconds: 200
      }

      delays =
        Enum.scan(1..4, failed("t1"), fn _n, task -> retry!(task_def, %WorkflowTask{}, task) end)
        |> Enum.map(& &1.callback_after_seconds)

      assert delays == [60, 120, 200, 200]
    end

    # TestDeciderService#testLinearBackoffWithMaxDelayCap
    test "linear backoff with a delay cap" do
      task_def = %TaskDef{
        retry_count: 10,
        retry_delay_seconds: 60,
        retry_logic: :linear_backoff,
        backoff_scale_factor: 2,
        max_retry_delay_seconds: 250
      }

      delays =
        Enum.scan(1..4, failed("t1"), fn _n, task -> retry!(task_def, %WorkflowTask{}, task) end)
        |> Enum.map(& &1.callback_after_seconds)

      assert delays == [120, 240, 250, 250]
    end

    # TestDeciderService#testMaxRetryDelaySeconds_zeroMeansNoCap
    test "a zero cap is no cap" do
      task_def = %TaskDef{
        retry_count: 10,
        retry_delay_seconds: 10,
        retry_logic: :exponential_backoff,
        max_retry_delay_seconds: 0
      }

      delays =
        Enum.scan(1..3, failed("t1"), fn _n, task -> retry!(task_def, %WorkflowTask{}, task) end)
        |> Enum.map(& &1.callback_after_seconds)

      assert delays == [10, 20, 40]
    end

    # TestDeciderService#testMaxRetryDelaySeconds_capLessThanBaseDelay
    test "a cap below the base delay applies from the first retry" do
      task_def = %TaskDef{retry_count: 10, retry_delay_seconds: 60, max_retry_delay_seconds: 10}
      t1 = retry!(task_def, %WorkflowTask{}, failed("t1"))
      assert t1.callback_after_seconds == 10
      assert retry!(task_def, %WorkflowTask{}, t1).callback_after_seconds == 10
    end

    # TestDeciderService#testJitterAddedToRetryDelay
    test "jitter is added to callback_after_ms only" do
      task_def = %TaskDef{retry_count: 10, retry_delay_seconds: 60, backoff_jitter_ms: 5000}
      ctx = context(jitter: fn 5000 -> 4321 end)
      retried = retry!(task_def, %WorkflowTask{}, failed("t1"), default_workflow(), ctx)
      assert retried.callback_after_seconds == 60
      assert retried.callback_after_ms == 64_321

      ranged = retry!(task_def, %WorkflowTask{}, failed("t1"))
      assert ranged.callback_after_ms in 60_000..65_000
    end

    # TestDeciderService#testJitterZeroMeansNoJitter
    test "zero jitter adds nothing" do
      task_def = %TaskDef{retry_count: 10, retry_delay_seconds: 60, backoff_jitter_ms: 0}
      ctx = context(jitter: fn _max -> flunk("jitter must not be drawn") end)
      retried = retry!(task_def, %WorkflowTask{}, failed("t1"), default_workflow(), ctx)
      assert retried.callback_after_seconds == 60
      assert retried.callback_after_ms == 60_000
    end

    # TestDeciderService#testJitterWithExponentialBackoff
    test "jitter with exponential backoff" do
      task_def = %TaskDef{
        retry_count: 10,
        retry_delay_seconds: 10,
        retry_logic: :exponential_backoff,
        backoff_jitter_ms: 2000
      }

      task2 = retry!(task_def, %WorkflowTask{}, failed("t1"))
      assert task2.callback_after_seconds == 10
      assert task2.callback_after_ms in 10_000..12_000
      task3 = retry!(task_def, %WorkflowTask{}, task2)
      assert task3.callback_after_seconds == 20
      assert task3.callback_after_ms in 20_000..22_000
    end

    # TestDeciderService#testJitterMs_minimumOneMs
    test "one millisecond of jitter" do
      task_def = %TaskDef{retry_count: 10, retry_delay_seconds: 30, backoff_jitter_ms: 1}
      retried = retry!(task_def, %WorkflowTask{}, failed("t1"))
      assert retried.callback_after_seconds == 30
      assert retried.callback_after_ms in 30_000..30_001
    end

    # TestDeciderService#testJitter_producesVariance
    test "the default jitter varies" do
      task_def = %TaskDef{retry_count: 20, retry_delay_seconds: 10, backoff_jitter_ms: 2000}

      distinct =
        for i <- 0..9, into: MapSet.new() do
          retry!(task_def, %WorkflowTask{}, failed("t-#{i}")).callback_after_ms
        end

      assert MapSet.size(distinct) > 1
    end

    # TestDeciderService#testRetryClearsStaleOutputArtifacts
    test "a retry clears the previous attempt's runtime state" do
      task =
        failed("t1",
          update_time: 12_345,
          external_output_payload_storage_path: "old-output.json",
          output_data: %{"result" => "stale"},
          input_data: %{"subWorkflowId" => "old-subworkflow-id", "kept" => 1},
          worker_id: "w",
          poll_count: 2,
          seq: 4,
          scheduled_time: 1,
          start_time: 2,
          end_time: 3,
          callback_after_ms: 9,
          sub_workflow_id: "sw",
          reason_for_incompletion: "boom",
          first_scheduled_time: 77
        )

      task_def = %TaskDef{retry_count: 10, retry_delay_seconds: 0}

      assert {:retry, retried, original} =
               Retry.retry(task_def, %WorkflowTask{}, task, default_workflow(), context())

      assert %Task{
               update_time: 0,
               external_output_payload_storage_path: nil,
               output_data: %{},
               input_data: %{"kept" => 1},
               worker_id: nil,
               poll_count: 0,
               seq: 0,
               scheduled_time: 0,
               start_time: 0,
               end_time: 0,
               callback_after_ms: 0,
               sub_workflow_id: nil,
               status: :scheduled,
               retried: false,
               reason_for_incompletion: "boom",
               first_scheduled_time: 77
             } = retried

      # TaskModel.copy() shares inputData, so upstream also drops subWorkflowId from the failed
      # task it persists.
      assert original.input_data == %{"kept" => 1}
      assert original.output_data == %{"result" => "stale"}
    end

    test "retry input resolves against the failed task without its subWorkflowId" do
      task =
        failed("t1", reference_task_name: "t", input_data: %{"subWorkflowId" => "stale-child"})

      workflow = %{
        default_workflow()
        | workflow_definition: %WorkflowDef{schema_version: 2},
          tasks: [task]
      }

      wt = %WorkflowTask{input_parameters: %{"previous" => "${t.input.subWorkflowId}"}}

      assert {:retry, retried, _original} = Retry.retry(%TaskDef{}, wt, task, workflow, context())
      assert Map.fetch!(retried.input_data, "previous") == nil
    end

    test "a terminating retry sets the workflow output from the failed task" do
      workflow = %{default_workflow() | tasks: [%Task{output_data: %{"last" => 1}}]}
      task = failed("t1", output_data: %{"failed" => true})

      assert {:terminate, _termination, %Workflow{output: %{"failed" => true}}} =
               Retry.retry(%TaskDef{retry_count: 0}, nil, task, workflow, context())
    end
  end

  describe "decide" do
    defp linear_workflow(tasks) do
      %Workflow{workflow_definition: linear_definition(), status: :running, tasks: tasks}
    end

    defp completed(ref, type, seq, extra \\ []) do
      struct!(
        %Task{task_type: type, reference_task_name: ref, seq: seq, status: :completed},
        extra
      )
    end

    # TestDeciderService#testDecideSuccessfulWorkflow
    test "a linear workflow schedules the next task, then completes" do
      task1 = completed("s1", "junit_task_l1", 1)
      workflow = linear_workflow([task1])

      assert {:ok, %Outcome{} = outcome} = Decider.decide(workflow, context())
      refute by_ref(outcome.workflow, "s1").retried
      assert by_ref(outcome.workflow, "s1").executed
      assert [%Task{reference_task_name: "s1", executed: true}] = outcome.tasks_to_be_updated

      assert [
               %Task{reference_task_name: "s2", task_type: "junit_task_l2", status: :scheduled} =
                 s2
             ] =
               outcome.tasks_to_be_scheduled

      assert s2.task_id == "id-1"
      assert s2.scheduled_time == @now
      assert s2.input_data == %{"p1" => "workflow.input.param1", "p2" => "workflow.input.param2"}
      refute outcome.complete?
      assert workflow.tasks == [task1], "decide must not change its input"

      task2 = completed("s2", "junit_task_l2", 2, output_data: %{"out" => 2})
      workflow = %{outcome.workflow | tasks: outcome.workflow.tasks ++ [task2]}

      assert {:ok, outcome} = Decider.decide(workflow, context())
      assert by_ref(outcome.workflow, "s2").executed
      refute by_ref(outcome.workflow, "s2").retried
      assert [%Task{reference_task_name: "s2"}] = outcome.tasks_to_be_updated
      assert outcome.tasks_to_be_scheduled == []
      assert outcome.complete?
      assert outcome.workflow.output == %{"out" => 2}
    end

    # TestDeciderService#testDecideWithLoopTask
    test "a task inside a loop iteration schedules its successor for the same iteration" do
      workflow = linear_workflow([completed("s1", "junit_task_l1", 1, iteration: 1)])

      assert {:ok, outcome} = Decider.decide(workflow, context())
      refute by_ref(outcome.workflow, "s1").retried
      assert [%Task{reference_task_name: "s1"}] = outcome.tasks_to_be_updated

      assert [%Task{reference_task_name: "s2__1", iteration: 1}] = outcome.tasks_to_be_scheduled
      refute outcome.complete?
    end

    # TestDeciderService#testDecideFailedTask
    test "a failed task is retried" do
      wt = %WorkflowTask{
        task_reference_name: "s1",
        name: "junit_task_l1",
        task_definition: %TaskDef{name: "junit_task_l1"}
      }

      task = %Task{
        task_type: "junit_task_l1",
        reference_task_name: "s1",
        seq: 1,
        status: :failed,
        task_id: "failed-1",
        workflow_task: wt
      }

      assert {:ok, outcome} = Decider.decide(linear_workflow([task]), context())
      refute by_ref(outcome.workflow, "s1").executed
      assert by_ref(outcome.workflow, "s1").retried

      assert [%Task{reference_task_name: "s1", task_id: "failed-1", retried: true}] =
               outcome.tasks_to_be_updated

      assert [
               %Task{
                 reference_task_name: "s1",
                 task_id: "id-1",
                 retry_count: 1,
                 retried_task_id: "failed-1"
               }
             ] =
               outcome.tasks_to_be_scheduled

      refute outcome.complete?
    end

    # TestDeciderService#testDecideDoesNotFailScheduledSubWorkflowTask
    test "a scheduled system task is handed back to be scheduled" do
      wt = %WorkflowTask{
        name: "child_workflow",
        task_reference_name: "sub1",
        type: "SUB_WORKFLOW",
        task_definition: %TaskDef{name: "child_workflow"},
        sub_workflow_param: %SubWorkflowParams{}
      }

      task = %Task{
        task_type: "SUB_WORKFLOW",
        task_def_name: "child_workflow",
        reference_task_name: "sub1",
        seq: 1,
        status: :scheduled,
        workflow_task: wt
      }

      workflow = %Workflow{
        workflow_definition: %WorkflowDef{name: "scheduled_subworkflow_workflow", tasks: [wt]},
        status: :running,
        tasks: [task]
      }

      assert {:ok, outcome} = Decider.decide(workflow, context())
      refute outcome.complete?
      assert outcome.tasks_to_be_updated == []
      assert [^task] = outcome.tasks_to_be_scheduled
    end

    test "a new workflow schedules its first task with resolved input" do
      definition = %{
        linear_definition()
        | tasks: [
            %{hd(linear_definition().tasks) | input_parameters: %{"x" => "${workflow.input.x}"}}
          ]
      }

      workflow = %Workflow{
        workflow_id: "wf-1",
        correlation_id: "corr",
        priority: 3,
        input: %{"x" => 7},
        workflow_definition: definition
      }

      assert {:ok, outcome} = Decider.decide(workflow, context())

      assert [
               %Task{
                 reference_task_name: "s1",
                 task_type: "junit_task_l1",
                 task_def_name: "junit_task_l1",
                 status: :scheduled,
                 input_data: %{"x" => 7},
                 workflow_instance_id: "wf-1",
                 workflow_type: "Linear Workflow",
                 correlation_id: "corr",
                 workflow_priority: 3,
                 response_timeout_seconds: 3600,
                 rate_limit_frequency_in_seconds: 1
               }
             ] = outcome.tasks_to_be_scheduled

      assert outcome.tasks_to_be_updated == []
      assert outcome.workflow == workflow
    end

    test "a definition without tasks terminates as completed" do
      workflow = %Workflow{workflow_definition: %WorkflowDef{tasks: []}}

      assert {:terminate,
              %Termination{reason: "No tasks found to be executed", status: :completed},
              %Outcome{workflow: ^workflow}} = Decider.decide(workflow, context())
    end

    test "a re-run reschedules the first task" do
      # Only a workflow with nothing left to process starts over, so the first task is skipped.
      task = %Task{reference_task_name: "s1", status: :skipped, retry_count: 2}

      workflow = %{
        linear_workflow([task])
        | re_run_from_workflow_id: "old"
      }

      assert {:ok, outcome} = Decider.decide(workflow, context())

      assert [%Task{reference_task_name: "s1", status: :scheduled, retried: true, retry_count: 0}] =
               outcome.tasks_to_be_scheduled

      assert hd(outcome.workflow.tasks).status == :scheduled
    end

    test "terminal and paused workflows are left alone" do
      task1 = completed("s1", "junit_task_l1", 1)

      for status <- [:completed, :paused] do
        workflow = %{linear_workflow([task1]) | status: status}

        assert {:ok, %Outcome{tasks_to_be_scheduled: [], workflow: ^workflow}} =
                 Decider.decide(workflow, context())
      end
    end

    test "a task timeout with TIME_OUT_WF terminates and keeps the timed-out task" do
      definition =
        update_in(linear_definition().tasks, fn [wt | rest] ->
          [
            %{wt | task_definition: %TaskDef{timeout_seconds: 1, timeout_policy: :time_out_wf}}
            | rest
          ]
        end)

      task = %Task{reference_task_name: "s1", status: :in_progress, start_time: @now - 5_000}
      workflow = %Workflow{workflow_definition: definition, tasks: [task]}

      assert {:terminate, %Termination{status: :timed_out}, outcome} =
               Decider.decide(workflow, context())

      assert [
               %Task{
                 status: :timed_out,
                 reason_for_incompletion: "Task timed out after 5 seconds" <> _
               }
             ] =
               outcome.workflow.tasks
    end

    test "a response timeout with retries left reschedules the task" do
      definition =
        update_in(linear_definition().tasks, fn [wt | rest] ->
          [
            %{
              wt
              | task_definition: %TaskDef{response_timeout_seconds: 10, retry_delay_seconds: 0}
            }
            | rest
          ]
        end)

      task = %Task{
        task_id: "t1",
        reference_task_name: "s1",
        status: :in_progress,
        update_time: @now - 11_000
      }

      workflow = %Workflow{workflow_definition: definition, tasks: [task]}

      assert {:ok, outcome} = Decider.decide(workflow, context())

      assert [%Task{task_id: "t1", status: :timed_out, retried: true}] =
               outcome.tasks_to_be_updated

      assert [%Task{task_id: "id-1", status: :scheduled, retry_count: 1}] =
               outcome.tasks_to_be_scheduled
    end

    test "an optional task out of retries completes with errors and the workflow goes on" do
      definition =
        update_in(linear_definition().tasks, fn [wt | rest] -> [%{wt | optional: true} | rest] end)

      wt = hd(definition.tasks)
      task = %Task{reference_task_name: "s1", status: :failed, retry_count: 3, workflow_task: wt}

      assert {:ok, outcome} =
               Decider.decide(
                 %Workflow{workflow_definition: definition, tasks: [task]},
                 context()
               )

      assert [%Task{status: :completed_with_errors, executed: true}] = outcome.tasks_to_be_updated
      assert [%Task{reference_task_name: "s2"}] = outcome.tasks_to_be_scheduled
    end

    test "a permissive task out of retries lets the workflow go on, then fails it at the end" do
      definition =
        update_in(linear_definition().tasks, fn [wt | rest] ->
          [%{wt | permissive: true} | rest]
        end)

      wt = hd(definition.tasks)

      task = %Task{
        task_id: "p1",
        reference_task_name: "s1",
        status: :failed,
        retry_count: 3,
        reason_for_incompletion: "bad",
        workflow_task: wt
      }

      assert {:ok, outcome} =
               Decider.decide(
                 %Workflow{workflow_definition: definition, tasks: [task]},
                 context()
               )

      assert [%Task{status: :failed, executed: true}] = outcome.tasks_to_be_updated
      assert [%Task{reference_task_name: "s2"} = s2] = outcome.tasks_to_be_scheduled

      workflow = %{
        outcome.workflow
        | tasks: outcome.workflow.tasks ++ [%{s2 | status: :completed}]
      }

      assert {:terminate, %Termination{status: :failed, reason: reason}, _outcome} =
               Decider.decide(workflow, context())

      assert reason == "Task p1 failed with status: FAILED and reason: 'bad'"
    end

    # DeciderService#decide calls checkWorkflowTimeout before it looks at PAUSED.
    test "a timed-out TIME_OUT_WF workflow terminates as TIMED_OUT, even when paused" do
      definition = %{linear_definition() | timeout_policy: :time_out_wf, timeout_seconds: 2}
      task = %Task{reference_task_name: "s1", task_type: "junit_task_l1", status: :in_progress}

      workflow = %Workflow{
        workflow_definition: definition,
        create_time: @now - 10_000,
        tasks: [task]
      }

      for status <- [:running, :paused] do
        assert {:terminate, %Termination{status: :timed_out, reason: reason}, _outcome} =
                 Decider.decide(%{workflow | status: status}, context())

        assert reason ==
                 "Workflow timed out after 10 seconds. Timeout configured as 2 seconds. " <>
                   "Timeout policy configured to TIME_OUT_WF"
      end
    end

    # DeciderService#decide judges each permissive task by its attempt with the highest retry
    # count, whatever the order of the workflow's tasks.
    test "a permissive task that failed, then succeeded on retry, lets the workflow complete" do
      definition =
        update_in(linear_definition().tasks, fn [wt | rest] ->
          [%{wt | permissive: true} | rest]
        end)

      [wt1, wt2] = definition.tasks

      failed_attempt = %Task{
        task_id: "p1",
        reference_task_name: "s1",
        task_type: "junit_task_l1",
        status: :failed,
        reason_for_incompletion: "bad",
        retry_count: 0,
        retried: true,
        executed: true,
        workflow_task: wt1
      }

      retried_attempt = %Task{
        task_id: "p2",
        reference_task_name: "s1",
        task_type: "junit_task_l1",
        status: :completed,
        retry_count: 1,
        executed: true,
        workflow_task: wt1
      }

      s2 = %Task{
        task_id: "t2",
        reference_task_name: "s2",
        task_type: "junit_task_l2",
        status: :completed,
        workflow_task: wt2
      }

      for attempts <- [[failed_attempt, retried_attempt], [retried_attempt, failed_attempt]] do
        workflow = %Workflow{
          workflow_definition: definition,
          status: :running,
          tasks: attempts ++ [s2]
        }

        assert {:ok, %Outcome{complete?: true}} = Decider.decide(workflow, context())
      end
    end

    test "an exhausted failure terminates with the failed task" do
      task = %Task{
        task_id: "t1",
        reference_task_name: "s1",
        task_type: "junit_task_l1",
        status: :failed,
        retry_count: 3,
        reason_for_incompletion: "boom",
        output_data: %{"partial" => 1}
      }

      assert {:terminate, %Termination{status: :failed, task: %Task{task_id: "t1"}} = termination,
              outcome} =
               Decider.decide(linear_workflow([task]), context())

      assert termination.reason == "Task t1 failed with status: FAILED and reason: 'boom'"
      assert outcome.workflow.output == %{"partial" => 1}
    end

    test "an unregistered task type without a task definition terminates the workflow" do
      definition = %WorkflowDef{
        tasks: [%WorkflowTask{name: "custom", task_reference_name: "c1", type: "CUSTOM"}]
      }

      workflow = %Workflow{workflow_definition: definition}

      assert {:terminate,
              %Termination{
                reason:
                  "Invalid task specified. Cannot find task by name custom in the task definitions",
                status: :failed
              }, _outcome} = Decider.decide(workflow, context())

      ctx =
        context(task_defs: %{"custom" => %TaskDef{name: "custom", rate_limit_per_frequency: 5}})

      assert {:ok, %Outcome{tasks_to_be_scheduled: [task]}} = Decider.decide(workflow, ctx)

      assert %Task{
               task_type: "CUSTOM",
               task_def_name: "custom",
               status: :scheduled,
               rate_limit_per_frequency: 5
             } =
               task
    end

    test "skipped tasks are passed over" do
      definition = %{
        linear_definition()
        | tasks:
            linear_definition().tasks ++
              [%WorkflowTask{name: "junit_task_l3", task_reference_name: "s3"}]
      }

      tasks = [
        completed("s1", "junit_task_l1", 1),
        %Task{reference_task_name: "s2", status: :skipped}
      ]

      assert {:ok, outcome} =
               Decider.decide(%Workflow{workflow_definition: definition, tasks: tasks}, context())

      assert [%Task{reference_task_name: "s3"}] = outcome.tasks_to_be_scheduled
    end
  end

  # TestDeciderService#testGetTasksToBeScheduled
  test "tasks_to_be_scheduled maps SIMPLE tasks" do
    workflow = %Workflow{workflow_definition: linear_definition(), status: :running}

    for name <- ["s1", "s2"] do
      wt = %WorkflowTask{
        name: name,
        task_reference_name: name,
        type: "SIMPLE",
        task_definition: %TaskDef{name: name}
      }

      assert {:ok, [%Task{reference_task_name: ^name}]} =
               Decider.tasks_to_be_scheduled(workflow, wt, 0, nil, context())
    end

    started = %{workflow | tasks: [%Task{reference_task_name: "s1", status: :in_progress}]}
    wt = %WorkflowTask{name: "s1", task_reference_name: "s1"}
    assert {:ok, []} = Decider.tasks_to_be_scheduled(started, wt, 0, nil, context())
  end

  # TestDeciderService#testFilterNextLoopOverTasks
  test "filter_next_loop_over_tasks" do
    task1 = %Task{
      reference_task_name: "task1",
      status: :completed,
      task_id: "task1",
      iteration: 1
    }

    task2 = %Task{reference_task_name: "task2", status: :scheduled, task_id: "task2"}
    task3 = %Task{reference_task_name: "task3__1", status: :in_progress, task_id: "task3__1"}
    task4 = %Task{reference_task_name: "task4", status: :scheduled, task_id: "task4"}
    task5 = %Task{reference_task_name: "task5", status: :completed, task_id: "task5"}
    workflow = %Workflow{tasks: [task1, task2, task3, task4, task5]}

    # Upstream passes the workflow's own task objects and renames them in place, so task3 becomes
    # `task3__1__1` in the workflow too and is dropped. Mapped next tasks are always new objects,
    # so the case is expressed with a fresh `task3` that gets the in-progress `task3__1` name.
    next = [task2, %Task{reference_task_name: "task3"}, task4]
    tasks = Decider.filter_next_loop_over_tasks(next, task1, workflow)

    assert length(tasks) == 2

    assert Enum.all?(
             tasks,
             &(String.ends_with?(&1.reference_task_name, "__1") and &1.iteration == 1)
           )
  end

  describe "update_output" do
    # TestDeciderService#testUpdateWorkflowOutput
    test "copies the last task's output" do
      workflow = %Workflow{workflow_definition: %WorkflowDef{}}
      assert Retry.update_output(workflow, nil).output == %{}

      workflow = %{workflow | tasks: [%Task{output_data: %{"taskKey" => "taskValue"}}]}
      assert Retry.update_output(workflow, nil).output == %{"taskKey" => "taskValue"}
    end

    # TestDeciderService#testUpdateWorkflowOutput_WhenDefinitionHasOutputParameters
    test "resolves the definition's output parameters" do
      workflow = %Workflow{
        workflow_definition: %WorkflowDef{output_parameters: %{"workflowKey" => "workflowValue"}},
        tasks: [%Task{reference_task_name: "test_task", output_data: %{"taskKey" => "taskValue"}}]
      }

      assert Retry.update_output(workflow, nil).output == %{"workflowKey" => "workflowValue"}
    end

    # TestDeciderService#testUpdateWorkflowOutput_WhenWorkflowHasTerminateTask (the external
    # payload storage half is not ported, ADR 0014)
    test "a successful TERMINATE task's output wins" do
      workflow = %Workflow{
        tasks: [
          %Task{
            task_type: "TERMINATE",
            status: :completed,
            output_data: %{"taskKey" => "taskValue"}
          },
          %Task{output_data: %{"other" => 1}}
        ]
      }

      assert Retry.update_output(workflow, nil).output == %{"taskKey" => "taskValue"}

      empty = put_in(workflow.tasks, [%Task{task_type: "TERMINATE", status: :completed}])
      assert Retry.update_output(%{empty | output: %{"old" => 1}}, nil).output == %{}
    end

    test "uses the given task instead of the last one" do
      workflow = %Workflow{
        workflow_definition: %WorkflowDef{},
        tasks: [%Task{output_data: %{"a" => 1}}, %Task{output_data: %{"b" => 2}}]
      }

      assert Retry.update_output(workflow, hd(workflow.tasks)).output == %{"a" => 1}
    end
  end

  describe "workflow_complete?" do
    # TestDeciderService#createConditionalWF
    defp conditional_definition do
      wt1 = %WorkflowTask{name: "junit_task_1", task_reference_name: "t1"}
      wt2 = %WorkflowTask{name: "junit_task_2", task_reference_name: "t2"}
      wt3 = %WorkflowTask{name: "junit_task_3", task_reference_name: "t3"}

      decision2 = %WorkflowTask{
        type: "DECISION",
        case_value_param: "case",
        name: "conditional2",
        task_reference_name: "conditional2",
        decision_cases: %{"one" => [wt1, wt3], "two" => [wt2]}
      }

      decision = %WorkflowTask{
        type: "DECISION",
        case_value_param: "case",
        name: "conditional",
        task_reference_name: "conditional",
        decision_cases: %{"nested" => [decision2], "three" => [wt3]},
        default_case: [wt2]
      }

      final = %WorkflowTask{
        name: "finalcondition",
        task_reference_name: "tf",
        type: "DECISION",
        case_value_param: "finalCase",
        decision_cases: %{
          "notify" => [%WorkflowTask{name: "junit_task_4", task_reference_name: "junit_task_4"}]
        }
      }

      %WorkflowDef{name: "Conditional Workflow", tasks: [decision, final]}
    end

    # TestDeciderService#testCheckForWorkflowCompletion
    test "a conditional workflow" do
      terminate = %WorkflowTask{
        type: "TERMINATE",
        task_reference_name: "terminate",
        name: "terminate",
        input_parameters: %{"terminationStatus" => "COMPLETED"}
      }

      definition = update_in(conditional_definition().tasks, &(&1 ++ [terminate]))
      workflow = %Workflow{workflow_definition: definition}
      refute Decider.workflow_complete?(workflow)

      dec_task = %Task{
        task_type: "SIMPLE",
        reference_task_name: "conditional2",
        status: :completed
      }

      task1 = %Task{reference_task_name: "t1", status: :completed}
      workflow = %{workflow | tasks: [dec_task, task1]}
      refute Decider.workflow_complete?(workflow)

      # Upstream sets the TERMINATE type on the decision task by mistake (`decTask` instead of
      # `terminateTask`); the check stops at the first successful TERMINATE task either way.
      task2 = %Task{reference_task_name: "t2", status: :scheduled}
      terminate_task = %Task{reference_task_name: "terminate", status: :completed}
      dec_task = %{dec_task | task_type: "TERMINATE"}
      workflow = %{workflow | tasks: [dec_task, task1, task2, terminate_task]}
      assert Decider.workflow_complete?(workflow)
    end

    # TestDeciderService#testWorkflowCompleted_WhenAllOptionalTasksInTerminalState
    test "only optional tasks" do
      definition = %WorkflowDef{
        schema_version: 2,
        name: "only_optional_tasks_workflow",
        tasks: [
          %WorkflowTask{name: "junit_task_1", task_reference_name: "o1", optional: true},
          %WorkflowTask{name: "junit_task_2", task_reference_name: "o2", optional: true}
        ]
      }

      workflow = %Workflow{workflow_definition: definition, status: :running}
      refute Decider.workflow_complete?(workflow)

      task1 = %Task{
        task_type: "SIMPLE",
        reference_task_name: "o1",
        status: :failed_with_terminal_error
      }

      task2 = %Task{
        task_type: "SIMPLE",
        reference_task_name: "o2",
        status: :completed_with_errors
      }

      assert Decider.workflow_complete?(%{workflow | tasks: [task1, task2]})
    end

    test "an unscheduled successor keeps the workflow open" do
      workflow = %Workflow{
        workflow_definition: %{linear_definition() | tasks: linear_definition().tasks},
        tasks: [
          %Task{reference_task_name: "s1", status: :completed},
          %Task{reference_task_name: "s2", status: :completed}
        ]
      }

      assert Decider.workflow_complete?(workflow)

      only_s2 = %{workflow | tasks: [%Task{reference_task_name: "s2", status: :completed}]}
      refute Decider.workflow_complete?(only_s2)
    end
  end
end
