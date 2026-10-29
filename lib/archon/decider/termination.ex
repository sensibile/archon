# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/exception/TerminateWorkflowException.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: an exception became a value returned by the Decider.

defmodule Archon.Decider.Termination do
  @moduledoc """
  Why the Decider ends a workflow: upstream `TerminateWorkflowException` as a value.

  `status` is the workflow status the runtime moves to (`:failed` unless upstream names another)
  and `task` the task that caused it, when upstream passes one.
  """

  alias Archon.Domain.{Task, Workflow}

  @enforce_keys [:reason]
  defstruct [:reason, :task, status: :failed]

  @type t :: %__MODULE__{reason: String.t(), status: Workflow.status(), task: Task.t() | nil}

  @doc "Builds a termination."
  @spec new(String.t(), Workflow.status(), Task.t() | nil) :: t()
  def new(reason, status \\ :failed, task \\ nil),
    do: %__MODULE__{reason: reason, status: status, task: task}
end
