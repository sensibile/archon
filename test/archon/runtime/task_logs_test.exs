# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Runtime.TaskLogsTest do
  @moduledoc "`Archon.Runtime.TaskLogs` (ADR 0027, decision 6, slice 8d)."

  use ExUnit.Case, async: true

  import Bitwise

  alias Archon.Domain.{TaskExecLog, TaskResult}
  alias Archon.Runtime.TaskLogs

  defp log(text, time \\ nil), do: %TaskExecLog{log: text, created_time: time}

  test "prepare/4 drops null entries and logs, sets the task ID and keeps the first `limit`" do
    logs = [nil, log(nil, 1), log("a", 7)] ++ for(n <- 1..12, do: log("l#{n}")) ++ [nil]

    assert [first | rest] = TaskLogs.prepare(logs, "t", 50, 10)
    assert first == %TaskExecLog{task_id: "t", log: "a", created_time: 7}
    assert length(rest) == 9
    assert Enum.all?(rest, &match?(%TaskExecLog{task_id: "t", created_time: 50}, &1))
    assert List.last(rest).log == "l9"

    assert TaskLogs.prepare(nil, "t", 50, 10) == []
    assert TaskLogs.prepare([log("a")], "t", 50, 0) == []
  end

  test "prepare/4 keeps a createdTime outside a Java long at the nearest long" do
    assert [%{created_time: 0x7FFFFFFFFFFFFFFF}, %{created_time: -0x8000000000000000}] =
             TaskLogs.prepare([log("a", 1 <<< 70), log("b", -(1 <<< 70))], "t", 1, 10)
  end

  test "text/1 puts U+FFFD for invalid UTF-8 and NUL" do
    assert TaskLogs.text("ok é") == "ok é"
    assert TaskLogs.text("a\u0000b" <> <<0xC3>>) == "a�b�"
  end

  test "revived/4 is upstream's line" do
    assert TaskLogs.revived("t", "p.1/x -> c.2/y", "reran", 9) ==
             %TaskExecLog{
               task_id: "t",
               log: "Sub workflow p.1/x -> c.2/y reran.",
               created_time: 9
             }
  end

  test "limit/1 reads task_exec_log_size_limit, 10 by default" do
    assert TaskLogs.limit([]) == 10
    assert TaskLogs.limit(task_exec_log_size_limit: 3) == 3
    assert TaskLogs.limit(task_exec_log_size_limit: -1) == 0
  end

  # Upstream's TaskExecLog constructor stamps a log without createdTime; null is a primitive's 0.
  test "a TaskResult log without createdTime decodes without one, null as 0" do
    json = %{
      "taskId" => "t",
      "workflowInstanceId" => "w",
      "status" => "IN_PROGRESS",
      "logs" => [%{"log" => "a"}, %{"log" => "b", "createdTime" => nil}, nil]
    }

    assert {:ok, %TaskResult{logs: [%{created_time: nil}, %{created_time: 0}, nil]}} =
             TaskResult.from_json(json)
  end
end
