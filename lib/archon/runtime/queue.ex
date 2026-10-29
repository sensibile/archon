# Copyright Conductor Authors.
# Copyright 2026 sensibile
#
# Licensed under the Apache License, Version 2.0 (see LICENSE).
#
# Derived from conductor-oss core/src/main/java/com/netflix/conductor/dao/QueueDAO.java and
# sqlite-persistence/src/main/java/com/netflix/conductor/sqlite/dao/SqliteQueueDAO.java
# at commit 1488804170d159021c7e62dce61514b8f31ef9ff.
# Modified by sensibile: reduced to the operations the MVP runtime uses (ADR 0018, decision 3);
# delays are milliseconds instead of seconds.

defmodule Archon.Runtime.Queue do
  @moduledoc """
  Task queue behaviour: the MVP part of upstream `QueueDAO`, with the meaning of the default
  server's `SqliteQueueDAO` (ADR 0018, decision 3).

  Only tasks that workers poll go into queues; a queue name is `[domain:]taskType`. A message is
  an ID, unique within its queue, with a priority and the time it becomes visible.

  Callbacks:

    * `c:push/4` - adds a message visible after `delay_ms`. If the ID is already in the queue,
      only its visible time changes to the new delay and its popped mark is cleared; the priority
      and place among equal messages stay (`SqliteQueueDAO#pushMessage`).
    * `c:pop/3` - pops up to `count` visible messages, highest priority first, then earliest
      visible time, then the order they were added. With none visible it waits up to `timeout_ms`
      and answers as soon as at least one is (upstream issue 142); `count <= 0` answers `[]` at once.
      A popped message is still in the queue (`c:size/1`, `c:contains?/2`) and becomes visible again
      if it is not acked within the unack timeout (60 seconds by default).
    * `c:ack/2` - deletes a message; `true` if it was there.
    * `c:remove/2` - deletes a message.
    * `c:postpone/4` - deletes and pushes again with a new priority and delay (upstream
      `QueueDAO#postpone` default), so the message also goes behind its equals.
    * `c:contains?/2` - whether the ID is in the queue, popped or not.
    * `c:size/1` - messages in the queue, popped or not (`SqliteQueueDAO#getSize`).
  """

  @callback push(
              queue :: String.t(),
              id :: String.t(),
              priority :: integer(),
              delay_ms :: integer()
            ) ::
              :ok
  @callback pop(queue :: String.t(), count :: integer(), timeout_ms :: integer()) :: [String.t()]
  @callback ack(queue :: String.t(), id :: String.t()) :: boolean()
  @callback remove(queue :: String.t(), id :: String.t()) :: :ok
  @callback postpone(
              queue :: String.t(),
              id :: String.t(),
              priority :: integer(),
              delay_ms :: integer()
            ) :: :ok
  @callback contains?(queue :: String.t(), id :: String.t()) :: boolean()
  @callback size(queue :: String.t()) :: non_neg_integer()
end
