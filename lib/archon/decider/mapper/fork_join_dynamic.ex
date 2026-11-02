# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/core/execution/mapper/ForkJoinDynamicTaskMapper.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: returns a value through the Archon.Decider.Mapper behaviour instead of
# throwing; the MetadataDAO and SystemTaskRegistry lookups read the Decider context; Jackson
# conversions became the domain codec; inputs that are not strings are read leniently.

defmodule Archon.Decider.Mapper.ForkJoinDynamic do
  @moduledoc """
  Upstream `ForkJoinDynamicTaskMapper`: a `COMPLETED` `FORK` task, the tasks of every dynamic
  branch and an `IN_PROGRESS` `JOIN` on the last task of each branch (ADR 0026, decision 4).

  The branches come from the first input form that applies:

    1. `forkTaskInputs` as a list: one branch per element, all of `forkTaskType` (default
       `SIMPLE`) named `forkTaskName` (default the type when it is a system task, else the
       reference name), or `SUB_WORKFLOW` branches of `forkTaskWorkflow` and
       `forkTaskWorkflowVersion`. Branch `i` is `_<name>_<i>`, `_<ref>_<name>_<i>` when the
       workflow already has a dynamic fork, and gets `__index` in its input.
    2. `dynamicForkTasksParam`: a list of workflow tasks, with their inputs in the map named
       `dynamicForkTasksInputParamName`.
    3. `dynamicForkJoinTasksParam`: the old `DynamicForkJoinTaskList`.

  Each branch is mapped by its own type's mapper (`Archon.Decider.tasks_to_be_scheduled/5`).
  When the workflow already has a task with the fork's reference name the branches are not made
  again and the `JOIN` waits on nothing. The definition must follow the fork with a `JOIN`; that
  is checked first, and a branch list that leads back to a fork being mapped ends the workflow.

  Upstream casts `forkTaskWorkflow`, `forkTaskWorkflowVersion`, `forkTaskType` and
  `forkTaskName` to strings and throws outside its termination path when one is not; here such a
  value is read as `String.valueOf` would print it (a number version is taken as it is). Upstream
  also throws when the old form does not convert; here the workflow terminates as when it is
  missing. The Java `toString` of a workflow and a workflow task in the messages is reproduced;
  that of an exception is not (ADR 0026, decision 4).
  """

  @behaviour Archon.Decider.Mapper

  alias Archon.Decider.{Mapper, Parameters, SystemTasks}
  alias Archon.Decider.Mapper.{Context, ForkJoin}
  alias Archon.Domain.{SubWorkflowParams, Task, TaskDef, Workflow, WorkflowTask}

  @impl true
  def map(%WorkflowTask{} = wt, %Context{} = context) do
    workflow = context.workflow
    input = context.task_input

    # The JOIN is looked up before the branches (upstream after them): a dynamic fork among the
    # branches then needs a reference of the definition followed by a JOIN, which bounds the
    # nesting a branch list can ask for (ADR 0026, decision 4).
    with :ok <- not_nested_in_itself(wt, context),
         {:ok, join} <- join_task(workflow, wt),
         {:ok, branches, inputs} <- branches(wt, input, context),
         {:ok, branches, branch_tasks, join_on} <-
           schedule_branches(wt, branches, inputs, context) do
      {:ok, [fork(context, branches) | branch_tasks] ++ [join(context, join, join_on)]}
    end
  end

  # A branch list that leads back to a fork being mapped would map forever (upstream ends in a
  # StackOverflowError; here the process would grow without bound).
  defp not_nested_in_itself(%WorkflowTask{task_reference_name: ref} = wt, context) do
    if ref in context.dynamic_forks,
      do: {:terminate, no_tasks_created(context.workflow, wt) <> duplicate(ref)},
      else: :ok
  end

  defp branches(wt, input, context) do
    case simple(wt, input, context) do
      nil when wt.dynamic_fork_tasks_param != nil -> fork_tasks_param(wt, input, context)
      nil -> fork_join_tasks_param(wt, input, context)
      simple -> simple
    end
  end

  # getDynamicTasksSimple: nil when `forkTaskInputs` is not a list.
  defp simple(wt, input, context) do
    case Map.get(input, "forkTaskInputs") do
      inputs when is_list(inputs) ->
        type = string(input["forkTaskType"])
        name = simple_name(string(input["forkTaskName"]), type, wt, context)
        make = branch_maker(name, type || "SIMPLE", input, context)
        prefix = if nested?(context.workflow), do: "_#{wt.task_reference_name}_", else: "_"

        branches =
          inputs
          |> Enum.with_index()
          |> Enum.map(fn {branch_input, i} ->
            branch = make.(branch_input)

            %{
              branch
              | task_reference_name: "#{prefix}#{name}_#{i}",
                input_parameters: Map.put(branch.input_parameters, "__index", i),
                optional: branch.optional == true or wt.optional == true
            }
          end)

        {:ok, branches, Map.new(branches, &{&1.task_reference_name, &1.input_parameters})}

      _other ->
        nil
    end
  end

  # A system task type names the branches when no name is given, else the fork's reference name.
  defp simple_name(nil, type, wt, context) do
    if type != nil and SystemTasks.system_task?(context.decider.system_tasks, type),
      do: type,
      else: wt.task_reference_name
  end

  defp simple_name(name, _type, _wt, _context), do: name

  defp branch_maker(name, type, input, context) do
    case string(input["forkTaskWorkflow"]) do
      nil ->
        &worker_task(name, type, &1, context)

      sub_workflow ->
        version = version(input["forkTaskWorkflowVersion"])
        &sub_workflow_task(sub_workflow, version, &1)
    end
  end

  # "can't rely on tasks from definition because dynamic forks can be inside dynamic forks"
  defp nested?(%Workflow{tasks: tasks}) do
    Enum.any?(tasks, &match?(%Task{workflow_task: %WorkflowTask{type: "FORK_JOIN_DYNAMIC"}}, &1))
  end

  defp worker_task(name, type, branch_input, context) do
    %{
      convert(branch_input)
      | name: name,
        type: type,
        input_parameters: branch_input_parameters(branch_input),
        task_definition: task_def(name, context)
    }
  end

  defp sub_workflow_task(name, version, branch_input) do
    task_to_domain =
      case branch_input do
        %{"taskToDomain" => mapping} when is_map(mapping) -> mapping
        _other -> nil
      end

    %{
      convert(branch_input)
      | name: name,
        type: "SUB_WORKFLOW",
        sub_workflow_param: %SubWorkflowParams{
          name: name,
          version: version,
          task_to_domain: task_to_domain
        },
        input_parameters: branch_input_parameters(branch_input)
    }
  end

  # objectMapper.convertValue(forkTaskInput, WorkflowTask.class), a new one when it fails.
  defp convert(value) when is_map(value) do
    case WorkflowTask.from_json(value) do
      {:ok, %WorkflowTask{} = task} -> task
      {:error, _reason} -> %WorkflowTask{}
    end
  end

  defp convert(_value), do: %WorkflowTask{}

  defp branch_input_parameters(value) when is_map(value), do: value
  defp branch_input_parameters(value), do: %{"input" => value}

  # getDynamicForkTasksAndInput
  defp fork_tasks_param(wt, input, context) do
    param = wt.dynamic_fork_tasks_param
    value = Map.get(input, param)

    with {:ok, tasks} <- workflow_tasks(value, param) do
      tasks = Enum.map(tasks, &with_task_def(&1, context))

      case Map.get(input, wt.dynamic_fork_tasks_input_param_name) do
        inputs when is_map(inputs) ->
          {:ok, tasks, inputs}

        other ->
          {:terminate,
           "Input to the dynamically forked tasks is not a map -> expecting a map of K,V  but found " <>
             Parameters.java_string(other)}
      end
    end
  end

  # metadataDAO.getTaskDef for a branch without a definition and with a name that is not blank.
  defp with_task_def(%WorkflowTask{task_definition: nil, name: name} = task, context)
       when is_binary(name) do
    if String.trim(name) == "",
      do: task,
      else: %{task | task_definition: task_def(name, context)}
  end

  defp with_task_def(task, _context), do: task

  # getDynamicForkWorkflowTasks
  defp workflow_tasks(value, param) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn
      item, {:ok, tasks} when is_map(item) ->
        case WorkflowTask.from_json(item) do
          {:ok, %WorkflowTask{task_reference_name: ref} = task} when ref != nil ->
            {:cont, {:ok, [task | tasks]}}

          _invalid ->
            {:halt, :error}
        end

      _item, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      :error -> invalid_tasks(param, value)
    end
  end

  defp workflow_tasks(value, param), do: invalid_tasks(param, value)

  defp invalid_tasks(param, value) do
    {:terminate,
     "Input '#{Parameters.java_string(param)}' is invalid. Cannot deserialize a list of Workflow Tasks from '#{Parameters.java_string(value)}'"}
  end

  # getDynamicForkJoinTasksAndInput
  defp fork_join_tasks_param(wt, input, context) do
    param = wt.dynamic_fork_join_tasks_param

    case Map.get(input, param) do
      %{"dynamicTasks" => tasks} when is_list(tasks) ->
        if Enum.all?(tasks, &legacy_task?/1),
          do: legacy_tasks(tasks, context),
          else: no_dynamic_tasks(param, input)

      %{} = list when not is_map_key(list, "dynamicTasks") ->
        {:ok, [], %{}}

      _other ->
        no_dynamic_tasks(param, input)
    end
  end

  # A DynamicForkJoinTask Jackson converts: an object whose input is an object or null.
  defp legacy_task?(%{} = task), do: is_map(Map.get(task, "input", %{})) or task["input"] == nil
  defp legacy_task?(_task), do: false

  defp legacy_tasks(tasks, context) do
    branches =
      Enum.map(tasks, fn task ->
        name = string(task["taskName"])

        task_def =
          if is_binary(name) and String.trim(name) != "", do: task_def(name, context)

        %WorkflowTask{
          task_reference_name: string(task["referenceName"]),
          name: name,
          type: string(Map.get(task, "type", "SIMPLE")),
          task_definition: task_def
        }
      end)

    inputs = Map.new(tasks, &{string(&1["referenceName"]), Map.get(&1, "input", %{})})
    {:ok, branches, inputs}
  end

  defp no_dynamic_tasks(param, input) do
    {:terminate,
     "Dynamic tasks could not be created. The value of #{Parameters.java_string(param)} from task's input " <>
       "#{Parameters.java_string(input)} has no dynamic tasks to be scheduled"}
  end

  # createDynamicForkTask, then the task input on top. The branches are those with their inputs
  # merged, as upstream merges them into the objects the FORK input holds.
  defp fork(context, branches) do
    input =
      Map.merge(
        %{
          "forkedTasks" => Enum.map(branches, & &1.task_reference_name),
          "forkedTaskDefs" => Enum.map(branches, &WorkflowTask.to_json/1)
        },
        context.task_input
      )

    %{ForkJoin.fork_task(context, input) | executed: true}
  end

  # Branch by branch, its input merged in, then mapped; nothing when the fork already exists.
  defp schedule_branches(%WorkflowTask{task_reference_name: ref}, branches, inputs, context) do
    if Enum.any?(context.workflow.tasks, &(&1.reference_task_name == ref)),
      do: {:ok, branches, [], []},
      else: schedule_each(branches, inputs, context)
  end

  defp schedule_each(branches, inputs, context) do
    context = %{
      context
      | dynamic_forks: [context.workflow_task.task_reference_name | context.dynamic_forks]
    }

    # Accumulated in reverse with the reference names seen, so the work stays linear in the
    # number of tasks made.
    branches
    |> Enum.reduce_while({:ok, [], [], [], MapSet.new()}, fn branch,
                                                             {:ok, merged, tasks, join_on, seen} ->
      with {:ok, branch} <- merge_input(branch, Map.get(inputs, branch.task_reference_name)),
           {:ok, forked} <- schedule_branch(branch, context),
           {:ok, seen} <- distinct(context.workflow, branch, seen, forked) do
        last = List.last(forked).reference_task_name

        {:cont,
         {:ok, [changed(branch, forked) | merged], Enum.reverse(forked, tasks), [last | join_on],
          seen}}
      else
        terminate -> {:halt, terminate}
      end
    end)
    |> case do
      {:ok, merged, tasks, join_on, _seen} ->
        {:ok, Enum.reverse(merged), Enum.reverse(tasks), Enum.reverse(join_on)}

      terminate ->
        terminate
    end
  end

  # A branch whose mapper changes its workflow task in place (DYNAMIC) changes the object the FORK
  # input holds upstream; the task it made carries the changed one.
  defp changed(%WorkflowTask{type: type, task_reference_name: ref} = branch, forked) do
    with true <- Mapper.changes_definition?(type),
         %Task{workflow_task: %WorkflowTask{} = wt} <-
           Enum.find(
             forked,
             &match?(%Task{workflow_task: %WorkflowTask{task_reference_name: ^ref}}, &1)
           ) do
      wt
    else
      _unchanged -> branch
    end
  end

  # dynForkTask.getInputParameters().putAll(forkedTaskInput)
  defp merge_input(branch, forked) when is_map(forked) or is_nil(forked),
    do:
      {:ok,
       %{branch | input_parameters: Map.merge(branch.input_parameters || %{}, forked || %{})}}

  defp merge_input(_branch, other) do
    {:terminate,
     "Tasks could not be dynamically forked due to invalid input: " <>
       "#{Parameters.java_string(other)} is not a map"}
  end

  # A reference name the fork already made (two branches leading to the same tasks): upstream
  # keeps both and drops one when it adds them; here the workflow ends, which also keeps branch
  # lists that share their sub-lists from multiplying.
  defp distinct(workflow, branch, seen, forked) do
    Enum.reduce_while(forked, {:ok, seen}, fn %Task{reference_task_name: ref}, {:ok, seen} ->
      if MapSet.member?(seen, ref),
        do: {:halt, {:terminate, no_tasks_created(workflow, branch) <> duplicate(ref)}},
        else: {:cont, {:ok, MapSet.put(seen, ref)}}
    end)
  end

  defp duplicate(ref), do: " attempted to create a duplicate task reference name: #{ref}"

  defp schedule_branch(branch, context) do
    case Context.tasks_to_be_scheduled(context, branch, nil) do
      {:ok, []} -> {:terminate, no_tasks_created(context.workflow, branch)}
      other -> other
    end
  end

  defp no_tasks_created(%Workflow{} = workflow, %WorkflowTask{} = branch) do
    message =
      "No dynamic tasks could be created for the Workflow: #{short_string(workflow)}, " <>
        "Dynamic Fork Task: #{Parameters.java_string(branch.name)}/#{Parameters.java_string(branch.task_reference_name)}"

    started? =
      Enum.any?(
        workflow.tasks,
        &(&1.reference_task_name == branch.task_reference_name and
            (&1.status == :in_progress or Task.terminal?(&1.status)))
      )

    if started?,
      do:
        message <>
          " attempted to create a duplicate task reference name: #{branch.task_reference_name}",
      else: message
  end

  # WorkflowModel#toShortString
  defp short_string(%Workflow{workflow_definition: definition, workflow_id: id}) do
    {name, version} =
      case definition do
        nil -> {nil, nil}
        definition -> {definition.name, definition.version}
      end

    "#{Parameters.java_string(name)}.#{Parameters.java_string(version)}/#{id}"
  end

  defp join_task(%Workflow{workflow_definition: definition}, %WorkflowTask{
         task_reference_name: ref
       }) do
    case ForkJoin.next_join(definition, ref) do
      %WorkflowTask{} = join ->
        {:ok, join}

      nil ->
        {:terminate,
         "Dynamic join definition is not followed by a join task.  Check the workflow definition."}
    end
  end

  # createJoinTask: not through the JOIN mapper; its input is the JOIN's own input parameters as
  # they are, with `joinOn`.
  defp join(%Context{workflow: workflow, decider: decider}, %WorkflowTask{} = join, join_on) do
    %Task{
      task_type: "JOIN",
      task_def_name: "JOIN",
      reference_task_name: join.task_reference_name,
      workflow_instance_id: workflow.workflow_id,
      workflow_type: Workflow.workflow_name(workflow),
      correlation_id: workflow.correlation_id,
      scheduled_time: decider.now,
      start_time: decider.now,
      input_data: Map.put(join.input_parameters || %{}, "joinOn", join_on),
      task_id: decider.new_id.(),
      status: :in_progress,
      workflow_task: join,
      workflow_priority: workflow.priority
    }
  end

  defp task_def(name, context) do
    case context.decider.task_def_lookup do
      nil ->
        nil

      lookup ->
        case lookup.(name) do
          {:ok, %TaskDef{} = task_def} -> task_def
          _not_found -> nil
        end
    end
  end

  # The `(String)` casts, read leniently.
  defp string(nil), do: nil
  defp string(value), do: Parameters.java_string(value)

  # Integer.parseInt, nil when it fails; a whole number is taken as it is.
  defp version(value) when is_integer(value), do: value

  defp version(value) when is_binary(value) do
    case Integer.parse(value) do
      {version, ""} when version in -2_147_483_648..2_147_483_647 -> version
      _other -> nil
    end
  end

  defp version(_value), do: nil
end
