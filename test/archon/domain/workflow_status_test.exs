# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).

defmodule Archon.Domain.WorkflowStatusTest do
  use ExUnit.Case, async: true

  alias Archon.Domain.{Workflow, WorkflowStatus}

  @workflow %Workflow{
    workflow_id: "w",
    correlation_id: "c",
    status: :completed,
    output: %{"y" => 3},
    variables: %{"v" => 1}
  }

  test "the output and variables only when asked" do
    assert WorkflowStatus.to_json(WorkflowStatus.new(@workflow, false, false)) == %{
             "workflowId" => "w",
             "correlationId" => "c",
             "status" => "COMPLETED"
           }

    assert WorkflowStatus.to_json(WorkflowStatus.new(@workflow, true, true)) == %{
             "workflowId" => "w",
             "correlationId" => "c",
             "output" => %{"y" => 3},
             "variables" => %{"v" => 1},
             "status" => "COMPLETED"
           }
  end

  test "an empty correlation ID is left out" do
    json =
      WorkflowStatus.to_json(WorkflowStatus.new(%{@workflow | correlation_id: ""}, true, false))

    refute Map.has_key?(json, "correlationId")
    assert json["output"] == %{"y" => 3}
  end

  test "decodes what it encodes" do
    status = WorkflowStatus.new(@workflow, true, true)
    assert WorkflowStatus.from_json(WorkflowStatus.to_json(status)) == {:ok, status}
  end
end
