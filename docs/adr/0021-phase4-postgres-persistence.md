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
| `java/com/netflix/conductor/postgres/dao/PostgresQueueDAO.java` | `pop`: `ORDER BY deliver_on, priority DESC, created_on ... FOR UPDATE SKIP LOCKED`로 고른 행을 `popped = true`로 바꾼다. 긴 poll은 100ms 간격으로 다시 묻는다. unack 재노출은 주기 작업 `processAllUnacks`(`deliver_on`부터 60초 지난 `popped` 행을 되돌림) |
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
- **인스턴스.** Postgres 구현의 콜백도 메모리 구현처럼 첫 인자로 인스턴스를 받는 형태가 있다(인자 없는 형태가 behaviour
  콜백). Postgres 인스턴스는 `%Archon.Runtime.Postgres{repo, prefix, clock}`이다. `prefix`는 Postgres 스키마 이름이고
  (런타임은 `public`), `clock`은 큐의 보일 시각 계산에 쓰는 시계다. 런타임 인스턴스의 `clock`은 `Archon.Runtime.now/0`
  (시험에서는 주입한 시계)이라 `Env.now`로 계산한 보일 시각과 pop의 비교가 같은 시계를 쓴다. 개발·시험의 마이그레이션은
  런타임 스키마와 계약 시험 스키마(`archon_contract`, 먼저 `CREATE SCHEMA IF NOT EXISTS`)에 모두 적용하고, `Archon.Release.migrate/0`는 런타임 스키마에만 적용한다.
- 시험은 `Ecto.Adapters.SQL.Sandbox`를 쓰지 않는다. 런타임 시험은 여러 프로세스(워크플로우 프로세스, 감독되는 Task)가
  같은 데이터를 쓰므로 Sandbox 소유권을 넘기기 번거롭다(결정 9).

### 2. 저장 형식: 색인 열과 JSON 텍스트

upstream처럼 행마다 색인 열과 `json_data text`를 둔다. 시각은 애플리케이션 시계의 epoch ms `bigint`다(Queue
behaviour moduledoc: 계약 시험이 시계를 주입하므로 DB `now()`를 쓰지 않는다).

| 표 | 열 | 색인·제약 |
|---|---|---|
| `workflow` | `workflow_id text` PK, `status text`, `parent_workflow_id text`, `wake_at bigint`(결정 6), `json_data text` | `status = 'RUNNING'`인 행의 `(COALESCE(wake_at, 0), workflow_id)` 부분 식 색인 |
| `task` | `task_id text` PK, `workflow_id text`(FK → `workflow`, `ON DELETE CASCADE`), `seq integer`, `status text`, `task_def_name text`, `json_data text` | `(workflow_id, seq)`, `status = 'IN_PROGRESS'`인 행의 `task_def_name` 부분 색인 |
| `outbox` | `id bigserial` PK, `workflow_id text`(FK → `workflow`, `ON DELETE CASCADE`), `effect text`, `inserted_at bigint` | `(workflow_id, id)` |
| `queue_message` | `queue_name text`, `message_id text`(둘이 PK), `priority integer`, `deliver_on bigint`, `popped boolean`, `unack_on bigint`, `seq bigserial` | `(queue_name, priority DESC, deliver_on, seq)` |
| `node_lease` | `id integer` PK(항상 1), `epoch bigint` | 결정 7 |
| `poll_data` | `queue_name text`, `domain_key text`(둘이 PK, `nil`은 `"DEFAULT"`), `domain text`, `worker_id text`, `last_poll_time bigint` | |
| `meta_task_def` | `name text` PK, `json_data text` | |
| `meta_workflow_def` | `name text`, `version integer`(둘이 PK), `json_data text` | |

- **저장 인코딩.** ADR 0014 결정 3이 미뤄 둔 "내부 필드를 포함하는 인코딩"을 `to_storage/1`·`from_storage/1`로
  정한다. `Workflow`, `Task`, `WorkflowDef`, `TaskDef`에 두고, `Archon.Domain.Codec`의 `encode/3`·`decode/4`에 옵션 인자
  (`internal: true`)를 더해 `wire: false` 필드까지 읽고 쓴다. 기존 `to_json/1`·`from_json/2`(REST)는 그대로다. 워크플로우
  행의 `json_data`는 `tasks`를 뺀 워크플로우다. 태스크는 `task` 표에서 `seq` 순으로 읽어 붙인다.
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

ADR 0018 결정 2의 `Commit` 필드 네 개에 다음 다섯을 더한다. 저장소는 아홉 필드를 한 트랜잭션으로 적용한다.
`commit/2`의 성공 반환은 지금처럼 `:ok`다.

| 필드 | 형태 | 의미 |
|---|---|---|
| `queue` | `[{:push, queue, id, priority, deliver_on} \| {:remove, queue, id} \| {:postpone, queue, id, priority, deliver_on}]` | 워커 큐 연산. 의미는 `Queue`의 같은 이름 콜백이고, 지연 대신 보일 시각(epoch ms)을 담는다 |
| `outbox` | `[Step.Effect.t()]` | 결정 4의 다른 워크플로우에 하는 일 |
| `outbox_ack` | `[id]` | 같은 트랜잭션에서 지울 outbox 항목(결정 4의 실패 워크플로우 시작 되먹임). 기본 `[]` |
| `wake` | `:keep \| {:at, ms} \| {:before, ms} \| :none` | 결정 6. 기본 `:keep` |
| `limits` | `%{task_def_name => limit}` | 결정 5. 기본 `%{}` |

- **큐는 저장과 같은 트랜잭션이다.** `WorkflowServer`는 `Step.run`이 낸 post Effect 가운데 `:queue_push`·`:queue_remove`·
  `:queue_postpone`을 빼서 `Commit.queue`에 넣고, 지연은 그 이벤트의 `Env.now`를 더해 보일 시각으로 바꾼다. `Step`은
  지금처럼 Effect로 내고, 옮기는 일은 프로세스가 한다. 그래서 "저장은 됐는데 큐 push는 안 된" 상태가 없다. 큐 push 실패를
  기록만 하고 넘기던 규칙(ADR 0018 결정 2의 3c 갱신)은 "Commit 실패이므로 예외 격리"로 바뀐다. 복구 검사의 "큐에 없는
  `SCHEDULED` 태스크 다시 넣기"는 그대로 둔다. 관리 작업 등으로 메시지가 빠진 경우를 메운다.
- **시작 실패 정리.** 최상위 `{:start}` 실패 때 `WorkflowServer`가 지우던 큐 메시지(ADR 0018 결정 1, 지금은 push Effect
  기록으로 찾음)는 지운 워크플로우의 Commit들이 넣은 `Commit.queue`의 push에서 찾는다.
- **저장소와 큐는 같은 백엔드여야 한다.** `Store.Postgres`는 `Queue.Postgres`의 쓰기 함수를 같은 트랜잭션 연결로
  부르고, `Store.Memory`는 다른 필드를 모두 검사·적용한 뒤 마지막에 `Queue.Memory`에 순서대로 적용한다(메모리 구현은
  원래 내구성이 없고, 큐 연산은 되돌리지 않으므로 거절될 수 있는 검사를 먼저 한다). `Queue.Memory`의 push·postpone은
  지연을 받으므로 `Store.Memory`가 보일 시각에서 같은 시계(`Archon.Runtime.now/0`)의 지금을 빼서 넘긴다. 설정이 둘을 섞으면
  `Archon.Runtime.Supervisor`가 시작을 거절한다.
- **Store behaviour의 새 콜백.**

  | 콜백 | 의미 |
  |---|---|
  | `pending_outbox(workflow_id)` | 그 워크플로우의 남은 항목 `[{id, effect}]`(`id` 순) |
  | `ack_outbox(workflow_id, [id])` | 실행을 마친 outbox 항목을 지운다 |
  | `outbox_workflow_ids(after, limit)` | 남은 항목이 있는 워크플로우 ID를 `after` 다음부터 ID 순으로(키셋 페이지) |
  | `due_workflow_ids(before_ms, after, limit)` | `RUNNING`이고 `wake_at`이 `before_ms` 이하이거나 없는 워크플로우를 `(COALESCE(wake_at, 0), workflow_id)` 순으로 `after` 다음부터(키셋 페이지). 결과는 `[{wake_key, workflow_id}]`이고 `after`는 마지막 결과의 그 쌍(첫 페이지는 `nil`). `wake_at`이 없는 행은 `wake_key` 0이다 |

  `commit/2`의 오류에 `{:error, {:limit, task_def_name}}`(결정 5)을 더한다.

### 4. 다른 워크플로우에 하는 일은 outbox에 남기고 워크플로우마다 실행기 하나가 순서대로 실행한다 (L1, L6, L9)

ADR 0018 대안 절이 Phase 4로 넘긴 outbox를 들인다.

- **대상 Effect:** `:terminate_sub_workflow`(post만. 종료 경로의 `pre` 자식 종료는 Commit 전에 끝나야 하므로 그대로다),
  `:notify_parent`, `:revive_parent`, `:retry_sub_workflow`, `:start_failure_workflow`. `WorkflowServer`는 이것들을 post에서
  빼서 `Commit.outbox`에 넣는다. `:start_sub_workflow`는 결과로 태스크를 바꾸는 Commit을 같은 메시지 안에서 하므로
  (ADR 0018 결정 2) 대상이 아니다. 그 복구는 지금처럼 "`SCHEDULED`인데 자식이 없는 SUB_WORKFLOW 재시작"이다.
- **항목 형식.** `effect`는 JSON이다: `kind`와 인자. 워크플로우 struct는 담지 않는다. `:notify_parent`는 자식 ID만
  남기고 실행할 때 저장소에서 다시 읽는다. `:start_failure_workflow`는 `Step.Effect.start` 맵 전체를 담는다(정의가
  박혀 있으면 `WorkflowDef.to_storage/1`).
- **실행기 하나.** 워크플로우 프로세스는 outbox 실행기를 한 번에 하나만 둔다. outbox를 담은 Commit 뒤나 활성화 직후
  (남은 항목이 있을 때) 실행기가 없으면 `Archon.Runtime.TaskSupervisor`(`Task.Supervisor`)에서
  `async_nolink`로 하나 띄운다. **프로세스가 재시작해도 하나다.** 실행기는 시작할 때 `Archon.Runtime.Registry`에
  `{:outbox, workflow_id}` 키로 자신을 등록하고, 이미 등록돼 있으면(이전 프로세스의 실행기가 아직 도는 중) 항목을 실행하지
  않고 `{:already_registered, pid}`를 돌려준다. 소유 프로세스는 그 pid를 감시하다가(이미 죽었으면 바로 `:DOWN`이 온다.
  Registry는 죽은 pid의 등록을 비동기로 지운다) 실행기를 다시 띄우고, 같은 답이 이어지면 아래 재시도 지연을 따른다.
  `SubWorkflows`는 실행기 안에서 자기 ID를 `Registry.keys/2`로 찾지 않는다(그 키는 `{:outbox, id}`다). 4e는 `own_ids/0`을
  없애고 소유 ID를 인자로 받는다. 이전 실행기는 소유 프로세스를 감시해
  소유자가 없어지면 다음 항목으로 넘어가지 않고 끝난다(진행 중인 항목 하나는 끝까지 실행할 수 있고, 그 항목은 멱등이다).
  실행기는 `pending_outbox/1`을 `id` 순으로 읽어 하나씩 실행하고, 끝난 항목마다
  `ack_outbox/2`를 부른다. 재시도할 실패를 만나면 그 자리에서 멈춘다(뒤 항목을 먼저 실행하지 않는다). 실행기가 끝나면
  프로세스가 결과를 받아, 그 사이 새 항목이 생겼으면 다시 띄우고, 재시도할 실패로 멈췄으면 지연(1초에서 두 배씩,
  `workflowOffsetTimeout` 30초 상한) 뒤 다시 띄운다. 그래서 살아 있는 프로세스도 실패한 항목을 다시 시도하고, 서로
  다른 Commit의 항목이 순서를 바꿔 실행되지 않는다.
- **실행기는 소유 워크플로우 ID를 인자로 넘긴다.** `SubWorkflows`의 자기·조상 검사(`terminate_child/2`의 조상 취소,
  `retry_child/1`의 자기·조상 건너뛰기)는 지금 `Registry.keys(@registry, self())`로 자기 ID를 찾는다. 실행기 Task에서는
  찾을 수 없으므로 소유 워크플로우 ID를 명시 인자로 받게 바꾼다.
- **부모 알림은 `call`이다.** 실행기는 워크플로우 프로세스 밖에서 기다리므로 상대 프로세스를 `call`해도 교착이 없다.
  그래서 자식 → 부모의 `:revive_parent`·`:notify_parent`는 cast 대신 `call`(`child_revived`, `child_changed`)로 보내고,
  부모가 처리한 뒤에 지운다. 0 timeout으로 끝나는 부모의 죽은 pid에 닿으면 `:noproc`이고, ADR 0018 결정 1의 규칙대로 다시
  활성화한다(L1). 워크플로우 프로세스끼리의 동기 호출 방향 규칙(부모 → 자식만 `call`)은 프로세스 자신이 하는 호출에만
  적용된다.
- **결과 분류.** 실행 결과마다 끝냄(ack)과 재시도를 다음처럼 나눈다.

  | 결과 | 처리 |
  |---|---|
  | `:ok`, 상대 워크플로우가 없음(`{:error, :not_found}`) | ack |
  | 허용 목록의 업무 오류: `{:error, :conflict}`, `{:error, {kind, message}}`에서 `kind`가 `:conflict`·`:not_found`·`:invalid_state`(ADR 0018 결정 9, upstream Conflict·NotFound·IllegalState). 예: 이미 실행 중인 자식의 재시도 | 기록하고 ack |
  | 그 밖의 모든 것: 호출 timeout, exit, 예외, 예외 격리의 응답(`{:error, {:commit \| :pre_effect \| :post_effect \| :env, _}}`), 저장소 오류 | 재시도 |

  모양이 아니라 허용 목록으로 가른다. 예외 격리의 응답도 `{:error, {kind, _}}` 모양이라, 모양으로 가르면 DB 장애로 실패한
  부모 재개를 업무 오류로 보고 지우게 된다. `:start_failure_workflow`의 업무 오류는 시작 오류 태그 `:not_found`·`:invalid`·
  `:terminate`(3c)이며 아래 되먹임으로 처리한다. 지금 `SubWorkflows.start_failure_workflow/1`은 모든 오류를 문구 하나로
  돌려주므로, 조각 4e가 `start_child/1`처럼 일시적 오류를 `{:error, :transient, message}`로 구분하게 고친다. 일시적 오류는
  재시도한다. 지금 `notify_parent`·`revive_parent`·
  `retry_child`가 실패를 기록하고 항상 `:ok`를 돌려주는 것은 이 분류를 따르는 결과로 바꾼다.
- **실패 워크플로우 시작의 되먹임.** `:start_failure_workflow`가 업무 오류(정의 없음 등)로 끝나면 지금처럼
  `{:failure_workflow_started, {:error, reason}}` 이벤트가 필요하다(ADR 0018 결정 8 (a)). 실행기는 그 항목을 ack하지 않고
  멈춰 결과를 프로세스에 돌려준다. 프로세스는 그 이벤트로 `Step.run`을 하고, 출력을 고치는 Commit의 `outbox_ack`에 그
  항목을 넣어 같은 트랜잭션에서 지운 뒤, 남은 항목이 있으면 실행기를 다시 띄운다. 그래서 출력은 "시작 실패"인데 항목이
  남아 나중에 시작이 성공하는 일이 없다. Commit 전에 죽으면 항목이 남아 다시 실행된다.
- **조상 취소(L6).** `SubWorkflows.terminate_child`의 `cancel_later`(`Elixir.Task.start`)는 같은 `TaskSupervisor`에서 돈다.
  실행기 안(post 자식 종료)에서는 실행기가 그 결과를 기다려 분류하고, 종료 경로의 `pre`(워크플로우 프로세스 안)에서는
  감독되는 Task로 띄우기만 한다. `pre`의 조상 취소가 VM과 함께 사라지면 그 조상이 다시 활성화될 때의 복구 검사만 메운다.
  남은 outbox도 요청도 없는 종료 상태 워크플로우는 활성화되지 않으므로 메워지지 않을 수 있다. Phase 3와 같은 성질이고,
  조상을 자식으로 가리키는 것은 worker가 준 ID뿐이므로(L7·L8) Phase 5 인증·인가 ADR에서 함께 본다.
- **다시 실행할 곳.** 프로세스가 없을 때 남은 항목은 (1) 그 워크플로우가 활성화될 때, (2) `Recovery`와 결정 6의
  `Archon.Runtime.Waker`가 `outbox_workflow_ids/2`로 찾은 워크플로우를 활성화할 때 실행된다. **프로세스는 outbox가 빌 때까지
  끝나지 않는다**(종료 상태에서 0 timeout으로 끝나는 규칙과 유휴 종료의 조건에 "남은 항목 없음"을 더한다). 그래서
  Waker가 방금 끝난 워크플로우를 다시 띄워 같은 항목을 겹쳐 실행하지 않는다. L9의 "실패 워크플로우를 못 띄운 종료 상태
  워크플로우"와 "자식 종료 요청을 못 보낸 종료 상태 부모"는 프로세스가 비정상 종료한 경우가 아니어도 메워진다. 원인
  태스크 없는 `TERMINATED` 종료도 실패 워크플로우 시작이 같은 Commit의 outbox에 들어가므로 재시작 검사에 기대지 않는다.
- **복구 검사와 겹치지 않게.** `Env`에 `outbox_pending?`(남은 항목이 있는지)를 더한다. 남은 항목이 있으면 `Step.Recover`의
  종료 상태 검사 둘(`CANCELED` SUB_WORKFLOW의 자식 종료 다시 보내기, 실패 워크플로우 재시작)은 Effect를 내지 않는다.
  outbox가 같은 일을 하고 있기 때문이다. 항목이 없을 때는 이 결정 전에 저장된 워크플로우를 위해 남겨 둔다. 자식의 활성화
  복구 검사 "부모가 종료 상태이고 자기 부모 태스크가 `CANCELED`이면 스스로 종료"와 "`parentWorkflowId`의 기록이 없으면
  스스로 종료"도 그대로 둔다.
- **빈 Commit 판정.** `WorkflowServer`는 지금 Phase 3의 네 필드가 비면 Commit을 건너뛴다. 새 필드(`queue`, `outbox`,
  `outbox_ack`, `limits`, `wake`가 `:keep`이 아님)만 있어도 빈 Commit이 아니다. 앞의 넷은 조각 4d·4e, `wake`는 4g가 이 판정에
  더한다. 그러지 않으면 출력이 이미 오류인 되먹임 재실행의 `outbox_ack`만 담은 Commit이 건너뛰어져 항목이 지워지지 않는다.
- **멱등.** 항목은 한 번 이상 실행된다. 각 Effect가 두 번 실행돼도 결과가 같아야 한다: 자식 종료는 이미 끝난 자식에
  `:ok`, 부모 알림은 저장소의 자식 상태를 반영할 뿐이고, 실패 워크플로우 시작은 저장된 ID의 `:conflict`를 성공으로
  본다(3e 구현). `child_revived`와 `retry`가 이미 실행 중인 대상에 무해한지는 조각 4e가 시험으로 확인하고, 아니면 그
  처리를 멱등하게 고친다.

### 5. 동시 실행 한도는 Commit 안에서 원자적으로 검사한다 (L10)

- `Step`이 태스크를 `IN_PROGRESS`로 바꾸는 Commit(워커 poll, 비동기 시스템 태스크 시작)에 그 태스크 정의의 한도를
  `Commit.limits`에 넣는다(한도는 `concurrentExecLimit`가 0보다 큰 정의만).
- 저장소는 Commit을 적용한 뒤, 이름마다 `IN_PROGRESS` 태스크 수가 한도를 넘으면 트랜잭션을 되돌리고
  `{:error, {:limit, name}}`을 돌려준다. Postgres 구현은 개수를 세기 전에 이름 순으로 `pg_advisory_xact_lock`(정의 이름의
  해시)을 잡아 같은 정의의 Commit을 직렬화한다. 메모리 구현은 GenServer 하나라 그대로 원자적이다.
- `WorkflowServer`는 이 오류를 받으면 `Env.in_progress[name]`를 한도로 두고 같은 이벤트로 `Step.run`을 한 번 더 부른다.
  `Step`은 한도 초과 규칙(ADR 0018 결정 7과 "upstream과 의도적으로 다른 점")대로 워커 태스크는 60초 미루고, 비동기
  시스템 태스크는 다음 `:wake`에 다시 본다. 이 재실행도 ADR 0018 결정 4의 반복 상한에 든다.
- upstream `exceedsLimit`의 도착 순서 공정성 검사는 여전히 옮기지 않는다.

### 6. 지연 활성화와 `Archon.Runtime.Waker`

- **재평가 시각 저장.** `WorkflowServer`는 Commit을 만들 때 Effect의 타이머 요청을 `Commit.wake`로 옮긴다:
  `{:wake_at, ms}` → `{:at, ms}`, `{:wake_before, ms}` → `{:before, ms}`, `:cancel_wake` → `:none`. 타이머 Effect는 프로세스
  타이머에도 그대로 적용한다. 저장소는 `{:at, ms}`면 `wake_at = ms`, `{:before, ms}`면 `wake_at = LEAST(COALESCE(wake_at, ms), ms)`,
  `:none`이면 `NULL`을 쓴다. `:none`은 일시정지에서만 나오므로 `RUNNING`인데 `NULL`인 행은 이 결정 전에 저장된 것뿐이다.
  상태를 바꾸지 않는 이벤트도 타이머를 당기면 `wake`만 담은 Commit을 쓴다. 반복 상한의 즉시 `:wake`는 저장하지
  않는다(프로세스가 살아 있고 곧 처리한다). 예외 격리의 `:recover` 기한(30초)은 `wake`만 담은 Commit `{:before, 기한}`으로
  저장을 시도한다. 저장소 장애로 실패하면 기록만 하고 넘어가며, 그 경우 노드가 기한 전에 재시작하면 회복이 저장된 `wake_at`까지
  늦어질 수 있다(실패한 요청의 호출자는 오류를 받았으므로 다시 보낼 수 있다).
- **`Recovery`.** 시작 때 `running_workflow_ids/0` 전체 대신 `due_workflow_ids(now + 활성화 여유, ...)`와
  `outbox_workflow_ids/2`를 키셋 페이지로 끝까지 읽어 활성화한다. `PAUSED` 워크플로우는 띄우지 않는다. 재개 요청이 오면
  메시지가 활성화한다.
- **`Archon.Runtime.Waker`.** 주기(설정값, 기본 1초)마다 `due_workflow_ids(now + 활성화 여유, ...)`와
  `outbox_workflow_ids/2`를 키셋 페이지로 읽고, `Registry`에 없는 워크플로우만 활성화한다. 살아 있는 프로세스의 저장된
  `wake_at`이 낡아도 페이지를 넘기므로 뒤의 워크플로우가 굶지 않는다. 활성화 여유(기본 5초)는 Waker 주기보다 길게 둬서
  타이머가 늦지 않게 한다. 활성화된 프로세스는 ADR 0018 결정 7대로 복구 검사를 하고 자기 타이머를 건다.
- **유휴 프로세스 종료.** 실행 중 워크플로우 프로세스가 `hibernate_after` 동안 메시지를 받지 않았고, 다음 `wake_at`이
  지금부터 `evict_after`(설정값, 기본 60초)보다 뒤이고, 남은 outbox가 없으면 hibernate 대신 `:normal`로 끝난다. 다음 사건
  (poll, 갱신, 자식 알림)은 활성화로, 기한은 Waker로 다시 띄운다. 메모리 백엔드에서는 `evict_after`를 끄고 지금처럼
  hibernate한다(설정 기본값이 백엔드별로 다르다).
- **기대 효과.** 재평가 후보가 없으면 `computePostpone`이 30초를 주므로 짧은 태스크만 있는 워크플로우는 대개 살아 있다.
  덜어지는 것은 긴 WAIT, 긴 응답 타임아웃의 워커 태스크, 하위 워크플로우를 기다리는 부모처럼 다음 재평가가 먼 워크플로우와,
  재시작 때 한꺼번에 띄우던 비용이다.
- `running_workflow_ids/0`은 관리·시험용으로 남긴다.

### 7. 노드는 하나이고 시작 때 DB 락으로 지킨다

- Phase 4도 ADR 0018 결정 1처럼 단일 노드다. 같은 DB에 두 번째 노드가 붙으면 쓰기 주체 규칙(워크플로우마다 프로세스
  하나)이 깨지므로 막는다.
- `Archon.Runtime.Postgres.NodeLock`은 풀 밖의 전용 Postgrex 연결(`backoff_type: :stop`, 링크)로 `pg_try_advisory_lock`
  (고정 키)을 잡는다. 못 잡으면 짧은 시간(설정값, 기본 10초) 동안 다시 시도한 뒤 시작에 실패한다
  (`{:stop, :another_node_holds_the_database}`). 같은 노드의 NodeLock이 다시 뜰 때 이전 연결의 락이 서버에서 아직 풀리지
  않았을 수 있기 때문이다. NodeLock은 exit를 가로채(`trap_exit`) 정상 종료(`terminate`)에서 `pg_advisory_unlock`을 부르고 연결을 닫으며, 링크한
  연결의 `{:EXIT, conn, _}`를 받으면 스스로 끝난다. DBConnection은 기본으로
  조용히 다시 연결하고 그러면 세션 락이 풀린 채 남으므로, 다시 연결하지 않게 하고 주기(기본 5초)마다 자기 연결이 락을
  쥐고 있는지 `pg_locks`로 확인한다. 연결이 끊기거나 락이 없으면 프로세스가 죽고, `rest_for_one`이라 그 뒤의 런타임
  전체가 다시 뜨며 락을 다시 잡는다. 그 사이 다른 노드가 잡았으면 이 노드는 다시 뜨지 못한다.
- **쓰기 펜싱.** 락 확인 주기 사이에 이 노드가 락을 잃고 다른 노드가 잡으면 두 노드가 쓸 수 있으므로, 락과 함께 fencing
  token을 둔다. 표 `node_lease`(행 하나, 마이그레이션이 두 스키마에 `(1, 0)`으로 넣는다)를 두고, NodeLock은 락을 잡은 직후
  한 트랜잭션에서 `pg_advisory_xact_lock(펜스 키)`(배타)를 잡고 `UPDATE node_lease SET epoch = epoch + 1 RETURNING epoch`로
  자기 epoch를 받는다. Postgres 구현의 모든 쓰기 트랜잭션(`Store.commit/2`, `remove_workflow/1`,
  `ack_outbox/2`, 큐의 push·pop·ack·remove·postpone, poll 데이터·메타데이터 쓰기)은 첫 문장에서
  `pg_advisory_xact_lock_shared(펜스 키)`(공유)를 잡고 `SELECT epoch FROM node_lease WHERE id = 1`을 읽어 자기 epoch와 다르면
  `{:error, :fenced}`로 되돌린다. 잠금과 epoch 읽기는 반드시 서로 다른 SQL 문이다(READ COMMITTED는 문마다 스냅샷을 잡으므로,
  한 문으로 합치면 잠금을 기다리기 전의 스냅샷으로 예전 epoch를 읽는다). 펜스 키는 NodeLock의 세션 락 키와 다른 고정 키다
  (같으면 NodeLock의 세션 배타 잠금이 모든 공유 잠금을 막는다). 배타 잠금은 진행 중인 공유 잠금이 끝나기를 기다리고, 그 뒤 시작한 이전 노드의 트랜잭션은
  공유 잠금을 얻은 다음 올라간 epoch를 읽으므로, 새 노드가 epoch를 올린 뒤에는 이전 노드의 어떤 쓰기도 커밋되지 않는다.
  행 잠금(`FOR SHARE`) 대신 advisory 잠금을 쓰는 이유는 쓰기마다 한 행에 잠금 기록(MultiXact)을 남기지 않기 위해서다.
  긴 poll은 100ms마다의 pop 시도를 각각 펜싱된 트랜잭션 하나로 하고, 5초 동안 트랜잭션을 잡고 있지 않는다.
  `:fenced`는 예외 격리로 가고, NodeLock의 다음 확인이 런타임을 내린다. 펜싱은 인스턴스 필드(`%Archon.Runtime.Postgres{fence:
  :runtime | nil}`)로 켠다. 런타임 인스턴스(`fence: :runtime`)만 NodeLock이 `:persistent_term`에 둔 epoch로 검사하고, 계약 시험
  인스턴스(`fence: nil`)는 런타임이 함께 돌아도 검사하지 않는다.
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

`TaskSupervisor`가 다시 뜨면 `rest_for_one`으로 워크플로우 프로세스도 다시 뜨고, 남은 outbox 항목은 활성화 때 다시 실행된다.

### 9. 시험 전략

- **계약 시험을 양쪽에.** `test/support/runtime/{store,queue,metadata}_contract.ex`를 메모리와 Postgres 구현이 함께
  통과한다. 새 Commit 필드와 콜백(결정 3·5·6)의 사례를 먼저 계약에 더하고(조각 4b), Postgres 구현은 그 계약으로 판정한다.
  Postgres 계약 시험의 `server`는 결정 1의 인스턴스(`prefix: "archon_contract"`, 주입 시계)이고, 사례마다 그 스키마의 표를
  비운다. 런타임 트리는 `public` 스키마를 쓰므로 Waker·Recovery가 계약 사례의 행을 건드리지 않는다. Postgres 고유
  사례(동시 pop이 같은 메시지를 두 번 내주지 않음, 동시 Commit의 한도 직렬화, 실패한 Commit이 큐·outbox까지 되돌림,
  `\u0000` 왕복)는 Postgres 시험 파일에 둔다.
- **런타임 시험을 Postgres로 한 번 더.** 환경 변수 `ARCHON_BACKEND=postgres`면 `config/test.exs`가 Postgres 구현을
  고른다. 런타임 시험(`test/archon/runtime/*_test.exs`, 골든 재현 포함)은 두 백엔드에서 같은 결과여야 한다. 런타임 시험은
  이미 `async: false`이고 스위트 시작 때 `public` 스키마를 비우며, 고정 ID를 쓰는 시험은 고유 ID로 바꾼다(L11).
- **내구성 시험.** `Archon.Runtime.Supervisor`를 멈췄다 다시 띄워(VM 재시작 흉내) 실행 중·대기 중·outbox가 남은
  워크플로우가 이어지는지 본다. Commit과 outbox 실행 사이, outbox 실행과 ack 사이에서 죽는 경우는 기존 시험 훅
  (`Archon.RuntimeHooks`)으로 만든다.
- **CI.** `test` 작업에 Postgres 서비스 컨테이너(공식 `postgres` 이미지, 버전 고정)를 붙이고, `mix test`(메모리)와
  `ARCHON_BACKEND=postgres mix test`(Postgres)를 차례로 돈다. 필수 체크 이름(`test`)은 그대로라 ruleset을 바꾸지 않는다.
  로컬은 Docker의 같은 이미지로 돈다. Postgres 시험 파일은 `@moduletag :postgres`이고, DB가 없으면 `test_helper.exs`가
  이 태그를 빼고 이유를 출력한다. 단 `ARCHON_REQUIRE_POSTGRES=1`(CI가 설정)이면 DB가 없을 때 시험을 실패시킨다. CI가 Postgres
  시험을 모두 건너뛰고 통과하는 일을 막기 위해서다.

### 10. 3e·3f 한계의 처리

| 번호 | 처리 | 근거 |
|---|---|---|
| L1 | 해결: 결정 4(`:revive_parent`를 outbox + `call`, 살아 있는 프로세스의 재시도) | 부모가 처리한 뒤에만 항목을 지운다 |
| L2 | 해결: `Workflow`에 내부 필드 둘(`wire: false`)을 더한다. `endCount`는 워크플로우가 실행 상태에서 종료 상태로 바뀔 때마다 1씩 오른다(`State.set_status`의 전이에서. 종료 상태를 다시 저장하며 `endTime`을 새로 찍는 일, 예를 들어 실패 워크플로우 되먹임은 올리지 않는다). `revivedParentEndCount`는 종료 상태의 자식이 재시도·재시작으로 다시 실행될 때, 그 처리에서 저장소로 읽은 부모의 `endCount`(부모가 끝나지 않았거나 없으면 0)다. 일시정지·재개는 둘 다 바꾸지 않는다. 이를 위해 `WorkflowServer.env/2`는 `{:retry, _}`·`{:restart, _}`에서도 부모를 `Env.workflows`에 읽는다(조각 4e). `Step.Lifecycle.revived_after?/2`는 `previous_status`와 시각 비교 대신 "`revivedParentEndCount`가 0이 아니고 지금 부모의 `endCount`와 같다"로 판정한다. 자식이 부모의 그 종료를 읽은 뒤에 다시 실행되었다는 인과 관계를 저장하므로 같은 밀리초에도 순서가 갈리고, 뒤의 종료 상태 저장이 `endTime`을 바꿔도 흔들리지 않는다. 부모가 그 뒤 재개되어 다시 끝나면 `endCount`가 올라 일반 규칙으로 돌아간다 | 시각이 아니라 관찰한 종료로 순서를 정한다 |
| L3 | 수용 | 결과 상태에 차이가 없는 오류 경로다. Phase 5 REST가 오류 코드를 맞출 때 upstream 문구와 함께 다시 본다 |
| L4 | 수용 | 결과 상태가 같고 반영이 더 이르다(ADR 0018 "하위 워크플로우 완료 알림" 차이와 같은 성질) |
| L5 | 해결: `WorkflowServer`가 `env/2` 실패를 `{:env, reason}`으로 감싸 예외 격리로 보내고, 하위 워크플로우 시작은 이 오류를 일시적 오류로 분류해 태스크를 `SCHEDULED`로 둔다. 저장소 구현은 DB 장애에서 raise해도 된다 | DB 장애는 일시적이다 |
| L6 | 해결: 결정 4·8(`TaskSupervisor`) | |
| L7 | Phase 5로 넘김: 인증·인가 ADR에서 L8과 함께 본다. 실행기 Task 안에서 기다리므로 워크플로우 프로세스는 막히지 않는다 | 신뢰 결정 범위 |
| L8 | Phase 5로 넘김: 태스크 갱신이 외부에 열리기 전 인증·인가 ADR | BOSS 2026-10-30 결정 |
| L9 | 해결: 인코딩 결정 2, 큐 원자성 결정 3, 지연 활성화 결정 6, 노드 결정 7, 종료 상태의 남은 일 결정 4 | |
| L10 | 해결: 결정 5 | |
| L11 | 해결: 고정 ID는 조각 4h에서 고유 ID로 바꾼다. `effects.ex`의 낡은 주석은 조각 4e가 그 함수를 고치며 없앤다 | Postgres 시험이 DB를 공유하므로 필요하다 |

### 11. 구현 조각

| 조각 | 범위 | 시험·정답 기준 | 선행 | 건드리는 파일·모듈 |
|---|---|---|---|---|
| 4a | 결정 1·2: 의존성, `Archon.Repo`, `Archon.Runtime.Postgres` 인스턴스 구조체와 쓰기 펜싱 도우미(결정 7, `fence: nil`이면 건너뜀), 마이그레이션(결정 2의 표 전부, 두 스키마), 저장 인코딩(`to_storage/1`·`from_storage/1`, `Codec`의 옵션 인자), `Workflow`의 `endCount`·`revivedParentEndCount` 내부 필드 정의(L2, 값은 아직 쓰지 않음), `Archon.Release.migrate/0`, CI Postgres 서비스와 `:postgres` 태그·`ARCHON_REQUIRE_POSTGRES` 처리 | 골든 픽스처와 내부 필드가 찬 struct의 저장 인코딩 왕복, `\u0000` 왕복, 마이그레이션 적용·되돌리기 | 없음 | `mix.exs`, `mix.lock`, `lib/archon/repo.ex`, `lib/archon/release.ex`, `lib/archon/runtime/postgres.ex`, `priv/repo/migrations/*`, `lib/archon/domain/{codec,workflow,task,workflow_def,task_def}.ex`, `config/{config,test,runtime}.exs`, `.github/workflows/ci.yml`, `test/test_helper.exs`, `test/archon/domain/storage_codec_test.exs` |
| 4b | 결정 3·5·6의 behaviour: `Commit`의 새 필드, `Store`의 새 콜백과 `{:limit, name}` 오류, 메모리 구현(`Store.Memory`가 검사 뒤 `Queue.Memory`에 큐 연산 적용), 계약 시험 사례 | 계약 시험(메모리) | 없음 | `lib/archon/runtime/{commit,store}.ex`, `lib/archon/runtime/store/memory.ex`, `lib/archon/runtime/queue/memory.ex`, `test/support/runtime/store_contract.ex`, `test/archon/runtime/store_test.exs`(큐 연산 사례의 `Queue.Memory`는 `Archon.Runtime.now/0`과 같은 시계) |
| 4c | 결정 2·3의 `Queue.Postgres`·`Metadata.Postgres`(Commit 트랜잭션에서 부를 큐 쓰기 함수 포함) | 큐·메타데이터 계약 시험(Postgres), 동시 pop, 쓰기마다 펜싱 도우미 호출 | 4a | `lib/archon/runtime/queue/postgres.ex`, `lib/archon/runtime/metadata/postgres.ex`, `test/archon/runtime/{queue,metadata}_postgres_test.exs` |
| 4d | 결정 3·5와 L5의 런타임: `WorkflowServer`가 큐 Effect를 `Commit.queue`로 옮김(시작 실패 정리 포함), `Step`이 `Commit.limits`를 채움, 한도 오류 재실행, `env` 실패 분류, 백엔드 혼합 거절(메모리 백엔드로) | 기존 런타임 시험 전부, 동시 poll 한도 시험, 큐 push 실패가 Commit 실패가 되는 시험, L5 재현 시험 | 4b | `lib/archon/runtime/{workflow_server,supervisor}.ex`, `lib/archon/runtime/step/{tasks,async,state}.ex`, `lib/archon/runtime/sub_workflows.ex`(시작 오류 분류만), `test/archon/runtime/{workflow_server,tasks,sub_workflow}_test.exs` |
| 4e | 결정 4와 L1·L2·L6: outbox로 옮김, 실행기(하나, Registry 울타리, 순서, 재시도 지연, 결과 분류, 되먹임), outbox가 빌 때까지 끝나지 않기, `TaskSupervisor`와 조상 취소 이전, 소유 ID 명시 인자, `call`로 바꾼 부모 알림, `Env.outbox_pending?`와 복구 검사, `endCount`·`revivedParentEndCount` 찍기와 `revived_after?/2` | 기존 런타임 시험 전부, outbox 크래시 시험(Commit 뒤·ack 전), 실행기 순서·재시도 시험, 실행기가 도는 중 소유 프로세스를 죽였을 때 실행기가 겹치지 않는 시험, L1·L2·L6 재현 시험 | 4a, 4d | `lib/archon/runtime/{workflow_server,effects,sub_workflows,supervisor}.ex`, `lib/archon/runtime/step.ex`, `lib/archon/runtime/step/{effect,env,recover,lifecycle,terminate}.ex`, `test/archon/runtime/{workflow_server,lifecycle,sub_workflow,recovery}_test.exs`, `test/archon/runtime/outbox_test.exs` |
| 4f | 결정 3·5의 `Store.Postgres`: 아홉 필드를 한 트랜잭션으로, 한도 advisory lock, 일관된 읽기, outbox·due 콜백 | 저장소 계약 시험(Postgres), 실패 Commit의 전체 되돌림, 동시 Commit 한도, 쓰기마다 펜싱 도우미 호출 | 4a, 4b, 4c | `lib/archon/runtime/store/postgres.ex`, `test/archon/runtime/store_postgres_test.exs` |
| 4g | 결정 6: `Commit.wake` 기록(예외 격리 기한의 최선 노력 저장 포함), `Recovery` 선택 활성화, `Archon.Runtime.Waker`, 유휴 프로세스 종료(메모리 백엔드로, `evict_after`를 켠 시험) | 지연 활성화 시험(시계 주입), 키셋 페이지, 기존 `recovery_test.exs` | 4e | `lib/archon/runtime/{workflow_server,recovery,waker,supervisor}.ex`, `config/config.exs`, `test/archon/runtime/{recovery,waker}_test.exs` |
| 4h | 결정 7·9의 통합: `NodeLock`(epoch 발급 포함), Postgres 백엔드 트리 연결, `ARCHON_BACKEND=postgres` 런타임 시험과 CI 단계, 내구성 시험, L11 | 런타임 시험 전부를 두 백엔드에서, 두 번째 노드 거절, 락 잃음 감지, epoch가 오른 뒤 이전 노드의 쓰기가 `:fenced`로 거절됨(배타 잠금을 쥔 채 epoch를 올리는 동안 기다리던 이전 노드의 쓰기 포함), Supervisor 재시작 내구성 시험 | 4f, 4g | `lib/archon/runtime/postgres/node_lock.ex`, `lib/archon/runtime/supervisor.ex`, `config/test.exs`, `test/test_helper.exs`(`public` 스키마 비우기), `.github/workflows/ci.yml`, `test/archon/runtime/{durability,node_lock}_test.exs`, 고정 ID를 쓰는 런타임 시험 |

- **병렬로 진행할 수 있는 묶음.**
  - 4a와 4b: 파일이 겹치지 않는다. 동시에 시작한다.
  - 4c와 4d: 4c는 4a, 4d는 4b가 끝나면 시작하고 서로 파일이 겹치지 않는다. 4c는 `Queue`·`Metadata` behaviour를 바꾸지 않는다.
  - 4f와 4e→4g 사슬: 4f는 Postgres 저장소 모듈만, 4e·4g는 런타임 프로세스 파일만 고친다. 4f는 4a·4b·4c 뒤, 4e는 4a·4d 뒤에
    시작한다.
  - 4h는 마지막이다.
- 4d, 4e, 4g는 모두 `workflow_server.ex`·`supervisor.ex`를 고치므로 순서대로 한다. 4h의 `supervisor.ex` 변경은 Postgres
  자식 연결뿐이다. `config/config.exs`는 4a(Repo)와 4g(Waker·유휴 종료 설정)가 서로 다른 키를 더한다. 4a가 먼저
  머지되므로 4g가 그 위에서 시작한다.
- 각 조각은 이 ADR의 결정 번호와 조각 이름을 PR에 적는다. 조각 중에 결정이 바뀌면 이 ADR의 해당 결정과 날짜 줄에 갱신
  사실을 적는다(ADR 0018과 같은 방식).

## upstream과 의도적으로 다른 점

- **큐 연산이 저장과 같은 트랜잭션이다.** upstream은 DAO 호출마다 트랜잭션이 따로라 `createTasks` 뒤 `addTaskToQueue`
  실패를 스위퍼에 맡긴다.
- **다른 워크플로우에 하는 일은 outbox로 최소 한 번 실행한다.** upstream은 그 사이에 서버가 죽으면 스위퍼·다음 decide가
  메우거나 놓친다(`updateAndPushParents`).
- **큐 순서는 우선순위가 먼저다.** upstream Postgres 큐(`deliver_on`이 먼저)가 아니라 기본 서버 `SqliteQueueDAO`의 pop
  순서이며, ADR 0018 결정 3과 계약 시험이 이미 고정했다.
- **unack 재노출은 pop 질의가 한다.** `popped`이고 `unack_on`(꺼낸 시각 + 60초)이 지난 행도 보이는 것으로 본다. upstream의
  주기 작업 `processAllUnacks`는 두지 않는다. upstream은 `deliver_on`부터 60초를 재므로 지연이 지난 뒤 꺼낸 메시지는 더 일찍
  다시 보일 수 있다. Archon은 계약대로 꺼낸 때부터 잰다.
- **시각은 애플리케이션 시계의 epoch ms다.** upstream은 DB `current_timestamp`로 `deliver_on`을 계산한다.
- **보조 표와 색인 표가 없다**(결정 2). LISTEN/NOTIFY 큐 리스너도 아직 없다. 빈 pop은 upstream처럼 100ms 간격으로 다시 묻는다.
- **실패 워크플로우 시작의 일시적 오류를 재시도한다**(결정 4). upstream `terminateWorkflow`는 실패 워크플로우 시작의 모든
  예외를 잡아 오류 출력을 쓴다. Archon은 업무 오류만 출력에 쓰고 DB 장애 같은 일시적 오류는 outbox로 다시 시도한다.
- **동시 실행 한도를 원자적으로 지킨다**(결정 5). upstream `exceedsLimit`은 개수 질의와 poll 저장이 원자적이지 않다.
- **여러 노드를 막는다**(결정 7). upstream Postgres 배포는 `locks` 표의 lease 락으로 여러 노드를 허용한다.

## 대안

- **Postgrex만 쓰기:** 의존성은 하나 줄지만 마이그레이션 실행기, 트랜잭션 도우미, 풀 설정을 직접 써야 한다. Ecto SQL은
  그 셋을 주고, 스키마 모듈을 쓰지 않으면 도메인 struct와 겹치지도 않는다. BOSS가 Ecto SQL을 골랐다.
- **`jsonb`나 `:erlang.term_to_binary` 저장:** 결정 2.
- **큐만 같은 트랜잭션에 넣고 나머지는 항목별 표지:** outbox보다 작지만 재개 대기, 자식 종료, 실패 워크플로우 시작마다
  다른 복구 경로가 생긴다. outbox는 한 규칙으로 메운다.
- **Phase 3처럼 분리 유지:** upstream과 같은 성질이지만 L1·L9가 남는다.
- **Commit마다 outbox Task를 따로 띄우기:** 단순하지만 서로 다른 Commit의 항목이 순서를 바꿔 실행되고(예: 자식 재시도가
  뒤의 자식 종료보다 늦게 실행), 같은 항목이 겹쳐 실행된다. 워크플로우마다 실행기 하나를 둔다(결정 4).
- **큐에 Oban 같은 작업 큐 라이브러리:** 워커 poll API(`QueueDAO` 의미, 우선순위·postpone·unack)와 맞지 않고 큐가 저장
  트랜잭션 밖 라이브러리 스키마에 놓인다.
- **Phase 4에서 여러 노드:** 워크플로우별 소유권 lease와 노드 간 메시지 라우팅이 필요해 조각이 두세 개 늘고, 단일 노드
  정합성이 먼저 서야 시험할 수 있다. BOSS가 뒤로 미뤘다.
- **시작 때 전체 활성화를 배치로만:** 구현은 작지만 대기 워크플로우가 많으면 메모리와 시작 시간이 그만큼 든다. BOSS가
  지연 활성화를 이번에 넣기로 했다.
- **Ecto Sandbox:** 결정 1.

## 결과

- 이 ADR은 결정만 담는다. 구현은 결정 11의 조각 4a~4h로 하며, 마지막 조각이 머지되면 `승인`으로 바꾼다. 그때 ADR 0018의
  목록 상태에 "일부 0021이 대체"를 적는다. 대체되는 것은 결정 1의 프로세스 트리·노드·자식 → 부모 cast, 결정 2의 큐 push
  실패 처리, 결정 3의 behaviour 연산, 결정 5의 부모 알림 결과(항상 `:ok`), 결정 6의 hibernate(유휴 종료), 결정 7의
  `Recovery`, 결정 9의 `updateAndPushParents` cast다.
- 기본 백엔드는 개발·시험이 메모리, 배포 설정이 Postgres다. Phase 5 REST는 백엔드와 무관하게 ADR 0018 결정 7의 API만 부른다.
- **Phase 5의 출시 조건.** worker가 준 `subWorkflowId`를 그대로 믿는 경로(L7·L8)는 태스크 갱신 REST가 외부에 열리기 전에
  인증·인가 ADR이 닫아야 한다. Phase 5는 그 ADR을 태스크 갱신 엔드포인트보다 먼저 머지한다.
- 아직 범위 밖: 여러 노드(결정 7), 검색 색인, 실행 로그·이벤트 표, 외부 payload 저장소, LISTEN/NOTIFY 큐 리스너, 다른 영속성
  백엔드(ADR 0003 결정 5), L3·L4(수용), L7·L8(Phase 5 인증·인가 ADR).
