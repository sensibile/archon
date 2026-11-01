# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss postgres-persistence/src/main/java/com/netflix/conductor/postgres/dao/PostgresExecutionDAO.java,
# PostgresBaseDAO.java and PostgresPollDataDAO.java at commit
# 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: reduced to the operations of `Archon.Runtime.Store` (ADR 0018,
# decision 3); a whole `Archon.Runtime.Commit` (workflow, tasks, outbox, re-evaluation time,
# limit check and queue operations) is one transaction instead of one per DAO call, the
# concurrent execution limit is checked under an advisory lock in that transaction instead of
# exceedsLimit's separate count, a workflow and its tasks are read in one statement, there are no
# workflow_to_task, workflow_pending or task_in_progress tables, the poll data has no trigger
# keeping lastPollTime from going back, and every write is fenced by the node epoch (ADR 0021,
# decisions 2 to 7); the queries by name and correlation ID read index columns of the workflow
# row instead of the workflow_def_to_workflow and workflow_pending tables (ADR 0025, decision 4).

defmodule Archon.Runtime.Store.Postgres do
  @moduledoc """
  PostgreSQL `Archon.Runtime.Store` on the `workflow`, `task`, `outbox` and `poll_data` tables
  (ADR 0021, decisions 2 to 7).

  Each function takes an optional first argument, an `Archon.Runtime.Postgres` instance
  (`Archon.Runtime.Postgres.runtime/0` by default); the arities without it are the behaviour
  callbacks.

  ## Rows

  A workflow row keeps its status, parent workflow ID, re-evaluation time `wake_at`, definition
  name and version, correlation ID and create time as columns and the workflow's storage
  encoding (`Archon.Domain.Workflow.to_storage/1`) without its `tasks` as `json_data` text. A
  task row keeps its workflow, `seq`, status and task definition name
  (`Archon.Domain.Task.task_def_name/1`, so the type when there is none) as columns and its
  storage encoding. Statuses are stored as upstream's constant names (`RUNNING`, `IN_PROGRESS`).
  Workflow IDs sort in binary order (`COLLATE "C"`).

  ## Commits

  `commit/3` applies every field of the commit in one transaction (`Archon.Runtime.Postgres.transaction/2`,
  so its first statement is the write fence): it takes the limit locks, writes the workflow and
  its tasks, the outbox and the re-evaluation time, checks the limits and applies the queue
  operations with `Archon.Runtime.Queue.Postgres.apply_ops/2` on the same connection. A refused
  commit rolls all of it back, and so does an exception, which reaches the caller (a database
  failure raises, ADR 0021 L5). A commit whose node epoch is stale is `{:error, :fenced}`.

  Limits (ADR 0021, decision 5): before anything else the commit takes
  `pg_advisory_xact_lock` on a key of each task definition name in `limits`, in key order, so
  commits over the same name run one at a time. After its writes it counts the `IN_PROGRESS`
  tasks of each name in one statement, which under READ COMMITTED sees every commit that held
  the lock before it.

  ## Outbox entries

  An entry's `effect` is JSON with the effect's `kind` and `args`, never a workflow struct. A
  `:notify_parent` entry keeps the parent's IDs only: `pending_outbox/2` gives it back with the
  workflow that owns the entry (the child) as it is stored when it is read, tasks included. A
  `:start_failure_workflow` entry keeps the start map, an embedded definition in its storage
  encoding. An effect of another kind or shape raises `ArgumentError` in the caller.

  ## Values the columns cannot hold

  Index columns are plain `text`, which cannot hold NUL or invalid UTF-8 (as in upstream). A
  commit or poll data write with such an ID, name or status raises `ArgumentError` before it
  reaches the database, and so does a value in a workflow or task that does not encode to UTF-8
  JSON; NUL inside JSON values is escaped and kept. Reads and deletes treat such an ID or name as
  absent. A page cursor with one raises `ArgumentError`, as no stored ID can have produced it.

  A workflow's definition name and version, correlation ID and create time are the exception:
  only the queries read their columns, so a value a column cannot hold (NUL, invalid UTF-8, a
  number outside the column's range) leaves it `NULL` instead of refusing the commit, and the
  queries do not find that workflow by it (`Archon.Runtime.Store`).

  ## Writes that cannot return an error

  `remove_workflow/2`, `ack_outbox/3` and `put_poll_data/5` run in
  `Archon.Runtime.Postgres.transaction!/2` and raise `Archon.Runtime.Postgres.FencedError` when
  the node epoch is stale (ADR 0021, decision 7). Reads are not fenced.
  """

  @behaviour Archon.Runtime.Store

  alias Archon.Domain.{Codec, Task, Workflow, WorkflowDef}
  alias Archon.Runtime.{Commit, Postgres, Store}
  alias Archon.Runtime.Queue.Postgres, as: PgQueue
  alias Archon.Runtime.Step.Effect

  # The first key of the two-key advisory locks on task definition names ("Arch" in ASCII); the
  # two-key space never meets the one-key node lock and fence keys.
  @limit_lock_class 0x41726368

  @running Codec.enum_name(:running)
  @in_progress Codec.enum_name(:in_progress)
  @not_terminal Enum.map([:running, :paused], &Codec.enum_name/1)
  # Inlined, so a generic plan still matches the partial index workflow_pending_name_index.
  @not_terminal_sql Enum.map_join(@not_terminal, ", ", &"'#{&1}'")

  @max_bigint 0x7FFFFFFFFFFFFFFF
  @int_range -0x80000000..0x7FFFFFFF
  @bigint_range (-@max_bigint - 1)..@max_bigint

  # Effect.start keys, in the order they are written.
  @start_keys [
    :workflow_id,
    :name,
    :version,
    :definition,
    :input,
    :correlation_id,
    :priority,
    :task_to_domain,
    :parent_workflow_id,
    :parent_workflow_task_id,
    :triggering_workflow_id,
    :idempotency_key,
    :idempotency_strategy
  ]

  @impl Store
  @spec commit(Postgres.t(), String.t(), Commit.t()) ::
          :ok | {:error, :conflict | :not_found | :fenced | {:limit, String.t()}}
  def commit(instance \\ Postgres.runtime(), workflow_id, %Commit{} = commit)
      when is_binary(workflow_id) do
    Commit.check!(workflow_id, commit)
    PgQueue.check_ops!(commit.queue)
    check_storable!(workflow_id)
    rows = encode_commit!(commit)

    case Postgres.transaction(instance, fn ->
           apply_commit(instance, workflow_id, commit, rows)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Store
  @spec get_workflow(Postgres.t(), String.t(), boolean()) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow(instance \\ Postgres.runtime(), id, include_tasks?)
      when is_binary(id) and is_boolean(include_tasks?) do
    if storable?(id), do: read_workflow(instance, id, include_tasks?), else: {:error, :not_found}
  end

  @impl Store
  @spec get_task(Postgres.t(), String.t()) ::
          {:ok, Task.t(), String.t()} | {:error, :not_found}
  def get_task(instance \\ Postgres.runtime(), task_id) when is_binary(task_id) do
    with true <- storable?(task_id),
         %{rows: [[json, workflow_id]]} <-
           query!(
             instance,
             "SELECT json_data, workflow_id FROM #{table(instance, "task")} WHERE task_id = $1",
             [task_id]
           ) do
      {:ok, decode!(Task, json, task_id), workflow_id}
    else
      _absent -> {:error, :not_found}
    end
  end

  @impl Store
  @spec running_workflow_ids(Postgres.t()) :: [String.t()]
  def running_workflow_ids(instance \\ Postgres.runtime()) do
    %{rows: rows} =
      query!(
        instance,
        "SELECT workflow_id FROM #{table(instance, "workflow")} " <>
          "WHERE status = ANY($1) ORDER BY workflow_id",
        [@not_terminal]
      )

    Enum.map(rows, &hd/1)
  end

  @impl Store
  @spec correlated_workflows(Postgres.t(), String.t(), [String.t()], boolean(), boolean()) ::
          [Workflow.t()]
  def correlated_workflows(
        instance \\ Postgres.runtime(),
        name,
        correlation_ids,
        include_closed?,
        include_tasks?
      )
      when is_binary(name) and is_list(correlation_ids) and is_boolean(include_closed?) and
             is_boolean(include_tasks?) do
    ids = correlation_ids |> Enum.filter(&(is_binary(&1) and storable?(&1))) |> Enum.uniq()

    if storable?(name) and ids != [],
      do: read_correlated(instance, name, ids, include_closed?, include_tasks?),
      else: []
  end

  @impl Store
  @spec pending_workflow_ids(Postgres.t(), String.t()) :: [String.t()]
  def pending_workflow_ids(instance \\ Postgres.runtime(), name) when is_binary(name) do
    if storable?(name) do
      instance
      |> query!(
        "SELECT workflow_id FROM #{table(instance, "workflow")} " <>
          "WHERE workflow_name = $1 AND status IN (#{@not_terminal_sql}) " <>
          "ORDER BY create_time, workflow_id",
        [name]
      )
      |> Map.fetch!(:rows)
      |> Enum.map(&hd/1)
    else
      []
    end
  end

  @impl Store
  @spec workflow_ids_created_between(Postgres.t(), String.t(), integer(), integer(), integer()) ::
          [String.t()]
  def workflow_ids_created_between(
        instance \\ Postgres.runtime(),
        name,
        version,
        start_ms,
        end_ms
      )
      when is_binary(name) and is_integer(version) and is_integer(start_ms) and
             is_integer(end_ms) do
    # A column holds no time past a bound outside its range: that range is empty, and the other
    # bound is clamped.
    if storable?(name) and version in @int_range and start_ms <= @bigint_range.last and
         end_ms >= @bigint_range.first do
      instance
      |> query!(
        "SELECT workflow_id FROM #{table(instance, "workflow")} " <>
          "WHERE workflow_name = $1 AND workflow_version = $2 " <>
          "AND create_time BETWEEN $3 AND $4 ORDER BY create_time, workflow_id",
        [name, version, clamp(start_ms), clamp(end_ms)]
      )
      |> Map.fetch!(:rows)
      |> Enum.map(&hd/1)
    else
      []
    end
  end

  defp clamp(ms), do: ms |> max(@bigint_range.first) |> min(@bigint_range.last)

  @impl Store
  @spec remove_workflow(Postgres.t(), String.t()) :: :ok | {:error, :not_found}
  def remove_workflow(instance \\ Postgres.runtime(), id) when is_binary(id) do
    if storable?(id),
      do: Postgres.transaction!(instance, fn -> delete_workflow(instance, id) end),
      else: {:error, :not_found}
  end

  # The tasks and the outbox go with it (ON DELETE CASCADE).
  defp delete_workflow(instance, id) do
    %{num_rows: rows} =
      query!(instance, "DELETE FROM #{table(instance, "workflow")} WHERE workflow_id = $1", [id])

    if rows == 1, do: :ok, else: {:error, :not_found}
  end

  @impl Store
  @spec in_progress_count(Postgres.t(), String.t()) :: non_neg_integer()
  def in_progress_count(instance \\ Postgres.runtime(), task_def_name)
      when is_binary(task_def_name) do
    instance |> count_in_progress([task_def_name]) |> Map.get(task_def_name, 0)
  end

  @impl Store
  @spec pending_outbox(Postgres.t(), String.t()) :: [{Store.outbox_id(), Effect.t()}]
  def pending_outbox(instance \\ Postgres.runtime(), workflow_id) when is_binary(workflow_id) do
    rows =
      if storable?(workflow_id) do
        query!(
          instance,
          "SELECT id, effect FROM #{table(instance, "outbox")} WHERE workflow_id = $1 ORDER BY id",
          [workflow_id]
        ).rows
      else
        []
      end

    entries = Enum.map(rows, fn [id, json] -> {id, decode_effect!(json, id)} end)

    if Enum.any?(entries, &match?({_id, {:notify_parent, _, _, _}}, &1)),
      do: with_child(instance, workflow_id, entries),
      else: entries
  end

  @impl Store
  @spec ack_outbox(Postgres.t(), String.t(), [Store.outbox_id()]) :: :ok
  def ack_outbox(instance \\ Postgres.runtime(), workflow_id, ids)
      when is_binary(workflow_id) and is_list(ids) do
    ids = outbox_ids(ids)

    if storable?(workflow_id) and ids != [] do
      Postgres.transaction!(instance, fn -> delete_outbox(instance, workflow_id, ids) end)
    end

    :ok
  end

  @impl Store
  @spec outbox_workflow_ids(Postgres.t(), String.t() | nil, non_neg_integer()) :: [String.t()]
  def outbox_workflow_ids(instance \\ Postgres.runtime(), cursor, limit)
      when (is_binary(cursor) or is_nil(cursor)) and is_integer(limit) and limit >= 0 do
    table = table(instance, "outbox")

    {sql, params} =
      case cursor do
        nil ->
          {"SELECT DISTINCT workflow_id FROM #{table} ORDER BY workflow_id LIMIT $1", [limit]}

        cursor ->
          check_cursor!(cursor)

          {"SELECT DISTINCT workflow_id FROM #{table} WHERE workflow_id > $1 " <>
             "ORDER BY workflow_id LIMIT $2", [cursor, limit]}
      end

    instance |> query!(sql, params) |> Map.fetch!(:rows) |> Enum.map(&hd/1)
  end

  @impl Store
  @spec due_workflow_ids(Postgres.t(), integer(), Store.due_key() | nil, non_neg_integer()) ::
          [Store.due_key()]
  def due_workflow_ids(instance \\ Postgres.runtime(), before_ms, cursor, limit)
      when is_integer(before_ms) and is_integer(limit) and limit >= 0 do
    # The row comparison and the order are the expression index workflow_running_wake_index.
    {after_sql, params} =
      case cursor do
        nil ->
          {"", [before_ms, limit]}

        {key, id} when is_integer(key) and is_binary(id) ->
          check_cursor!(id)
          {"AND (COALESCE(wake_at, 0), workflow_id) > ($3, $4) ", [before_ms, limit, key, id]}

        _other ->
          raise ArgumentError, "invalid cursor #{inspect(cursor)}"
      end

    %{rows: rows} =
      query!(
        instance,
        """
        SELECT COALESCE(wake_at, 0), workflow_id FROM #{table(instance, "workflow")}
        WHERE status = '#{@running}' AND (wake_at IS NULL OR wake_at <= $1)
        #{after_sql}ORDER BY COALESCE(wake_at, 0), workflow_id LIMIT $2
        """,
        params
      )

    Enum.map(rows, fn [key, id] -> {key, id} end)
  end

  @impl Store
  @spec put_poll_data(Postgres.t(), String.t(), String.t() | nil, String.t() | nil, integer()) ::
          :ok
  def put_poll_data(instance \\ Postgres.runtime(), task_type, domain, worker_id, now)
      when is_binary(task_type) and is_integer(now) do
    Enum.each([task_type, domain, worker_id], &(&1 == nil or check_storable!(&1)))

    Postgres.transaction!(instance, fn ->
      query!(
        instance,
        """
        INSERT INTO #{table(instance, "poll_data")}
          (queue_name, domain_key, domain, worker_id, last_poll_time)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (queue_name, domain_key) DO UPDATE SET domain = EXCLUDED.domain,
          worker_id = EXCLUDED.worker_id, last_poll_time = EXCLUDED.last_poll_time
        """,
        [task_type, poll_key(domain), domain, worker_id, now]
      )

      :ok
    end)
  end

  @impl Store
  @spec get_poll_data(Postgres.t(), String.t(), String.t() | nil) ::
          {:ok, Store.poll_data()} | {:error, :not_found}
  def get_poll_data(instance \\ Postgres.runtime(), task_type, domain)
      when is_binary(task_type) do
    with true <- storable?(task_type) and (domain == nil or storable?(domain)),
         %{rows: [[domain, worker_id, last_poll_time]]} <-
           query!(
             instance,
             "SELECT domain, worker_id, last_poll_time FROM #{table(instance, "poll_data")} " <>
               "WHERE queue_name = $1 AND domain_key = $2",
             [task_type, poll_key(domain)]
           ) do
      {:ok,
       %{
         queue_name: task_type,
         domain: domain,
         worker_id: worker_id,
         last_poll_time: last_poll_time
       }}
    else
      _absent -> {:error, :not_found}
    end
  end

  # SqlitePollDataDAO stores a nil domain under "DEFAULT".
  defp poll_key(nil), do: "DEFAULT"
  defp poll_key(domain), do: domain

  ## Commit

  # Applies the encoded commit inside the fenced transaction, in the order of the memory store.
  defp apply_commit(instance, workflow_id, commit, rows) do
    # The limit count needs a snapshot taken after the lock; the runtime fence already sets this.
    if instance.fence == nil,
      do: query!(instance, "SET TRANSACTION ISOLATION LEVEL READ COMMITTED", [])

    lock_limits(instance, commit.limits)

    with :ok <- create_or_lock(instance, workflow_id, rows.create),
         :ok <- update_workflow(instance, workflow_id, rows.workflow),
         :ok <- put_tasks(instance, workflow_id, rows.tasks),
         :ok <- delete_tasks(instance, workflow_id, commit.delete_task_ids),
         :ok <- delete_outbox(instance, workflow_id, outbox_ids(commit.outbox_ack)),
         :ok <- append_outbox(instance, workflow_id, rows.outbox),
         :ok <- put_wake(instance, workflow_id, commit.wake),
         :ok <- check_limits(instance, commit.limits),
         :ok <- PgQueue.apply_ops(instance, commit.queue) do
      :ok
    else
      {:error, reason} -> Postgres.rollback(instance, reason)
    end
  end

  # Everything that can be refused before the transaction: storable columns and the JSON.
  defp encode_commit!(%Commit{} = commit) do
    %{
      create: commit.create && encode_workflow!(commit.create),
      workflow: commit.workflow && encode_workflow!(commit.workflow),
      # The created tasks and then the upserts, as one statement: a later version wins.
      tasks: encode_tasks!(((commit.create && commit.create.tasks) || []) ++ commit.upsert_tasks),
      outbox: Enum.map(commit.outbox, &encode_effect!/1)
    }
  end

  defp encode_workflow!(%Workflow{} = workflow) do
    json = workflow |> Workflow.to_storage() |> Map.delete("tasks")
    Enum.each([json["status"], workflow.parent_workflow_id], &(&1 == nil or check_storable!(&1)))

    [
      json["status"],
      workflow.parent_workflow_id,
      queryable(Workflow.workflow_name(workflow)),
      in_range(Workflow.workflow_version(workflow), @int_range),
      queryable(workflow.correlation_id),
      in_range(workflow.create_time, @bigint_range),
      encode_json!(json)
    ]
  end

  # A value only the queries read: NULL when the column cannot hold it.
  defp queryable(value) when is_binary(value), do: if(storable?(value), do: value)
  defp queryable(_value), do: nil

  defp in_range(value, range) when is_integer(value), do: if(value in range, do: value)
  defp in_range(_value, _range), do: nil

  # A task listed twice keeps its last version, as the memory store does.
  defp encode_tasks!(tasks) do
    tasks
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.task_id)
    |> Enum.reverse()
    |> Enum.map(fn %Task{} = task ->
      unless is_integer(task.seq) and task.status in Task.statuses(),
        do: raise(ArgumentError, "task #{task.task_id} needs a seq and a status")

      json = Task.to_storage(task)
      name = Task.task_def_name(task)
      Enum.each([task.task_id, json["status"], name], &(&1 == nil or check_storable!(&1)))
      [task.task_id, task.seq, json["status"], name, encode_json!(json)]
    end)
  end

  defp encode_json!(json) do
    JSON.encode!(json)
  rescue
    error in [ErlangError, Protocol.UndefinedError] ->
      reraise ArgumentError,
              "a stored value must encode to UTF-8 JSON: #{Exception.message(error)}",
              __STACKTRACE__
  end

  # ADR 0021, decision 5: one lock per key, in key order, so that two commits never wait on each
  # other's locks (names of the same key share one).
  defp lock_limits(instance, limits) do
    limits
    |> Map.keys()
    |> Enum.map(&limit_key/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(
      &query!(instance, "SELECT pg_advisory_xact_lock($1::integer, $2::integer)", [
        @limit_lock_class,
        &1
      ])
    )
  end

  # A signed 32-bit key of the name.
  defp limit_key(name) do
    <<key::signed-32>> = <<:erlang.crc32(name)::32>>
    key
  end

  defp check_limits(_instance, limits) when map_size(limits) == 0, do: :ok

  defp check_limits(instance, limits) do
    counts = count_in_progress(instance, Map.keys(limits))

    limits
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {name, limit} ->
      if Map.get(counts, name, 0) > limit, do: {:error, {:limit, name}}
    end)
  end

  defp count_in_progress(instance, names) do
    case Enum.filter(names, &storable?/1) do
      [] ->
        %{}

      names ->
        %{rows: rows} =
          query!(
            instance,
            "SELECT task_def_name, count(*) FROM #{table(instance, "task")} " <>
              "WHERE status = '#{@in_progress}' AND task_def_name = ANY($1) GROUP BY task_def_name",
            [names]
          )

        Map.new(rows, fn [name, count] -> {name, count} end)
    end
  end

  defp create_or_lock(instance, workflow_id, nil) do
    # Commits of one workflow come from its process; the lock orders them against a removal.
    case query!(
           instance,
           "SELECT 1 FROM #{table(instance, "workflow")} WHERE workflow_id = $1 FOR NO KEY UPDATE",
           [workflow_id]
         ) do
      %{num_rows: 1} -> :ok
      %{num_rows: 0} -> {:error, :not_found}
    end
  end

  defp create_or_lock(instance, workflow_id, row) do
    %{num_rows: rows} =
      query!(
        instance,
        "INSERT INTO #{table(instance, "workflow")} " <>
          "(workflow_id, status, parent_workflow_id, workflow_name, workflow_version, " <>
          "correlation_id, create_time, json_data) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) " <>
          "ON CONFLICT (workflow_id) DO NOTHING",
        [workflow_id | row]
      )

    if rows == 1, do: :ok, else: {:error, :conflict}
  end

  defp update_workflow(_instance, _workflow_id, nil), do: :ok

  defp update_workflow(instance, workflow_id, row) do
    query!(
      instance,
      "UPDATE #{table(instance, "workflow")} SET status = $2, parent_workflow_id = $3, " <>
        "workflow_name = $4, workflow_version = $5, correlation_id = $6, create_time = $7, " <>
        "json_data = $8 WHERE workflow_id = $1",
      [workflow_id | row]
    )

    :ok
  end

  defp put_tasks(_instance, _workflow_id, []), do: :ok

  # A task ID another workflow owns is neither inserted nor updated, so it is not counted. A
  # commit writes all its tasks in this one statement, locking them in task ID order, so two
  # commits over the same IDs wait on each other but never deadlock.
  defp put_tasks(instance, workflow_id, tasks) do
    [ids, seqs, statuses, names, jsons] = transpose(tasks, 5)
    table = table(instance, "task")

    %{num_rows: rows} =
      query!(
        instance,
        """
        INSERT INTO #{table} AS t (task_id, workflow_id, seq, status, task_def_name, json_data)
        SELECT u.task_id, $1, u.seq, u.status, u.task_def_name, u.json_data
        FROM unnest($2::text[], $3::integer[], $4::text[], $5::text[], $6::text[])
          AS u(task_id, seq, status, task_def_name, json_data)
        ORDER BY u.task_id
        ON CONFLICT (task_id) DO UPDATE SET seq = EXCLUDED.seq, status = EXCLUDED.status,
          task_def_name = EXCLUDED.task_def_name, json_data = EXCLUDED.json_data
        WHERE t.workflow_id = EXCLUDED.workflow_id
        """,
        [workflow_id, ids, seqs, statuses, names, jsons]
      )

    if rows == length(tasks), do: :ok, else: {:error, :conflict}
  end

  defp transpose(rows, width) do
    rows
    |> Enum.reduce(List.duplicate([], width), fn row, columns ->
      Enum.zip_with(row, columns, &[&1 | &2])
    end)
    |> Enum.map(&Enum.reverse/1)
  end

  defp delete_tasks(instance, workflow_id, task_ids) do
    case Enum.filter(task_ids, &(is_binary(&1) and storable?(&1))) do
      [] ->
        :ok

      ids ->
        query!(
          instance,
          "DELETE FROM #{table(instance, "task")} WHERE workflow_id = $1 AND task_id = ANY($2)",
          [workflow_id, ids]
        )

        :ok
    end
  end

  # IDs a bigint can hold; any other cannot name an entry.
  defp outbox_ids(ids), do: Enum.filter(ids, &(is_integer(&1) and &1 > 0 and &1 <= @max_bigint))

  defp delete_outbox(_instance, _workflow_id, []), do: :ok

  defp delete_outbox(instance, workflow_id, ids) do
    query!(
      instance,
      "DELETE FROM #{table(instance, "outbox")} WHERE workflow_id = $1 AND id = ANY($2)",
      [workflow_id, ids]
    )

    :ok
  end

  defp append_outbox(_instance, _workflow_id, []), do: :ok

  # The IDs (bigserial) follow the list: the rows are inserted in ordinality order.
  defp append_outbox(instance, workflow_id, effects) do
    query!(
      instance,
      """
      INSERT INTO #{table(instance, "outbox")} (workflow_id, effect, inserted_at)
      SELECT $1, u.effect, $3 FROM unnest($2::text[]) WITH ORDINALITY AS u(effect, n)
      ORDER BY u.n
      """,
      [workflow_id, effects, Postgres.now(instance)]
    )

    :ok
  end

  defp put_wake(_instance, _workflow_id, :keep), do: :ok

  defp put_wake(instance, workflow_id, wake) do
    {set, params} =
      case wake do
        :none -> {"NULL", []}
        {:at, ms} -> {"$2", [ms]}
        {:before, ms} -> {"LEAST(COALESCE(wake_at, $2), $2)", [ms]}
      end

    query!(
      instance,
      "UPDATE #{table(instance, "workflow")} SET wake_at = #{set} WHERE workflow_id = $1",
      [workflow_id | params]
    )

    :ok
  end

  ## Reads

  # ADR 0021, decision 2: one statement, so the workflow and its tasks come from one snapshot.
  defp read_workflow(instance, id, include_tasks?) do
    sql =
      if include_tasks? do
        """
        WITH w AS (SELECT workflow_id, json_data FROM #{table(instance, "workflow")}
                   WHERE workflow_id = $1)
        SELECT w.json_data,
               ARRAY(SELECT t.json_data FROM #{table(instance, "task")} t
                     WHERE t.workflow_id = w.workflow_id
                     ORDER BY t.seq, t.task_id COLLATE "C")
        FROM w
        """
      else
        "SELECT json_data, NULL FROM #{table(instance, "workflow")} WHERE workflow_id = $1"
      end

    case query!(instance, sql, [id]) do
      %{rows: [[json, tasks]]} ->
        workflow = decode!(Workflow, json, id)
        {:ok, %{workflow | tasks: Enum.map(tasks || [], &decode!(Task, &1, id))}}

      %{rows: []} ->
        {:error, :not_found}
    end
  end

  # One statement, as read_workflow/3: the workflows and their tasks come from one snapshot.
  defp read_correlated(instance, name, correlation_ids, include_closed?, include_tasks?) do
    tasks =
      if include_tasks? do
        "ARRAY(SELECT t.json_data FROM #{table(instance, "task")} t " <>
          "WHERE t.workflow_id = w.workflow_id ORDER BY t.seq, t.task_id COLLATE \"C\")"
      else
        "NULL"
      end

    status = if include_closed?, do: "", else: "AND w.status = '#{@running}' "

    %{rows: rows} =
      query!(
        instance,
        "SELECT w.workflow_id, w.json_data, #{tasks} FROM #{table(instance, "workflow")} w " <>
          "WHERE w.workflow_name = $1 AND w.correlation_id = ANY($2) #{status}" <>
          "ORDER BY w.create_time, w.workflow_id",
        [name, correlation_ids]
      )

    Enum.map(rows, fn [id, json, tasks] ->
      workflow = decode!(Workflow, json, id)
      %{workflow | tasks: Enum.map(tasks || [], &decode!(Task, &1, id))}
    end)
  end

  # A :notify_parent entry carries the stored child: the workflow that owns the entry.
  defp with_child(instance, workflow_id, entries) do
    case read_workflow(instance, workflow_id, true) do
      {:ok, child} ->
        Enum.map(entries, fn
          {id, {:notify_parent, parent, task, _child}} ->
            {id, {:notify_parent, parent, task, child}}

          entry ->
            entry
        end)

      # Removed since the entries were read, and its outbox with it.
      {:error, :not_found} ->
        []
    end
  end

  defp decode!(module, json, id), do: from_storage!(module, JSON.decode!(json), id)

  defp from_storage!(module, json, id) do
    case module.from_storage(json) do
      {:ok, value} ->
        value

      {:error, errors} ->
        raise ArgumentError,
              "stored #{inspect(module)} of #{inspect(id)} does not decode: #{inspect(errors)}"
    end
  end

  ## Outbox effects

  # ADR 0021, decision 4: the kind and its arguments, never a workflow struct.
  defp encode_effect!(effect) do
    {kind, args} = effect_args(effect)
    encode_json!(%{"kind" => kind, "args" => args})
  end

  defguardp id?(value) when is_binary(value)
  defguardp task_id?(value) when is_binary(value) or value == nil

  defp effect_args({:terminate_sub_workflow, child, reason}) when id?(child) and id?(reason),
    do: {"terminate_sub_workflow", [child, reason]}

  # Slice 4e adds the parent's end count (ADR 0021, decision 4).
  defp effect_args({:terminate_sub_workflow, child, reason, end_count})
       when id?(child) and id?(reason) and is_integer(end_count),
       do: {"terminate_sub_workflow", [child, reason, end_count]}

  defp effect_args({:notify_parent, parent, task, _child}) when id?(parent) and task_id?(task),
    do: {"notify_parent", [parent, task]}

  defp effect_args({:revive_parent, parent, task}) when id?(parent) and task_id?(task),
    do: {"revive_parent", [parent, task]}

  defp effect_args({:retry_sub_workflow, child}) when id?(child),
    do: {"retry_sub_workflow", [child]}

  defp effect_args({:start_failure_workflow, %{} = start}),
    do: {"start_failure_workflow", [encode_start!(start)]}

  defp effect_args(effect),
    do: raise(ArgumentError, "an outbox entry cannot hold #{inspect(effect)}")

  defp encode_start!(start) do
    case Map.keys(start) -- @start_keys do
      [] -> :ok
      unknown -> raise ArgumentError, "a stored start cannot hold the keys #{inspect(unknown)}"
    end

    for key <- @start_keys, Map.has_key?(start, key), into: %{} do
      value =
        case {key, start[key]} do
          {:definition, %WorkflowDef{} = definition} ->
            WorkflowDef.to_storage(definition)

          {:definition, nil} ->
            nil

          {:definition, other} ->
            raise ArgumentError, "a stored start's definition: #{inspect(other)}"

          {_key, value} ->
            value
        end

      {Atom.to_string(key), value}
    end
  end

  defp decode_effect!(json, id) do
    case JSON.decode!(json) do
      %{"kind" => "terminate_sub_workflow", "args" => [child, reason]} ->
        {:terminate_sub_workflow, child, reason}

      %{"kind" => "terminate_sub_workflow", "args" => [child, reason, end_count]} ->
        {:terminate_sub_workflow, child, reason, end_count}

      %{"kind" => "notify_parent", "args" => [parent, task]} ->
        {:notify_parent, parent, task, nil}

      %{"kind" => "revive_parent", "args" => [parent, task]} ->
        {:revive_parent, parent, task}

      %{"kind" => "retry_sub_workflow", "args" => [child]} ->
        {:retry_sub_workflow, child}

      %{"kind" => "start_failure_workflow", "args" => [start]} ->
        {:start_failure_workflow, decode_start!(start, id)}

      other ->
        raise ArgumentError, "stored outbox entry #{id} does not decode: #{inspect(other)}"
    end
  end

  defp decode_start!(start, id) do
    for key <- @start_keys, Map.has_key?(start, Atom.to_string(key)), into: %{} do
      case {key, start[Atom.to_string(key)]} do
        {:definition, %{} = definition} -> {key, from_storage!(WorkflowDef, definition, id)}
        {key, value} -> {key, value}
      end
    end
  end

  ## Helpers

  defp check_storable!(value) do
    unless is_binary(value) and storable?(value),
      do:
        raise(ArgumentError, "an ID, name or status must be UTF-8 without NUL: #{inspect(value)}")

    :ok
  end

  defp check_cursor!(cursor) do
    unless storable?(cursor),
      do: raise(ArgumentError, "a cursor must be UTF-8 without NUL: #{inspect(cursor)}")
  end

  defp storable?(name), do: String.valid?(name) and not String.contains?(name, <<0>>)

  defp query!(%Postgres{repo: repo}, sql, params), do: repo.query!(sql, params)

  defp table(instance, name), do: Postgres.table(instance, name)
end
