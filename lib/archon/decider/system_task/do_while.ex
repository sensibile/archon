# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/tasks/DoWhile.java
# and core/.../execution/WorkflowExecutorOps.java (scheduleNextIteration)
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: execute returns the updated task with the tasks to schedule and the
# tasks to remove instead of scheduling and deleting them; the script evaluator comes from the
# Decider context; a keepLastN that is not an int or an empty loopOver fails the task instead of
# throwing (ADR 0014).

defmodule Archon.Decider.SystemTask.DoWhile do
  @moduledoc """
  Upstream `DoWhile#execute` as a pure function (ADR 0014, decision 5).

  Each call looks at the loop body tasks of the current iteration (the latest retry of each
  reference name):

    * none yet - the first iteration starts: `iteration` becomes 1 and the first `loopOver` task
      is mapped for it. A list iteration over an empty `items` list completes instead, with
      `iteration` 0.
    * one failed - the task fails with their reasons.
    * not all terminal, or a successor inside the body not scheduled yet - nothing changes.
    * all done - the iteration's outputs are stored under its number and `loopCondition` is
      evaluated with the context's `evaluate_script`. True starts the next iteration, false
      completes the task, and a script error, or a termination while mapping the next iteration,
      fails it with `FAILED_WITH_TERMINAL_ERROR`.

  The result is a `t:t/0`. `changed?` is upstream's return value. `tasks_to_be_scheduled` are the
  tasks of the next iteration (upstream `WorkflowExecutorOps#scheduleNextIteration`: the first
  `loopOver` task mapped like any other, with the `__<iteration>` suffix), which the runtime
  schedules and adds to the workflow. `removed_task_ids` are the body tasks of iterations that
  `keepLastN` no longer keeps, which the runtime deletes (upstream `removeIterations`), whether or
  not `changed?`. Task domains are the runtime's (Phase 3).

  A list iteration (`items`, or `_items` in the input parameters) also puts `loopIndex` and
  `loopItem` in the output for each iteration and stops after the last item.
  """

  alias Archon.Decider
  alias Archon.Decider.{Context, Parameters, Termination}
  alias Archon.Domain.{Task, Workflow, WorkflowTask}
  alias Archon.Script

  @enforce_keys [:task]
  defstruct [:task, changed?: false, tasks_to_be_scheduled: [], removed_task_ids: []]

  @type t :: %__MODULE__{
          task: Task.t(),
          changed?: boolean(),
          tasks_to_be_scheduled: [Task.t()],
          removed_task_ids: [String.t()]
        }

  @int_min -2_147_483_648
  @int_max 2_147_483_647

  @doc """
  Upstream `DoWhile#execute` of `task` in `workflow`. A termination comes from mapping the first
  iteration, where upstream's `TerminateWorkflowException` ends the decide. Mapping a later
  iteration fails the loop task instead, as upstream catches it with the condition's errors.
  """
  @spec execute(Workflow.t(), Task.t(), Context.t()) :: {:ok, t()} | {:terminate, Termination.t()}
  def execute(%Workflow{} = workflow, %Task{task_type: "DO_WHILE"} = task, %Context{} = context) do
    case iteration_tasks(workflow, task) do
      [] -> start(workflow, task, context)
      tasks -> continue(workflow, task, tasks, context)
    end
  end

  defp start(workflow, task, context) do
    if list_iteration?(task) and items(workflow, task) == [] do
      {:ok, changed(%{add_output(task, "iteration", 0) | status: :completed})}
    else
      task = add_output(%{task | iteration: 1}, "iteration", 1)
      workflow = replace(workflow, task)
      next_iteration(workflow, inject_loop_variables(workflow, task), context, [])
    end
  end

  defp continue(workflow, task, tasks, context) do
    {output, failure} = iteration_output(tasks)
    task = add_output(task, Integer.to_string(task.iteration), output)

    case keep_last_n(task) do
      {:error, reason} ->
        {:ok, changed(failed(task, :failed_with_terminal_error, reason))}

      {:ok, keep} ->
        {task, removed} = remove_iterations(workflow, task, keep)
        decide_iteration(workflow, task, tasks, failure, removed, context)
    end
  end

  defp decide_iteration(workflow, task, tasks, failure, removed, context) do
    cond do
      failure != nil ->
        {:ok, changed(failed(task, :failed, failure), removed)}

      not iteration_complete?(task, tasks) ->
        {:ok, %__MODULE__{task: task, removed_task_ids: removed}}

      true ->
        workflow = replace(workflow, task)

        case continue?(workflow, task, context) do
          {:ok, true} ->
            advance(workflow, task, context, removed)

          {:ok, false} ->
            {:ok, changed(%{task | status: :completed}, removed)}

          {:error, error} ->
            reason = condition_failure(task, Exception.message(error))

            {:ok, changed(failed(task, :failed_with_terminal_error, reason), removed)}
        end
    end
  end

  # The next iteration after a true condition. Upstream maps it inside the try around the
  # condition, so a termination while mapping fails the loop task like a condition error; only the
  # first iteration (start/3) lets it end the decide.
  defp advance(workflow, task, context, removed) do
    task = add_output(%{task | iteration: task.iteration + 1}, "iteration", task.iteration + 1)
    workflow = replace(workflow, task)
    task = inject_loop_variables(workflow, task)

    case next_iteration(workflow, task, context, removed) do
      {:terminate, %Termination{reason: reason}} ->
        failure = condition_failure(task, reason)
        {:ok, changed(failed(task, :failed_with_terminal_error, failure), removed)}

      result ->
        result
    end
  end

  defp condition_failure(%Task{workflow_task: wt}, message),
    do: "Unable to evaluate condition #{java(wt.loop_condition)}, exception #{message}"

  # The body tasks of the current iteration, the latest retry of each reference name, in the
  # order their names first appear in the workflow.
  defp iteration_tasks(%Workflow{tasks: tasks}, %Task{} = loop) do
    tasks
    |> Enum.filter(
      &(body_task?(loop, &1) and &1.reference_task_name != loop.reference_task_name and
          &1.iteration == loop.iteration)
    )
    |> Enum.reduce({[], %{}}, fn t, {order, latest} ->
      case Map.fetch(latest, t.reference_task_name) do
        :error ->
          {[t.reference_task_name | order], Map.put(latest, t.reference_task_name, t)}

        {:ok, seen} when t.retry_count > seen.retry_count ->
          {order, %{latest | t.reference_task_name => t}}

        {:ok, _seen} ->
          {order, latest}
      end
    end)
    |> then(fn {order, latest} -> order |> Enum.reverse() |> Enum.map(&latest[&1]) end)
  end

  defp body_task?(%Task{workflow_task: wt}, %Task{reference_task_name: ref}),
    do: WorkflowTask.has?(wt, Parameters.remove_iteration(ref))

  # The outputs by reference name without the suffix, up to and including the first unsuccessful
  # task, whose reason (Java "null" when absent) fails the loop.
  defp iteration_output(tasks) do
    Enum.reduce_while(tasks, {%{}, nil}, fn t, {output, nil} ->
      output = Map.put(output, Parameters.remove_iteration(t.reference_task_name), t.output_data)

      if Task.successful?(t.status),
        do: {:cont, {output, nil}},
        else: {:halt, {output, "#{java(t.reason_for_incompletion)} "}}
    end)
  end

  # The raw keepLastN input parameter, which upstream casts to Integer.
  defp keep_last_n(%Task{workflow_task: wt}) do
    case Map.get(wt.input_parameters || %{}, "keepLastN") do
      nil -> {:ok, nil}
      n when is_integer(n) and n >= @int_min and n <= @int_max -> {:ok, n}
      other -> {:error, "keepLastN must be an int, got: #{Parameters.java_string(other)}"}
    end
  end

  # The output keys of the iterations keepLastN drops, and upstream removeIterations: the body
  # tasks of those iterations.
  defp remove_iterations(_workflow, task, keep) when is_nil(keep) or task.iteration <= keep,
    do: {task, []}

  defp remove_iterations(workflow, %Task{iteration: iteration} = task, keep) do
    dropped = iteration - keep
    output = Map.drop(task.output_data, Enum.map(1..dropped//1, &Integer.to_string/1))

    removed =
      for t <- workflow.tasks,
          body_task?(task, t),
          t.reference_task_name != task.reference_task_name,
          t.iteration <= dropped,
          do: t.task_id

    {%{task | output_data: output}, removed}
  end

  # isIterationComplete: every loopOver task of the iteration is present and terminal, every
  # nested one too, and each terminal task's successor inside the body is scheduled.
  defp iteration_complete?(%Task{workflow_task: wt, iteration: iteration}, tasks) do
    by_ref = Map.new(tasks, &{&1.reference_task_name, &1})

    Enum.all?(body(wt), fn %WorkflowTask{task_reference_name: ref} ->
      case Map.fetch(by_ref, suffixed(ref, iteration)) do
        {:ok, t} -> Task.terminal?(t.status)
        :error -> false
      end
    end) and Enum.all?(tasks, &Task.terminal?(&1.status)) and
      Enum.all?(tasks, &successor_scheduled?(wt, &1, by_ref, iteration))
  end

  defp successor_scheduled?(wt, %Task{reference_task_name: ref}, by_ref, iteration) do
    case WorkflowTask.next(wt, Parameters.remove_iteration(ref), nil) do
      %WorkflowTask{task_reference_name: next} ->
        next == wt.task_reference_name or not WorkflowTask.has?(wt, next) or
          Map.has_key?(by_ref, suffixed(next, iteration))

      nil ->
        true
    end
  end

  # evaluateCondition
  defp continue?(workflow, %Task{workflow_task: wt} = task, context) do
    input = condition_input(workflow, task)

    cond do
      list_iteration?(task) -> list_continue?(workflow, task, input, context)
      wt.loop_condition == nil -> {:ok, false}
      true -> eval_bool(wt.loop_condition, input, context)
    end
  end

  # A list loop goes on while items remain and its condition, if any, holds. The condition is
  # evaluated even after the last item.
  defp list_continue?(
         workflow,
         %Task{workflow_task: wt, iteration: iteration} = task,
         input,
         context
       ) do
    items = items(workflow, task)
    input = Map.merge(input, loop_variables(items, iteration))
    more? = iteration < length(items)

    if java_blank?(wt.loop_condition) do
      {:ok, more?}
    else
      with {:ok, result} <- eval_bool(wt.loop_condition, input, context),
           do: {:ok, result and more?}
    end
  end

  # The resolved input parameters, the loop task's output under its name and the latest output
  # of each body task by its name without the suffix.
  defp condition_input(workflow, %Task{workflow_task: wt} = task) do
    input =
      wt.input_parameters
      |> Parameters.task_input(workflow, task.task_id, Task.task_definition(task))
      |> Map.put(task.reference_task_name, task.output_data)

    for t <- workflow.tasks,
        body_task?(task, t),
        t.reference_task_name != task.reference_task_name,
        reduce: input,
        do: (acc ->
               Map.put(acc, Parameters.remove_iteration(t.reference_task_name), t.output_data))
  end

  defp eval_bool(condition, input, %Context{evaluate_script: evaluate}) do
    case evaluate.(:eval, condition, input) do
      {:ok, value} -> {:ok, Script.to_boolean(value)}
      {:error, error} -> {:error, error}
    end
  end

  # scheduleNextIteration: the first loopOver task mapped for the loop task's retry count, named
  # for the iteration.
  defp next_iteration(workflow, %Task{workflow_task: wt} = task, context, removed) do
    case body(wt) do
      [] ->
        reason = "DO_WHILE task #{java(task.reference_task_name)} has no loopOver tasks"
        {:ok, changed(failed(task, :failed_with_terminal_error, reason), removed)}

      [first | _rest] ->
        workflow = replace(workflow, task)

        case Decider.tasks_to_be_scheduled(workflow, first, task.retry_count, nil, context) do
          {:ok, tasks} ->
            tasks =
              Enum.map(
                tasks,
                &%{
                  &1
                  | reference_task_name: suffixed(&1.reference_task_name, task.iteration),
                    iteration: task.iteration
                }
              )

            {:ok,
             %__MODULE__{
               task: task,
               changed?: true,
               tasks_to_be_scheduled: tasks,
               removed_task_ids: removed
             }}

          {:terminate, termination} ->
            {:terminate, termination}
        end
    end
  end

  # injectLoopVariables
  defp inject_loop_variables(workflow, task) do
    if list_iteration?(task) do
      variables = loop_variables(items(workflow, task), task.iteration)
      %{task | output_data: Map.merge(task.output_data, variables)}
    else
      task
    end
  end

  # The 0-based loopIndex of the iteration, and its loopItem while the index is in the list.
  defp loop_variables(items, iteration) do
    index = iteration - 1

    case Enum.fetch(items, index) do
      {:ok, item} when index >= 0 -> %{"loopIndex" => index, "loopItem" => item}
      _out_of_bounds -> %{"loopIndex" => index}
    end
  end

  @doc """
  Upstream `isListIteration`: the task has a non-blank `items`, or an `_items` input parameter
  that is a non-blank string or a list.
  """
  @spec list_iteration?(Task.t()) :: boolean()
  def list_iteration?(%Task{workflow_task: %WorkflowTask{} = wt}),
    do: not java_blank?(wt.items) or java_items?(Map.get(wt.input_parameters || %{}, "_items"))

  defp java_items?(items) when is_binary(items), do: not java_blank?(items)
  defp java_items?(items), do: is_list(items)

  @doc """
  Upstream `evaluateItemsList`: `items` resolved like an input parameter, else the resolved
  `_items` input parameter. A list is the items, any other value a list of one, `nil` none.
  """
  @spec items(Workflow.t(), Task.t()) :: [Archon.Domain.Codec.json()]
  def items(%Workflow{} = workflow, %Task{workflow_task: wt} = task) do
    task_def = Task.task_definition(task)

    value =
      if java_blank?(wt.items),
        do: nil,
        else:
          Parameters.task_input(%{"items" => wt.items}, workflow, task.task_id, task_def)["items"]

    value =
      if value == nil,
        do:
          Parameters.task_input(wt.input_parameters, workflow, task.task_id, task_def)["_items"],
        else: value

    case value do
      nil -> []
      list when is_list(list) -> list
      other -> [other]
    end
  end

  defp body(%WorkflowTask{loop_over: body}), do: Enum.reject(body || [], &is_nil/1)

  defp suffixed(ref, iteration), do: "#{ref}__#{iteration}"

  defp add_output(task, key, value),
    do: %{task | output_data: Map.put(task.output_data, key, value)}

  defp failed(task, status, reason), do: %{task | status: status, reason_for_incompletion: reason}

  defp changed(task, removed \\ []),
    do: %__MODULE__{task: task, changed?: true, removed_task_ids: removed}

  defp replace(%Workflow{tasks: tasks} = workflow, %Task{task_id: id} = task),
    do: %{workflow | tasks: Enum.map(tasks, &if(&1.task_id == id, do: task, else: &1))}

  # String.trim().isEmpty() on a nullable string: trim drops every character up to U+0020.
  defp java_blank?(nil), do: true

  defp java_blank?(value) when is_binary(value),
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 <= 0x20))

  defp java(nil), do: "null"
  defp java(value), do: value
end
