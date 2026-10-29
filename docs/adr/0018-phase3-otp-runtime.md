# ADR 0018: Phase 3 OTP 런타임 설계

- 상태: 제안
- 날짜: 2026-10-30
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`

## 맥락

[ADR 0003](0003-porting-strategy.md)은 Phase 3를 "OTP 런타임: 워크플로우 인스턴스당 GenServer, 레지스트리,
DynamicSupervisor"로 정했다. [ADR 0014](0014-phase2-decider.md)의 Decider는 `decide/2`로 `Outcome`이나
`{:terminate, Termination, Outcome}`을 돌려줄 뿐이다. 저장, 큐 투입, 하위 워크플로우 시작·취소, 재평가 간격은
"Phase 3 런타임"으로 넘겼다. 지금은 `test/support/decider_replay.ex`가 그 규칙을 흉내 내어 골든 픽스처를
재현한다.

upstream에서 이 일을 하는 곳은 다음과 같다(경로는 `core/src/main/java/` 아래).

| upstream | 하는 일 |
|---|---|
| `com/netflix/conductor/core/execution/WorkflowExecutorOps.java` | 시작(`startWorkflow`, `startWorkflowIdempotent`), decide 루프(`decide`), 완료·종료(`endExecution`, `completeWorkflow`, `terminateWorkflow`, `terminate`), 태스크 갱신(`updateTask`), 재시도·재시작·일시정지·재개(`retry`, `restart`, `pauseWorkflow`, `resumeWorkflow`), 하위 워크플로우 부모 갱신(`updateParentWorkflowTask`, `updateAndPushParents`), 예약(`scheduleTask`, `addTaskToQueue`, `setTaskDomains`, `scheduleNextIteration`) |
| `com/netflix/conductor/core/execution/AsyncSystemTaskExecutor.java` | 비동기 시스템 태스크(JOIN, WAIT, SUB_WORKFLOW 등 `isAsync()`가 참인 것)를 시스템 태스크 큐에서 꺼내 `start`·`execute`하고, 끝나면 decide |
| `com/netflix/conductor/core/execution/tasks/SystemTaskWorker.java`, `SystemTaskWorkerCoordinator.java` | 시스템 태스크 큐마다 poller 스레드 |
| `org/conductoross/conductor/core/execution/WorkflowSweeper.java`, `ExecutorUtils.java` | decider 큐(`_deciderQueue`)에서 워크플로우를 꺼내 decide하고 빠진 큐 메시지를 복구. 다음 재평가 시각은 `computePostpone` |
| `com/netflix/conductor/service/ExecutionService.java`, `TaskServiceImpl.java` | 워커 poll(`poll`, `batchPoll`)과 갱신 진입점 |
| `com/netflix/conductor/core/utils/QueueUtils.java` | 큐 이름 `[domain:]taskType[@namespace][-isolationGroup]` |
| `com/netflix/conductor/core/execution/tasks/SubWorkflow.java`, `Join.java`, `Wait.java` | `start`, `execute`, `cancel`, `getEvaluationOffset` |
| `com/netflix/conductor/core/sync/` | 워크플로우 ID 단위 락(`Lock`, `LocalOnlyLock`, `NoopLock`) |

(`com/netflix/conductor/core/reconciliation/`의 `WorkflowSweeper`·`WorkflowReconciler`·`WorkflowRepairService`는
deprecated이고 속성을 켜야 동작한다. 기본으로 도는 스위퍼는 `org/conductoross/...` 쪽이다.)

upstream 런타임에서 OTP 설계에 직접 걸리는 성질은 다음과 같다.

- **락은 decide만 직렬화한다.** 락 ID는 workflowId이고 기본값은 lease 60초, 시도 500ms다. `decide(String)`가 락을
  못 잡으면 `max(lockTimeToTry/2, 100ms)` 뒤로 decider 큐에 다시 넣고 `null`을 돌려준다. `updateTask`와
  `AsyncSystemTaskExecutor`는 락 없이 태스크를 저장한 뒤 decide를 부른다. 종료·일시정지·재개는 60초 동안 락을
  시도하지만 결과를 무시하고 진행한다. 서버 기본 설정(`application.properties`)은 `LocalOnlyLock`(프로세스 안
  재진입 락)이라 단일 노드에서만 정합성이 있다.
- **decide 루프는 동기 시스템 태스크를 그 자리에서 실행한다.** `scheduleTask`가 새 태스크에 `seq`·
  `firstScheduledTime`을 매기고 저장한 뒤, 동기 시스템 태스크는 `start`하고 나머지는 큐에 넣는다. 루프는
  `execute`가 상태를 바꾸는 동안 반복하고, lease − 100ms에 가까워지면 저장한 뒤 decider 큐에 지연 0으로 넣고 멈춘다.
- **decider 큐 메시지가 워크플로우마다의 타이머다.** 스위퍼는 실행 중 워크플로우의 메시지를 ack하지 않는다.
  decide가 끝날 때마다 `computePostpone`(태스크별 응답·poll·WAIT·워크플로우 타임아웃 중 가장 이른 것, 상한
  `maxPostponeDurationSeconds` 3600초, 기본 `workflowOffsetTimeout` 30초)으로 다음 재평가 시각을 조정한다. 모든
  타임아웃 판정은 Decider 안에 있으므로 이 타이머가 타임아웃을 발화시킨다.
- **비동기 시스템 태스크는 큐 지연으로 다시 평가한다.** `AsyncSystemTaskExecutor`는 끝나지 않은 태스크를
  `getEvaluationOffset(task, 30)`(없으면 30초)만큼 미룬다. JOIN은 `pollCount`가 200 이하이면 0, 그 뒤
  `min(1.2^(pollCount-200), 30)`이다. WAIT은 `waitTimeout`까지 남은 초다. SUB_WORKFLOW는 `isAsyncComplete`가 참이라
  `start` 뒤에는 다시 평가하지 않고, 하위 워크플로우가 끝날 때 부모를 갱신한다.
- **하위 워크플로우는 서로의 큐를 통해 알린다.** 자식 ID는 `UUID.nameUUIDFromBytes("subworkflow:<부모ID>:<태스크ID>:<retryCount>")`로
  결정적이고, `startWorkflowIdempotent`로 만든다. 자식이 끝나면 `updateParentWorkflowTask`가 부모 태스크에
  `SubWorkflow.execute`를 적용해 저장하고, 진행 중 JOIN과 부모를 우선순위 큐로 앞당긴다. 부모가 끝나면
  `cancelNonTerminalTasks` → `SubWorkflow.cancel` → 자식 `terminateWorkflow`가 동기로 이어진다.
- **워커 poll은 큐에서 꺼낸 뒤 태스크마다 검사한다.** 없거나 끝난 태스크는 큐에서 지우고, 동시 실행·빈도 한도를
  넘으면 `taskExecutionPostponeDuration`(60초) 미룬다. 통과하면 `IN_PROGRESS`, `pollCount + 1`, `workerId`,
  `callbackAfterSeconds = 0`, `startTime`(0일 때만)을 저장하고 poll 데이터를 기록한 뒤 메시지를 ack한다.
- **`updateTask`는 저장 뒤 동기로 decide한다.** 워커 태스크가 `IN_PROGRESS`를 보내면 `SCHEDULED`로 저장하고
  `callbackAfterSeconds`만큼 큐에서 미룬다. 끝난 상태면 큐에서 지운다. 대상 태스크나 워크플로우가 이미 끝났으면
  큐에서 지우고 무시한다. `isLazyEvaluateWorkflow`(FORK_JOIN 가지이고 JOIN의 `joinOn`에 들어 있으며 루프 안이 아니고
  성공한 태스크)이면 decide를 건너뛴다.

[ADR 0001](0001-api-contract-scope.md)은 바깥에서 decide를 트리거하는 `PUT /api/workflow/decide/{workflowId}`와
`POST /api/admin/sweep/requeue/{workflowId}`를 Unsupported로 분류했다. 워크플로우마다 프로세스가 상태 전이를 직접
맡는 구조를 전제로 한 분류다. MVP 경로는 정의 등록·조회, 워크플로우 시작·조회·종료, 워커 poll·update다.
일시정지·재개·재시도·재시작·rerun·skip은 Later다.

## 결정

### 1. 워크플로우 인스턴스마다 GenServer 하나가 그 워크플로우의 유일한 쓰기 주체다

프로세스 트리는 다음과 같다. 모듈 이름은 이 ADR에서 정하고 구현에서 바꾸지 않는다.

```text
Archon.Supervisor (one_for_one)
├── Archon.Script.Pool                       (ADR 0015, 지금 있음)
└── Archon.Runtime.Supervisor (rest_for_one)
    ├── Archon.Runtime.Metadata.Memory       (결정 3)
    ├── Archon.Runtime.Store.Memory          (결정 3)
    ├── Archon.Runtime.Queue.Memory          (결정 3)
    ├── Archon.Runtime.Registry              (Registry, keys: :unique, workflowId → pid)
    ├── Archon.Runtime.WorkflowSupervisor    (DynamicSupervisor)
    │   └── Archon.Runtime.WorkflowServer    (워크플로우마다 하나, restart: :transient)
    └── Archon.Runtime.Recovery              (시작 시 한 번 도는 Task, 결정 7)
```

- `rest_for_one`이므로 저장소나 큐 프로세스가 죽으면 그 뒤의 레지스트리와 모든 워크플로우 프로세스가 다시 뜨고,
  `Recovery`가 저장소에서 실행 중 워크플로우를 되살린다. 저장소·큐 구현은 설정(`config :archon, Archon.Runtime`)으로
  고르고, Phase 4는 Postgres 구현을 같은 자리에 넣는다.
- **쓰기 주체 규칙.** 한 워크플로우와 그 태스크의 저장소 기록은 그 워크플로우의 `WorkflowServer`만 쓴다. 워커 poll,
  태스크 갱신, 종료, 하위 워크플로우 알림은 모두 그 프로세스로 보내는 메시지다. 메시지는 하나씩 처리되므로 upstream이
  락으로 막으려던 동시 decide와 "락 없는 `updateTask` 저장"이 구조상 생기지 않는다. 락, 락 실패 시 재큐잉, 락
  lease, `decideWithLock`은 옮기지 않는다.
- **활성화.** 메시지를 보낼 때 `Registry`에 프로세스가 없으면 `WorkflowSupervisor`에 시작을 요청하고, 프로세스는
  `init`에서 저장소의 상태를 읽는다(결정 7). 둘이 동시에 시작하면 `{:already_started, pid}`를 받은 쪽이 그 pid를
  쓴다. 저장소에 없는 ID면 `{:error, :not_found}`다.
- **읽기는 저장소에서 한다.** `GET /api/workflow/{id}`, `GET /api/tasks/{taskId}`에 해당하는 조회는 프로세스를 거치지
  않고 저장소를 읽는다. 프로세스는 응답 전에 저장을 마치므로(결정 2의 write-through) 호출자는 자기가 일으킨 변경을
  읽는다. 끝난 워크플로우를 읽으려고 프로세스를 띄우지 않는다.
- **수명.** 워크플로우가 종료 상태에 이르면 부모 알림(결정 5)까지 마친 뒤 `:normal`로 끝난다. 재시도·재시작처럼
  끝난 워크플로우를 다시 움직이는 요청은 활성화로 다시 띄운다. 오래 기다리는(WAIT, 사람 대기) 프로세스는 일정 시간
  메시지가 없으면 hibernate한다.
- **프로세스 사이 호출 방향.** 워크플로우 프로세스끼리는 부모 → 자식 방향만 `GenServer.call`을 쓰고(자식 종료 요청),
  자식 → 부모 알림은 `cast`다. 서로를 동기 호출하는 고리가 없으므로 교착이 생기지 않는다.
- **노드는 하나다.** Phase 3는 단일 노드에서 정합성을 보장한다. upstream 기본 서버 설정(`LocalOnlyLock`)도 같다.
  여러 노드에서 한 워크플로우의 프로세스를 하나로 유지하는 방법(Postgres advisory lock, 분산 레지스트리 등)은
  Phase 4 이후 별도 ADR에서 정한다.

### 2. 런타임은 순수한 단계 함수(`Archon.Runtime.Step`)와 그것을 실행하는 프로세스로 나눈다

Decider를 순수 함수로 둔 이유(ADR 0014 결정 1)를 런타임에도 적용한다. upstream `WorkflowExecutorOps`가 하는
결정은 `Archon.Runtime.Step`(순수 함수)이 하고, `WorkflowServer`는 그 결과를 실행한다.

```elixir
@spec Step.run(Workflow.t(), Step.Event.t(), Step.Env.t()) :: {Workflow.t(), Step.Commit.t(), [Step.Effect.t()]}
```

- `Event`는 프로세스가 받은 일이다: `:start`, `{:poll, task_id, worker_id}`, `{:update, TaskResult}`,
  `{:evaluate, task_id}`(비동기 시스템 태스크 재평가), `:wake`(타이머), `{:child_changed, task_id, child}`,
  `{:terminate, reason}`, 그리고 결정 9의 생명주기 요청.
- `Env`는 바깥 값이다: `now`, `new_id`, `jitter`, `evaluate_script`, 태스크 정의, 최신 워크플로우 버전,
  도메인별 마지막 poll 시각(`setTaskDomains`의 `getActiveDomain`용), 설정값. Decider `Context`는 `Env`에서 만든다.
- 반환하는 `Workflow`는 **저장한 뒤의 상태**다. upstream이 메모리에서만 바꾸고 저장하지 않은 값은 넣지 않는다
  (예: 완료 시 Decider가 `executed: true`로 바꾼 태스크는 저장하지 않으므로 `executed: false`로 남는다. ADR 0014 결과).
- `Commit`은 한 번에 원자적으로 저장할 변경이다: 워크플로우 필드, 추가·갱신할 태스크, 지울 태스크 ID(DO_WHILE
  `keepLastN`).
- `Effect`는 저장 뒤 실행할 일이다: 태스크 큐 push(지연 포함)·remove·postpone, 하위 워크플로우 시작·종료 요청,
  부모 알림, 실패 워크플로우 시작, 다음 재평가 타이머(`{:wake_at, ms}`), 비동기 시스템 태스크 평가 예약
  (`{:evaluate, task_id}`).

`WorkflowServer`는 `Step.run`을 부르고, `Commit`을 저장소에 쓰고(write-through), 그다음 `Effect`를 순서대로 실행한
뒤 호출자에게 응답한다. 저장 뒤 Effect를 실행하다 프로세스가 죽으면 결정 7의 활성화 복구가 빠진 큐 메시지를 다시
넣는다. upstream도 `createTasks` 뒤 `addTaskToQueue` 실패를 스위퍼 복구에 맡긴다.

이렇게 나누면 `decider_replay.ex`가 흉내 내던 규칙이 `Step`의 제품 코드가 되고, 프로세스 없이도 같은 규칙을
시험할 수 있다(결정 10).

### 3. 저장소·큐·메타데이터는 behaviour로 두고 Phase 3는 메모리 구현을 쓴다

Phase 4가 갈아 끼울 경계를 지금 정한다. behaviour는 MVP 런타임이 쓰는 연산만 담고, Phase 4가 연산을 더할 때는
그 ADR에 적는다.

**`Archon.Runtime.Store`** (upstream `ExecutionDAOFacade`의 MVP 부분)

| 콜백 | 의미 |
|---|---|
| `create_workflow(Workflow.t())` | 태스크 포함 새 워크플로우. 같은 ID가 있으면 `{:error, :conflict}` |
| `commit(workflow_id, Commit.t())` | 결정 2의 변경을 원자적으로 적용 |
| `get_workflow(id, include_tasks?)` | 없으면 `{:error, :not_found}` |
| `get_task(task_id)` | 태스크와 소속 워크플로우 ID |
| `running_workflow_ids()` | 종료 상태가 아닌 워크플로우 ID(결정 7의 복구용) |
| `put_poll_data(task_type, domain, worker_id, now)`·`get_poll_data(task_type, domain)` | `PollData`(도메인 선택용) |

- 저장 형식은 ADR 0014 결정 3의 내부 필드(`wire: false`)를 포함한다. 메모리 구현은 struct를 그대로 담는다.
  Phase 4가 저장용 인코딩을 정한다.
- 저장소 안의 상태는 항상 "어떤 `Commit`까지 반영한 상태"다. 부분 반영이 없다.

**`Archon.Runtime.Queue`** (upstream `QueueDAO`의 MVP 부분)

| 콜백 | 의미 |
|---|---|
| `push(queue, id, priority, delay_ms)` | 메시지 ID는 큐 안에서 유일하다. 같은 ID가 있으면 보일 시각을 새 지연으로 바꾸고 꺼낸 표시를 지운다(upstream 기본 서버의 `SqliteQueueDAO#pushMessage`가 `ON CONFLICT ... DO UPDATE`로 하는 일) |
| `pop(queue, count, timeout_ms)` | 보이는 메시지를 우선순위·시각 순으로 최대 `count`개 꺼낸다. 없으면 `timeout_ms`까지 기다린다 |
| `ack(queue, id)`·`remove(queue, id)` | 메시지 삭제 |
| `postpone(queue, id, priority, delay_ms)` | 다시 넣으며 지연을 바꾼다 |
| `contains?(queue, id)` | 복구 검사 |
| `size(queue)` | 관리·시험용 |

- 큐 이름은 upstream `QueueUtils.getQueueName`에서 실행 네임스페이스와 격리 그룹을 뺀 `[domain:]taskType`이다.
- 큐에는 **워커가 poll하는 태스크(SIMPLE 등 시스템 태스크가 아닌 것)만** 들어간다. upstream의 decider 큐와 시스템
  태스크 큐는 두지 않는다(결정 4, 6).
- 메모리 구현은 GenServer 하나가 큐별 정렬 집합과 지연 타이머를 가진다. `pop`의 대기는 응답을 미루는 방식으로 한다.

**`Archon.Runtime.Metadata`** (upstream `MetadataDAO`의 MVP 부분): 워크플로우 정의 등록·조회(이름·버전, 최신 버전),
태스크 정의 등록·조회. 런타임은 시작 때 정의를 찾고(`MetadataMapperService.lookupForWorkflowDefinition`), 태스크
정의를 박아 넣고(`populateTaskDefinitions`), decide마다 `Env`의 태스크 정의와 최신 버전을 채운다. Phase 5 메타데이터
REST도 이 behaviour를 쓴다.

behaviour마다 공통 계약 시험(결정 10)을 두어 Phase 4 구현이 같은 시험을 통과하게 한다.

### 4. decide 루프, 저장 규칙, 시스템 태스크 실행

`Step`의 decide 루프는 upstream `WorkflowExecutorOps#decide(WorkflowModel)`를 옮긴다.

1. 워크플로우가 종료 상태면 끝낸다(성공이 아니면 남은 태스크를 취소한다).
2. 바뀐 SUB_WORKFLOW 태스크(`subworkflowChanged`)가 있으면 그 표시를 지우고 실패한 JOIN을 `IN_PROGRESS`로 되돌린다
   (`adjustStateIfSubWorkflowChanged`, 결정 9의 재시도와 함께 구현).
3. `Decider.decide/2`를 부른다.
   - `complete?`면 `endExecution`: `terminate_task`가 있으면 그 입력의 `terminationStatus`로 `FAILED`·`TERMINATED`면
     종료(결정 8), 아니면 완료. 완료는 `outcome.workflow.output`, `COMPLETED`, `endTime`, 실패 태스크 이름 집합을
     저장하고 태스크는 저장하지 않는다. 남은 태스크를 취소한다.
   - `{:terminate, termination, outcome}`이면 결정 8.
4. 새 태스크에 도메인을 매긴다(`setTaskDomains`: 시스템 태스크 제외, `*` 뒤 태스크 타입 키로 덮어쓰기,
   `getActiveDomain`은 `activeWorkerLastPollTimeout` 10초 안에 poll된 첫 도메인, 없으면 마지막 값, `NO_DOMAIN`이면 없음).
5. 참조명·`retryCount`가 이미 있는 태스크를 빼고(`dedupAndAddTasks`) 더한다. `seq`(0일 때만)와
   `firstScheduledTime`(0일 때만)을 매기고, 끝나지 않은 시스템 태스크의 `startTime`이 0이면 지금 시각을 넣는다.
6. 동기 시스템 태스크(SWITCH·DECISION·FORK·DO_WHILE)는 그 자리에서 `start`·`execute`하고(`SystemTask.execute/3`,
   `SystemTask.DoWhile.execute/3`), DO_WHILE이 돌려준 다음 반복 태스크도 4·5를 거쳐 더하고 `keepLastN`이 뺀 태스크를
   지운다. 비동기 시스템 태스크(JOIN·WAIT·SUB_WORKFLOW)는 결정 6, 워커 태스크는 큐 push Effect다. 지연은
   `callbackAfterMs`, 없으면 `callbackAfterSeconds`다(재시도 지연이 여기로 온다).
7. `tasks_to_be_updated`와 새 태스크를 한 `Commit`에 담는다. 동기 실행이 상태를 바꿨으면 3으로 돌아간다.
8. 끝나지 않았으면 다음 재평가 시각을 계산해 `{:wake_at, ms}` Effect를 낸다(결정 6).

루프가 오래 돌면(upstream의 lease 보호, 기본 `lockLeaseTime − 100ms` = 59.9초) 그때까지를 저장하고 자기 자신에게
`:wake`를 보내 끝낸다. 그 사이에 쌓인 종료 요청 같은 메시지가 먼저 처리된다.

upstream의 스키마 검증(`enforceSchema`, `rejectTasksFailingInputSchema`, `validateSystemTaskOutput`)은 JSON Schema
검증기를 들일 때 붙인다. 그 전까지 Archon은 스키마를 검사하지 않는다(아래 "upstream과 의도적으로 다른 점").

### 5. 하위 워크플로우

- **시작.** SUB_WORKFLOW 태스크가 예약되면 부모 프로세스가 upstream `SubWorkflow.start`를 따른다. 자식 ID는 upstream과
  같은 이름 기반 UUID(`nameUUIDFromBytes("subworkflow:<부모ID>:<태스크ID>:<retryCount>")`, UUID v3)이고, 입력은
  `parentWorkflowId`, `parentWorkflowTaskId`, `taskToDomain`(부모 것 또는 `subWorkflowTaskToDomain`), `priority`,
  `correlationId`, 해석한 하위 워크플로우 정의·입력이다. 자식 생성은 멱등이다. 같은 ID가 있으면 소유자를 확인하고 그것을
  쓰며, 그것이 실패 상태로 끝나 있으면 새 ID로 다시 시작한다(upstream 문구 그대로). 자식의 첫 decide는 자식 프로세스가
  자기 메시지로 한다(upstream은 decider 큐에 우선순위 10으로 넣는다). 부모는 자식 생성까지만 기다린다.
- **진행 반영.** 자식이 종료 상태가 되면 자식 프로세스가 부모에게 `{:child_changed, task_id, child}`를 `cast`한다.
  부모는 그 태스크가 아직 자기 태스크 목록에 있는지 확인하고(upstream의 세대 펜스), `SystemTask.SubWorkflow.execute/2`로
  상태·출력·실패 이유를 반영한 뒤 진행 중 JOIN을 평가하고 decide한다. 알림이 사라질 경우(부모 재시작 등)에 대비해 부모는
  진행 중 SUB_WORKFLOW가 있으면 `workflowOffsetTimeout`(30초)마다 저장소에서 자식을 읽는다(upstream `computePostpone`의
  활성 하위 워크플로우 규칙과 같은 간격).
- **취소.** 부모가 종료되면 남은 SUB_WORKFLOW 태스크마다 자식 프로세스에 종료를 `call`한다(upstream `SubWorkflow.cancel`,
  사유 문구 그대로). 자식은 부모를 동기 호출하지 않으므로 교착이 없다.
- **실패 워크플로우.** 정의의 `failureWorkflow`(`$`로 시작하면 입력에서 이름을 읽는다)는 종료 처리 마지막에 같은 시작
  경로로 띄우고 결과를 `conductor.failure_workflow` 출력에 적는다(upstream `terminateWorkflow`).

### 6. 타이머와 재평가

upstream의 decider 큐와 스위퍼, 시스템 태스크 큐의 지연 재평가를 **워크플로우 프로세스의 타이머 하나**로 대신한다.

- 프로세스는 `Process.send_after`로 `:wake` 타이머를 하나만 가진다. 시각은 `Step`이 정하고 새 값이 오면 바꾼다.
- 시각은 다음 후보 중 가장 이른 것이다.
  - upstream `ExecutorUtils.computePostpone`의 후보: 진행 중 태스크의 응답 타임아웃까지 남은 시간 + 1초, 예약된
    태스크의 poll 타임아웃까지 + 1초(없으면 워크플로우 타임아웃 + 1초, 그것도 없으면 30초), 진행 중 WAIT의
    `waitTimeout`, 활성 SUB_WORKFLOW는 30초. 각 후보는 `maxPostponeDurationSeconds`(3600초)로 자르고, 후보가 없으면
    30초다.
  - 재시도 대기 중인 태스크(`callbackAfterMs`)는 워커 큐 지연으로 처리하므로 후보가 아니다. 지연이 끝나면 큐에서 보인다.
- `:wake`를 받으면 진행 중 WAIT을 `SystemTask.execute/3`로 평가하고 decide한다. Decider의 타임아웃 판정(워크플로우·
  태스크·poll·응답·전체 타임아웃, ADR 0014)은 이 decide에서 발화한다.
- **비동기 시스템 태스크의 평가 시점.** 프로세스 밖에서 상태가 바뀌는 일이 없으므로 시간 기반 반복 poll 대신 사건으로
  평가한다.
  - JOIN: 예약된 직후, `joinOn`의 태스크가 종료 상태가 된 직후(`isLazyEvaluateWorkflow`로 decide를 건너뛴 갱신 포함),
    하위 워크플로우 진행 반영 직후. 평가할 때마다 `pollCount + 1`이다. 끝나면 `endTime`을 찍고 decide한다
    (upstream `AsyncSystemTaskExecutor`). 이 규칙으로 `workflow_get_completed_fork`의 JOIN `pollCount` 3(예약 직후,
    가지 둘)이 나온다.
  - WAIT: 위 `:wake`. 외부 완료는 태스크 갱신(결정 7의 `update`)이다.
  - SUB_WORKFLOW: 결정 5.
  - 평가 전 검사는 upstream `AsyncSystemTaskExecutor#execute`를 따른다(태스크가 끝났으면 무시, 워크플로우가 끝났으면
    `CANCELED`, `SCHEDULED`이면 `startTime`을 찍고 `start`).
- 프로세스가 죽으면 타이머도 사라진다. 다시 뜬 프로세스는 `init` 직후 decide하고 타이머를 새로 건다(결정 7).

### 7. 워커 연동 API, 재시작과 크래시 복구

**런타임 API**는 `Archon.Runtime`(워크플로우)과 `Archon.Runtime.Tasks`(워커)다. Phase 5 REST 컨트롤러는 이 함수만
부른다.

| 함수 | upstream | 비고 |
|---|---|---|
| `Archon.Runtime.start_workflow(input)` | `startWorkflow` | 정의 확인, 태스크 정의 박아 넣기, 입력 `null` 검사(문구 그대로), 저장, 프로세스 시작, 첫 decide까지 동기. workflowId를 돌려준다 |
| `get_workflow(id, include_tasks?)` | `getExecutionStatus` | 저장소 읽기 |
| `terminate_workflow(id, reason)` | `terminateWorkflow` | `COMPLETED`면 `{:error, :conflict}`, `TERMINATED`면 그대로 성공 |
| `Tasks.poll(task_type, worker_id, domain, count, timeout_ms)` | `ExecutionService#poll` | 결정 3의 큐에서 꺼내 태스크마다 소유 프로세스에 `{:poll, ...}`를 보낸다 |
| `Tasks.update(task_result)` | `WorkflowExecutorOps#updateTask` | `workflowInstanceId`의 프로세스로 보낸다 |
| `Tasks.update_v2(task_result)` | `TaskResource#updateTaskV2` | 갱신 뒤 같은 타입의 다음 태스크 poll |
| `Tasks.get(task_id)` | `getTask` | 저장소 읽기 |

- `poll`: 큐에서 꺼낸 ID마다 소유 프로세스가 검사한다. 태스크가 없거나 끝났으면 큐에서 지우고 건너뛴다. 아니면
  `IN_PROGRESS`, `pollCount + 1`, `workerId`, `callbackAfterSeconds = 0`, `startTime`(0일 때만), `updateTime`을 저장한다.
  다 돌면 poll 데이터를 기록하고(빈 poll도) 메시지를 ack한다. `timeout_ms` 상한 5000은 upstream과 같다.
- `update`: upstream `updateTask`의 순서를 그대로 따른다(위 "맥락"). 응답 전에 decide까지 마친다.
- **재시작·크래시 복구.**
  - `WorkflowServer`는 `restart: :transient`다. 비정상 종료하면 다시 떠서 `init`에서 저장소 상태를 읽는다. 처리 중이던
    메시지는 잃는다. 그 메시지가 저장 전이었으면 호출자는 오류를 받고 다시 보낼 수 있고, 저장 뒤였으면 결과는 남는다.
  - 활성화 직후 복구(upstream 스위퍼의 repair): 큐에 메시지가 없는 `SCHEDULED` 워커 태스크를 다시 넣고, 진행 중
    SUB_WORKFLOW의 자식이 이미 끝났으면 반영하고, decide한 뒤 타이머를 건다. 실행 중인데 끝나지 않은 태스크가 없으면
    upstream처럼 마지막 태스크를 미실행으로 되돌려 다시 decide한다.
  - `Archon.Runtime.Recovery`는 애플리케이션 시작 때 `Store.running_workflow_ids/0`의 워크플로우를 모두 활성화한다.
    Phase 3 메모리 저장소에서는 저장소 프로세스 재시작 뒤가 이 경우다. 워크플로우가 많을 때의 지연 활성화(저장소의
    다음 재평가 시각으로 필요할 때만 띄우기)는 Phase 4 ADR에서 정한다.
- 동시 실행 한도(`concurrentExecLimit`)와 빈도 한도(`rateLimitPerFrequency`)는 여러 워크플로우의 진행 중 태스크를 세야
  하므로 Phase 4 저장소 질의와 함께 붙인다. 그 전까지 Archon은 한도를 적용하지 않는다.

### 8. 종료 처리와 내부 필드

`{:terminate, termination, outcome}`과 `terminate_workflow` 요청은 upstream `terminate`·`terminateWorkflow`를 따른다.

- 워크플로우가 아직 종료 상태가 아니면 `termination.status`로 바꾼다. `termination.task`가 있고 `failed_task_id`가
  비어 있으면 그 ID를 넣고, 그 태스크를 저장한다.
- 출력은 `outcome.workflow.output`(Decider가 채운 값)을 쓰고, 실패 태스크(`FAILED`, `FAILED_WITH_TERMINAL_ERROR`)의
  참조명·정의명을 `failedReferenceTaskNames`·`failedTaskNames`에 더하고, `reasonForIncompletion`에 사유를 넣는다.
- 남은 태스크를 `CANCELED`로 바꾸고 시스템 태스크는 `cancel`한다(SUB_WORKFLOW는 결정 5). 모든 태스크를 큐에서 지운다.
- 부모가 있으면 결정 5로 알린다. 실패 워크플로우를 띄운다.
- **`previous_status`**: upstream `WorkflowModel#setStatus`는 상태가 바뀔 때마다 이전 값을 기록한다. core 안에서 읽는
  곳은 없지만 저장 형식에는 있다. `Step`은 상태를 바꾸는 모든 곳에서 같은 규칙으로 기록한다(상태 변경 함수 하나로 모은다).
- **`failed_task_id`**: 위 규칙으로 넣고, 재시작과 부모 재개(`updateAndPushParents`)에서 지운다. 실패 워크플로우 입력의
  `failureTaskId`가 이 값을 읽는다.

### 9. 생명주기 연산(REST는 Later)

일시정지·재개·재시도·재시작은 REST가 Later지만 하위 워크플로우 재시도(`updateAndPushParents`)와 얽혀 있어 런타임 메시지로
Phase 3 마지막 조각에서 옮긴다. upstream 규칙(`pauseWorkflow`: 종료 상태면 conflict, `resumeWorkflow`: `PAUSED`가 아니면
오류와 `lastRetriedTime`, `retry`: 실패·취소 태스크 재예약과 JOIN·DO_WHILE 제자리 재시도, `restart`: 태스크 비우고 처음부터)을
따르고, 일시정지 중에는 타이머를 걸지 않는다. rerun, skip, `resetCallbacksForWorkflow`는 이 ADR 범위 밖이다.

### 10. 시험 전략

- **behaviour 계약 시험.** `test/support/runtime/store_contract.ex`, `queue_contract.ex`, `metadata_contract.ex`가 콜백
  의미를 시험하는 공유 케이스다. 메모리 구현이 지금 통과하고, Phase 4 Postgres 구현이 같은 케이스를 통과해야 한다.
- **`Step` 단위 시험.** 프로세스 없이 이벤트를 차례로 넣는다. 지금의 재현 시험(`simple_replay_test.exs`,
  `system_task_replay_test.exs`, `do_while_replay_test.exs`)은 `decider_replay.ex` 대신 `Step`으로 같은 픽스처를 재현한다.
  `decider_replay.ex`는 그 뒤 지운다.
- **골든 픽스처를 실제 프로세스로 재현.** 애플리케이션 트리를 띄우고 `Archon.Runtime`·`Archon.Runtime.Tasks`만 불러
  `workflow_start_*` → `task_poll_*` → `task_update_*`를 넣은 뒤, `get_workflow`가 `workflow_get_completed_simple`,
  `_switch`, `_fork`와 같은지 본다(비교 규칙은 ADR 0014 결정 8과 같다). 종료는 `workflow_start_to_terminate` →
  `workflow_terminate` → `workflow_get_terminated`, 빈 큐는 `task_poll_empty`다. 시계와 ID는 `config :archon,
  Archon.Runtime`의 `clock`·`new_id`로 주입해 결정적으로 만든다.
- **타이머 시험.** 실제로 기다리지 않는다. 주입한 시계를 앞으로 돌리고 프로세스에 `:wake`를 직접 보낸다.
- **크래시 시험.** 진행 중인 `WorkflowServer`를 `Process.exit(pid, :kill)`로 죽이고, 다시 뜬 프로세스가 같은 상태에서
  이어 가는지 본다. 저장 뒤·Effect 전 크래시는 시험용 훅으로 만든다.
- **골든 픽스처가 없는 시나리오**(하위 워크플로우, WAIT, 재시도 지연, 타임아웃, 생명주기)의 정답은 upstream
  `test-harness/src/test/groovy/com/netflix/conductor/test/integration/`의 Spock 명세(`SubWorkflowSpec`,
  `FailureWorkflowSpec`, `RetryPolicySpec`, `SubWorkflowRetrySpec`, `SubWorkflowRestartSpec` 등)에서 옮긴다. 명세가
  모자라면 `scripts/contract/capture_fixtures.sh`로 로컬 upstream 서버에서 새 픽스처를 캡처한다. 옮긴 사례는 시험 파일에
  원본 명세 이름을 적는다.

### 11. ADR 0014가 Phase 3로 넘긴 항목

| 항목 | 출처 | 이 ADR의 처리 | 조각 |
|---|---|---|---|
| 저장(`tasks_to_be_updated`와 새 태스크만, 완료 시 상태·출력만) | 결정 1, 결과 | 결정 2의 `Commit`, 결정 4의 3·7 | 3b |
| 큐 투입(지연, 도메인) | 결정 1 | 결정 4의 4·6, 결정 3의 `Queue` | 3b, 3c |
| 시작 시 태스크 정의 박아 넣기, `seq`·`firstScheduledTime`, 시스템 태스크 `startTime` | 결과(2b) | 결정 4의 5, 결정 7의 `start_workflow` | 3b, 3c |
| 참조명·`retryCount` 중복 제거 | 결과(2b) | 결정 4의 5 | 3b |
| 동기 시스템 태스크 실행 루프(SWITCH·DECISION·FORK·DO_WHILE) | 결정 5(2c, 2e) | 결정 4의 6 | 3b |
| JOIN 비동기 실행, `isLazyEvaluateWorkflow` | 결정 5(2c) | 결정 6, 결정 7의 `update` | 3b, 3c |
| JOIN·WAIT 재평가 간격(`getEvaluationOffset`) | 결정 5(2c, 2d) | 결정 6(사건 기반 평가와 `:wake`) | 3b, 3c |
| 하위 워크플로우 시작(`start`, `SCHEDULED`인데 자식이 없을 때의 재시작)·취소 | 결정 5(2d) | 결정 5 | 3e |
| `SubWorkflow.execute`에 넘길 자식 읽기 | 결정 5(2d) | 결정 5의 진행 반영 | 3e |
| DO_WHILE 다음 반복 예약과 그 태스크의 도메인 지정, `keepLastN` 삭제 | 결정 5(2e) | 결정 4의 4·6, `Commit`의 삭제 | 3b |
| DO_WHILE을 decide 루프가 매번 다시 실행 | 결정 5(2e) | 결정 4의 6 | 3b |
| `previous_status`, `failed_task_id` | 결과 | 결정 8 | 3b |
| `Termination`의 `status`·`task`로 종료 | 결정 1 | 결정 8 | 3b |
| `terminate_task`(TERMINATE 태스크)로 끝내기 | 결정 1 | 결정 4의 3 | 3b |
| 완료 시 출력은 `outcome.workflow.output`, 상태·`endTime`은 런타임 | 결정 1 | 결정 4의 3 | 3b |
| 재시도 지연(`callbackAfterMs`)을 큐 지연으로 | 결정 2(2b) | 결정 4의 6 | 3b, 3c |
| 타임아웃 판정이 발화할 재평가 | 결정 2 | 결정 6 | 3b, 3c |
| `decider_replay.ex`가 흉내 내는 poll·update 규칙 | 결과 | 결정 7(upstream 그대로. 재현 하네스가 단순화한 `startTime` 덮어쓰기, `IN_PROGRESS` → `SCHEDULED` 변환 생략, 끝난 태스크 무시 분기 생략은 upstream대로 고친다) | 3d |

### 12. 구현 조각

| 조각 | 범위 | 정답 기준 | 선행 | 건드리는 파일·모듈 |
|---|---|---|---|---|
| 3a | 결정 3: `Store`·`Queue`·`Metadata` behaviour와 메모리 구현, 공통 계약 시험 | 계약 시험. upstream `QueueDAO` 의미(지연, 우선순위, postpone, ack)와 `ExecutionDAOFacade`·`MetadataDAO`의 MVP 연산 | 없음 | `lib/archon/runtime/{store,queue,metadata}.ex`, `lib/archon/runtime/{store,queue,metadata}/memory.ex`, `test/support/runtime/*_contract.ex`, `test/archon/runtime/{store,queue,metadata}_test.exs` |
| 3b | 결정 2·4·6·8의 순수 부분: `Step`(decide 루프, 저장 규칙, 도메인, 동기 시스템 태스크, DO_WHILE, JOIN·WAIT 평가, 종료·완료, 재평가 시각, poll·update 상태 전이) | 지금의 재현 시험 셋을 `Step`으로 통과, upstream `TestWorkflowExecutor`(`scheduleTask`, `setTaskDomains`, `getActiveDomain`, `dedupAndAddTasks`, `cancelNonTerminalTasks`, `updateTask`)와 `ExecutorUtilsTest`(`computePostpone`), `TestWorkflowExecutorDecideLoop` 사례 | 없음 | `lib/archon/runtime/step.ex`, `lib/archon/runtime/step/*.ex`, `test/archon/runtime/step*_test.exs`, `test/archon/decider/*_replay_test.exs`, `test/support/decider_replay.ex`(삭제) |
| 3c | 결정 1·6·7의 프로세스 부분: `Runtime.Supervisor`, `Registry`, `WorkflowSupervisor`, `WorkflowServer`(활성화, write-through, Effect 실행, `:wake` 타이머, 루프 시간 보호), `Recovery`, `Archon.Runtime`의 시작·조회·종료, `Application` 연결 | 시작·종료 골든 픽스처(`workflow_start_to_terminate`, `workflow_terminate`, `workflow_get_terminated`, `workflow_get_running`)를 프로세스로 재현, 크래시·재활성화 시험 | 3a, 3b | `lib/archon/runtime.ex`, `lib/archon/runtime/{supervisor,workflow_server,recovery,effects}.ex`, `lib/archon/application.ex`, `config/*.exs`, `test/archon/runtime/{runtime,workflow_server,recovery}_test.exs` |
| 3d | 결정 7의 워커 API: `Archon.Runtime.Tasks`(poll, batch poll, update, update-v2, get), poll 데이터, 도메인 큐 | `workflow_get_completed_simple`·`_switch`·`_fork`, `task_poll_empty`, `task_get`을 프로세스로 재현. DO_WHILE은 `do_while_replay_test.exs` 시나리오를 프로세스로 | 3c | `lib/archon/runtime/tasks.ex`, `test/archon/runtime/tasks_test.exs`, `test/archon/runtime/golden_replay_test.exs` |
| 3e | 결정 5: 하위 워크플로우 시작·진행 반영·취소, 실패 워크플로우 | upstream `SubWorkflowSpec`, `FailureWorkflowSpec`, `NestedForkJoinSubWorkflowSpec`(MVP 타입 부분)에서 옮긴 시나리오 | 3c | `lib/archon/runtime/sub_workflows.ex`, `test/archon/runtime/sub_workflow_test.exs` |
| 3f | 결정 9: 일시정지·재개·재시도·재시작, `updateAndPushParents`, `adjustStateIfSubWorkflowChanged` | upstream `RetryPolicySpec`, `SubWorkflowRetrySpec`, `SubWorkflowRestartSpec`, `HierarchicalForkJoinSubworkflowRetrySpec`·`RestartSpec`(MVP 타입 부분), `TestWorkflowExecutor`의 retry·restart·pause·resume 사례 | 3d, 3e | `lib/archon/runtime/lifecycle.ex`, `lib/archon/runtime/step/lifecycle.ex`, `test/archon/runtime/lifecycle_test.exs` |

- **병렬로 진행할 수 있는 묶음.**
  - 3a와 3b: 서로 파일이 겹치지 않고 서로를 부르지 않는다(3b는 순수 함수라 저장소를 모른다). 동시에 시작한다.
  - 3d와 3e: 3c가 끝난 뒤 동시에 진행한다. 3c는 `WorkflowServer`가 Effect를 `Archon.Runtime.Effects`로 넘기게 하고,
    하위 워크플로우 Effect의 실행은 `Archon.Runtime.SubWorkflows`의 함수 이름만 정해 두어(자리만 있는 구현) 3e가 그
    파일만 채우게 한다. 3d와 3e가 `workflow_server.ex`나 `step` 파일을 고쳐야 하면 병렬 조건이 깨진 것이므로, 그
    변경은 먼저 머지된 쪽에 맞춰 다른 쪽이 rebase한다.
- 3b의 `Step`에는 하위 워크플로우 Effect를 내는 부분까지 들어간다. 3e는 그 Effect를 실행하는 쪽만 맡는다.
- 3f는 `Step`에 생명주기 이벤트를 더하므로 다른 조각과 병렬로 하지 않는다.
- 각 조각은 이 ADR의 결정 번호와 조각 이름을 PR에 적는다. 조각 중에 결정이 바뀌면 이 ADR의 해당 결정과 날짜 줄에
  갱신 사실을 적는다(ADR 0014와 같은 방식).

## upstream과 의도적으로 다른 점

- **락이 없다.** 워크플로우마다 프로세스 하나가 메시지를 하나씩 처리한다. upstream에서 락 없이 저장하던 `updateTask`·
  `AsyncSystemTaskExecutor`와 decide가 겹치는 경합, 락 실패 재큐잉, lease 만료는 생기지 않는다.
- **decider 큐와 스위퍼가 없다.** 워크플로우 프로세스의 타이머 하나(결정 6)와 활성화 복구(결정 7)가 대신한다.
  `PUT /api/workflow/decide/{id}`와 `POST /api/admin/sweep/requeue/{id}`는 ADR 0001대로 Unsupported다.
- **시스템 태스크 큐가 없다.** JOIN·WAIT·SUB_WORKFLOW는 소유 프로세스가 평가한다. JOIN은 시간 기반 지수 백오프 poll
  대신 사건으로 평가하므로 `pollCount`는 평가 횟수(예약 직후 + 관련 사건 수)다. upstream의 `pollCount`는 poller 간격에
  따라 달라지는 값이다. 골든 픽스처 `workflow_get_completed_fork`와는 같다.
- **큐 이름에 실행 네임스페이스와 격리 그룹이 없다.** 도메인만 지원한다.
- **하위 워크플로우 완료 알림은 프로세스 메시지다.** upstream은 부모를 decider 큐 우선순위로 앞당긴다. 결과 상태는 같고
  반영 시점이 더 이르다.
- **동시 실행·빈도 한도와 스키마 검증은 아직 적용하지 않는다**(결정 4, 7). 그 기능을 붙이는 조각이나 ADR에서 이 항목을 고친다.
- **워크플로우·태스크 상태 리스너, 메트릭, 이벤트 큐 연동은 두지 않는다.** 리스너 호출 지점(`notifyWorkflowStatusListener`, `notifyTaskStatusListener`)은 결과 상태에 영향을 주지 않는다.
- **여러 노드를 지원하지 않는다**(결정 1). upstream 기본 서버 설정(`LocalOnlyLock`)과 같은 범위다.

## 대안

- **upstream 구조를 그대로 옮기기(저장소 + decider 큐 + 스위퍼 + 워크플로우 ID 락):** ADR 0003이 이미 기각했다. 락·재큐잉·
  복구가 하는 일의 대부분이 "같은 워크플로우를 둘이 동시에 만지지 않기"인데, 프로세스 하나가 그 성질을 구조로 준다.
- **프로세스 없이 저장소 트랜잭션으로 직렬화(`SELECT ... FOR UPDATE`):** Phase 4 전에는 쓸 수 없고, 타이머·하위 워크플로우
  알림을 다시 큐로 만들어야 한다. 노드가 여럿일 때의 소유권 문제는 Phase 4 이후 ADR에서 이 방식과 함께 다시 본다.
- **`Step` 없이 `WorkflowServer` 안에 규칙을 두기:** 파일은 줄지만 규칙 시험에 프로세스가 필요하고, 재현 하네스와 제품
  코드가 따로 놀게 된다. 지금의 `decider_replay.ex`가 그 상태다.
- **Phase 3에서 저장소 경계 없이 프로세스 상태만 쓰기:** 가장 빠르지만 크래시 복구와 읽기 경로를 Phase 4에서 다시 짜야
  한다. 경계만 먼저 정하고 메모리로 구현하면 Phase 4는 구현 교체가 된다.
- **비동기 시스템 태스크를 upstream처럼 시간 기반 재평가:** 같은 프로세스 안의 사건을 놓칠 일이 없으므로 이득이 없고,
  시험이 시간에 묶인다.

## 결과

- 이 ADR은 결정만 담는다. 구현은 결정 12의 조각 3a~3f로 하며, 마지막 조각이 머지되면 `승인`으로 바꾼다.
- Phase 4 ADR은 결정 3의 behaviour를 Postgres로 구현하면서 저장용 인코딩(ADR 0014 결정 3), 큐의 원자성(저장과 같은
  트랜잭션에 넣을지), 지연 활성화, 여러 노드의 소유권을 정한다.
- Phase 5 REST는 결정 7의 API만 부르고, 응답 형태와 오류 코드를 ADR 0001의 MVP 계약에 맞춘다.
- 아직 범위 밖: rerun, skip, 콜백 초기화, 동시 실행·빈도 한도, 스키마 검증, 실행 로그(`TaskExecLog`), 리스너,
  외부 payload 저장소, 격리 그룹·실행 네임스페이스, 여러 노드.
