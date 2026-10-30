# ADR 0021: Phase 4 PostgreSQL 영속성과 큐 설계

- 상태: 제안
- 날짜: 2026-10-30
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`
- 비고: 설계 갈림길 네 가지(DB 라이브러리, 큐·Effect 원자성, 여러 노드, 지연 활성화)는 2026-10-30 BOSS가 이 문서의 추천안으로 정했다.

## 맥락

[ADR 0003](0003-porting-strategy.md)은 Phase 4를 "영속성과 큐: PostgreSQL 우선"으로 정했다.
[ADR 0018](0018-phase3-otp-runtime.md)은 `Archon.Runtime.Store`·`Queue`·`Metadata` behaviour와 메모리 구현을 만들고
(결정 3), Postgres 구현이 그 자리를 갈아 끼우도록 했다(결정 1). 또 결과 절에서 저장용 인코딩, 큐의 원자성,
지연 활성화, 여러 노드의 소유권, 종료 상태 워크플로우의 남은 일 복구를 Phase 4 ADR로 넘겼다. 조각 3e·3f도
다음 한계를 Phase 4로 넘겼다(3f 인계 기록).

| 번호 | 한계 | 출처 |
|---|---|---|
| L1 | 재개 cast 유실: 자식의 `{:revive_parent}` cast를 부모가 처리하기 전에 죽거나, 0 timeout으로 끝나는 부모 pid와 겹치면 부모가 종료 상태로 남는다 | 3f |
| L2 | `previous_status`로 "부모가 끝난 뒤 다시 실행된 자식"을 가리므로, 재시도된 자식을 일시정지·재개하면 복구 검사가 그 자식을 종료할 수 있다. 같은 밀리초에서 자식 재시도가 부모 종료보다 먼저면 놓친다 | 3f |
| L3 | `resumeSubworkflowTasks`: 자식을 못 읽으면 그 위를 재시도한다(upstream NotFound). 내려간 끝이 실행 중인 자식이면 "still running" 오류를 돌려준다(upstream은 검사 없이 재시도) | 3f |
| L4 | 형제 자식 재시도 직후 바로 decide한다(upstream은 decider 큐 30초 지연). 결과 상태는 같다 | 3f |
| L5 | 저장소 구현이 `WorkflowServer.env/2`에서 raise하면 자식 시작이 `FAILED`로 분류된다 | 3e |
| L6 | `SubWorkflows.terminate_child`의 조상 취소 `Elixir.Task.start`가 감독되지 않는다 | 3e |
| L7 | worker가 준 `subWorkflowId`들이 조상 사슬이 아닌 순환을 이루면 종료가 call timeout까지 기다린다 | 3e |
| L8 | worker가 준 `subWorkflowId`로 관계없는 워크플로우가 취소·재시도될 수 있다(BOSS 2026-10-30 upstream 유지 결정) | 3b·3e |
| L9 | ADR 0018 결과 절: 저장용 인코딩, 큐 원자성, 지연 활성화, 여러 노드 소유권, 종료 상태인데 실패 워크플로우를 못 띄운 워크플로우·자식 종료 요청을 못 보낸 부모의 복구, 원인 태스크 없는 `TERMINATED` 종료의 실패 워크플로우 재시작 빈틈 | 0018 |
| L10 | 동시 실행 한도: 개수 확인과 `IN_PROGRESS` 저장이 다른 프로세스에서 일어나 한도를 잠깐 넘을 수 있다 | 3c |
| L11 | 시험 소음: 고정 ID(`runtime_test.exs` "idem-1", `workflow_server_test.exs`의 `ws-crash-after-commit`·`ws-push-fails`)와 `effects.ex`의 낡은 `failure_workflow_started/1` 주석 | 3f |

upstream의 Postgres 구현은 `postgres-persistence` 모듈이다(경로는 그 모듈의 `src/main/` 아래).

| upstream | 하는 일 |
|---|---|
| `resources/db/migration_postgres/V1__initial_schema.sql`, `V5__new_queue_message_pk.sql`, `V6__update_pk.sql`, `V7__new_qm_index_desc_priority.sql`, `V10__poll_data_check.sql`, `V11__locking.sql` | 표마다 `json_data TEXT`와 색인 열. 실행 표 `workflow`·`task`·`workflow_to_task`·`workflow_pending`·`task_in_progress`·`task_scheduled`·`poll_data`, 큐 표 `queue`·`queue_message`(`(queue_name, message_id)` 기본 키, `deliver_on`·`priority`·`popped`), 메타데이터 표 `meta_task_def`·`meta_workflow_def`, 락 표 `locks` |
| `java/com/netflix/conductor/postgres/dao/PostgresBaseDAO.java` | DAO 호출마다 커넥션 하나로 트랜잭션을 열고 끝나면 commit한다(`getWithTransaction`, `withTransaction`). 여러 DAO 호출을 묶는 트랜잭션은 없다 |
| `java/com/netflix/conductor/postgres/dao/PostgresExecutionDAO.java` | `createTasks`, `updateTask`(`task_in_progress` 갱신), `exceedsLimit`(개수 질의 뒤 도착 순서 검사), `getInProgressTaskCount`, `removeWorkflow`, `insertOrUpdateWorkflow`(`workflow_pending` 갱신) |
| `java/com/netflix/conductor/postgres/dao/PostgresQueueDAO.java` | `pop`: `ORDER BY deliver_on, priority DESC, created_on ... FOR UPDATE SKIP LOCKED`로 고른 행을 `popped = true`로 바꾼다. 긴 poll은 100ms 간격으로 다시 묻는다. unack 재노출은 주기 작업 `processAllUnacks`(60초 지난 `popped` 행을 되돌림) |
| `java/com/netflix/conductor/postgres/util/PostgresQueueListener.java`, `migration_postgres_notify/V10.1__notify.sql` | 선택 기능: `LISTEN conductor_queue_state`로 큐별 다음 전달 시각을 받아 빈 pop 질의를 건너뛴다 |
| `java/com/netflix/conductor/postgres/dao/PostgresLockDAO.java` | `locks` 표의 lease 락(여러 노드에서 워크플로우 락) |
| `java/com/netflix/conductor/postgres/dao/PostgresPollDataDAO.java`, `PostgresMetadataDAO.java` | poll 데이터(`lastPollTime`이 줄지 않게 하는 트리거), 정의 저장 |

ADR 0018 결정 3의 큐 의미는 기본 서버의 `SqliteQueueDAO`(`ORDER BY priority DESC, deliver_on, created_on`)다.
upstream Postgres 큐는 보일 시각을 먼저 본다. Archon은 이미 계약 시험으로 고정한 SQLite 의미를 따른다(아래
"upstream과 의도적으로 다른 점").

## 결정

### 1. Ecto SQL과 Postgrex를 쓴다

- 의존성은 `ecto_sql`과 `postgrex`다. 구현 조각이 그때의 최신 안정판을 고르고 `mix.lock`으로 고정한다. 둘 다
  Apache-2.0이다.
- 저장소 모듈은 `Archon.Repo`(`Ecto.Repo`, `adapter: Ecto.Adapters.Postgres`)다. 연결 설정은 `config/runtime.exs`가
  `DATABASE_URL`에서 읽는다.
- 쿼리는 Ecto 스키마 없이 `Ecto.Query`(스키마 없는 원천 표 질의)나 `Repo.query/3`로 쓴다. 행을 도메인 struct로
  바꾸는 일은 결정 2의 저장 인코딩이 한다. Ecto 스키마 모듈을 두면 도메인 struct와 같은 필드를 두 벌 관리하게 된다.
- 마이그레이션은 `priv/repo/migrations`의 Ecto 마이그레이션이다. 개발·시험은 `mix ecto.create`·`mix ecto.migrate`
  alias로, 배포는 `Archon.Release.migrate/0`로 한다. 애플리케이션 시작이 마이그레이션을 실행하지는 않는다.
- 시험은 `Ecto.Adapters.SQL.Sandbox`를 쓰지 않는다. 런타임 시험은 여러 프로세스(워크플로우 프로세스, 감독되는 Task)가
  같은 데이터를 쓰므로 Sandbox 소유권을 넘기기 번거롭다. Postgres 시험은 `async: false`로 돌고, 시험마다 고유 ID를
  쓰며, 스위트 시작 때 표를 비운다(결정 9).

### 2. 저장 형식: 색인 열과 JSON 텍스트

upstream처럼 행마다 색인 열과 `json_data text`를 둔다. 시각은 애플리케이션 시계의 epoch ms `bigint`다(Queue
behaviour moduledoc: 계약 시험이 시계를 주입하므로 DB `now()`를 쓰지 않는다).

| 표 | 열 | 색인·제약 |
|---|---|---|
| `workflow` | `workflow_id text` PK, `status text`, `parent_workflow_id text`, `wake_at bigint`(결정 6), `json_data text` | `status`가 `RUNNING`·`PAUSED`인 행의 `wake_at` 부분 색인 |
| `task` | `task_id text` PK, `workflow_id text`(FK → `workflow`, `ON DELETE CASCADE`), `seq integer`, `status text`, `task_def_name text`, `json_data text` | `(workflow_id, seq)`, `status = 'IN_PROGRESS'`인 행의 `task_def_name` 부분 색인 |
| `outbox` | `id bigserial` PK, `workflow_id text`(FK → `workflow`, `ON DELETE CASCADE`), `effect text`, `inserted_at bigint` | `workflow_id` |
| `queue_message` | `queue_name text`, `message_id text`(둘이 PK), `priority integer`, `deliver_on bigint`, `popped boolean`, `unack_on bigint`, `seq bigserial` | `(queue_name, priority DESC, deliver_on, seq)` |
| `poll_data` | `queue_name text`, `domain_key text`(둘이 PK, `nil`은 `"DEFAULT"`), `domain text`, `worker_id text`, `last_poll_time bigint` | |
| `meta_task_def` | `name text` PK, `json_data text` | |
| `meta_workflow_def` | `name text`, `version integer`(둘이 PK), `json_data text` | |

- **저장 인코딩.** ADR 0014 결정 3이 미뤄 둔 "내부 필드를 포함하는 인코딩"을 `to_storage/1`·`from_storage/1`로
  정한다. `Workflow`, `Task`, `WorkflowDef`, `TaskDef`에 두고, `Archon.Domain.Codec.encode/4`·`decode/5`에 `internal: true`
  옵션을 더해 `wire: false` 필드까지 읽고 쓴다. 기존 `to_json/1`·`from_json/2`(REST)는 그대로다. 워크플로우 행의
  `json_data`는 `tasks`를 뺀 워크플로우다. 태스크는 `task` 표에서 `seq` 순으로 읽어 붙인다.
- **`jsonb`가 아니라 `text`.** `jsonb`는 문자열 안의 `\u0000`을 받지 않아 upstream(`TEXT`)이 받는 입력을 거절하게
  된다. 키 순서·숫자 표기도 바꾼다. 저장 형식은 질의 대상이 아니므로 바이트 그대로 두는 `text`를 쓴다.
- **`:erlang.term_to_binary`가 아닌 이유.** struct 모양이 바뀐 뒤 예전 행을 읽으면 빠진 필드가 조용히 생기고, DB에서
  내용을 볼 수 없다.
- upstream의 `workflow_to_task`, `workflow_pending`, `task_in_progress`, `task_scheduled`, `workflow_def_to_workflow`,
  색인 표(`workflow_index`, `task_index`)는 두지 않는다. 앞의 넷은 `task.workflow_id`·`workflow.status`·`task.status`
  열과 `Step`의 중복 제거(ADR 0018 결정 4의 5)가 대신한다. 검색 API가 필요해지면 그 ADR에서 색인을 더한다.
- **일관된 읽기.** `get_workflow(id, true)`는 워크플로우와 태스크를 한 SQL 문(CTE)으로 읽는다. READ COMMITTED에서 두
  문으로 읽으면 서로 다른 Commit의 워크플로우와 태스크를 섞어 볼 수 있다(Store behaviour의 "부분 반영이 없다" 위반).

### 3. Commit에 큐 연산, outbox, 재평가 시각, 한도 검사를 담는다

ADR 0018 결정 2의 `Commit` 필드 네 개에 다음 넷을 더한다. 저장소는 여덟 필드를 한 트랜잭션으로 적용한다.

| 필드 | 형태 | 의미 |
|---|---|---|
| `queue` | `[{:push, queue, id, priority, delay_ms} \| {:remove, queue, id} \| {:postpone, queue, id, priority, delay_ms}]` | 워커 큐 연산. 의미는 `Queue`의 같은 이름 콜백 |
| `outbox` | `[Step.Effect.t()]` | 결정 4의 다른 워크플로우에 하는 일. 저장된 항목은 ID를 받는다 |
| `wake` | `:keep \| {:at, ms} \| {:before, ms} \| :none` | 결정 6. 기본 `:keep` |
| `limits` | `%{task_def_name => limit}` | 결정 5. 기본 `%{}` |

- **큐는 저장과 같은 트랜잭션이다.** `WorkflowServer`는 `Step.run`이 낸 post Effect 가운데 `:queue_push`·`:queue_remove`·
  `:queue_postpone`을 빼서 `Commit.queue`에 넣는다. `Step`은 지금처럼 Effect로 내고, 옮기는 일은 프로세스가 한다.
  그래서 "저장은 됐는데 큐 push는 안 된" 상태가 없다. 큐 push 실패를 기록만 하고 넘기던 규칙(ADR 0018 결정 2의 3c 갱신)은
  "Commit 실패이므로 예외 격리"로 바뀐다. 복구 검사의 "큐에 없는 `SCHEDULED` 태스크 다시 넣기"는 그대로 둔다. unack나
  관리 작업으로 메시지가 빠진 경우를 메운다.
- **저장소와 큐는 같은 백엔드여야 한다.** `Store.Postgres`는 `Queue.Postgres`의 쓰기 함수를 같은 트랜잭션 연결로
  부르고, `Store.Memory`는 `Queue.Memory`에 순서대로 적용한다(메모리 구현은 원래 내구성이 없다). 설정이 둘을 섞으면
  `Archon.Runtime.Supervisor`가 시작을 거절한다.
- 지연(`delay_ms`)은 Commit을 만든 `Env.now`에 더해 `deliver_on`으로 저장한다.
- **Store behaviour의 새 콜백.**

  | 콜백 | 의미 |
  |---|---|
  | `ack_outbox(workflow_id, [id])` | 실행을 마친 outbox 항목을 지운다 |
  | `pending_outbox(workflow_id)` | 그 워크플로우의 남은 항목 `[{id, effect}]`(넣은 순서) |
  | `outbox_workflow_ids(limit)` | 남은 항목이 있는 워크플로우 ID |
  | `due_workflow_ids(before_ms, limit)` | `RUNNING`이고 `wake_at`이 `before_ms` 이하이거나 없는 워크플로우 ID(이른 순) |

  `commit/2`의 오류에 `{:error, {:limit, task_def_name}}`(결정 5)을 더한다.

### 4. 다른 워크플로우에 하는 일은 outbox에 남겨 감독되는 Task가 실행한다 (L1, L6, L9)

ADR 0018 대안 절이 Phase 4로 넘긴 outbox를 들인다.

- **대상 Effect:** `:terminate_sub_workflow`(post만. 종료 경로의 `pre` 자식 종료는 Commit 전에 끝나야 하므로 그대로다),
  `:notify_parent`, `:revive_parent`, `:retry_sub_workflow`, `:start_failure_workflow`. `WorkflowServer`는 이것들을 post에서
  빼서 `Commit.outbox`에 넣는다. `:start_sub_workflow`는 결과를 같은 메시지 안에서 되먹이므로(ADR 0018 결정 2) 대상이
  아니다. 그 복구는 지금처럼 "`SCHEDULED`인데 자식이 없는 SUB_WORKFLOW 재시작"이다.
- **항목 형식.** `effect`는 JSON이다: `kind`와 인자. 워크플로우 struct는 담지 않는다. `:notify_parent`는 자식 ID만
  남기고 실행할 때 저장소에서 다시 읽는다. `:start_failure_workflow`의 시작 정보는 ID·이름·버전·입력과, 정의가 박혀
  있으면 `WorkflowDef.to_storage/1`이다.
- **실행.** Commit 뒤 `WorkflowServer`는 저장된 항목을 `Archon.Runtime.TaskSupervisor`(`Task.Supervisor`) 아래 Task
  하나에 넘긴다. Task는 항목을 넣은 순서대로 실행하고, 성공한 항목마다 `ack_outbox`를 부른다. 실패하면 남은 항목을 두고
  끝난다. 워크플로우 프로세스가 기다리지 않으므로 Task는 상대 프로세스를 `call`해도 교착이 없다. 그래서 자식 → 부모의
  `:revive_parent`·`:notify_parent`도 cast가 아니라 `call`(`child_revived`, `child_changed`)로 바꾸고, 부모가 처리한
  뒤에 지운다. 0 timeout으로 끝나는 부모의 죽은 pid에 닿으면 `:noproc`이고, ADR 0018 결정 1의 규칙대로 다시
  활성화한다(L1).
- **조상 취소(L6).** `SubWorkflows.terminate_child`의 `cancel_later`는 `Elixir.Task.start` 대신 같은 `TaskSupervisor`에서
  돈다. 그 요청은 이미 부모의 outbox 항목 실행 안에 있으므로 따로 기록하지 않는다. 실패하면 항목이 남는다.
- **다시 실행.** 남은 항목은 (1) 그 워크플로우 프로세스가 활성화될 때 `handle_continue`에서, (2) `Recovery`와 결정 6의
  `Archon.Runtime.Waker`가 `outbox_workflow_ids/1`로 찾은 워크플로우를 활성화할 때 다시 실행한다. 종료 상태 워크플로우도
  활성화되어 남은 항목을 실행한 뒤 유휴 시간에 끝난다. 그래서 L9의 "실패 워크플로우를 못 띄운 종료 상태 워크플로우"와
  "자식 종료 요청을 못 보낸 종료 상태 부모"는 프로세스가 비정상 종료한 경우가 아니어도 메워진다. 원인 태스크 없는
  `TERMINATED` 종료도 실패 워크플로우 시작이 같은 Commit의 outbox에 들어가므로 재시작 검사에 기대지 않는다.
- **멱등.** 항목은 한 번 이상 실행된다. 각 Effect가 두 번 실행돼도 결과가 같아야 한다: 자식 종료는 이미 끝난 자식에
  `:ok`, 부모 알림은 저장소의 자식 상태를 반영할 뿐이고, 실패 워크플로우 시작은 저장된 ID의 `:conflict`를 성공으로
  본다(3e 구현). `child_revived`와 `retry`가 이미 실행 중인 대상에 무해한지는 조각 4d가 시험으로 확인하고, 아니면 그
  처리를 멱등하게 고친다.
- 활성화 복구 검사의 "부모가 종료 상태이고 자기 부모 태스크가 `CANCELED`이면 스스로 종료"는 남긴다. 부모 outbox가
  지워진 뒤 시작 실패로 지워진 부모(`parentWorkflowId` 기록 없음)도 이 검사가 다룬다.

### 5. 동시 실행 한도는 Commit 안에서 원자적으로 검사한다 (L10)

- `Step`이 poll로 태스크를 `IN_PROGRESS`로 바꾸는 Commit에 그 태스크 정의의 한도를 `Commit.limits`에 넣는다(한도는
  `concurrentExecLimit`가 0보다 큰 정의만).
- 저장소는 Commit을 적용한 뒤, 이름마다 `IN_PROGRESS` 태스크 수가 한도를 넘으면 트랜잭션을 되돌리고
  `{:error, {:limit, name}}`을 돌려준다. Postgres 구현은 개수를 세기 전에 `pg_advisory_xact_lock`(정의 이름의 해시)을
  잡아 같은 정의의 Commit을 직렬화한다. 메모리 구현은 GenServer 하나라 그대로 원자적이다.
- `WorkflowServer`는 이 오류를 받으면 `Env.in_progress[name]`를 한도로 두고 같은 이벤트로 `Step.run`을 한 번 더 부른다.
  `Step`은 한도 초과 규칙(ADR 0018 결정 7)대로 그 메시지를 60초 미룬다. 이 재실행도 결정 4의 반복 상한에 든다.
- upstream `exceedsLimit`의 도착 순서 공정성 검사는 여전히 옮기지 않는다(ADR 0018 "upstream과 의도적으로 다른 점").

### 6. 지연 활성화와 `Archon.Runtime.Waker`

- **재평가 시각 저장.** `WorkflowServer`는 Commit을 만들 때 Effect의 타이머 요청을 `Commit.wake`로 옮긴다:
  `{:wake_at, ms}` → `{:at, ms}`, `{:wake_before, ms}` → `{:before, ms}`(저장된 값보다 이를 때만 바꾼다),
  `:cancel_wake` → `:none`. 타이머 Effect는 프로세스 타이머에도 그대로 적용한다. 저장소는 `workflow.wake_at`을 바꾼다.
  상태를 바꾸지 않는 이벤트도 타이머를 당기면 `wake`만 담은 Commit을 쓴다.
- **`Recovery`.** 시작 때 `running_workflow_ids/0` 전체 대신 `due_workflow_ids(now + 활성화 여유, 배치)`와
  `outbox_workflow_ids(배치)`를 배치로 활성화한다. `wake_at`이 없는 `RUNNING` 워크플로우(이 결정 전에 저장된 것)는
  기한이 된 것으로 본다. `PAUSED` 워크플로우는 띄우지 않는다. 재개 요청이 오면 메시지가 활성화한다.
- **`Archon.Runtime.Waker`.** 주기(설정값, 기본 1초)마다 `due_workflow_ids(now + 활성화 여유, 배치)`와
  `outbox_workflow_ids(배치)`를 읽어 `Registry`에 없는 워크플로우를 활성화한다. 활성화 여유(기본 5초)는 Waker 주기보다
  길게 둬서 타이머가 늦지 않게 한다. 활성화된 프로세스는 ADR 0018 결정 7대로 복구 검사를 하고 자기 타이머를 건다.
- **유휴 프로세스 종료.** 실행 중 워크플로우 프로세스가 메시지 없이 `evict_after`(설정값, 기본 60초)를 보냈고 다음
  `wake_at`이 그보다 멀면 hibernate 대신 `:normal`로 끝난다. 다음 사건(poll, 갱신, 자식 알림)은 활성화로, 기한은
  Waker로 다시 띄운다. 메모리 백엔드에서는 `evict_after`를 끄고 지금처럼 hibernate한다(설정 기본값이 백엔드별로 다르다).
- `running_workflow_ids/0`은 관리·시험용으로 남긴다.

### 7. 노드는 하나이고 시작 때 DB 락으로 지킨다

- Phase 4도 ADR 0018 결정 1처럼 단일 노드다. 같은 DB에 두 번째 노드가 붙으면 쓰기 주체 규칙(워크플로우마다 프로세스
  하나)이 깨지므로 막는다.
- `Archon.Runtime.Postgres.NodeLock`은 풀 밖의 전용 Postgrex 연결로 `pg_try_advisory_lock`(고정 키)을 잡는다. 못 잡으면
  시작에 실패하고(`{:stop, :another_node_holds_the_database}`), 연결이 끊기면 프로세스가 죽는다. `rest_for_one`이라 그
  뒤의 런타임 전체가 다시 뜨며 락을 다시 잡는다. 그 사이 다른 노드가 잡았으면 이 노드는 다시 뜨지 못한다.
- 여러 노드의 소유권(워크플로우별 advisory lock·lease, 분산 레지스트리, 노드 간 라우팅)은 Phase 5 뒤 별도 ADR에서 정한다.

### 8. 프로세스 트리

ADR 0018 결정 1의 트리를 다음처럼 바꾼다. `Archon.Repo`와 `NodeLock`은 Postgres 백엔드일 때만 있다. Postgres 구현의
`Store`·`Queue`·`Metadata`는 프로세스가 없는 모듈이라 자식이 아니다.

```text
Archon.Runtime.Supervisor (rest_for_one)
├── Archon.Repo                              (Postgres일 때)
├── Archon.Runtime.Postgres.NodeLock         (Postgres일 때, 결정 7)
├── Archon.Runtime.{Metadata,Store,Queue}.Memory (메모리일 때)
├── Archon.Runtime.Registry
├── Archon.Runtime.TaskSupervisor            (Task.Supervisor, 결정 4)
├── Archon.Runtime.WorkflowSupervisor
├── Archon.Runtime.Recovery                  (결정 6)
└── Archon.Runtime.Waker                     (결정 6)
```

`TaskSupervisor`가 다시 뜨면 실행 중이던 outbox Task는 사라지지만 항목은 남아 있어 Waker가 다시 실행한다.

### 9. 시험 전략

- **계약 시험을 양쪽에.** `test/support/runtime/{store,queue,metadata}_contract.ex`를 메모리와 Postgres 구현이 함께
  통과한다. 새 Commit 필드와 콜백(결정 3·5·6)의 사례를 먼저 계약에 더하고(조각 4b), Postgres 구현은 그 계약으로 판정한다.
  Postgres 고유 사례(동시 pop이 같은 메시지를 두 번 내주지 않음, 동시 Commit의 한도 직렬화, 실패한 Commit이 큐·outbox까지
  되돌림, `\u0000` 왕복)는 Postgres 시험 파일에 둔다.
- **런타임 시험을 Postgres로 한 번 더.** 환경 변수 `ARCHON_BACKEND=postgres`면 `config/test.exs`가 Postgres 구현을
  고른다. 런타임 시험(`test/archon/runtime/*_test.exs`, 골든 재현 포함)은 두 백엔드에서 같은 결과여야 한다. 고정 ID를
  쓰는 시험은 고유 ID로 바꾼다(L11).
- **내구성 시험.** `Archon.Runtime.Supervisor`를 멈췄다 다시 띄워(VM 재시작 흉내) 실행 중·대기 중·outbox가 남은
  워크플로우가 이어지는지 본다. Commit과 outbox 실행 사이, outbox 실행과 ack 사이에서 죽는 경우는 기존 시험 훅
  (`Archon.RuntimeHooks`)으로 만든다.
- **CI.** `test` 작업에 Postgres 서비스 컨테이너(공식 `postgres` 이미지, 버전 고정)를 붙이고, `mix test`(메모리)와
  `ARCHON_BACKEND=postgres mix test`(Postgres)를 차례로 돈다. 필수 체크 이름(`test`)은 그대로라 ruleset을 바꾸지 않는다.
  로컬은 Docker의 같은 이미지로 돈다. Postgres 시험 파일은 `@moduletag :postgres`이고, DB가 없으면 `test_helper.exs`가
  이 태그를 빼고 이유를 출력한다.

### 10. 3e·3f 한계의 처리

| 번호 | 처리 | 근거 |
|---|---|---|
| L1 | 해결: 결정 4(`:revive_parent`를 outbox + `call`) | 부모가 처리한 뒤에만 항목을 지운다 |
| L2 | 해결: `Workflow`에 내부 필드 `revivedTime`(`wire: false`)을 더한다. 종료 상태에서 재시도·재시작으로 다시 실행될 때만 찍고, 일시정지·재개는 바꾸지 않는다. `Step.Lifecycle.revived_after?/2`는 `previous_status` 대신 이 값과 부모 `endTime`을 비교한다. 같은 밀리초의 순서 문제는 결정 4가 부모 재개를 보장하므로 복구 검사가 추측하지 않아도 된다 | 지속 표지 |
| L3 | 수용 | 결과 상태에 차이가 없는 오류 경로다. Phase 5 REST가 오류 코드를 맞출 때 upstream 문구와 함께 다시 본다 |
| L4 | 수용 | 결과 상태가 같고 반영이 더 이르다(ADR 0018 "하위 워크플로우 완료 알림" 차이와 같은 성질) |
| L5 | 해결: `WorkflowServer`가 `env/2` 실패를 `{:env, reason}`으로 감싸 예외 격리로 보내고, 하위 워크플로우 시작은 이 오류를 일시적 오류로 분류해 태스크를 `SCHEDULED`로 둔다. 저장소 구현은 DB 장애에서 raise해도 된다 | DB 장애는 일시적이다 |
| L6 | 해결: 결정 4·8(`TaskSupervisor`) | |
| L7 | Phase 5로 넘김: 인증·인가 ADR에서 L8과 함께 본다. outbox Task 안에서 기다리므로 워크플로우 프로세스는 막히지 않는다 | 신뢰 결정 범위 |
| L8 | Phase 5로 넘김: 태스크 갱신이 외부에 열리기 전 인증·인가 ADR | BOSS 2026-10-30 결정 |
| L9 | 해결: 인코딩 결정 2, 큐 원자성 결정 3, 지연 활성화 결정 6, 노드 결정 7, 종료 상태의 남은 일 결정 4 | |
| L10 | 해결: 결정 5 | |
| L11 | 해결: 조각 4f에서 고유 ID로 바꾸고 주석을 고친다 | Postgres 시험이 DB를 공유하므로 필요하다 |

### 11. 구현 조각

| 조각 | 범위 | 시험·정답 기준 | 선행 | 건드리는 파일·모듈 |
|---|---|---|---|---|
| 4a | 결정 1·2: 의존성, `Archon.Repo`, 마이그레이션(결정 2의 표 전부), 저장 인코딩(`to_storage/1`·`from_storage/1`, `Codec`의 `internal: true`), `Archon.Release.migrate/0`, CI Postgres 서비스와 `:postgres` 태그 처리 | 골든 픽스처와 내부 필드가 찬 struct의 저장 인코딩 왕복, `\u0000` 왕복, 마이그레이션 적용·되돌리기 | 없음 | `mix.exs`, `mix.lock`, `lib/archon/repo.ex`, `lib/archon/release.ex`, `priv/repo/migrations/*`, `lib/archon/domain/{codec,workflow,task,workflow_def,task_def}.ex`, `config/{config,test,runtime}.exs`, `.github/workflows/ci.yml`, `test/test_helper.exs`, `test/archon/domain/storage_codec_test.exs` |
| 4b | 결정 3·5·6의 behaviour: `Commit`의 새 필드, `Store`의 새 콜백과 `{:limit, name}` 오류, 메모리 구현(`Store.Memory`가 `Queue.Memory`에 큐 연산 적용), 계약 시험 사례 | 계약 시험(메모리) | 없음 | `lib/archon/runtime/{commit,store}.ex`, `lib/archon/runtime/store/memory.ex`, `lib/archon/runtime/queue/memory.ex`, `test/support/runtime/store_contract.ex`, `test/archon/runtime/store_test.exs` |
| 4c | 결정 2·3의 `Queue.Postgres`·`Metadata.Postgres`(Commit 트랜잭션에서 부를 큐 쓰기 함수 포함) | 큐·메타데이터 계약 시험(Postgres), 동시 pop | 4a | `lib/archon/runtime/queue/postgres.ex`, `lib/archon/runtime/metadata/postgres.ex`, `test/archon/runtime/{queue,metadata}_postgres_test.exs` |
| 4d | 결정 3·4·5와 L2·L5의 런타임: `WorkflowServer`가 큐·outbox·wake·한도를 Commit으로 옮김, outbox 실행과 다시 실행, `TaskSupervisor`와 조상 취소 이전, `call`로 바꾼 부모 알림, 한도 오류 재실행, `env` 실패 분류, `revivedTime`과 `revived_after?/2`, 백엔드 혼합 거절(메모리 백엔드로) | 기존 런타임 시험 전부, outbox 크래시 시험(Commit 뒤·ack 전), L1·L2·L5·L6 재현 시험, 동시 poll 한도 시험 | 4b | `lib/archon/runtime/{workflow_server,effects,sub_workflows,supervisor,lifecycle}.ex`, `lib/archon/runtime/step/*.ex`, `lib/archon/domain/workflow.ex`(`revivedTime` 필드만), `test/archon/runtime/{workflow_server,sub_workflow,lifecycle,recovery,tasks}_test.exs`, `test/archon/runtime/outbox_test.exs` |
| 4e | 결정 3·5의 `Store.Postgres`: 여덟 필드를 한 트랜잭션으로, 한도 advisory lock, 일관된 읽기, outbox·due 콜백 | 저장소 계약 시험(Postgres), 실패 Commit의 전체 되돌림, 동시 Commit 한도 | 4a, 4b, 4c | `lib/archon/runtime/store/postgres.ex`, `test/archon/runtime/store_postgres_test.exs` |
| 4f | 결정 6: `Commit.wake` 기록, `Recovery` 선택 활성화, `Archon.Runtime.Waker`, 유휴 프로세스 종료(메모리 백엔드로) | 지연 활성화 시험(시계 주입), 기존 `recovery_test.exs` | 4d | `lib/archon/runtime/{workflow_server,recovery,waker,supervisor}.ex`, `config/config.exs`, `test/archon/runtime/{recovery,waker}_test.exs` |
| 4g | 결정 7·9의 통합: `NodeLock`, Postgres 백엔드 트리 연결, `ARCHON_BACKEND=postgres` 런타임 시험과 CI 단계, 내구성 시험, L11 | 런타임 시험 전부를 두 백엔드에서, 두 번째 노드 거절, Supervisor 재시작 내구성 시험 | 4e, 4f | `lib/archon/runtime/postgres/node_lock.ex`, `lib/archon/runtime/supervisor.ex`, `lib/archon/runtime/effects.ex`(주석), `config/test.exs`, `.github/workflows/ci.yml`, `test/archon/runtime/{durability,node_lock}_test.exs`, 고정 ID를 쓰는 런타임 시험 |

- **병렬로 진행할 수 있는 묶음.**
  - 4a와 4b: 파일이 겹치지 않는다. 동시에 시작한다.
  - 4c와 4d: 4c는 4a, 4d는 4b가 끝나면 시작하고 서로 파일이 겹치지 않는다. 4c는 `Queue`·`Metadata` behaviour를 바꾸지 않는다.
  - 4e와 4f: 4e는 Postgres 저장소 모듈만, 4f는 런타임 프로세스 파일만 고친다. 4d 뒤에 4f, 4a·4b·4c 뒤에 4e를 시작하면
    동시에 진행할 수 있다.
  - 4g는 마지막이다.
- 4d와 4f는 모두 `workflow_server.ex`·`supervisor.ex`를 고치므로 순서대로 한다. 4g의 `supervisor.ex` 변경은 Postgres
  자식 연결뿐이다.
- 각 조각은 이 ADR의 결정 번호와 조각 이름을 PR에 적는다. 조각 중에 결정이 바뀌면 이 ADR의 해당 결정과 날짜 줄에 갱신
  사실을 적는다(ADR 0018과 같은 방식).

## upstream과 의도적으로 다른 점

- **큐 연산이 저장과 같은 트랜잭션이다.** upstream은 DAO 호출마다 트랜잭션이 따로라 `createTasks` 뒤 `addTaskToQueue`
  실패를 스위퍼에 맡긴다.
- **다른 워크플로우에 하는 일은 outbox로 최소 한 번 실행한다.** upstream은 그 사이에 서버가 죽으면 스위퍼·다음 decide가
  메우거나 놓친다(`updateAndPushParents`).
- **큐 순서는 우선순위가 먼저다.** upstream Postgres 큐(`deliver_on`이 먼저)가 아니라 기본 서버 `SqliteQueueDAO`의 pop
  순서이며, ADR 0018 결정 3과 계약 시험이 이미 고정했다.
- **unack 재노출은 pop 질의가 한다.** `popped`이고 `unack_on`이 지난 행도 보이는 것으로 본다. upstream의 주기 작업
  `processAllUnacks`는 두지 않는다.
- **시각은 애플리케이션 시계의 epoch ms다.** upstream은 DB `current_timestamp`로 `deliver_on`을 계산한다.
- **보조 표와 색인 표가 없다**(결정 2). LISTEN/NOTIFY 큐 리스너도 아직 없다. 빈 pop은 upstream처럼 100ms 간격으로 다시 묻는다.
- **동시 실행 한도를 원자적으로 지킨다**(결정 5). upstream `exceedsLimit`은 개수 질의와 poll 저장이 원자적이지 않다.
- **여러 노드를 막는다**(결정 7). upstream Postgres 배포는 `locks` 표의 lease 락으로 여러 노드를 허용한다.

## 대안

- **Postgrex만 쓰기:** 의존성은 하나 줄지만 마이그레이션 실행기, 트랜잭션 도우미, 풀 설정을 직접 써야 한다. Ecto SQL은
  그 셋을 주고, 스키마 모듈을 쓰지 않으면 도메인 struct와 겹치지도 않는다. BOSS가 Ecto SQL을 골랐다.
- **`jsonb`나 `:erlang.term_to_binary` 저장:** 결정 2.
- **큐만 같은 트랜잭션에 넣고 나머지는 항목별 표지:** outbox보다 작지만 재개 대기, 자식 종료, 실패 워크플로우 시작마다
  다른 복구 경로가 생긴다. outbox는 한 규칙으로 메운다.
- **Phase 3처럼 분리 유지:** upstream과 같은 성질이지만 L1·L9가 남는다.
- **큐에 Oban 같은 작업 큐 라이브러리:** 워커 poll API(`QueueDAO` 의미, 우선순위·postpone·unack)와 맞지 않고 큐가 저장
  트랜잭션 밖 라이브러리 스키마에 놓인다.
- **Phase 4에서 여러 노드:** 워크플로우별 소유권 lease와 노드 간 메시지 라우팅이 필요해 조각이 두세 개 늘고, 단일 노드
  정합성이 먼저 서야 시험할 수 있다. BOSS가 뒤로 미뤘다.
- **시작 때 전체 활성화를 배치로만:** 구현은 작지만 대기 워크플로우가 많으면 메모리와 시작 시간이 그만큼 든다. BOSS가
  지연 활성화를 이번에 넣기로 했다.
- **Ecto Sandbox:** 결정 1.

## 결과

- 이 ADR은 결정만 담는다. 구현은 결정 11의 조각 4a~4g로 하며, 마지막 조각이 머지되면 `승인`으로 바꾼다. 그때 ADR 0018의
  목록 상태에 "일부 0021이 보완"을 적는다(결정 1의 프로세스 트리·노드, 결정 2의 큐 push 실패 처리, 결정 3의 behaviour 연산,
  결정 7의 `Recovery`).
- 기본 백엔드는 개발·시험이 메모리, 배포 설정이 Postgres다. Phase 5 REST는 백엔드와 무관하게 ADR 0018 결정 7의 API만 부른다.
- 아직 범위 밖: 여러 노드(결정 7), 검색 색인, 실행 로그·이벤트 표, 외부 payload 저장소, LISTEN/NOTIFY 큐 리스너, 다른 영속성
  백엔드(ADR 0003 결정 5), L3·L4(수용), L7·L8(Phase 5 인증·인가 ADR).
