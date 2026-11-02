# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/Terminate.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns the updated task instead of mutating it (ADR 0026, decision 2);
# a terminationStatus that is not a string is not valid instead of a ClassCastException.

defmodule Archon.Decider.SystemTask.Terminate do
  @moduledoc """
  Upstream `Terminate#execute`: a `terminationStatus` of `COMPLETED`, `FAILED` or `TERMINATED`
  completes the task with the `workflowOutput` input as its output (a map as it is, another
  value as `{"output": value}`, none as an empty map). Any other status fails it with
  `given termination status is not valid` and answers `false` (ADR 0026, decisions 2 and 3).

  Ending the workflow is the decide's (`Archon.Decider.Retry.successful_terminate?/1`,
  `Archon.Runtime.Step.Decide`). Upstream casts `terminationStatus` to a string outside any
  `try`; the definition check already rejects one that is not a string (the captured 400s), so
  here such a value is just not valid.
  """

  @behaviour Archon.Decider.SystemTask

  alias Archon.Decider.SystemTask
  alias Archon.Domain.Task

  @statuses ~w(COMPLETED FAILED TERMINATED)

  @impl true
  def execute(_workflow, %Task{input_data: input} = task, _context) do
    if Map.get(input, "terminationStatus") in @statuses do
      SystemTask.changed(%{task | output_data: output(input), status: :completed})
    else
      SystemTask.unchanged(%{
        task
        | reason_for_incompletion: "given termination status is not valid",
          status: :failed
      })
    end
  end

  # getInputFromParam
  defp output(input) do
    case Map.get(input, "workflowOutput") do
      nil -> %{}
      map when is_map(map) -> map
      value -> %{"output" => value}
    end
  end
end
