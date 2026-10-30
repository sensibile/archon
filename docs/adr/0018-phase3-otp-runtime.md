# ADR 0018: Phase 3 OTP 런타임 설계

- 상태: 제안
- 날짜: 2026-10-30, 갱신 2026-10-30(조각 3b: 결정 2의 이벤트·Env·Effect 목록, 결정 8 (a)의 출력), 갱신 2026-10-30(조각 3c: 결정 2의 Env 채우기와 큐 push 실패, 결정 7의 시작 오류, 결정 12의 3c·3e 경계), 갱신 2026-10-30(조각 3d: 결정 7의 워커 API 형태와 poll 실패 처리), 갱신 2026-10-30(조각 3e: 결정 5의 시작 오류 분류와 부모 알림, 결정 8 (a)의 실패 워크플로우 시작 결과, 결정 12의 3e 시험 범위)
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
| `com/netflix/conductor/core/dal/ExecutionDAOFacade.java` | 저장. 저장할 때 `updatedTime`·`updateTime`·`endTime`을 찍는다 |
| `com/netflix/conductor/core/utils/QueueUtils.java` | 큐 이름 `[domain:]taskType[@namespace][-isolationGroup]` |
| `com/netflix/conductor/core/execution/tasks/SubWorkflow.java`, `Join.java`, `Wait.java` | `start`, `execute`, `cancel`, `getEvaluationOffset` |
| `com/netflix/conductor/core/sync/` | 워크플로우 ID 단위 락(`Lock`, `LocalOnlyLock`, `NoopLock`) |

(`com/netflix/conductor/core/reconciliation/`의 `WorkflowSweeper`·`WorkflowReconciler`·`WorkflowRepairService`는
deprecated이고 속성을 켜야 동작한다. 기본으로 도는 스위퍼는 `org/conductoross/...` 쪽이다. 서버 기본 저장소·큐는
`sqlite-persistence`의 `SqliteExecutionDAO`·`SqliteQueueDAO`다.)

upstream 런타임에서 OTP 설계에 직접 걸리는 성질은 다음과 같다.

- **락은 decide만 직렬화한다.** 락 ID는 workflowId이고 기본값은 lease 60초, 시도 500ms다. `decide(String)`가 락을
  못 잡으면 `max(lockTimeToTry/2, 100ms)` 뒤로 decider 큐에 다시 넣고 `null`을 돌려준다. `updateTask`와
  `AsyncSystemTaskExecutor`는 락 없이 태스크를 저장한 뒤 decide를 부른다. 종료·일시정지·재개는 60초 동안 락을
  시도하지만 결과를 무시하고 진행한다. 서버 기본 설정(`application.properties`)은 `LocalOnlyLock`(프로세스 안
  재진입 락)이라 단일 노드에서만 정합성이 있다.
- **decide 루프는 동기 시스템 태스크를 그 자리에서 실행한다.** `scheduleTask`가 새 태스크에 `seq`·
  `firstScheduledTime`을 매기고 저장한 뒤, 동기 시스템 태스크는 `start`하고 나머지는 큐에 넣는다. 루프는 동기
  시스템 태스크를 새로 시작했거나 `execute`가 참을 돌려준 동안 반복하고, lease − 100ms에 가까워지면 저장한 뒤
  decider 큐에 지연 0으로 넣고 멈춘다.
- **decider 큐 메시지가 워크플로우마다의 타이머다.** 스위퍼는 실행 중 워크플로우의 메시지를 ack하지 않는다.
  decide가 끝날 때마다 `computePostpone`으로 다음 재평가 시각을 정하고, 그 값이 `workflowOffsetTimeout`(30초)과 다를
  때만 메시지의 unack 타임아웃을 바꾼다. 후보는 태스크마다 하나이고 가장 작은 값을 쓴다.
  - 예약된 태스크: 태스크 정의의 `pollTimeoutSeconds`가 있으면 남은 poll 시간 + 1초, 없고 워크플로우
    `timeoutSeconds`가 있으면 `timeoutSeconds + 1`, 둘 다 없으면 30초.
  - 진행 중 WAIT: `waitTimeout`까지 남은 초(내림, 0 이상). `waitTimeout`이 0이면 30초.
  - 진행 중 HUMAN, 활성 SUB_WORKFLOW: 30초.
  - 그 밖의 진행 중 태스크: 응답 타임아웃(태스크 정의 값, 0이면 태스크 값)이 있으면 남은 시간 + 1초, 없으면 30초.
  - 각 후보는 `maxPostponeDurationSeconds`(3600초)로 자르고, 후보가 없으면 30초다.
  - 모든 타임아웃 판정은 Decider 안에 있으므로 이 타이머가 타임아웃을 발화시킨다. 워커 poll도
    `adjustDeciderQueuePostpone`으로 응답 타임아웃이 더 이르면 타이머를 당긴다.
- **비동기 시스템 태스크는 큐 지연으로 다시 평가한다.** `AsyncSystemTaskExecutor`는 끝나지 않은 태스크의
  `callbackAfterSeconds`를 `getEvaluationOffset(task, 30)`(없으면 30초)로 저장하고 그만큼 큐에서 미룬다. JOIN은
  `joinMode`가 `SYNC`이면 0, 아니면 `pollCount`가 200 이하일 때 0, 그 뒤 `min(1.2^(pollCount-200), 30)`이다.
  WAIT은 `waitTimeout`까지 남은 초(0이면 1)다. SUB_WORKFLOW는 `isAsyncComplete`가 참이라 `start` 뒤에는 다시 평가하지
  않고, 하위 워크플로우가 끝날 때 부모를 갱신한다.
- **하위 워크플로우는 서로의 큐를 통해 알린다.** 자식 ID는 `UUID.nameUUIDFromBytes("subworkflow:<부모ID>:<태스크ID>:<retryCount>")`로
  결정적이고, `startWorkflowIdempotent`로 만든다. 자식이 끝나면 `updateParentWorkflowTask`가 부모 태스크에
  `SubWorkflow.execute`를 적용해 저장하고, 진행 중 JOIN과 부모를 우선순위 큐로 앞당긴다. 부모가 끝나면
  `cancelNonTerminalTasks` → `SubWorkflow.cancel` → 자식 `terminateWorkflow`가 동기로 이어지고, 이 취소는 부모 상태를
  저장하기 전에 한다.
- **워커 poll은 큐에서 꺼낸 뒤 태스크마다 검사한다.** 없거나 끝난 태스크는 큐에서 지우고, 동시 실행 한도를 넘으면
  `taskExecutionPostponeDuration`(60초) 미룬다. 기본 서버의 `SqliteExecutionDAO#exceedsRateLimitPerFrequency`는 항상
  거짓이라 빈도 한도는 적용되지 않는다. 통과하면 `IN_PROGRESS`, `pollCount + 1`, `workerId`,
  `callbackAfterSeconds = 0`, `startTime`(0일 때만)을 저장하고 poll 데이터를 기록한 뒤 메시지를 ack한다.
  `SqliteQueueDAO`는 꺼낸 뒤 ack되지 않은 메시지를 60초 뒤 다시 보이게 한다.
- **`updateTask`는 저장 뒤 동기로 decide한다.** 워커 태스크가 `IN_PROGRESS`를 보내면 `SCHEDULED`로 저장하고
  `callbackAfterSeconds`만큼 큐에서 미룬다. 끝난 상태면 큐에서 지운다. 대상 태스크나 워크플로우가 이미 끝났으면
  큐에서 지우고 무시한다. `isLazyEvaluateWorkflow`(FORK_JOIN 가지이고 JOIN의 `joinOn`에 들어 있으며 루프 안이 아니고
  성공한 태스크)이면 decide를 건너뛴다.
- **종료는 두 경로가 다르다.** REST 종료 `terminateWorkflow(String, String)`은 `COMPLETED`면 conflict, `TERMINATED`면
  아무것도 하지 않고, 그 밖의 상태(`FAILED`·`TIMED_OUT` 포함)는 `TERMINATED`로 바꾼 뒤 실패 워크플로우 없이 끝낸다.
  Decider가 던진 `TerminateWorkflowException`은 `terminate(workflow, exception)`을 거쳐 `failedTaskId`를 기록하고
  정의의 `failureWorkflow`를 띄운다.

[ADR 0001](0001-api-contract-scope.md)은 바깥에서 decide를 트리거하는 `PUT /api/workflow/decide/{workflowId}`와
`POST /api/admin/sweep/requeue/{workflowId}`를 Unsupported로 분류했다. 워크플로우마다 프로세스가 상태 전이를 직접
맡는 구조를 전제로 한 분류다. MVP 경로는 정의 등록·조회, 워크플로우 시작·조회·상태 요약·종료, 워커 poll·update다.
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
    └── Archon.Runtime.Recovery              (시작 시 한 번 도는 Task, restart: :transient, 결정 7)
```

- `rest_for_one`이므로 저장소나 큐 프로세스가 다시 뜨면 그 뒤의 레지스트리와 모든 워크플로우 프로세스가 다시 뜨고,
  `Recovery`가 저장소에서 실행 중 워크플로우를 되살린다. 저장소·큐 구현은 설정(`config :archon, Archon.Runtime`)으로
  고르고, Phase 4는 Postgres 구현을 같은 자리에 넣는다. Phase 3 메모리 구현은 프로세스가 죽으면 데이터도 잃는다.
  메모리 구현은 개발·시험용이고, 데이터가 남는 재시작 복구는 Phase 4 저장소에서 의미가 있다.
- **쓰기 주체 규칙.** 한 워크플로우와 그 태스크의 저장소 기록은 그 워크플로우의 `WorkflowServer`만 쓴다. 새
  워크플로우의 첫 기록(`create_workflow`)도 그 워크플로우의 프로세스가 `start` 이벤트를 처리하며 쓴다(결정 7). 워커
  poll, 태스크 갱신, 종료, 하위 워크플로우 알림은 모두 그 프로세스로 보내는 메시지다. 메시지는 하나씩 처리되므로
  upstream이 락으로 막으려던 동시 decide와 "락 없는 `updateTask` 저장"이 구조상 생기지 않는다. 락, 락 실패 시
  재큐잉, 락 lease, `decideWithLock`은 옮기지 않는다.
- **활성화.** 메시지를 보낼 때 `Registry`에 프로세스가 없으면 `WorkflowSupervisor`에 시작을 요청한다. 둘이 동시에
  시작하면 `{:already_started, pid}`를 받은 쪽이 그 pid를 쓴다. `init`은 저장소에서 상태를 읽기만 하고, 복구·decide·
  타이머 설정은 `handle_continue`에서 한다. 그래서 `init`이 다른 프로세스 시작을 기다리며 `WorkflowSupervisor`를
  막는 일이 없다. 저장소에 없는 ID면 `init`이 `:ignore`를 돌려주고 호출자는 `{:error, :not_found}`를 받는다.
  새 워크플로우는 `start_workflow`(결정 7)가 "새로 만듦" 인자로 띄운다. 이때도 `init`은 저장소를 확인해서, 기록이
  있으면(같은 인자로 재시작된 경우) 일반 활성화처럼 저장소 상태를 읽고 `:recover`를 한다. 기록이 없으면
  `handle_continue`를 하지 않는다. 기록 생성과 첫 decide는 이어서 받는 `{:start, input}` 호출이 한다. 최상위 시작은 첫 decide까지 마치고
  답하고, 하위 워크플로우의 멱등 시작은 기록을 만든 뒤 바로 답하고 첫 decide를 `{:continue, ...}`로 이어서 한다(결정 5).
  기존 기록으로 활성화된 프로세스는 `{:start}`에 최상위 시작이면 `{:error, :conflict}`, 하위 워크플로우의 멱등 시작이면
  결정 5의 규칙(소유자 확인 뒤 기존 기록을 쓰거나 새 무작위 ID로 다시 시작)으로 답하고, 수명은 아래 일반 규칙을 따른다
  (실행 중이면 끝나지 않는다). 기록이 없는 상태에서 `{:start}`의 생성이 실패한(conflict 포함) 프로세스는 오류로 답하고 바로 끝난다.
  `{:start}` 처리 중 예외는 예외 격리 대신 upstream `startWorkflow`처럼 처리한다. Commit 전이면 오류로 답하고 끝나고,
  기록을 만든 뒤(첫 decide나 큐가 아닌 Effect 중)이면 `Store.remove_workflow`로 워크플로우와 태스크를 먼저 지우고 그다음 `WorkflowServer`가 이미
  넣은 태스크마다 `Queue.remove`를 한 뒤(둘을 합친 것이 upstream `ExecutionDAOFacade.removeWorkflow`) 오류로 답하고 끝난다.
  최상위 `{:start}`는 하위 워크플로우 시작 Effect를 응답 뒤 `{:continue, ...}`로 미루므로(upstream에서도 SUB_WORKFLOW는
  `startWorkflow`가 답한 뒤 시스템 태스크 큐에서 시작된다) 지운 부모의 자식은 생기지 않는다. 워커 큐 push 실패는 시작
  실패가 아니다. upstream `scheduleTask`처럼 기록하고 넘어가며, 결정 2의 복구 검사가 다시 넣는다. 호출자가 ID를 받지 못한 워크플로우가 계속 실행되지 않게 한다. 지우기
  전에 프로세스가 죽으면 기록이 남아 복구된다(upstream도 서버가 그 사이에 죽으면 같다). 하위 워크플로우의 멱등 시작은
  기록을 만든 뒤 바로 답하므로 이 규칙이 아니라 일반 예외 격리를 따른다.
- **호출이 프로세스 종료와 겹칠 때.** 종료 직후 `:normal`로 끝나는 프로세스나 레지스트리에 남은 죽은 pid로 보낸
  `call`이 `:noproc`·`:normal` exit로 끝나면, 호출 함수(`Archon.Runtime` 안)는 활성화를 한 번 더 시도한다.
- **읽기는 저장소에서 한다.** `GET /api/workflow/{id}`, `GET /api/tasks/{taskId}`에 해당하는 조회는 프로세스를 거치지
  않고 저장소를 읽는다. 프로세스는 응답 전에 저장을 마치므로(결정 2의 write-through) 호출자는 자기가 일으킨 변경을
  읽는다. 끝난 워크플로우를 읽으려고 프로세스를 띄우지 않는다.
- **수명.** 프로세스는 처리한 메시지가 워크플로우를 종료 상태로 바꿨을 때, 응답과 Effect까지 마친 뒤 `:normal`로
  끝난다. 이미 종료 상태인 워크플로우로 활성화된 프로세스는 `handle_continue`의 복구 검사에서 decide·종료를 하지 않고(실패 워크플로우 재시작 검사,
  결정 8 (a)는 한다. `CANCELED`인
  SUB_WORKFLOW 태스크의 자식(태스크의 `subWorkflowId`, 없으면 결정적 ID)이 아직 끝나지 않았으면
  `{:cancel_by_parent, reason}`을 다시 보내는 검사도 한다. 완료·종료 Commit
  뒤 자식 종료 요청 전에 죽은 부모가 `:transient` 재시작으로 다시 뜰 때 이 검사가 남은 자식을 정리한다. 일시정지된 자식처럼
  스스로 깨어나지 않는 자식도 이렇게 정리된다),
  활성화를 일으킨 요청(이미 `FAILED`인 워크플로우의 종료 요청, 재시도, 재시작 등)을 처리한다. 그 요청 뒤에도 종료
  상태면 끝나고, 실행 상태가 되었으면 계속 산다. 요청이 오지 않으면 짧은 유휴 시간(설정값) 뒤 끝난다. 오래 기다리는(WAIT, 사람 대기) 프로세스는 일정 시간
  메시지가 없으면 hibernate한다.
- **프로세스 사이 호출 방향.** 워크플로우 프로세스끼리는 부모 → 자식 방향만 `GenServer.call`을 쓰고(자식 종료 요청),
  자식 → 부모 알림은 `cast`다. 결정 9의 `updateAndPushParents`처럼 자식에서 부모 쪽으로 가는 일도 `cast`다. 서로를
  동기 호출하는 고리가 없으므로 교착이 생기지 않는다.
- **예외 격리.** `WorkflowServer`는 `Step.run`과 Effect 실행에서 나는 예외를 잡는다. 잡으면 마지막으로 저장한 상태를
  그대로 두고, 오류를 기록하고, 호출자에게 `{:error, reason}`으로 답하고, `workflowOffsetTimeout`(30초) 뒤 `:recover`로
  다시 시도한다(활성화 복구와 같은 검사이므로 실패한 Effect가 빠뜨린 큐 메시지도 메운다). upstream에서 decide 예외가 로그로 남고 스위퍼가 나중에 다시 시도하는 것과 같다. 프로세스 재시작은
  잡지 못한 exit에만 일어나므로, 한 워크플로우가 계속 실패해도 supervisor 재시작 한도를 넘겨 다른 워크플로우를
  내리지 않는다.
- **노드는 하나다.** Phase 3는 단일 노드에서 정합성을 보장한다. upstream 기본 서버 설정(`LocalOnlyLock`)도 같다.
  여러 노드에서 한 워크플로우의 프로세스를 하나로 유지하는 방법(Postgres advisory lock, 분산 레지스트리 등)은
  Phase 4 이후 별도 ADR에서 정한다.

### 2. 런타임은 순수한 단계 함수(`Archon.Runtime.Step`)와 그것을 실행하는 프로세스로 나눈다

Decider를 순수 함수로 둔 이유(ADR 0014 결정 1)를 런타임에도 적용한다. upstream `WorkflowExecutorOps`가 하는
결정은 `Archon.Runtime.Step`(순수 함수)이 하고, `WorkflowServer`는 그 결과를 실행한다.

```elixir
@spec Step.run(Workflow.t() | nil, Step.Event.t(), Step.Env.t()) ::
        {reply :: term(), Workflow.t(), pre :: [Step.Effect.t()], Archon.Runtime.Commit.t(),
         post :: [Step.Effect.t()]}
```

- `Event`는 프로세스가 받은 일이다: `{:start, input}`, `{:poll, task_id, worker_id}`, `{:update, TaskResult}`,
  `:wake`(타이머), `{:child_changed, task_id, child}`, `{:terminate, reason}`, `{:cancel_by_parent, reason}`·`{:sub_workflow_started, task_id, result}`(결정 5), 복구 검사 `:recover`(활성화 직후와 예외 격리 뒤.
  상태를 바꾸지 않은 `:wake`도 같은 검사를 한다), 그리고 결정 9의 생명주기 요청.
  (3b 갱신) 하위 워크플로우의 멱등 시작은 `{:start_idempotent, workflow}`로 따로 둔다. 기록을 만들기만 하고 decide하지 않으며,
  기록이 있으면 결정 5의 소유자 확인 결과로 답한다. 첫 decide는 이어서 보내는 `:wake`가 한다. 실패 워크플로우 시작이
  실패한 결과는 `{:failure_workflow_started, {:error, reason}}`로 되먹인다(결정 8 (a)). `{:start, workflow}`·`{:start_idempotent, workflow}`의
  `workflow`는 호출자가 만든 새 인스턴스(upstream `createWorkflowModel`)다.
- `Env`는 바깥 값이다: `now`, `new_id`, `jitter`, `evaluate_script`, 태스크 정의, 최신 워크플로우 버전, 도메인별
  마지막 poll 시각(`getActiveDomain`용), 태스크 정의별 진행 중 개수(동시 실행 한도용), 큐에 메시지가 있는지(복구용),
  설정값. Decider `Context`는 `Env`에서 만든다. `WorkflowServer`가 이벤트마다 저장소·큐·메타데이터를 읽어 채운다.
  (3b 갱신) `Env.workflows`는 `Step`이 읽는 다른 워크플로우(진행 중 SUB_WORKFLOW의 자식, 부모, 실패 워크플로우)를 ID로
  담는다. 값이 `nil`이면 저장소에 없다는 뜻이고, 키가 없으면 읽지 않았다는 뜻이라 그 값이 필요한 검사를 건너뛴다. 3e가
  자식을 읽어 채우면 `:wake`·`:recover`의 자식 반영(결정 5의 30초 재평가)이 동작한다.
  (3c 갱신) `Env`는 `WorkflowServer`가 이벤트마다 채운다. `task_defs`는 정의를 박아 넣지 않은 태스크 이름, `latest_workflow_versions`는
  버전이 없는 SUB_WORKFLOW 이름, `poll_data`는 `taskToDomain`이 있을 때 워커 태스크 타입 × 그 도메인, `in_progress`는
  `concurrentExecLimit`이 있는 태스크 정의마다 읽는다. `queued`와 `workflows`(부모, `IN_PROGRESS`·`CANCELED` SUB_WORKFLOW의 자식,
  출력의 실패 워크플로우)는 그것을 읽는 `:wake`·`:recover`에서만 읽는다. 그래서 3e는 `WorkflowServer`를 고치지 않는다.
- `reply`는 호출자에게 돌려줄 값이다: 시작한 workflowId, poll로 내줄 태스크(건너뛰면 `nil`), 갱신한 태스크,
  `{:error, :conflict | :not_found | ...}`.
- 반환하는 `Workflow`는 **저장한 뒤의 상태**다. upstream이 메모리에서만 바꾸고 저장하지 않은 값은 넣지 않는다
  (예: 완료 시 Decider가 `executed: true`로 바꾼 태스크는 저장하지 않으므로 `executed: false`로 남는다. ADR 0014 결과).
- `Commit`은 한 번에 원자적으로 저장할 변경이다. 필드는 `create :: Workflow.t() | nil`(새 워크플로우, 태스크 포함),
  `workflow :: Workflow.t() | nil`(바뀐 워크플로우, `tasks` 필드는 무시), `upsert_tasks :: [Task.t()]`,
  `delete_task_ids :: [String.t()]`(DO_WHILE `keepLastN`) 네 개다. 저장소 경계의 타입이므로 `Archon.Runtime.Commit`으로 두고 3a에서 정의한다.
  upstream `ExecutionDAOFacade`가 저장할 때 찍는 시각(워크플로우 `updatedTime`과 종료 상태의 `endTime`, 태스크
  `updateTime`과 종료 시 비어 있는 `endTime`)은 `Step`이 `Commit`을 만들 때 `Env.now`로 찍는다. 저장소 구현은 시각을
  다시 찍지 않는다. (3b 갱신) 새 태스크의 `scheduledTime`도 upstream DAO의 `createTasks`(`SqliteExecutionDAO`)처럼
  `Step`이 지금 시각으로 찍는다. Decider가 재시도 태스크에 0을 넣으므로, 찍지 않으면 poll 타임아웃이 바로 발화한다.
- `Effect`는 바깥에 하는 일이다: 태스크 큐 push(지연 포함)·remove·postpone·ack, 하위 워크플로우 시작·종료 요청,
  부모 알림, 실패 워크플로우 시작, 다음 재평가 타이머(`{:wake_at, ms}`). 대부분은 저장 뒤에 실행하는 `post`이고,
  `pre`는 Commit 전에 끝나야 하는 일이다. 지금 `pre`에 들어가는 것은 종료 처리의 자식 종료 요청뿐이다(결정 8).
  (3b 갱신) decide하지 않은 이벤트가 타이머를 당기기만 하는 일(결정 6)은 `{:wake_before, ms}`다. ack는 poll한 묶음 전체를
  아는 `Archon.Runtime.Tasks`(3d)가 하므로 `Step`의 Effect가 아니다. poll한 태스크가 워크플로우에 없으면 `Step`은
  `{:error, :not_found}`로 답하고, 그 큐 메시지는 호출자가 지운다.

`WorkflowServer`는 `Step.run`을 부르고, `pre`를 순서대로 실행하고, `Commit`을 저장소에 쓰고(write-through), 그다음
`post`를 순서대로 실행한 뒤 `reply`로 응답한다. `pre`가 하나라도 실패하면 아무것도 Commit하지 않고 결정 1의 예외 격리
규칙으로 처리한다. post Effect의 결과가 상태를 바꿔야 하면(지금은 하위 워크플로우 시작뿐, 결정 5) `WorkflowServer`가 같은
메시지 처리 안에서 그 결과를 이벤트로 `Step.run`에 다시 넣고 같은 순서(pre → Commit → post)를 한 번 더 돈 뒤 응답한다.
이 되먹임 횟수에도 결정 4의 반복 상한이 적용된다. JOIN 평가처럼 한 이벤트가 이어서 일으키는 일은 같은 `Step.run` 안에서 끝낸다. 자기 자신에게
메시지를 보내 나중에 처리하지 않으므로, 응답을 받은 호출자가 읽는 저장소 상태에 그 결과가 이미 들어 있다. 예외는 최상위 `{:start}`의 하위 워크플로우 시작으로, 응답 뒤
`{:continue, ...}`에서 한다(결정 1). 호출자가 이미 ID를 받았으므로 그 continue의 예외는 기록 삭제가 아니라 일반 예외 격리를
따른다.

Effect를 실행하다 프로세스가 죽거나 Effect가 실패하면 다음 규칙으로 메운다.

- 워커 큐 Effect: 결정 7의 복구 검사(활성화 직후, 예외 격리 뒤의 `:recover`, 그리고 상태를 바꾸지 않은 `:wake`)가
  큐에 없는 `SCHEDULED` 태스크를 다시 넣는다. upstream도 `createTasks` 뒤
  `addTaskToQueue` 실패를 스위퍼 복구에 맡긴다. (3c 갱신) 그래서 `post`의 큐 push 실패는 시작뿐 아니라 어느 이벤트에서도 기록하고
  넘어가며 예외 격리로 보내지 않는다. 다른 Effect의 실패는 예외 격리다.
- 하위 워크플로우 종료 Effect: 결정 8의 종료 순서가 "자식 종료(`pre`) 먼저, 부모 Commit 나중"이라 부모가 종료 상태로
  저장되었으면 자식 종료는 이미 끝났다. 완료 경로는 upstream처럼 완료 뒤에 남은 태스크를 취소하지만, 취소한 태스크
  상태(`CANCELED`)는 완료와 같은 Commit에 넣고 자식 종료 요청만 `post`로 보낸다. 그래서 Commit 뒤 자식 종료 전에 죽어도
  부모 태스크는 이미 `CANCELED`이고, 자식의 복구 검사는 부모가 종료 상태이고 자기 부모 태스크가 `CANCELED`이면 스스로
  종료한다. `parentWorkflowId`가 있는데 그 기록이 저장소에 없을 때도(시작 실패로 지워진 경우) 스스로 종료한다.
- 실패 워크플로우 시작 Effect: 결정 8 (a).
- 부모 알림 Effect: 부모의 30초 재평가(결정 5)가 저장소에서 자식을 읽어 메운다.

이렇게 나누면 `decider_replay.ex`가 흉내 내던 규칙이 `Step`의 제품 코드가 되고, 프로세스 없이도 같은 규칙을
시험할 수 있다(결정 10).

### 3. 저장소·큐·메타데이터는 behaviour로 두고 Phase 3는 메모리 구현을 쓴다

Phase 4가 갈아 끼울 경계를 지금 정한다. behaviour는 MVP 런타임이 쓰는 연산만 담고, Phase 4가 연산을 더할 때는
그 ADR에 적는다.

**`Archon.Runtime.Store`** (upstream `ExecutionDAOFacade`의 MVP 부분)

| 콜백 | 의미 |
|---|---|
| `commit(workflow_id, Commit.t())` | 결정 2의 변경을 원자적으로 적용. 새 워크플로우인데 같은 ID가 있으면 `{:error, :conflict}` |
| `get_workflow(id, include_tasks?)` | 없으면 `{:error, :not_found}` |
| `get_task(task_id)` | 태스크와 소속 워크플로우 ID |
| `running_workflow_ids()` | 종료 상태가 아닌 워크플로우 ID(결정 7의 복구용) |
| `remove_workflow(id)` | 워크플로우와 그 태스크 삭제(시작 실패 정리용, 큐 메시지는 `WorkflowServer`가 지운다). 지운 뒤 `get_workflow`·`get_task`는 `:not_found`, `running_workflow_ids`에서 빠진다 |
| `in_progress_count(task_def_name)` | 진행 중 태스크 수(동시 실행 한도용, upstream `getInProgressTaskCount`) |
| `put_poll_data(task_type, domain, worker_id, now)`·`get_poll_data(task_type, domain)` | `PollData`(도메인 선택용) |

- 저장 형식은 ADR 0014 결정 3의 내부 필드(`wire: false`)를 포함한다. 메모리 구현은 struct를 그대로 담는다.
  Phase 4가 저장용 인코딩을 정한다.
- 저장소 안의 상태는 항상 "어떤 `Commit`까지 반영한 상태"다. 부분 반영이 없다.

**`Archon.Runtime.Queue`** (upstream `QueueDAO`의 MVP 부분, 의미는 기본 서버의 `SqliteQueueDAO`)

| 콜백 | 의미 |
|---|---|
| `push(queue, id, priority, delay_ms)` | 메시지 ID는 큐 안에서 유일하다. 같은 ID가 있으면 보일 시각을 새 지연으로 바꾸고 꺼낸 표시를 지운다(`SqliteQueueDAO#pushMessage`의 `ON CONFLICT ... DO UPDATE`) |
| `pop(queue, count, timeout_ms)` | 보이는 메시지를 우선순위 높은 순, 같으면 보일 시각 순으로 최대 `count`개 꺼낸다. 없으면 `timeout_ms`까지 기다린다. 꺼낸 메시지는 ack되지 않으면 unack 타임아웃(기본 60초) 뒤 다시 보인다 |
| `ack(queue, id)`·`remove(queue, id)` | 메시지 삭제 |
| `postpone(queue, id, priority, delay_ms)` | 다시 넣으며 지연을 바꾼다 |
| `contains?(queue, id)` | 복구 검사 |
| `size(queue)` | 관리·시험용 |

- 큐 이름은 upstream `QueueUtils.getQueueName`에서 실행 네임스페이스와 격리 그룹을 뺀 `[domain:]taskType`이다.
- 큐에는 **워커가 poll하는 태스크(SIMPLE 등 시스템 태스크가 아닌 것)만** 들어간다. upstream의 decider 큐와 시스템
  태스크 큐는 두지 않는다(결정 4, 6).
- 메모리 구현은 GenServer 하나가 큐별 정렬 집합과 지연·unack 타이머를 가진다. `pop`의 대기는 응답을 미루는 방식으로 한다.

**`Archon.Runtime.Metadata`** (upstream `MetadataDAO`의 MVP 부분): 워크플로우 정의 등록·조회(이름·버전, 최신 버전),
태스크 정의 등록·조회. 런타임은 시작 때 정의를 찾고(`MetadataMapperService.lookupForWorkflowDefinition`), 태스크
정의를 박아 넣고(`populateTaskDefinitions`), 이벤트마다 `Env`의 태스크 정의와 최신 버전을 채운다. Phase 5 메타데이터
REST도 이 behaviour를 쓴다.

behaviour마다 공통 계약 시험(결정 10)을 두어 Phase 4 구현이 같은 시험을 통과하게 한다.

### 4. decide 루프, 저장 규칙, 시스템 태스크 실행

`Step`의 decide 루프는 upstream `WorkflowExecutorOps#decide(WorkflowModel)`를 옮긴다.

1. 워크플로우가 종료 상태면 끝낸다(성공이 아니면 남은 태스크를 취소한다).
2. 바뀐 SUB_WORKFLOW 태스크(`subworkflowChanged`)가 있으면 그 표시를 지우고 실패한 JOIN을 `IN_PROGRESS`로 되돌린다
   (`adjustStateIfSubWorkflowChanged`, 결정 9의 재시도와 함께 구현).
3. `Decider.decide/2`를 부른다.
   - `complete?`면 `endExecution`: `terminate_task`가 있으면 그 입력의 `terminationStatus`로 `FAILED`·`TERMINATED`면
     결정 8 (a)로 종료, 아니면 완료. TERMINATE 태스크로 완료하면 `reasonForIncompletion`에 그 입력의 `terminationReason`을,
     비어 있으면 upstream 문구 `Workflow is <terminationStatus> by TERMINATE task: <taskId>`를 넣는다(결정 8 (a)의 사유도 같다). 완료는 upstream `completeWorkflow`처럼 `Archon.Decider.Retry.update_output/2`로 다시 계산한 출력(3b 갱신), `COMPLETED`, `endTime`, 실패 태스크 이름 집합을
     저장한다. 끝난 태스크(Decider가 `executed` 등을 바꾼 것)는 저장하지 않고, 끝나지 않은 태스크만 `CANCELED`로 바꿔
     같은 Commit에 넣는다(upstream `cancelNonTerminalTasks`). 자식 종료 요청은 `post`다.
   - `{:terminate, termination, outcome}`이면 결정 8 (a).
4. 새 태스크에 도메인을 매긴다(`setTaskDomains`: 시스템 태스크 제외, `*` 뒤 태스크 타입 키로 덮어쓰기,
   `getActiveDomain`은 `activeWorkerLastPollTimeout` 10초 안에 poll된 첫 도메인, 없으면 마지막 값, `NO_DOMAIN`이면 없음).
5. 참조명·`retryCount`가 이미 있는 태스크를 빼고(`dedupAndAddTasks`) 더한다. `seq`(0일 때만)와
   `firstScheduledTime`(0일 때만)을 매기고, 끝나지 않은 시스템 태스크의 `startTime`이 0이면 지금 시각을 넣는다.
6. 동기 시스템 태스크(SWITCH·DECISION·FORK·DO_WHILE)는 그 자리에서 `start`·`execute`하고(`SystemTask.execute/3`,
   `SystemTask.DoWhile.execute/3`), DO_WHILE이 돌려준 다음 반복 태스크도 4·5를 거쳐 더하고 `keepLastN`이 뺀 태스크를
   지운다. 비동기 시스템 태스크(JOIN·WAIT·SUB_WORKFLOW)는 결정 5·6, 워커 태스크는 큐 push Effect다. 지연은
   `callbackAfterMs`, 없으면 `callbackAfterSeconds`다(재시도 지연이 여기로 온다).
7. `tasks_to_be_updated`와 새 태스크를 `Commit`에 담는다. 동기 시스템 태스크를 새로 시작했거나 `execute`가 참을
   돌려줬으면 3으로 돌아간다.
8. 끝나지 않았으면 다음 재평가 시각을 계산해 `{:wake_at, ms}` Effect를 낸다(결정 6).

`Step`은 한 이벤트 안에서 decide 루프를 최대 반복 횟수(설정값, 기본 100회)까지만 돈다. 넘으면 그때까지를 저장하고
자기 자신에게 `:wake`를 바로 보내 끝낸다(결정 6의 최소 1초 규칙의 예외). 그 사이에 쌓인 종료 요청 같은 메시지가 먼저 처리된다. upstream의 lease 보호(`lockLeaseTime
− 100ms`)는 락이 없으므로 시간 대신 횟수로 바꾼다. 런타임 API의 `GenServer.call` 타임아웃은 결정 7에 적는다.

upstream의 스키마 검증(`enforceSchema`, `rejectTasksFailingInputSchema`, `validateSystemTaskOutput`, `completeWorkflow`의
출력 검증)은 JSON Schema 검증기를 들일 때 붙인다. 결과 섹션의 조건을 본다.

### 5. 하위 워크플로우

- **시작.** SUB_WORKFLOW 태스크가 예약되면(`startDelay`가 있으면 그 지연 뒤, 결정 6) 부모 프로세스가 upstream `SubWorkflow.start`를 따른다. 자식 ID는 upstream과
  같은 이름 기반 UUID(`nameUUIDFromBytes("subworkflow:<부모ID>:<태스크ID>:<retryCount>")`, UUID v3)이고, 입력은
  `parentWorkflowId`, `parentWorkflowTaskId`, `taskToDomain`(부모 것 또는 `subWorkflowTaskToDomain`), `priority`,
  `correlationId`, 해석한 하위 워크플로우 정의·입력이다. 자식 생성은 `Archon.Runtime.start_workflow_idempotent/1`
  (upstream `startWorkflowIdempotent`)로 하며 멱등이다. 같은 ID가 이미 있으면 부모 ID·부모 태스크
  ID가 같은지 확인하고(다르면 upstream `validateIdempotentWorkflowOwnership`의 오류 문구) 그것을 쓰며, 그것이 성공이 아닌
  종료 상태(`FAILED`·`TIMED_OUT`·`TERMINATED`)로 끝나 있으면 새 무작위 ID로 다시 시작한다. 이 대체 ID는 시작 Effect가 만들지
  않는다. 시작 결과가 "기존 자식이 실패로 끝남"이면 `Step`이 `Env.new_id`로 대체 ID를 만들어 태스크의 `subWorkflowId`에 넣어
  (상태는 `SCHEDULED` 그대로) 먼저 Commit하고, 그 ID로 다시 멱등 시작한다. 자식의 첫 decide는 자식
  프로세스가 기록을 만들고 답한 뒤 `{:continue, ...}`로 한다(결정 1의 활성화, upstream은 decider 큐에 우선순위 10으로 넣는다). 부모는 자식 기록 생성까지만
  기다린다. 시작이 일시적 오류면 태스크는 `SCHEDULED`로 남고 이유와 출력 `subWorkflowLaunchError`를 남겨 다음 재평가에서
  다시 시도하고, 그 밖의 오류면 `FAILED`다(upstream `start`의 예외 처리).
- **시작 결과 기록.** 자식 시작은 부모 Commit 뒤의 `post` Effect이므로 그 결과(실제 자식 ID와 상태, 또는 오류)는 같은
  메시지 처리 안에서 `{:sub_workflow_started, task_id, result}` 이벤트로 `Step.run`에 다시 넣어 두 번째 Commit으로 저장한
  뒤 응답한다. 저장 내용은 upstream `attachToSubWorkflow`와 같다: `subWorkflowId`와 출력 `subWorkflowId`(무작위 ID로 다시
  시작했으면 그 ID), `reasonForIncompletion`·`subWorkflowLaunchError` 지우기, 자식 상태에 따른 태스크 상태(`updateTaskStatus`). 그 뒤 태스크가 `SCHEDULED`가 아니면 decide한다(upstream
  `AsyncSystemTaskExecutor`가 `start` 뒤에 하는 일. 이미 끝난 자식에 붙어 태스크가 끝나는 경우가 있다).
  Commit 사이에 프로세스가 죽으면 태스크는 `SCHEDULED`로 남는다. 복구 검사는 태스크에 `subWorkflowId`가 있으면 그 ID로,
  없으면 결정적 ID로 시작을 다시 해서(멱등) 이미 만든 자식에 붙는다. 대체 ID가 시작 전에 저장되므로 대체 자식이 둘
  생기지 않는다.
- **진행 반영.** 자식이 종료 상태가 되면 자식 프로세스가 부모에게 `{:child_changed, task_id, child}`를 `cast`한다.
  부모는 그 태스크가 아직 자기 태스크 목록에 있고 지금 그 자식에 붙어 있는지 확인하고(upstream의 세대 펜스. upstream은 태스크의 `subWorkflowId`로 자식을 읽는다. 3b 갱신), `SystemTask.SubWorkflow.execute/2`로
  상태·출력·실패 이유를 반영한 뒤 진행 중 JOIN을 평가하고 decide한다. 알림이 사라질 경우(부모 재시작 등)에 대비해 부모는
  진행 중 SUB_WORKFLOW가 있으면 `workflowOffsetTimeout`(30초)마다 저장소에서 자식을 읽는다(upstream `computePostpone`의
  활성 하위 워크플로우 규칙과 같은 간격).
- **취소.** 부모가 종료되면 남은 SUB_WORKFLOW 태스크마다 자식 프로세스에 `{:cancel_by_parent, reason}`을 `call`한다
  (upstream `SubWorkflow.cancel`). 이 이벤트는 결정 8 (b)와 달리 자식 상태와 관계없이(`COMPLETED`여도) `TERMINATED`로
  바꾸고, 사유는 upstream 문구 그대로이며, 실패 워크플로우를 띄우지 않는다. 이미 `TERMINATED`면 아무것도 하지 않는다.
  자식이 아직 없으면(시작 지연 중이거나 시작이 일시적 오류로 실패한 경우) 활성화가 `:not_found`를 돌려주는데, 이것은 취소
  성공으로 본다(upstream `SubWorkflow.cancel`도 자식이 없으면 그냥 돌아간다). 부모 태스크는 `CANCELED`가 되고 부모 종료는
  막히지 않는다. (3b 갱신) 같은 이벤트 안에서 자식 시작을 요청한 뒤 부모가 종료되면(시작 지연이 끝나는 `:wake`에 워크플로우 타임아웃이 함께 오는 경우) `Step`은 그 시작 Effect를 버린다. 자식 종료 요청은 Commit 전에 이미 실행되므로, 시작이 뒤에 오면 자식이 남는다. 자식은 부모를 동기 호출하지 않으므로 교착이 없다. 이 `call`의 타임아웃은 `:infinity`가 아니라
  설정값(기본 30초)이고, 시간이 넘으면 결정 1의 예외 격리 규칙으로 부모 종료를 실패로 처리한다. Decider 종료(결정 8 (a))는 다음 decide에서
  같은 종료가 다시 나오므로 다시 시도되고, 종료 요청(결정 8 (b))은 호출자가 오류를 받고 끝난다(upstream도 같다).
- **실패 워크플로우.** 결정 8 (a).
- **(3e 갱신) 시작 오류의 분류.** upstream `SubWorkflow.start`는 `TransientException`(저장소 장애)이면 태스크를 `SCHEDULED`로
  두고 그 밖의 예외면 `FAILED`로 만든다. `Archon.Runtime.SubWorkflows.start_child/1`은 `start_workflow_idempotent/1`의 오류를
  이렇게 나눈다. 워크플로우를 만들기 전의 거절(정의 없음 `{:not_found, …}`, `nil` 입력 `{:invalid, …}`, 정의 없는
  SUB_WORKFLOW `{:terminate, …}`, 다른 부모의 자식이라는 소유자 확인 문구)과 자식이 시작을 처리하다 낸 예외는 그 문구로
  `FAILED`다. 나머지(자식 프로세스 활성화 실패, 호출 타임아웃·종료, 자식 Commit 실패)는 저장소 장애에 해당하므로 일시적
  오류이고, 태스크의 지연(`callbackAfterSeconds`)이 지난 다음 `:wake`에서 다시 시작한다. 워커가 준 `subWorkflowId`가 부모
  자신의 ID면(결과 절의 신뢰 결정) 자기 프로세스를 호출할 수 없으므로 upstream 소유자 확인과 같은 문구로 `FAILED`다.
  자식이 붙은 뒤 워커가 그 ID를 부모 자신으로 바꾼 경우, 부모 종료의 자식 종료 요청은 자기 자신이 대상이라 호출하지 않고
  성공으로 본다(upstream은 같은 워크플로우를 다시 종료하므로 결과가 같다). 그 ID가 부모의 조상이면 동기 호출은 교착이다
  (조상의 취소가 다시 이 부모를 호출한다). 그래서 저장소의 부모 사슬로 조상인지 보고, 조상이면 별도 프로세스에서 취소를
  보내고 성공으로 본다. 부모가 Commit한 뒤 조상의 호출이 오면 이미 `TERMINATED`라 바로 답한다. upstream처럼 그 ID의
  워크플로우는 종료되지만 "자식 종료가 부모 Commit보다 먼저"라는 순서는 이 경우에만 지키지 않는다. 두 경우 모두 원래
  자식은 바로 종료되지 않고, 복구 검사(부모가 종료 상태이고 자기 부모 태스크가 `CANCELED`)가 나중에 끝낸다. 남은 한계:
  워커가 준 ID들이 조상 사슬이 아닌 순환(P→X→P처럼 관계없는 워크플로우끼리)을 이루면, 그중 하나를 종료할 때 호출
  타임아웃까지 기다리고 다시 시도한다. 워커 갱신이 둘 이상 위조되어야 하는 경우라 신뢰 결정의 범위로 둔다. 별도 프로세스의
  취소는 감독되지 않는다(`supervisor.ex`를 고칠 수 있는 3f나 Phase 4에서 `Task.Supervisor`로 옮긴다). 그 사이 VM이 죽으면
  복구 검사가 `CANCELED` 태스크의 대상을 다시 종료한다.
  알려진 한계: `WorkflowServer`는 자식이 시작을 처리하기 전의 저장소·메타데이터 읽기(`env/2`)와 `Step` 실행을 같은 예외
  격리로 감싸므로, 저장소 구현이 장애를 예외(`raise`)로 알리면 그 예외는 `Step` 버그와 구별되지 않아 `FAILED`로 분류된다.
  메모리 구현은 GenServer라 장애가 exit(일시적 오류)로 오므로 지금은 생기지 않는다. Phase 4 저장소는 장애를 exit나 오류
  반환으로 알리거나, `WorkflowServer`가 `env/2` 단계의 실패에 표지를 붙여 일시적 오류로 넘기도록 그때 고친다(3e는
  `workflow_server.ex`를 고치지 않는다).
- **(3e 갱신) 부모 알림.** 자식의 부모 알림 Effect는 부모 태스크 ID가 없거나 부모를 활성화하지 못하면(부모 기록 없음 등)
  기록만 남기고 성공으로 끝낸다. 알림이 사라져도 부모의 30초 재평가가 저장소에서 자식을 읽어 메우므로, 자식의 Effect를
  실패로 만들 이유가 없다.

### 6. 타이머와 재평가

upstream의 decider 큐와 스위퍼, 시스템 태스크 큐의 지연 재평가를 **워크플로우 프로세스의 타이머 하나**로 대신한다.

- 프로세스는 `Process.send_after`로 `:wake` 타이머를 하나만 가진다. 시각은 `Step`이 정한다. decide를 한 이벤트는 그
  결과로 시각을 새로 정하고, decide를 하지 않은 이벤트(`isLazyEvaluateWorkflow`로 건너뛴 갱신, poll 등)는 지금보다 이른
  시각으로 당기기만 한다. 그래야 관계없는 갱신이 계속 들어와도 타임아웃 판정이 미뤄지지 않는다(upstream decider 큐 메시지는
  decide만 다시 정하고, poll은 `setUnackTimeoutIfShorter`로 당기기만 한다).
- 시각은 다음 후보 중 가장 이른 것이다. 후보는 ms 단위로 계산하고 지금보다 최소 1초 뒤로 둔다(upstream
  `Wait.getEvaluationOffset`이 0을 1로 올리는 것과 같은 이유로, 마감 직전에 `:wake`가 연달아 발화하지 않게 한다).
  - upstream `ExecutorUtils.computePostpone`의 후보(맥락의 목록 그대로, 상한 3600초, 후보가 없으면 30초).
  - 재시도 대기 중인 워커 태스크(`callbackAfterMs`)는 워커 큐 지연으로 처리하므로 후보가 아니다. 지연이 끝나면 큐에서
    보인다.
  - 예약될 때 지연(`callbackAfterMs`, 없으면 `callbackAfterSeconds`)이 있는 비동기 시스템 태스크는 `scheduledTime + 지연`
    전에는 어떤 계기(`:wake`, 사건)로도 평가하지 않고, 그 시각이 후보다. 지연이 끝난 뒤 첫 평가는 `SCHEDULED`면 `start`,
    아니면 `execute`다(WAIT은 처음부터 `IN_PROGRESS`라 `execute`). upstream은 그 지연을 걸어 시스템 태스크 큐에 넣는다. SUB_WORKFLOW
    매퍼가 `startDelay`를 `callbackAfterSeconds`에 넣으므로 하위 워크플로우 시작이 그만큼 늦어진다.
- upstream은 `computePostpone`이 30초와 다를 때만 decider 큐의 unack 타임아웃을 바꾸지만 Archon은 매번 새 시각으로
  바꾼다. 결과가 같은 시각이면 같은 일이다.
- **워커 poll도 타이머를 당긴다.** poll로 태스크가 `IN_PROGRESS`가 되면 응답 타임아웃(태스크 정의 값, 0이면 태스크 값)이
  있을 때 `now + 응답 타임아웃`이 지금 타이머보다 이르면 그 시각으로 당긴다(upstream `adjustDeciderQueuePostpone`).
- `:wake`를 받으면 지연이 끝난 `SCHEDULED` 비동기 시스템 태스크를 `start`하고, 진행 중 WAIT과 JOIN을 평가하고 decide한다. 그 결과 아무 태스크 상태도 바뀌지 않았으면 결정 7의 복구
  검사를 한다(upstream 스위퍼가 상태 변화 없는 sweep마다 repair하는 것과 같다). Decider의 타임아웃 판정(워크플로우·태스크·poll·응답·
  전체 타임아웃, ADR 0014)은 이 decide에서 발화한다.
- **비동기 시스템 태스크의 평가 시점.** 프로세스 밖에서 상태가 바뀌는 일이 없으므로 시간 기반 반복 poll 대신 사건으로
  평가한다.
  - JOIN: 예약된 직후, `joinOn`의 태스크를 종료 상태로 만드는 모든 `Commit` 직후(워커 갱신, `isLazyEvaluateWorkflow`로
    decide를 건너뛴 갱신, Decider의 타임아웃·재시도 표시, 하위 워크플로우 진행 반영, 종료 처리 포함), 그리고 `:wake`.
    평가할 때마다 `pollCount + 1`이다. 끝나면 `endTime`을 찍고 decide한다(upstream `AsyncSystemTaskExecutor`). 이 규칙으로
    `workflow_get_completed_fork`의 JOIN `pollCount` 3(예약 직후, 가지 둘)이 나온다.
  - WAIT: `:wake`. WAIT 매퍼(ADR 0014 2d)는 태스크를 처음부터 `IN_PROGRESS`와 `waitTimeout`으로 만들므로 재평가 시각은
    `computePostpone`의 진행 중 WAIT 후보(마감 시각)다. 외부 완료는 태스크 갱신(결정 7의 `update`)이다.
  - SUB_WORKFLOW: 결정 5. 시작은 위 지연 규칙을 따른다.
  - 평가 전 검사는 upstream `AsyncSystemTaskExecutor#execute`를 따른다(태스크가 끝났으면 무시, 워크플로우가 끝났으면
    `CANCELED`, `SCHEDULED`이면 `startTime`을 찍고 `start`). 끝나지 않은 JOIN·WAIT의 `callbackAfterSeconds`는 upstream처럼
    `getEvaluationOffset` 값(JOIN은 위 공식, WAIT은 남은 초)으로 저장한다. GET 응답에 보이는 값이다.
- 프로세스가 죽으면 타이머도 사라진다. 다시 뜬 프로세스는 `handle_continue`에서 복구하고 decide한 뒤 타이머를 새로
  건다(결정 7).

### 7. 워커 연동 API, 재시작과 크래시 복구

**런타임 API**는 `Archon.Runtime`(워크플로우)과 `Archon.Runtime.Tasks`(워커)다. Phase 5 REST 컨트롤러는 이 함수만
부른다.

| 함수 | upstream | 비고 |
|---|---|---|
| `Archon.Runtime.start_workflow(input)` | `startWorkflow` | 호출자 쪽에서 정의 확인, 태스크 정의 박아 넣기, 입력 `null` 검사(문구 그대로), workflowId 생성. 그 ID로 프로세스를 띄워 `{:start, input}`을 보내면 프로세스가 기록을 만들고 첫 decide까지 하고 답한다. workflowId를 돌려준다. (3c 갱신) 정의가 없으면 `{:error, {:not_found, 문구}}`, 입력이 `nil`이면 `{:error, {:invalid, 문구}}`, 버전 없는 SUB_WORKFLOW의 정의가 없으면 upstream `populateVersionForSubWorkflow`처럼 `{:error, {:terminate, 문구}}`다 |
| `get_workflow(id, include_tasks?)` | `getExecutionStatus` | 저장소 읽기. `GET /api/workflow/{id}/status` 요약도 이 결과로 만든다 |
| `terminate_workflow(id, reason)` | `terminateWorkflow(String, String)` | 결정 8 (b) |
| `Tasks.poll(task_type, worker_id, domain)` | `getLastPollTask` | (3d 갱신) 한 개, 대기 100ms. `{:ok, task}`, 없으면 `{:ok, nil}`(REST 204) |
| `Tasks.batch_poll(task_type, worker_id, domain, count, timeout_ms)` | `ExecutionService#poll` | 결정 3의 큐에서 꺼내 태스크마다 소유 프로세스에 `{:poll, ...}`를 보낸다. `{:ok, [task]}`, `timeout_ms`가 5000을 넘으면 `{:error, {:invalid, "Long Poll Timeout value cannot be more than 5 seconds"}}` |
| `Tasks.update(task_result)` | `WorkflowExecutorOps#updateTask` | `workflowInstanceId`의 프로세스로 보낸다. (3d 갱신) `{:ok, task}`, `extendLease`면 `{:ok, nil}`, 워크플로우·태스크가 없거나 `workflowInstanceId`가 비면 `{:error, :not_found}` |
| `Tasks.update_v2(task_result)` | `TaskResource#updateTaskV2` | 갱신한 태스크가 종료 상태면 같은 타입의 다음 태스크를 poll해 돌려주고, 아니면 없음(REST 204). (3d 갱신) 그 poll은 갱신한 태스크의 도메인과 결과의 `workerId`로 한다. `@Valid`처럼 `workflowInstanceId`·`taskId`가 비면 `{:error, {:invalid, errors}}` |
| `Tasks.get(task_id)` | `getTask` | 저장소 읽기. (3d 갱신) `{:ok, task}` 또는 `{:error, :not_found}` |

- `poll`: 큐에서 꺼낸 ID마다 소유 프로세스가 검사한다. 태스크가 없거나 끝났으면 큐에서 지우고 건너뛴다. 동시 실행 한도
  (`concurrentExecLimit`, `Env`의 진행 중 개수)를 넘으면 60초 미룬다. 아니면 `IN_PROGRESS`, `pollCount + 1`, `workerId`,
  `callbackAfterSeconds = 0`, `startTime`(0일 때만), `updateTime`을 저장하고 결정 6대로 타이머를 당긴다. 다 돌면 poll
  데이터를 기록하고(빈 poll도) 내준 메시지를 ack한다. `timeout_ms` 상한 5000은 upstream과 같다. 빈도 한도
  (`rateLimitPerFrequency`)는 upstream 기본 서버처럼 적용하지 않는다.
  (3d 갱신) 꺼낸 ID의 워크플로우는 `Store.get_task`로 찾는다. 저장소에 없거나 소유 프로세스가 `{:error, :not_found}`로 답하면
  큐에서 지운다. 소유 프로세스가 그 밖의 오류로 답하거나 호출이 실패하면(예외 격리, 호출 타임아웃) upstream이 DB 예외에서
  하듯 우선순위 0으로 `task_execution_postpone_ms`(60초) 미뤄 다시 poll되게 한다. poll 데이터 기록 실패는 upstream
  `updateTaskLastPoll`처럼 기록만 하고 넘어간다. ack는 내준 태스크의 큐 이름(`[domain:]taskType`)으로 한다.
- `update`: upstream `updateTask`의 순서를 그대로 따른다(위 "맥락"). 응답 전에 decide까지 마친다. `TaskResult`의
  `extendLease`가 참이면 `updateTime`만 바꾼다.
- **호출 타임아웃.** 런타임 API가 워크플로우 프로세스에 거는 `GenServer.call` 타임아웃은 설정값(기본 30초)이다. 결정 4의
  반복 상한이 한 호출의 일을 제한한다.
- **재시작·크래시 복구.**
  - `WorkflowServer`는 `restart: :transient`다. 결정 1의 예외 격리로 잡지 못한 exit만 재시작으로 이어지고, 다시 뜬
    프로세스는 저장소 상태에서 시작한다. 처리 중이던 메시지는 잃는다. 그 메시지가 저장 전이었으면 호출자는 오류를 받고
    다시 보낼 수 있고, 저장 뒤였으면 결과는 남는다.
  - 활성화 직후 복구(`:recover` 이벤트, upstream 스위퍼의 repair): decide한 뒤에도(3b 갱신. 스위퍼처럼 decide 뒤에 메운다) 큐에 메시지가 없는 `SCHEDULED` 워커 태스크를 다시
    넣고(지연은 저장된 `updateTime`(0이면 `scheduledTime`)에 `callbackAfterMs`, 없으면 `callbackAfterSeconds`를 더한
    시각까지 남은 시간. 워커가 `IN_PROGRESS`와 `callbackAfterSeconds`로 미룬 태스크가 일찍 다시 나가지 않게 한다. upstream
    스위퍼는 `callbackAfterSeconds` 전체를 다시 걸지만 Archon은 남은 시간만 건다), 진행 중 SUB_WORKFLOW의 자식이 이미 끝났으면 반영하고, 부모가 종료 상태이고 자기 부모 태스크가 `CANCELED`이면
    (또는 `parentWorkflowId`가 있는데 그 기록이 없으면) 스스로 종료하고, decide한 뒤 타이머를 건다. 실행 중인데 끝나지 않은 태스크가 없으면 upstream처럼 마지막 태스크를
    미실행으로 되돌려 다시 decide한다.
  - `Archon.Runtime.Recovery`는 애플리케이션 시작 때와 `rest_for_one`으로 다시 뜰 때 `Store.running_workflow_ids/0`의
    워크플로우를 모두 활성화한다. 워크플로우가 많을 때의 지연 활성화(저장소의 다음 재평가 시각으로 필요할 때만 띄우기)는
    Phase 4 ADR에서 정한다.

### 8. 종료 처리와 내부 필드

upstream의 두 종료 경로를 그대로 나눈다. 둘 다 순서는 "남은 태스크 취소(자식 종료 Effect 포함) → 워크플로우 Commit →
큐 정리·부모 알림"이다(upstream `terminateWorkflow`가 `cancelNonTerminalTasks` 뒤에 `updateWorkflow`를 하는 순서).
그래서 `Step`은 종료 이벤트에서 자식 종료 요청을 `pre` Effect로 내고, 취소한 태스크와 워크플로우 상태는 `Commit`에,
큐 정리·부모 알림·실패 워크플로우 시작은 `post`에 담는다(결정 2). `pre`가 실패하면 아무것도 저장하지 않고 다시 시도한다.
완료 경로(결정 4의 3)는 upstream `endExecution`처럼 완료 뒤에 남은 태스크를 취소하므로 자식 종료가 `post`다. 이때도
취소한 태스크 상태는 완료와 같은 Commit에 넣는다(결정 2).

**(a) Decider 종료**(`{:terminate, termination, outcome}`, `FAILED`·`TERMINATED` TERMINATE 태스크). upstream
`terminate(workflow, exception)` → `terminateWorkflow(workflow, reason, failureWorkflow, version)`.

- 워크플로우가 아직 종료 상태가 아니면 `termination.status`로 바꾼다. `termination.task`가 있고 `failed_task_id`가
  비어 있으면 그 ID를 넣고 그 태스크를 저장한다.
- 출력은 (b)와 같이 `Archon.Decider.Retry.update_output/2`로 다시 계산한다. upstream `terminateWorkflow`가 Decider가 채운
  값 위에 `updateWorkflowOutput(workflow, null)`을 다시 부르기 때문이다(3b 갱신. 처음에는 `outcome.workflow.output`을
  쓴다고 적었다). 실패 태스크(`FAILED`, `FAILED_WITH_TERMINAL_ERROR`)의
  참조명·정의명을 `failedReferenceTaskNames`·`failedTaskNames`에 더하고, `reasonForIncompletion`에 사유를 넣는다.
- 남은 태스크를 `CANCELED`로 바꾸고 시스템 태스크는 `cancel`한다(SUB_WORKFLOW는 결정 5). 모든 태스크를 큐에서 지운다.
  부모가 있으면 결정 5로 알린다.
- 정의의 `failureWorkflow`(`$`로 시작하면 입력에서 이름을 읽는다)가 있으면 실패 워크플로우 ID를 `Env.new_id`로 미리
  만들어 `conductor.failure_workflow` 출력과 함께 같은 Commit에 넣고, Commit 뒤 그 ID로 시작한다. 입력은 upstream과 같다
  (`workflowId`, `reason`, `failureStatus`, `failureTaskId`, `failedWorkflow`). 시작이 실패하면 출력을 upstream 문구
  `Error workflow <이름> failed to start.  reason: <사유>`로 바꿔 다시 Commit한다. (3e 갱신) 사유는 시작 오류의 문구(정의가 없으면
  `No such workflow defined. name=<이름>, version=null`)다. 저장해 둔 ID가 이미 있다는 `:conflict`는 앞선 시도가 그 ID로
  시작한 것이므로 시작 성공으로 본다. 시작 Effect를 실행하기 전에 프로세스가
  죽으면, 활성화 복구는 출력에 ID가 있는데 그 워크플로우가 저장소에 없으면 다시 시작한다(같은 ID라 멱등이다). (3b 갱신) 다시 시작할 때 입력은 저장된 워크플로우에서 출력의 그 키를 빼고 만든다. `failedWorkflow`의 태스크는 저장된 상태라, 첫 시작이 담은 메모리 상태(저장하지 않은 `executed` 등)와 다를 수 있다. 출력이 실패 문구면 다시 시작하지 않는다. 출력은 태스크(워커)가 채울 수 있으므로, 다시 시작은 Decider 종료로 끝난 워크플로우(`FAILED`·`TIMED_OUT`, 또는 원인 태스크가 있는 `TERMINATED`이고 실행 상태에서 바로 끝난 것)에만 한다. `FAILED` 뒤에 종료 요청으로 `TERMINATED`가 된 워크플로우는 `failed_task_id`가 남지만 다시 시작하지 않는다. 원인 태스크 없이 `TERMINATED`로 끝난 Decider 종료는 다시 시작하지 못하며, 이 빈틈은 결과 절의 Phase 4 복구에 남긴다.

**(b) 종료 요청**(`terminate_workflow`, REST `DELETE /api/workflow/{id}`). upstream `terminateWorkflow(String, String)`.

- `COMPLETED`면 `{:error, :conflict}`, `TERMINATED`면 아무것도 하지 않고 성공이다. 그 밖의 상태는 (`FAILED`·`TIMED_OUT`
  포함) `TERMINATED`로 바꾼다.
- 출력은 Decider 결과가 없으므로 `Archon.Decider.Retry.update_output/2`(upstream `updateWorkflowOutput`)로 계산한다.
  골든 픽스처 `workflow_get_terminated`의 출력이 이 결과다.
- 실패 태스크 이름 집합, 사유, 남은 태스크 취소, 큐 정리, 부모 알림은 (a)와 같다. 실패 워크플로우를 띄우지 않고
  `failed_task_id`를 넣지 않는다.

**내부 필드.**

- **`previous_status`**: upstream `WorkflowModel#setStatus`는 상태가 바뀔 때마다 이전 값을 기록한다. core 안에서 읽는
  곳은 없지만 저장 형식에는 있다. `Step`은 상태를 바꾸는 모든 곳에서 같은 규칙으로 기록한다(상태 변경 함수 하나로 모은다).
- **`failed_task_id`**: (a)의 규칙으로 넣고, 재시작과 부모 재개(`updateAndPushParents`)에서 지운다. 실패 워크플로우 입력의
  `failureTaskId`가 이 값을 읽는다.

### 9. 생명주기 연산(REST는 Later)

일시정지·재개·재시도·재시작은 REST가 Later지만 하위 워크플로우 재시도(`updateAndPushParents`)와 얽혀 있어 런타임 메시지로
Phase 3 마지막 조각에서 옮긴다. upstream 규칙(`pauseWorkflow`: 종료 상태면 conflict, 이미 `PAUSED`면 아무것도 하지 않음, `resumeWorkflow`: `RUNNING`이면 아무것도 하지 않고 성공,
그 밖에 `PAUSED`가 아니면 오류, 재개하면 `lastRetriedTime`, `retry`: 실패·취소 태스크 재예약과 JOIN·DO_WHILE 제자리 재시도, `restart`: 태스크 비우고 처음부터)을
따르고, 일시정지 중에는 타이머를 걸지 않는다. `updateAndPushParents`가 부모를 되살리는 일은 부모 프로세스에 `cast`로
보낸다(결정 1의 호출 방향). rerun, skip, `resetCallbacksForWorkflow`는 이 ADR 범위 밖이다.

### 10. 시험 전략

- **behaviour 계약 시험.** `test/support/runtime/store_contract.ex`, `queue_contract.ex`, `metadata_contract.ex`가 콜백
  의미를 시험하는 공유 케이스다(큐의 우선순위·지연·postpone·unack 타임아웃 재노출 포함). 메모리 구현이 지금 통과하고,
  Phase 4 Postgres 구현이 같은 케이스를 통과해야 한다.
- **`Step` 단위 시험.** 프로세스 없이 이벤트를 차례로 넣는다. 지금의 재현 시험(`simple_replay_test.exs`,
  `system_task_replay_test.exs`, `do_while_replay_test.exs`)은 `decider_replay.ex` 대신 `Step`으로 같은 픽스처를 재현한다.
  `decider_replay.ex`는 그 뒤 지운다.
- **골든 픽스처를 실제 프로세스로 재현.** 애플리케이션 트리를 띄우고 `Archon.Runtime`·`Archon.Runtime.Tasks`만 불러
  `workflow_start_*` → `task_poll_*` → `task_update_*`를 넣은 뒤, `get_workflow`가 `workflow_get_completed_simple`,
  `_switch`, `_fork`와 같은지 본다(비교 규칙은 ADR 0014 결정 8과 같다). 종료는 `workflow_start_to_terminate` →
  `workflow_terminate` → `workflow_get_terminated`, 빈 큐는 `task_poll_empty`다. 시계와 ID는 `config :archon,
  Archon.Runtime`의 `clock`·`new_id`로 주입해 결정적으로 만든다.
- **타이머 시험.** 실제로 기다리지 않는다. 타이머를 거는 함수도 `config :archon, Archon.Runtime`의 `timer`로 주입하고,
  시험에서는 걸린 시각만 기록하는 함수를 넣는다. 시계를 앞으로 돌리고 프로세스에 `:wake`를 직접 보낸다.
- **크래시 시험.** 진행 중인 `WorkflowServer`를 `Process.exit(pid, :kill)`로 죽이고, 다시 뜬 프로세스가 같은 상태에서
  이어 가는지 본다. 저장 뒤·Effect 전 크래시와 계속 실패하는 워크플로우(예외 격리)는 시험용 훅으로 만든다.
- **골든 픽스처가 없는 시나리오**(하위 워크플로우, WAIT, 재시도 지연, 타임아웃, 생명주기)의 정답은 upstream
  `test-harness/src/test/groovy/com/netflix/conductor/test/integration/`의 Spock 명세(`SubWorkflowSpec`, `WaitTaskSpec`,
  `ForkJoinSpec`, `DoWhileSpec`, `FailureWorkflowSpec`, `RetryPolicySpec`, `SubWorkflowRetrySpec`, `SubWorkflowRestartSpec`
  등)에서 옮긴다. 명세가 모자라면 `scripts/contract/capture_fixtures.sh`로 로컬 upstream 서버에서 새 픽스처를 캡처한다.
  옮긴 사례는 시험 파일에 원본 명세 이름을 적는다.

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
| 하위 워크플로우 시작(`start`, `SCHEDULED`인데 자식이 없을 때의 재시작)·취소 | 결정 5(2d) | 결정 5 | 3b(Effect), 3e(실행) |
| `SubWorkflow.execute`에 넘길 자식 읽기 | 결정 5(2d) | 결정 5의 진행 반영 | 3e |
| DO_WHILE 다음 반복 예약과 그 태스크의 도메인 지정, `keepLastN` 삭제 | 결정 5(2e) | 결정 4의 4·6, `Commit`의 삭제 | 3b |
| DO_WHILE을 decide 루프가 매번 다시 실행 | 결정 5(2e) | 결정 4의 6 | 3b |
| `previous_status`, `failed_task_id` | 결과 | 결정 8 | 3b |
| `Termination`의 `status`·`task`로 종료 | 결정 1 | 결정 8 (a) | 3b |
| `terminate_task`(TERMINATE 태스크)로 끝내기 | 결정 1 | 결정 4의 3 | 3b |
| 완료 시 출력은 `outcome.workflow.output`, 상태·`endTime`은 런타임 | 결정 1 | 결정 4의 3(출력은 upstream `completeWorkflow`처럼 다시 계산한다. 3b 갱신) | 3b |
| 재시도 지연(`callbackAfterMs`)을 큐 지연으로 | 결정 2(2b) | 결정 4의 6 | 3b, 3c |
| 타임아웃 판정이 발화할 재평가 | 결정 2 | 결정 6 | 3b, 3c |
| `decider_replay.ex`가 흉내 내는 poll·update 규칙 | 결과 | 결정 7(upstream 그대로. 재현 하네스가 단순화한 `startTime` 덮어쓰기, `IN_PROGRESS` → `SCHEDULED` 변환 생략, 끝난 태스크 무시 분기 생략은 upstream대로 고친다) | 3b(상태 전이), 3d(API) |

### 12. 구현 조각

| 조각 | 범위 | 정답 기준 | 선행 | 건드리는 파일·모듈 |
|---|---|---|---|---|
| 3a | 결정 3: `Store`·`Queue`·`Metadata` behaviour와 메모리 구현, `Archon.Runtime.Commit`, 공통 계약 시험 | 계약 시험. upstream `SqliteQueueDAO`(지연, 우선순위, postpone, ack, unack 재노출)와 `ExecutionDAOFacade`·`MetadataDAO`의 MVP 연산 | 없음 | `lib/archon/runtime/{store,queue,metadata,commit}.ex`, `lib/archon/runtime/{store,queue,metadata}/memory.ex`, `test/support/runtime/*_contract.ex`, `test/archon/runtime/{store,queue,metadata}_test.exs` |
| 3b | 결정 2·4·6·8의 순수 부분: `Step`(decide 루프, 저장 규칙과 저장 시각, 도메인, 동기 시스템 태스크, DO_WHILE, JOIN·WAIT 평가, 하위 워크플로우 Effect, 두 종료 경로, 재평가 시각, poll·update 상태 전이, 복구 이벤트) | 지금의 재현 시험 셋을 `Step`으로 통과, upstream `TestWorkflowExecutor`(`scheduleTask`, `setTaskDomains`, `getActiveDomain`, `dedupAndAddTasks`, `cancelNonTerminalTasks`, `updateTask`), `TestWorkflowExecutorDecideLoop`, `ExecutorUtilsTest`(`computePostpone`) 사례 | 없음(아래) | `lib/archon/runtime/step.ex`, `lib/archon/runtime/step/*.ex`, `test/archon/runtime/step*_test.exs`, `test/archon/decider/*_replay_test.exs`, `test/support/decider_replay.ex`(삭제) |
| 3c | 결정 1·6·7의 프로세스 부분: `Runtime.Supervisor`, `Registry`, `WorkflowSupervisor`, `WorkflowServer`(활성화, write-through, Effect 실행, 예외 격리, `:wake` 타이머), `Recovery`, `Archon.Runtime`의 시작·조회·종료, `WorkflowServer`의 poll·update 클라이언트 함수, `Archon.Runtime.SubWorkflows`의 자리만 있는 함수, `Application` 연결 | 시작·종료 골든 픽스처(`workflow_start_to_terminate`, `workflow_terminate`, `workflow_get_terminated`, `workflow_get_running`)를 프로세스로 재현, 크래시·재활성화·예외 격리 시험 | 3a, 3b | `lib/archon/runtime.ex`, `lib/archon/runtime/{supervisor,workflow_server,recovery,effects,sub_workflows}.ex`, `lib/archon/application.ex`, `config/*.exs`, `test/archon/runtime/{runtime,workflow_server,recovery}_test.exs` |
| 3d | 결정 7의 워커 API: `Archon.Runtime.Tasks`(poll, batch poll, update, update-v2, get), poll 데이터 기록, 도메인 큐, 동시 실행 한도 시험(판정은 3b의 `Step`, `Env`의 진행 중 개수 채우기는 3c) | `workflow_get_completed_simple`·`_switch`·`_fork`, `task_poll_empty`, `task_get`을 프로세스로 재현. DO_WHILE은 `do_while_replay_test.exs` 시나리오를 프로세스로 | 3c | `lib/archon/runtime/tasks.ex`, `test/archon/runtime/tasks_test.exs`, `test/archon/runtime/golden_replay_test.exs` |
| 3e | 결정 5·8 (a)의 실행: 하위 워크플로우 시작·진행 반영·취소, 실패 워크플로우 시작 | upstream `SubWorkflowSpec`, `FailureWorkflowSpec`, `NestedForkJoinSubWorkflowSpec`(MVP 타입 부분)에서 옮긴 시나리오. 자식 SIMPLE 태스크는 3c의 `WorkflowServer` poll·update 클라이언트 함수로 진행한다 | 3c | `lib/archon/runtime/sub_workflows.ex`, `test/archon/runtime/sub_workflow_test.exs` |
| 3f | 결정 9: 일시정지·재개·재시도·재시작, `updateAndPushParents`, `adjustStateIfSubWorkflowChanged` | upstream `RetryPolicySpec`, `SubWorkflowRetrySpec`, `SubWorkflowRestartSpec`, `HierarchicalForkJoinSubworkflowRetrySpec`·`RestartSpec`(MVP 타입 부분), `TestWorkflowExecutor`의 retry·restart·pause·resume 사례 | 3d, 3e | `lib/archon/runtime/lifecycle.ex`, `lib/archon/runtime/step/lifecycle.ex`, `test/archon/runtime/lifecycle_test.exs` |

- **병렬로 진행할 수 있는 묶음.**
  - 3a와 3b: 파일이 겹치지 않는다. 3b가 쓰는 3a의 것은 `Archon.Runtime.Commit` 구조체 하나뿐이므로, 그 필드를 결정 2대로
    고정해 두고 두 조각이 동시에 시작한다. 3a가 먼저 머지되면 3b는 그것을 쓰고, 3b가 먼저 끝나면 3a의 `commit.ex`가 머지된
    뒤 rebase해 올린다(3b는 `commit.ex`를 만들지 않는다).
  - 3d와 3e: 3c가 끝난 뒤 동시에 진행한다. 3c는 `WorkflowServer`가 Effect를 `Archon.Runtime.Effects`로 넘기게 하고,
    하위 워크플로우 Effect의 실행은 `Archon.Runtime.SubWorkflows`의 함수 이름만 정해 두어(자리만 있는 구현) 3e가 그
    파일만 채우게 한다. 3e의 시험은 3d의 `Tasks`가 아니라 3c의 클라이언트 함수로 자식 태스크를 진행한다. 3d나 3e가
    `workflow_server.ex`나 `step` 파일을 고쳐야 하면 병렬 조건이 깨진 것이므로, 그 변경은 먼저 머지된 쪽에 맞춰 다른
    쪽이 rebase한다.
- 3b의 `Step`에는 하위 워크플로우 Effect를 내는 부분까지 들어간다. 3e는 그 Effect를 실행하는 쪽만 맡는다.
- (3c 갱신) 3c는 `Archon.Runtime.start_workflow_idempotent/1`과 `WorkflowServer`의 `{:start_idempotent}`·`{:cancel_by_parent}`·
  `{:child_changed}` 처리, 클라이언트 함수 `cancel_by_parent/2`·`child_changed/3`, Effect 결과의 되먹임까지 넣는다.
  `Archon.Runtime.SubWorkflows`의 자리 함수는 `start_child/1`, `terminate_child/2`, `notify_parent/3`,
  `start_failure_workflow/1`이고(인자와 반환은 그 moduledoc), 3e는 이 네 함수만 채운다.
- (3e 갱신) 3e는 `sub_workflows.ex`만 고쳤고 `workflow_server.ex`·`step` 파일은 건드리지 않았다(병렬 조건 유지). 3c의
  `test/archon/runtime/runtime_test.exs`에 자리 함수의 일시적 오류를 단정한 시험 하나가 있어, 자식이 실제로 시작되고 부모
  종료로 함께 종료되는지 보도록 고쳤다(3d가 건드리지 않는 파일). upstream 시나리오의 LAMBDA·TERMINATE는 MVP 타입이 아니므로
  (ADR 0003) 같은 출력을 내는 SIMPLE 태스크(워커가 완료)와 워커가 실패시키는 SIMPLE 태스크로 바꿔 옮겼다. 그래서
  `FailureWorkflowSpec`의 `Workflow is FAILED by TERMINATE task` 사유 대신 실패 태스크의 사유를 확인한다.
- 3f는 `Step`에 생명주기 이벤트를 더하므로 다른 조각과 병렬로 하지 않는다.
- 각 조각은 이 ADR의 결정 번호와 조각 이름을 PR에 적는다. 조각 중에 결정이 바뀌면 이 ADR의 해당 결정과 날짜 줄에
  갱신 사실을 적는다(ADR 0014와 같은 방식).

## upstream과 의도적으로 다른 점

- **락이 없다.** 워크플로우마다 프로세스 하나가 메시지를 하나씩 처리한다. upstream에서 락 없이 저장하던 `updateTask`·
  `AsyncSystemTaskExecutor`와 decide가 겹치는 경합, 락 실패 재큐잉, lease 만료는 생기지 않는다. decide 루프의 lease 보호는
  반복 횟수 상한으로 바꾼다(결정 4).
- **decider 큐와 스위퍼가 없다.** 워크플로우 프로세스의 타이머 하나(결정 6)와 활성화 복구(결정 7)가 대신한다.
  `PUT /api/workflow/decide/{id}`와 `POST /api/admin/sweep/requeue/{id}`는 ADR 0001대로 Unsupported다. 타이머는
  `computePostpone`이 30초와 같아도 새로 건다.
- **시스템 태스크 큐가 없다.** JOIN·WAIT·SUB_WORKFLOW는 소유 프로세스가 평가한다. JOIN은 시간 기반 지수 백오프 poll
  대신 사건으로 평가하므로 `pollCount`는 평가 횟수(예약 직후 + 관련 사건 수 + `:wake` 수)다. WAIT의 `pollCount`도 깨어난
  횟수다. upstream의 `pollCount`는 poller 간격에 따라 달라지는 값이다. 골든 픽스처 `workflow_get_completed_fork`와는 같다.
- **큐 이름에 실행 네임스페이스와 격리 그룹이 없다.** 도메인만 지원한다.
- **동시 실행 한도는 개수만 본다.** 비동기 시스템 태스크도 `SCHEDULED`에서 같은 한도를 보지만, 넘으면 60초 미루는 대신
  다음 `:wake`에 다시 본다(3b 갱신). upstream `SqliteExecutionDAO#exceedsLimit`의 도착 순서 공정성 검사
  (`findAllTasksInProgressInOrderOfArrival`)는 옮기지 않는다. 한도 안에서 어느 태스크가 먼저 나가는지는 큐 순서를 따른다.
  개수 확인과 `IN_PROGRESS` 저장은 서로 다른 워크플로우 프로세스에서 일어나므로, 같은 정의의 태스크를 동시에 poll하면
  한도를 잠깐 넘을 수 있다. upstream도 `exceedsLimit`의 개수 질의와 poll 저장이 원자적이지 않아 같은 성질이다. 원자적
  예약은 Phase 4 저장소에서 다시 본다.
- **하위 워크플로우 완료 알림은 프로세스 메시지다.** upstream은 부모를 decider 큐 우선순위로 앞당긴다. 결과 상태는 같고
  반영 시점이 더 이르다.
- **스키마 검증은 아직 하지 않는다**(결정 4). 결과 섹션의 조건대로 Phase 5 전에 붙인다.
- **워크플로우·태스크 상태 리스너, 메트릭, 실행 로그(`TaskExecLog`), 이벤트 큐 연동은 두지 않는다.** 리스너 호출
  지점(`notifyWorkflowStatusListener`, `notifyTaskStatusListener`)은 결과 상태에 영향을 주지 않는다.
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
- **미실행 Effect를 저장소에 outbox로 남기기:** 모든 Effect를 한 규칙으로 복구할 수 있지만 저장소 behaviour가 커진다.
  Phase 3에서는 Effect마다 복구 경로(결정 2)를 두고, Phase 4에서 큐를 같은 트랜잭션에 넣을 때 다시 본다.
- **비동기 시스템 태스크를 upstream처럼 시간 기반 재평가:** 같은 프로세스 안의 사건을 놓칠 일이 없으므로 이득이 없고,
  시험이 시간에 묶인다.

## 결과

- 이 ADR은 결정만 담는다. 구현은 결정 12의 조각 3a~3f로 하며, 마지막 조각이 머지되면 `승인`으로 바꾼다.
- Phase 4 ADR은 결정 3의 behaviour를 Postgres로 구현하면서 저장용 인코딩(ADR 0014 결정 3), 큐의 원자성(저장과 같은
  트랜잭션에 넣을지), 지연 활성화, 여러 노드의 소유권, 그리고 종료 상태인데 실패 워크플로우를 아직 띄우지 못한
  워크플로우와 자식 종료 요청을 보내지 못한 종료 상태 부모의 복구(Phase 3는 프로세스가 비정상 종료 뒤 다시 뜰 때만
  메운다)를 정한다.
- Phase 5 REST는 결정 7의 API만 부르고, 응답 형태와 오류 코드를 ADR 0001의 MVP 계약에 맞춘다. upstream은
  `enforceSchema`가 켜져 있고 스키마가 있는 정의에서 입력·출력을 검증하므로, Phase 5가 정의 등록 REST를 열기 전에 스키마
  검증(검증기 채택)을 별도 ADR로 정해 붙인다. 그 전까지 스키마가 있는 정의는 검증 없이 실행된다.
- 워커 `TaskResult`의 `subWorkflowId`는 upstream `updateTask`처럼 그대로 저장하고, 부모가 끝날 때 그 ID의 자식에 취소를
  보낸다. 워커가 다른 워크플로우의 ID를 넣으면 그 워크플로우가 종료될 수 있다(3b Codex 보안 리뷰). upstream OSS는 워커와
  API 호출자를 신뢰하고 권한 모델이 없으며, 그 호출자는 `DELETE /api/workflow/{id}`로 어떤 워크플로우든 직접 종료할 수 있으므로
  새 권한을 주지 않는다. BOSS가 2026-10-30 upstream 동작을 유지하기로 정했다. 인증·인가를 들이는 ADR에서 이 경로를 다시 본다.
- 아직 범위 밖: rerun, skip, 콜백 초기화, 스키마 검증, 실행 로그, 리스너, 외부 payload 저장소, 격리 그룹·실행
  네임스페이스, 여러 노드.
