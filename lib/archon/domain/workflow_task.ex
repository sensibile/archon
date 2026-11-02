# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss common/src/main/java/com/netflix/conductor/common/metadata/workflow/WorkflowTask.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: re-modelled as a recursive Elixir struct with a JSON codec; bean
# validation annotations ported to validate/1, which also applies the core
# WorkflowTaskTypeConstraint (Archon.Domain.TaskTypeConstraint).

defmodule Archon.Domain.WorkflowTask do
  @moduledoc """
  One step of a workflow definition (`WorkflowDef.tasks`).

  The structure is recursive: `decision_cases` (case value => tasks) and `default_case` hold the
  branches of `SWITCH`/`DECISION`, `fork_tasks` the parallel branches of `FORK_JOIN` and
  `loop_over` the body of `DO_WHILE`.

  `type` stays a string because upstream accepts any task type name (custom system tasks,
  user-defined `SIMPLE` workers); it defaults to `"SIMPLE"`.
  """

  alias Archon.Domain.{
    CacheConfig,
    Codec,
    StateChangeEvent,
    SubWorkflowParams,
    TaskDef,
    TaskTypeConstraint,
    Validation
  }

  @type join_mode :: :sync | :async

  @fields [
    {:name, "name", :string, []},
    {:task_reference_name, "taskReferenceName", :string, []},
    {:description, "description", :string, []},
    {:input_parameters, "inputParameters", :object, default: %{}},
    {:type, "type", :string, default: "SIMPLE"},
    {:dynamic_task_name_param, "dynamicTaskNameParam", :string, []},
    {:case_value_param, "caseValueParam", :string, []},
    {:case_expression, "caseExpression", :string, []},
    {:script_expression, "scriptExpression", :string, []},
    {:decision_cases, "decisionCases", {:map_of, {:list, {:struct, __MODULE__}}}, default: %{}},
    {:dynamic_fork_join_tasks_param, "dynamicForkJoinTasksParam", :string, []},
    {:dynamic_fork_tasks_param, "dynamicForkTasksParam", :string, []},
    {:dynamic_fork_tasks_input_param_name, "dynamicForkTasksInputParamName", :string, []},
    {:default_case, "defaultCase", {:list, {:struct, __MODULE__}}, default: []},
    {:fork_tasks, "forkTasks", {:list, {:list, {:struct, __MODULE__}}}, default: []},
    {:start_delay, "startDelay", :int, []},
    {:sub_workflow_param, "subWorkflowParam", {:struct, SubWorkflowParams}, []},
    {:join_on, "joinOn", {:list, :string}, default: []},
    {:sink, "sink", :string, []},
    {:optional, "optional", :bool, []},
    {:task_definition, "taskDefinition", {:struct, TaskDef}, []},
    {:rate_limited, "rateLimited", :boolean, []},
    {:default_exclusive_join_task, "defaultExclusiveJoinTask", {:list, :string}, default: []},
    {:async_complete, "asyncComplete", :boolean, default: false},
    {:loop_condition, "loopCondition", :string, []},
    {:loop_over, "loopOver", {:list, {:struct, __MODULE__}}, default: []},
    {:items, "items", :string, []},
    {:retry_count, "retryCount", :integer, []},
    {:evaluator_type, "evaluatorType", :string, []},
    {:expression, "expression", :string, []},
    {:on_state_change, "onStateChange", {:map_of, {:list, {:struct, StateChangeEvent}}},
     default: %{}},
    {:join_status, "joinStatus", :string, []},
    {:cache_config, "cacheConfig", {:struct, CacheConfig}, []},
    {:permissive, "permissive", :bool, []},
    {:join_mode, "joinMode", {:enum, [:sync, :async]}, []},
    # setMetadata replaces null with an empty map.
    {:metadata, "metadata", :object, default: %{}, null: :default}
  ]

  defstruct Codec.defaults(@fields)

  @doc false
  @spec __fields__() :: [Codec.field()]
  def __fields__, do: @fields

  @type t :: %__MODULE__{
          name: String.t() | nil,
          task_reference_name: String.t() | nil,
          description: String.t() | nil,
          input_parameters: Codec.json_object() | nil,
          type: String.t() | nil,
          dynamic_task_name_param: String.t() | nil,
          case_value_param: String.t() | nil,
          case_expression: String.t() | nil,
          script_expression: String.t() | nil,
          decision_cases: %{optional(String.t()) => [t() | nil] | nil} | nil,
          dynamic_fork_join_tasks_param: String.t() | nil,
          dynamic_fork_tasks_param: String.t() | nil,
          dynamic_fork_tasks_input_param_name: String.t() | nil,
          default_case: [t() | nil] | nil,
          fork_tasks: [[t() | nil] | nil] | nil,
          start_delay: integer(),
          sub_workflow_param: SubWorkflowParams.t() | nil,
          join_on: [String.t() | nil] | nil,
          sink: String.t() | nil,
          optional: boolean(),
          task_definition: TaskDef.t() | nil,
          rate_limited: boolean() | nil,
          default_exclusive_join_task: [String.t() | nil] | nil,
          async_complete: boolean() | nil,
          loop_condition: String.t() | nil,
          loop_over: [t() | nil] | nil,
          items: String.t() | nil,
          retry_count: integer() | nil,
          evaluator_type: String.t() | nil,
          expression: String.t() | nil,
          on_state_change: %{optional(String.t()) => [StateChangeEvent.t() | nil] | nil} | nil,
          join_status: String.t() | nil,
          cache_config: CacheConfig.t() | nil,
          permissive: boolean(),
          join_mode: join_mode() | nil,
          metadata: Codec.json_object()
        }

  @doc "Decodes upstream JSON, recursively."
  @spec from_json(Codec.json(), Codec.path()) :: Codec.result(t())
  def from_json(json, path \\ []), do: Codec.decode(__MODULE__, @fields, json, path)

  @doc "Encodes to upstream JSON, recursively."
  @spec to_json(t()) :: Codec.json_object()
  def to_json(%__MODULE__{} = task), do: Codec.encode(__MODULE__, @fields, task)

  @doc """
  Upstream `WorkflowTask#collectTasks`: this task followed by all nested tasks, depth first.

  Which branches count depends on `type`, as upstream's `children()`: `DECISION`/`SWITCH` use the
  decision cases then the default case, `FORK_JOIN` the fork branches and `DO_WHILE` the loop
  body. Other types have no children even if those fields are set.
  """
  @spec collect_tasks(t()) :: [t()]
  def collect_tasks(%__MODULE__{} = task) do
    [task | Enum.flat_map(children(task), &collect_tasks/1)]
  end

  @doc """
  This task with the first task named `replacement.task_reference_name` (itself or one nested
  in it, in `collect_tasks/1` order) replaced by `replacement`, as a change upstream makes in
  place to a definition's task object shows wherever that object is.
  """
  @spec replace(t(), t()) :: {:ok, t()} | :error
  def replace(%__MODULE__{task_reference_name: ref}, %__MODULE__{task_reference_name: ref} = new),
    do: {:ok, new}

  def replace(%__MODULE__{type: type} = task, new) when type in ["DECISION", "SWITCH"] do
    cases = Enum.sort(task.decision_cases || %{})

    with :error <- replace_in_cases(task, cases, new),
         {:ok, default} <- replace_in_list(task.default_case, new) do
      {:ok, %{task | default_case: default}}
    end
  end

  def replace(%__MODULE__{type: "FORK_JOIN", fork_tasks: forks} = task, new) do
    with {:ok, forks} <- replace_in_lists(forks, new), do: {:ok, %{task | fork_tasks: forks}}
  end

  def replace(%__MODULE__{type: "DO_WHILE", loop_over: body} = task, new) do
    with {:ok, body} <- replace_in_list(body, new), do: {:ok, %{task | loop_over: body}}
  end

  def replace(%__MODULE__{}, _new), do: :error

  @doc false
  # The first task list element (or nested task) named as `new` replaced; `:error` if none is.
  @spec replace_in_list([t() | nil] | nil, t()) :: {:ok, [t() | nil]} | :error
  def replace_in_list(nil, _new), do: :error
  def replace_in_list([], _new), do: :error
  def replace_in_list([nil | rest], new), do: prepend(nil, replace_in_list(rest, new))

  def replace_in_list([task | rest], new) do
    case replace(task, new) do
      {:ok, task} -> {:ok, [task | rest]}
      :error -> prepend(task, replace_in_list(rest, new))
    end
  end

  defp replace_in_lists(nil, _new), do: :error
  defp replace_in_lists([], _new), do: :error

  defp replace_in_lists([list | rest], new) do
    case replace_in_list(list, new) do
      {:ok, list} -> {:ok, [list | rest]}
      :error -> prepend(list, replace_in_lists(rest, new))
    end
  end

  # collect_tasks/1 order: the cases in Map.values/1 order of the decision cases.
  defp replace_in_cases(_task, [], _new), do: :error

  defp replace_in_cases(task, [{key, list} | rest], new) do
    case replace_in_list(list, new) do
      {:ok, list} -> {:ok, %{task | decision_cases: Map.put(task.decision_cases, key, list)}}
      :error -> replace_in_cases(task, rest, new)
    end
  end

  defp prepend(head, {:ok, tail}), do: {:ok, [head | tail]}
  defp prepend(_head, :error), do: :error

  @doc """
  Upstream `WorkflowTask#has`: whether this task or one nested in it has `ref_name`.
  """
  @spec has?(t(), String.t()) :: boolean()
  def has?(%__MODULE__{} = task, ref_name), do: get(task, ref_name) != nil

  @doc """
  Upstream `WorkflowTask#get`: this task or the first nested task with `ref_name`, depth first.
  """
  @spec get(t(), String.t()) :: t() | nil
  def get(%__MODULE__{} = task, ref_name) do
    task |> collect_tasks() |> Enum.find(&(&1.task_reference_name == ref_name))
  end

  @doc """
  Upstream `WorkflowTask#next`: the task to run after `ref_name` inside this task, or `nil`.

  Only `DECISION`, `SWITCH`, `DO_WHILE` and `FORK_JOIN` look inside. Within a branch the task
  after `ref_name` (or after the nested task containing it) is next. When `ref_name` is the last
  task of a `DO_WHILE` body, the `DO_WHILE` task itself is returned so the loop can decide on the
  next iteration. When it ends a `FORK_JOIN` branch, `parent` is asked for the task after the
  fork, which is how a nested fork reaches its join.
  """
  @spec next(t(), String.t(), t() | nil) :: t() | nil
  def next(%__MODULE__{type: type} = task, ref_name, _parent)
      when type in ["DECISION", "SWITCH", "DO_WHILE"] do
    found =
      Enum.find_value(branches(task), fn branch ->
        case scan_branch(branch, ref_name, task) do
          {:next, next} -> next
          {_stop, [next | _rest]} -> next
          _other -> nil
        end
      end)

    cond do
      found -> found
      type == "DO_WHILE" and has?(task, ref_name) -> task
      true -> nil
    end
  end

  def next(%__MODULE__{type: "FORK_JOIN"} = task, ref_name, parent) do
    Enum.find_value(branches(task), fn branch ->
      case scan_branch(branch, ref_name, task) do
        {:next, next} -> next
        {_stop, [next | _rest]} -> next
        {:found, []} when parent != nil -> next(parent, task.task_reference_name, parent)
        _other -> nil
      end
    end)
  end

  def next(%__MODULE__{}, _ref_name, _parent), do: nil

  @doc false
  # The iterator loop shared by upstream's `next` and `WorkflowDef#getNextTask`: walks `branch`
  # until `ref_name` (`{:found, rest}`), a nested task that resolves it (`{:next, task}`) or a
  # nested task containing it (`{:within, rest}`). `rest` holds the tasks after the stop.
  @spec scan_branch([t() | nil], String.t(), t() | nil) ::
          {:next, t()} | {:found, [t()]} | {:within, [t()]} | :not_found
  def scan_branch(branch, ref_name, parent) do
    branch
    |> Enum.reject(&is_nil/1)
    |> do_scan(ref_name, parent)
  end

  defp do_scan([], _ref_name, _parent), do: :not_found

  defp do_scan([%__MODULE__{task_reference_name: ref_name} | rest], ref_name, _parent),
    do: {:found, rest}

  defp do_scan([task | rest], ref_name, parent) do
    case next(task, ref_name, parent) do
      nil -> if has?(task, ref_name), do: {:within, rest}, else: do_scan(rest, ref_name, parent)
      next -> {:next, next}
    end
  end

  defp children(task), do: task |> branches() |> Enum.concat()

  # Upstream `children()`: the task lists nested in `task`, by type. `nil` lists and elements are
  # dropped (upstream would throw on them).
  defp branches(%__MODULE__{type: type} = task) when type in ["DECISION", "SWITCH"] do
    present(Map.values(task.decision_cases || %{}) ++ [task.default_case])
  end

  defp branches(%__MODULE__{type: "FORK_JOIN", fork_tasks: forks}), do: present(forks || [])
  defp branches(%__MODULE__{type: "DO_WHILE", loop_over: body}), do: present([body])
  defp branches(%__MODULE__{}), do: []

  defp present(branches) do
    branches |> Enum.reject(&is_nil/1) |> Enum.map(&Enum.reject(&1, fn task -> is_nil(task) end))
  end

  @doc """
  Bean validation of this task and the tasks it cascades into.

  Field annotations: `name` and `taskReferenceName` are `@NotEmpty`, `startDelay` is
  `@PositiveOrZero`. `@Valid` cascades into `decisionCases`, `defaultCase`, `forkTasks` and
  `onStateChange`, but not `loopOver` or `taskDefinition`, which upstream leaves unannotated.
  """
  @spec validate(t(), Validation.opts()) :: Validation.result()
  def validate(%__MODULE__{} = task, opts \\ []), do: task |> errors(opts) |> Validation.result()

  @doc false
  @spec errors(t(), Validation.opts()) :: [Codec.error()]
  def errors(%__MODULE__{} = task, opts \\ []) do
    Validation.not_empty("name", task.name, "WorkflowTask name cannot be empty or null") ++
      Validation.not_empty(
        "taskReferenceName",
        task.task_reference_name,
        "WorkflowTask taskReferenceName name cannot be empty or null"
      ) ++
      Validation.min("startDelay", task.start_delay, 0, "must be greater than or equal to 0") ++
      decision_case_errors(task.decision_cases, opts) ++
      list_errors(task.default_case, "defaultCase", opts) ++
      fork_errors(task.fork_tasks, opts) ++
      state_change_errors(task.on_state_change) ++
      TaskTypeConstraint.errors(task, opts)
  end

  defp decision_case_errors(nil, _opts), do: []

  defp decision_case_errors(cases, opts) do
    cases
    |> Enum.sort()
    |> Enum.flat_map(fn {key, tasks} -> list_errors(tasks, "decisionCases[#{key}]", opts) end)
  end

  defp fork_errors(nil, _opts), do: []

  defp fork_errors(forks, opts) do
    forks
    |> Enum.with_index()
    |> Enum.flat_map(fn {tasks, index} -> list_errors(tasks, "forkTasks[#{index}]", opts) end)
  end

  defp list_errors(nil, _prefix, _opts), do: []

  defp list_errors(tasks, prefix, opts) do
    tasks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {nil, _index} -> []
      {task, index} -> task |> errors(opts) |> Validation.nest("#{prefix}[#{index}]")
    end)
  end

  defp state_change_errors(nil), do: []

  defp state_change_errors(events) do
    events
    |> Enum.sort()
    |> Enum.flat_map(fn {key, list} ->
      (list || [])
      |> Enum.with_index()
      |> Enum.flat_map(&event_errors(&1, "onStateChange[#{key}]"))
    end)
  end

  defp event_errors({nil, _index}, _prefix), do: []

  defp event_errors({event, index}, prefix) do
    case StateChangeEvent.validate(event) do
      :ok -> []
      {:error, errors} -> Validation.nest(errors, "#{prefix}[#{index}]")
    end
  end
end
