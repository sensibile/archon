# ADR 0026: Phase 7 MVP 밖 시스템 태스크 타입 설계

- 상태: 제안
- 날짜: 2026-11-02
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`
- 비고: 설계 갈림길 네 가지(주제, 타입 범위, JQ 엔진, HTTP 대상 제한)는 2026-11-02 BOSS가 이 문서의 추천안으로 정했다.
- 갱신: 2026-11-02 조각 7a가 결정 2·4·8 끝에 정한 것과 캡처에서 확인한 것을 적었다.

## 맥락

Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md))까지 archon은 [ADR 0003](0003-porting-strategy.md) 결정 4의
MVP 태스크 타입(SIMPLE, SWITCH, DECISION, FORK_JOIN, JOIN, DO_WHILE, SUB_WORKFLOW, WAIT)만 실행한다. 그 밖의 타입은
`Archon.Decider.Mapper`가 `UserDefined`로 매핑한다. 그래서 INLINE·JSON_JQ_TRANSFORM·HTTP·TERMINATE 같은 시스템 태스크를 쓰는
정의는, 같은 이름의 태스크 정의가 없으면 `"Invalid task specified. Cannot find task by name ..."`로 워크플로우가 끝나고, 있으면
아무 워커도 꺼내지 않는 큐에서 멈춘다. upstream 정의와 SDK 예제는 이 타입들을 흔히 쓴다.

BOSS는 Phase 7 주제로 이 타입들을 골랐다. 다른 후보(검색·색인과 task log, 스케줄러, 이벤트 핸들러, 외부 payload 저장소, 큐
관리·admin, 인증, 여러 노드)의 조사는 결과 절에 남긴다. 새 REST 경로는 없다. 응답 형태가 바뀌는 곳은 워크플로우·태스크 JSON
안의 새 타입 태스크뿐이다.

upstream에서 각 타입이 사는 곳과 실행 방식은 다음과 같다(`core/.../core/execution/mapper/`, `core/.../core/execution/tasks/`,
`http-task/`, `json-jq-task/`). "동기"는 upstream `isAsync()`가 거짓이라 결정 루프 안에서 끝나는 것, "비동기"는 타입 이름의 큐를
`SystemTaskWorker`(기본 50ms 폴링)가 꺼내 `AsyncSystemTaskExecutor`로 실행하는 것이다.

| 타입 | upstream 매퍼 + 태스크 | 실행 | 예약 상태 | 일하는 곳 |
|---|---|---|---|---|
| TERMINATE | `TerminateTaskMapper` 66 + `Terminate` 114 | 동기 | `IN_PROGRESS` | `execute` |
| SET_VARIABLE | `SetVariableTaskMapper` 47 + `SetVariable` 125 | 동기 | `IN_PROGRESS` | `execute`(워크플로우 `variables`를 바꿈) |
| NOOP | `NoopTaskMapper` 46 + `Noop` 36 | 동기 | `IN_PROGRESS` | `execute` |
| HUMAN | `HumanTaskMapper` 73 + `Human` 40 | 동기 | `IN_PROGRESS` | 외부 `POST /api/tasks`가 끝냄 |
| EXCLUSIVE_JOIN | `ExclusiveJoinTaskMapper` 60 + `ExclusiveJoin` 137 | 동기 | `IN_PROGRESS` | 결정마다 `execute` |
| DYNAMIC | `DynamicTaskMapper` 157 | 매퍼만 | `SCHEDULED`(대상 타입) | 매퍼 |
| FORK_JOIN_DYNAMIC | `ForkJoinDynamicTaskMapper` 605 | 매퍼만 | `FORK` `COMPLETED` + 가지 + `JOIN` | 매퍼 |
| START_WORKFLOW | `StartWorkflowTaskMapper` 51 + `StartWorkflow` 151 | 비동기 | `SCHEDULED` | `start` |
| INLINE | `InlineTaskMapper` 87 + `Inline` 125 | 동기 | `IN_PROGRESS` | `execute`(평가기) |
| LAMBDA | `LambdaTaskMapper` 83 + `Lambda` 104 | 동기 | `IN_PROGRESS` | `execute`(JavaScript) |
| JSON_JQ_TRANSFORM | `JsonJQTransformTaskMapper` 77 + `JsonJqTransform` 160 | 동기 | `IN_PROGRESS` | `start`(예약 때) |
| HTTP | `HTTPTaskMapper` 99 + `HttpTask` 424 | 비동기 | `SCHEDULED` | `start`(나가는 요청) |

archon에 이미 있는 것(`5c2355f` 기준, Phase 6 조각 6h 머지 뒤):

- `Archon.Decider.SystemTasks`(등록부, `isAsyncComplete` 규칙), `Archon.Decider.SystemTask.execute/3`(동기 실행),
  `Archon.Runtime.Step.Decide.execute_sync`(결정 루프의 동기 실행 반복), `Archon.Runtime.Step.Async`(비동기 태스크 평가).
  비동기 여부는 `Step.Schedule`의 `@async ~w(JOIN WAIT SUB_WORKFLOW)`처럼 여러 파일에 타입 목록으로 박혀 있다
  (`step/schedule.ex`, `step/async.ex`, `step/postpone.ex`, `step/recover.ex`, `step/lifecycle.ex`, `runtime/tasks.ex`).
- TERMINATE 태스크로 끝나는 워크플로우 처리: `Retry.successful_terminate?/1`, `Retry.update_output/2`, `Decider`의 `terminate_task`,
  `Step.Decide.end_execution`(`terminationStatus`·`terminationReason`·기본 문구). 매퍼와 태스크 실행만 없다.
- `Workflow.variables`(코덱 필드, 저장, `${workflow.variables...}`), 정의의 `variables`로 시작 때 채움.
- 스크립트 평가기: `Archon.Script`(QuickJS-ng 호스트 `archon_js`, 워커 풀, `Decider.Context.evaluate_script`,
  [ADR 0015](0015-script-evaluator.md)). ADR 0015는 INLINE·LAMBDA를 같은 평가기로 나중에 붙인다고 했다.
- 타입 제약: `Archon.Domain.TaskTypeConstraint`가 DYNAMIC, FORK_JOIN_DYNAMIC, TERMINATE 규칙을 이미 갖는다. HTTP·JSON_JQ_TRANSFORM
  규칙은 태스크 정의 조회가 필요해 미뤘다([ADR 0014](0014-phase2-decider.md) 결정 7).
- 하위 워크플로우 시작 경로: `Step.SubWorkflow.start/2`가 효과 `{:start_sub_workflow, task_id, start}`를 올리고, 커밋 뒤
  `Effects.run`이 `SubWorkflows.start_child/1`(안에서 `Runtime.start_workflow_idempotent/1`과 소유권 확인)을 불러 결과를 이벤트
  `{:sub_workflow_started, ...}`로 되먹인다. 되먹임은 같은 메시지 처리 안에서 다시 결정한다(`WorkflowServer.feed_back`).
  자식 ID는 `Step.SubWorkflow.child_id/2`(부모 ID·태스크 ID·재시도 횟수의 해시)라 다시 시도해도 같은 자식이다.
- HTTP 클라이언트 의존성은 없다(`mix.lock`에 Req·Finch·Mint·hackney 없음).

## 결정

### 1. 범위: 시스템 태스크 타입 열두 개

- **연다.** TERMINATE, SET_VARIABLE, NOOP, HUMAN, EXCLUSIVE_JOIN, DYNAMIC, FORK_JOIN_DYNAMIC, START_WORKFLOW, INLINE, LAMBDA,
  JSON_JQ_TRANSFORM, HTTP(BOSS 결정).
- **Later로 남는 것.**
  - EVENT: 이벤트 큐·이벤트 핸들러와 함께 연다. upstream 기본 서버에서도 `conductor:` 싱크만 동작한다.
  - KAFKA_PUBLISH: 브로커가 필요하다. upstream도 브로커 없이는 실행 때 실패한다.
  - PULL_WORKFLOW_MESSAGES: upstream 기본 꺼짐(`conductor.workflow-message-queue.enabled=false`)이다.
  - INLINE의 `python` 평가기: ADR 0015 결정 5대로 보류한다. `Unknown evaluator 'python' in INLINE task.`가 아니라
    upstream이 실행하는 타입이므로 의도적 차이로 적는다.
  - 비밀 값 치환(upstream `substituteSecrets`, `/api/secrets`): 비밀 저장소와 함께 연다. 그때까지 시스템 태스크 입력의 비밀
    참조는 바꾸지 않고 넘긴다.
- Later 타입은 지금처럼 `UserDefined`로 매핑한다(동작 변화 없음).
- REST 경로·쿼리·응답 모델은 바뀌지 않는다. 새 타입은 기존 경로의 워크플로우·태스크 JSON 안에서만 보인다.

### 2. 시스템 태스크 등록부를 하나로 모은다(조각 7a)

새 타입을 더할 때마다 여러 파일의 타입 목록을 고치지 않도록, 타입별 성질을 두 표로 모은다. 키 공간이 다르기 때문이다.
매퍼는 정의의 `WorkflowTask.type`(FORK_JOIN, DYNAMIC, FORK_JOIN_DYNAMIC 등)으로 찾고, 시스템 태스크는 만들어진 `Task.taskType`(FORK,
DYNAMIC이 풀어 낸 이름 등)으로 찾는다. upstream에서도 DYNAMIC·FORK_JOIN_DYNAMIC은 매퍼만 있고 시스템 태스크 등록부에 없다.

- **매퍼 표**(`Archon.Decider.Mapper`): 워크플로우 태스크 타입 → 매퍼 모듈. 없는 타입은 지금처럼 `UserDefined`다.
- **시스템 태스크 표**(`Archon.Decider.SystemTasks`): 태스크 타입 → 실행 모듈, `async?`(upstream `isAsync`), `isAsyncComplete`
  규칙(지금의 `:by_task`·고정 값), 재시도하지 않는 내장 타입 여부(`Retry`의 `@built_in`, upstream `TaskType.isBuiltIn`), 제자리
  재평가 여부(`Step.Lifecycle`의 `@in_place`), 비동기 시작이 멱등인지(결정 7). `system_task?/2`는 이 표에 있는지다. 그래서 7c가
  DYNAMIC·FORK_JOIN_DYNAMIC을 매퍼 표에만 넣으면 시스템 태스크로 판정되지 않는다.
- `Decider`(`Mapper.module_for/1` 호출), `Step.Schedule`의 `@async`, `Step.Async`의 타입별 분기, `Step.Postpone`, `Step.Recover`,
  `Step.Lifecycle`, `Runtime.Tasks`, `Retry`가 타입 이름 대신 두 표를 읽는다. 동작은 바뀌지 않는다(기존 시험·재생이 그대로 통과).
- **동기 실행 behaviour** `Archon.Decider.SystemTask`:
  - `start(workflow, task, context) :: Result.t()` (선택. upstream `start`. `Step.Schedule`이 동기 시스템 태스크를 예약한 직후 한 번
    부른다. 지금의 "동기 타입에는 start가 없다"는 전제를 바꾼다. JSON_JQ_TRANSFORM·HUMAN이 쓴다)
  - `execute(workflow, task, context) :: Result.t()` (upstream `execute`)
  - `Result`는 `%{changed?: boolean, task: Task.t(), workflow: Workflow.t() | nil}`다. `changed?`는 upstream `execute`의 반환값이다.
    upstream은 `false`를 돌려주면서 태스크를 바꾸는 경우가 있다(TERMINATE의 잘못된 상태: `FAILED`로 바꾸고 `false`). archon은
    `changed?`와 상관없이 바뀐 태스크를 상태에 넣는다. 저장은 upstream처럼 `true`일 때만 갱신 목록에 들어간다(결과 상태는 같은
    결정의 다른 저장이나 다음 결정에서 저장된다. 7b가 이 경우를 시험으로 정한다).
  - `workflow`는 SET_VARIABLE처럼 태스크 밖(`variables`)을 바꾸는 타입만 채운다. `Step.Decide`는 이것을 받으면 워크플로우 상태를
    바꾸고 그 결정이 끝날 때 `State.save_workflow`를 반드시 부른다(지금 `loop`로 가면 저장하지 않는 경로가 있다). upstream
    `SetVariable`이 `updateWorkflow`를 직접 부르는 것과 같은 결과다.
  - 지금의 `SystemTask.execute/3`(`now`만 받음)은 이 behaviour로 옮긴다. DO_WHILE은 다음 반복 예약·지울 ID·종료를 돌려주므로
    `decide.ex`의 별도 분기를 그대로 둔다. `context`는 `Decider.Context`이고 `now`·`evaluate_script` 등을 담는다.
- **`Decider.Context`의 주입 함수 셋.** 7a가 필드·`Step.Env` 연결·기본값·`Archon.StepReplay`의 고정 함수(픽스처의 정의에서 만든
  표)를 만들고 7c·7e가 쓴다.
  - `task_def_lookup :: (name -> {:ok, TaskDef.t()} | {:error, :not_found})`: `task_defs`에 없는 이름을 읽는다. DYNAMIC·FORK_JOIN_DYNAMIC은
    입력을 풀어야 태스크 이름을 알 수 있어 `WorkflowServer`가 미리 읽을 수 없다. 기본값은 `Runtime.metadata().get_task_def/1`이다.
  - `workflow_def_lookup :: (name, version | nil -> {:ok, WorkflowDef.t()} | {:error, :not_found})`: FORK_JOIN_DYNAMIC 간단 형태의
    `forkTaskWorkflow`처럼 미리 알 수 없는 하위 워크플로우 이름의 최신 버전을 읽는다.
  - `evaluate_jq :: (query, input -> {:ok, [value]} | {:error, Archon.Script.Error.t()})`: 기본값은 결정 6의 풀을 부른다. 7e 전까지는
    7a가 둔 "평가기 없음" 오류를 돌려준다(JSON_JQ_TRANSFORM이 등록되기 전이라 불리지 않는다).
  - 조회 둘은 upstream 매퍼가 `MetadataDAO`를 읽는 그 자리의 읽기다. upstream처럼 한 결정 안에서 기억하지 않는다(정의를 동시에
    등록하면 upstream과 같이 결정마다 다른 값을 볼 수 있다). 이는 [ADR 0014](0014-phase2-decider.md) 결정 2("`task_defs`는 호출자가
    미리 채운다")와 [ADR 0015](0015-script-evaluator.md) 결정 3의 예외("계산 요청")를 "metadata 읽기"까지 넓힌다. 결과 절에 적는다.
- **설정.** 7b가 쓸 `max_workflow_variables_payload_kb`(결정 3)와 7e·7g의 설정 키를 읽어 `Context`에 넣는 자리도 7a가 만든다.
- **타입 제약의 태스크 정의 조회.** `TaskTypeConstraint.errors/1`은 `WorkflowTask.errors/1`에서 불리고 `WorkflowDef.validate`와
  `StartWorkflowRequest.validate`(시작 REST의 내장 정의)를 거친다. 7a가 이 사슬에 태스크 정의 조회 옵션을 넘기는 연결(정의 등록
  `Archon.Metadata`, 시작 경로)을 만든다. 7e·7g는 `TaskTypeConstraint`에 자기 규칙 절만 더한다.

- **조각 7a에서 정한 것(2026-11-02).**
  - 시스템 태스크 표의 항목은 `Archon.Decider.SystemTasks.Spec`(`module`, `async?`, `async_complete`(`:by_task` 또는 고정 값),
    `start_idempotent?`)이다. 재시도하지 않는 내장 타입(`built_in?/1`)과 제자리 재시도(`in_place?/1`)는 upstream처럼 등록과 상관없는
    타입 이름 집합이라 표 항목이 아니라 같은 모듈의 함수로 둔다(EXCLUSIVE_JOIN·FORK_JOIN이 등록 전에도 들어 있다). 2차 조각은
    `default/0`에 자기 줄 하나를 더한다.
  - 매퍼 표는 그대로 `Archon.Decider.Mapper`의 `@mappers`이고 `mapped?/1`이 재생 건너뛰기(결정 8)의 판정이다.
  - behaviour 분배(`SystemTask.start/3`, `execute/3`)는 표의 `module`이 이 behaviour를 선언했을 때만 그 함수를 부른다. DO_WHILE
    (`DoWhile.execute/3`)과 SUB_WORKFLOW(`SubWorkflow.execute/2`)는 계약이 다른 같은 이름 함수가 있어 런타임이 직접 부른다. WAIT의
    `start`(`IN_PROGRESS`)는 behaviour로 옮겼고 `Step.Async`가 SUB_WORKFLOW 밖의 비동기 시작에서 부른다.
  - `start`는 `Step.Schedule.start_sync/2`가 동기 타입 예약 직후에, 그리고 rerun 대상이 동기 시스템 태스크일 때
    `Step.Lifecycle`이 부른다(upstream `rerunWF`도 `start`를 부른다). rerun 대상은 `start` 뒤에도 `SCHEDULED`일 때만 큐에 넣는다.
    다만 archon은 이전부터 rerun 대상을 먼저 `SCHEDULED`로 두는데, upstream `rerunWF`는 동기 시스템 태스크의 상태를 바꾸지 않고
    (`FORK`는 `COMPLETED`로 남음) `FORK_JOIN_DYNAMIC`은 `COMPLETED`로 둔다. 7a는 동작을 바꾸지 않으므로 이 차이는 FORK rerun을
    옮기는 7c가 맞춘다(`p7_fjd_rerun_fork_get`).
  - `Result`의 태스크는 `changed?`와 상관없이 상태에 넣고, `workflow`가 오면 그 자리에서 `State.save_workflow`를 부른다
    (`Step.Schedule.apply_result/2`). upstream `SetVariable`이 `execute` 안에서 `updateWorkflow`를 부르는 것과 같은 시점이다.
  - 조회 둘의 기본값은 `Context`·`Step.Env` 모두 "없음"이고(순수 시험이 저장소를 읽지 않게), 메타데이터 저장소를 읽는 함수는
    `WorkflowServer.env/2`가 넣는다. `Archon.StepReplay.env/2`는 픽스처가 등록한 정의(캡처 순서에서 마지막 등록)를 읽는다.
    `evaluate_jq`의 기본값은 `%Archon.Script.Error{kind: :request, reason: "no jq evaluator is available"}`이다.
  - 설정 `max_workflow_variables_payload_kb`(기본 256)는 `Step.Env`·`Context`의 필드이고 `config :archon, Archon.Runtime,
    settings: [...]`로 바꾼다. 7e·7g의 설정은 실행기·풀의 설정이라 `Context`를 거치지 않는다.
  - `Step.Env.http_in_flight`(진행 중 HTTP 태스크 ID 집합, 기본 빈 집합)는 자리만 있다. 7g가 채운다.
  - 타입 제약의 조회는 검증 옵션 `task_def_lookup`이다(`t:Archon.Domain.Validation.opts/0`). `WorkflowDef.validate/2`가
    `WorkflowTask.errors/2`를 거쳐(중첩 태스크 포함) `TaskTypeConstraint.errors/2`에 넘기고, 규칙은
    `TaskTypeConstraint.task_definition/2`(내장 정의, 없으면 조회)로 읽는다. 정의 등록·갱신·검증(`Archon.Metadata`)과 시작 REST의
    내장 정의 검증(`POST /api/workflow`, `execute`)이 `Archon.Metadata.validation_opts/0`로 저장소의 조회를 넘긴다.

### 3. 엔진이 필요 없는 동기 타입(조각 7b)

모두 upstream 매퍼·태스크를 그대로 옮긴다. 문구는 upstream 문자열을 쓴다.

- **문자열이 아닌 입력(결정 3·5·6 공통).** upstream은 몇몇 입력을 `try` 밖에서 `(String)`으로 캐스트한다(TERMINATE
  `terminationStatus`, INLINE `evaluatorType`·`expression`, JSON_JQ_TRANSFORM `queryExpression`). 표현식이 수 같은 값을 내면
  `ClassCastException`이 태스크 실패 경로가 아니라 결정·예약 밖으로 새어 나간다. 이 ADR의 실패 문구 서술은 문자열 입력에만 해당한다.
  HTTP 입력의 `Input` 변환(`HttpTask.start`의 `convertValue`)도 `try` 밖이다. 비동기라 upstream `AsyncSystemTaskExecutor`가 예외를
  로그만 남기고 삼켜, 태스크는 `SCHEDULED`로 남았다가 응답 시간 상한(직접 정의한 HTTP는 1시간, 결정 7) 뒤 `TIMED_OUT`이 된다.
  이 경우는 캡처하지 않고 7g가 StepReplay 시험으로 정한다.
  문자열이 아닌 경우의 결과(워크플로우 상태, 오류 응답)는 7a가 캡처하고, 해당 조각이 그 결과에 맞추거나 맞출 수 없으면 의도적
  차이로 적는다.

- **TERMINATE.** 매퍼는 `IN_PROGRESS`, 입력은 `getTaskInputV2`(태스크 정의 없음). 실행은 문자열 `terminationStatus`가 `COMPLETED`·`FAILED`·
  `TERMINATED`면 출력에 `workflowOutput`(맵이면 그대로, 다른 값이면 `{"output": 값}`, 없으면 빈 맵)을 넣고 `COMPLETED`, 아니면
  `"given termination status is not valid"`로 `FAILED`(upstream 반환 `false`, 결정 2)다. 워크플로우 쪽(`end_execution`, 출력 덮어쓰기, 남은 태스크 `CANCELED`,
  실패 워크플로우)은 이미 있는 경로를 쓴다.
- **SET_VARIABLE.** 입력의 모든 키를 `workflow.variables`에 넣는다. 크기는 upstream처럼 JSON으로 직렬화한 바이트 수를
  `max_workflow_variables_payload_kb`(기본 256, `config :archon, Archon.Runtime`)와 비교한다. 넘으면 바꾸기 전 값으로 되돌리고
  `FAILED_WITH_TERMINAL_ERROR`, 문구 `"The variables payload size: <n> of workflow: <id> is greater than the permissible limit:
  <k> kilobytes"`다. 출력은 없다. 바뀐 `variables`는 결정 2의 `workflow` 결과로 그 결정의 커밋에 저장된다.
- **NOOP.** 바로 `COMPLETED`.
- **HUMAN.** `start`가 `IN_PROGRESS`로 두고(DYNAMIC이 HUMAN을 `SCHEDULED`로 만들 때 필요), 그대로 남아 `POST /api/tasks`·`update-v2`·ref 갱신·signal이 끝낸다. 취소는 `CANCELED`. upstream의
  `humanTaskPreventsDeciderQueue`는 결정 큐가 없는 archon에 대응이 없다(워크플로우 프로세스는 이벤트가 올 때만 결정한다).
- **EXCLUSIVE_JOIN.** 입력 `{joinOn, defaultExclusiveJoinTask?}`. 결정마다 `ExclusiveJoin.execute`를 옮긴 판정을 한다: `joinOn`을
  차례로 보고(반복 안에서는 `__<iteration>` 접미사) 없거나 `SKIPPED`인 것은 건너뛰고 처음 찾은 태스크에서 멈춘다. 그것이 끝나지
  않았으면 `defaultExclusiveJoinTask` 쪽 판정으로 넘어가고, 끝났으면 성공 시 그 출력으로 `COMPLETED`, 실패 시 `reasonForIncompletion`으로
  `FAILED`다. 세부(실패 이유를 잇는 공백, permissive 판정)는 이 요약이 아니라 upstream 코드가 기준이다. 내장 타입이라 재시도하지
  않는다.

### 4. 매퍼 확장: DYNAMIC, FORK_JOIN_DYNAMIC(조각 7c)

- **DYNAMIC.** `dynamicTaskNameParam`이 가리키는 입력 값을 문자열로 바꿔 태스크 이름으로 쓴다. 없으면
  `"Cannot map a dynamic task based on the parameter and input. Parameter= <p>, input= <input>"`로 종료한다. 태스크 정의는 내장 정의,
  없으면 `task_def_lookup`이고, 없으면 `"Invalid task specified.  Cannot find task by name <name> in the task definitions"`로 종료한다
  (upstream은 대상이 시스템 타입이어도 정의를 요구한다). 태스크의 `taskType`은 풀린 이름이고 상태는 `SCHEDULED`다. 그래서 대상이
  시스템 태스크 표의 타입이면 그 타입의 실행 경로를 탄다. upstream 매퍼는 정의의 `WorkflowTask`에 `setName`·`setTaskDefinition`을
  하고, `DeciderService`가 정의 객체를 복사하지 않고 넘기므로 저장되는 `workflowDefinition`에 보일 수 있다. 7a 캡처의
  `workflowDefinition`으로 확인해, 보이면 맞추고 아니면 그대로 둔다. `ignore`로 덮지 않는다. 맞춰야 하면 Decider 계약(`Outcome`의
  바뀐 정의 필드와 `Step.Decide`의 반영)은 캡처를 한 7a가 만들고, 7c·7g는 자기 매퍼에서 그 필드만 채운다. 이와 별개로 DYNAMIC
  태스크 자신의 `workflowTask`에는 upstream처럼(`setName`·`setTaskDefinition` 뒤 `createTaskModel`) 풀린 이름과 태스크 정의를 넣는다.
  같은 태스크의 재시도·시간 초과가 이 정의를 쓴다.
- **FORK_JOIN_DYNAMIC.** 세 입력 형태를 upstream 순서로 시도한다.
  1. `forkTaskInputs`가 목록이면 간단 형태(`forkTaskName`, `forkTaskType`(기본 SIMPLE), `forkTaskWorkflow`·`forkTaskWorkflowVersion`이면
     SUB_WORKFLOW 가지, ref는 `_<name>_<i>` 또는 이미 동적 포크가 있으면 `_<부모 ref>_<name>_<i>`, 입력에 `__index`).
  2. `dynamicForkTasksParam` + `dynamicForkTasksInputParamName`.
  3. 옛 `dynamicForkJoinTasksParam`(`DynamicForkJoinTaskList`).
  결과는 upstream처럼 `FORK` 태스크(`COMPLETED`, 입력 `forkedTasks`·`forkedTaskDefs`), 가지마다 그 가지 타입의 매퍼가 만든 태스크,
  정의에서 다음에 오는 `JOIN`(입력 `joinOn`은 가지마다 마지막 태스크 ref)이다. 다음이 JOIN이 아니면
  `"Dynamic join definition is not followed by a join task.  Check the workflow definition."`로 종료한다. 이미 그 ref의 FORK가 있으면
  가지를 다시 만들지 않는다. 오류 문구 여섯 가지(목록 변환 실패, 입력 맵 아님, 동적 태스크 없음, 잘못된 입력, ref 중복, ref 없음
  `"One of the tasks had a null/missing taskReferenceName"`)는 upstream 문자열이다. 다만 문구 안의 Java `toString`
  (`WorkflowModel.toShortString()`, `WorkflowTask.toString()`)은 재현하지 않고 앞부분만 맞춘다(의도적 차이). `FORK_JOIN` 매퍼의 가지 예약·JOIN 찾기 함수를 같이 쓴다.
- **생명주기의 동적 포크 분기.** ADR 0025가 "MVP 타입 밖"이라 미룬 rerun의 동적 FORK 분기(upstream `rerunWF`의
  `FORK_JOIN_DYNAMIC` 분기와 `finalizeRerun`: FORK 태스크를 지우고 매퍼를 다시 불러 가지를 새로 만든다)를 이 조각이 옮긴다.
  `Step.Lifecycle`의 `contains_type?(..., "FORK_JOIN_DYNAMIC")` 판정(실패 JOIN 되돌리기, 바뀐 SUB_WORKFLOW 찾기)은 이미 있으므로
  시험만 더한다. `Step.Tasks.lazy_evaluate?/2`는 이미 upstream `isLazyEvaluateWorkflow`와 같다(정의에 없는 동적 가지 ref의 갱신은
  늘 결정한다, `WorkflowExecutorOps` 1237행). 고치지 않고 회귀 시험만 더한다.

- **조각 7a의 캡처에서 확인한 것(2026-11-02).** 정의 변경은 보인다. `p7_dynamic_get`의 `workflowDefinition.tasks[0].name`이 풀린
  이름(`archon_p7_worker`)이고, HTTP의 `inputParameters.asyncComplete`도 `false`로 덮인 채 저장된다(`p7_http_async_input_get`).
  그래서 7a가 Decider 계약을 만들었다. 정의를 바꾸는 매퍼는 `Archon.Decider.Mapper`의 선택 콜백 `changes_definition?/0`에서
  `true`를 답하고, 바꾼 `WorkflowTask`를 돌려주는 태스크의 `workflow_task`에 넣는다(upstream에서 태스크와 정의가 같은 객체를
  가리키는 것과 같다). `Archon.Decider.decide/2`는 예약할 태스크 가운데 그런 타입의 `workflow_task`가 정의의 같은 ref 태스크와
  다르면 정의에 써 넣고(`WorkflowDef.replace_task/2`, 중첩 포함) `Outcome.changed_workflow_tasks`에 담는다. `Step.Decide`는 그 결정에서
  바로 워크플로우를 저장한다. 7c·7g는 매퍼에서 콜백과 `workflow_task`만 채운다. 판정은 예약할 태스크 전체(재시도 사본 포함)를
  보는데 재시도 사본은 매퍼가 아니라 `Decider.Retry`가 만든다. 사본의 `workflow_task`가 정의와 다를 수 있는 경우(DO_WHILE 반복
  안의 DYNAMIC은 upstream에서 정의가 아니라 사본을 바꾼다)는 7c가 확인하고, 필요하면 판정을 매퍼가 방금 만든 태스크로 좁힌다.
  캡처는 정의 없는 이름도 보여 준다. upstream은 시작 때 정의가 없는 모든 태스크에 기본 태스크 정의(이름은 정의의 태스크 이름
  `archon_p7_dynamic`)를 채우므로(`MetadataMapperService`), DYNAMIC 매퍼는 늘 그 정의를 쓰고 `"Invalid task specified ..."`로
  끝나지 않는다. 정의 없는 이름(`archon_p7_missing`)의 태스크가 그 타입으로 `SCHEDULED`에 남는다(`p7_dynamic_missing_get`).
  `workflowDefinition`의 `taskDefinition`도 그 기본 정의로 남는다. 위 "없으면 ... 종료한다"는 이 동작으로 바뀐다(정답은 캡처).

### 5. 스크립트 타입: INLINE, LAMBDA(조각 7d)

- 평가는 ADR 0015의 `evaluate_script`(QuickJS-ng, 시간 4초, 요청마다 새 realm)를 그대로 쓴다. 새 엔진·새 설정은 없다.
- **INLINE.** 입력은 `getTaskInputV2`(태스크 정의의 `inputTemplate` 합침). `evaluatorType`(기본 `javascript`)이 `javascript`·`graaljs`면
  `expression`을 `$` = 태스크 입력 전체로 평가하고, `value-param`이면 기존 `Archon.Decider.Evaluator`를 쓴다. 출력 `result`로
  `COMPLETED`. 문자열 입력의 오류는(문자열이 아닌 `evaluatorType`·`expression`은 결정 3 머리의 공통 규칙) 출력 `error`와
  `reasonForIncompletion`에 같은 메시지(upstream처럼 원인 예외가 있으면 그 메시지)를 넣고, 상태는
  upstream `Inline`처럼 예외 종류로 정한다.

  | 오류 | upstream 예외 | 상태 |
  |---|---|---|
  | `Empty 'evaluatorType' ...`, `Unknown evaluator '<x>' in INLINE task.`, `Empty 'expression' ...` | `TerminateWorkflowException`(`checkEvaluatorType`·`checkExpression`) | `FAILED_WITH_TERMINAL_ERROR` |
  | 스크립트 문법·실행 오류(ADR 0015 결정 4의 ``Error evaluating the script `...` at line N``) | `TerminateWorkflowException`(`ScriptEvaluator.handlePolyglotException`) | `FAILED_WITH_TERMINAL_ERROR` |
  | `value-param` 평가기 오류 | `TerminateWorkflowException`(`ValueParamEvaluator`) | `FAILED_WITH_TERMINAL_ERROR` |
  | 시간 초과(`Script not evaluated within <N> seconds, interrupted.`) | `NonTransientException` | `FAILED` |

  평가기 풀이 받지 못함(대기열 가득 참, 프로세스 죽음)은 upstream에 대응이 없다. 일시적 오류이므로 `FAILED`(재시도 가능)로 둔다.
  표의 상태는 7a 캡처(모르는 평가기, 스크립트 오류)로 확인한다.
- **LAMBDA.** `scriptExpression`을 `function scriptFun(){<식>} scriptFun();`으로 감싸 평가한다. 빈 식은
  `"Empty 'scriptExpression' in Lambda task's input parameters. A non-empty String value must be provided."`. upstream `Lambda`는 모든
  예외를 `FAILED`로 두므로(`reasonForIncompletion`은 예외 메시지, 출력 `error`는 원인 메시지) 그대로 따른다.
- 결과 값 변환(정수·실수·비유한 수)은 ADR 0015 결정 4를 따른다. 정답 기준도 ADR 0015 결정 7의 GraalJS 오라클이다.

- **조각 7d에서 정한 것과 확인한 것(2026-11-03).** 기준 SHA upstream 서버에 INLINE·LAMBDA 경계 사례 38개를 돌려 확인했다.
  - **문자열이 아닌 `evaluatorType`·`expression`(의도적 차이).** upstream은 `try` 밖 캐스트의 `ClassCastException`이 결정 밖으로
    새어, 시작 요청이면 워크플로우를 지우고(`startWorkflow`의 `removeWorkflow`) 500을 답한다(`p7_inline_*_not_string_start`).
    archon은 태스크를 `FAILED`로 끝내고 `reasonForIncompletion`과 출력 `error`에 upstream 예외 문구(``class <클래스> cannot be cast
    to class java.lang.String (...)``)를 넣는다. 시작은 200이고 워크플로우는 `FAILED`다. 결정에서 예외를 던지면 워크플로우 프로세스가
    죽고 복구가 같은 결정을 되풀이하므로, 매퍼·태스크가 던지는 대신 태스크를 실패시키는 기존 방식(ADR 0014, WAIT의 `duration`)을
    따른다. 상태는 upstream `Inline`의 `catch` 규칙(`TerminateWorkflowException`이 아니면 `FAILED`)을 따랐고, 같은 캐스트를 `try`
    안에서 하는 LAMBDA의 upstream 결과(`FAILED`, 같은 문구)와 같다. `<클래스>`는 Jackson이 준 값의 클래스로 서버에서 확인했다
    (`Integer`, `Long`, `BigInteger`, `Double`, `Boolean`, `java.util.LinkedHashMap`, `java.util.ArrayList`). `evaluatorType`을 먼저 보고,
    기본값 `javascript`는 `null`일 때만이다(`false`도 캐스트 오류).
    재생은 이 두 단계에 단계 옵션 `expect: :started`(Archon이 시작해 ID를 답함, 바인딩 없음)를 쓴다. 7h가 "upstream과 의도적으로
    다른 점"에 옮긴다.
  - **평가 오류의 상태.** `Archon.Script.Error`의 `:syntax`·`:runtime`(upstream `handlePolyglotException`의
    `TerminateWorkflowException`)은 `FAILED_WITH_TERMINAL_ERROR`, 나머지 `:timeout`·`:conversion`·`:limit`·`:crashed`·`:request`는
    `FAILED`다. `:conversion`은 upstream `getObject`가 `Future` 밖에서 던지는 `PolyglotException`이라 감싸이지 않으므로 `FAILED`가 맞다.
    LAMBDA는 모두 `FAILED`.
  - **`python`.** upstream 서버에는 `python` 평가기가 등록되어 있어 `expression: "1"`이 `result: null`로 `COMPLETED`였다. archon은
    `Unknown evaluator 'python' in INLINE task.`로 `FAILED_WITH_TERMINAL_ERROR`다(결정 1·ADR 0015 결정 5의 범위 밖).
  - **빈 값.** `evaluatorType`이 없거나 `null`이면 `javascript`, 빈 문자열·공백이면 빈 값 오류(Java `isBlank`, 줄바꿈 없는 공백은
    빈 값이 아님). 모르는 평가기는 빈 `expression`보다 먼저 본다(서버 확인). LAMBDA의 빈 식은 출력 `error` 없이 `FAILED`다.
  - **매퍼.** 태스크 정의가 없으면 입력 계산에 호출자가 채운 `task_defs`(`UserDefined`와 같음), 그다음 `task_def_lookup`을 쓴다
    (upstream `metadataDAO.getTaskDef`). 격리 그룹은 INLINE만,
    `TaskMapperContext`의 정의에서만 읽는다. 등록된 평가기 목록은 `Archon.Decider.Evaluator.registered?/1`이 답한다.
  - **엔진 문구.** 스크립트 오류 본문은 ADR 0015의 의도적 차이 그대로다(`Cannot read property` 대 `cannot read property`). 재생은
    `p7_inline_script_error_get`·`p7_lambda_error_get`의 메시지 네 곳을 `ignore`하고, StepReplay 시험은 그 대소문자만 바꿔 비교한다.
  - **오라클.** INLINE 식과 LAMBDA로 감싼 식 43개를 GraalJS 25.0.2 프로브와 `archon_js`에 돌려 35개가 같았다. 다른 8개는 모두
    ADR 0015에 적은 차이(오류 본문 문구, `throw 'x'`·`new Error`의 줄 번호)이고 상태 분류는 같다.

### 6. JSON_JQ_TRANSFORM과 jq 엔진(조각 7e, BOSS 결정: jqlang vendoring)

- **엔진.** [jqlang/jq](https://github.com/jqlang/jq)(MIT) 안정 릴리스의 소스와 정규식 라이브러리 oniguruma(BSD-2)를 `c_src/jq/`에
  고정 버전으로 vendoring한다. 버전·원본 URL·SHA256은 조각 7e가 `c_src/jq/VERSION`과 이 ADR의 갱신 줄에 적는다. 고치지 않고 통째로
  바꾸는 규칙, `NOTICE` 기록은 ADR 0015 결정 6과 같다. 빌드는 기존 `elixir_make`와 `Makefile`에 `priv/archon_jq` 대상을 더한다
  (빌드에 네트워크 없음, C 컴파일러만).
- **호스트 `archon_jq`.** libjq를 링크한 전용 C 호스트(`c_src/archon_jq/`)다. `archon_js`와 같은 `{:packet, 4}` 길이 접두 JSON
  프로토콜(요청 `{"op": "eval", "query", "input"}`, 응답은 결과 목록 또는 `{"error", "message"}`)을 쓴다. 격리 조건:
  - 시작할 때 `clearenv()`로 환경 변수를 비운다(`$ENV`·`env`가 서버 환경을 읽지 못함. 시간대는 UTC).
  - 라이브러리 검색 경로를 비워 `import`·`include`가 파일을 읽지 못하게 한다. `input`·`inputs`에는 추가 입력이 없다.
  - jq의 디버그·stderr 콜백은 버린다. `halt`·`halt_error`는 오류로 바꾼다.
  - 시간 상한은 워커가 기다리다 OS 프로세스를 kill한다(ADR 0015 결정 2의 바깥 겹). 출력 크기 상한도 `archon_js`처럼 둔다.
  - **메모리 상한은 지원하는 모든 호스트(Linux, macOS)에서 건다.** jq에는 QuickJS의 `JS_SetMemoryLimit` 같은 엔진 상한이 없고,
    `[range(0; 100000000)]` 같은 쿼리는 시간 상한 전에 호스트 메모리를 다 쓸 수 있다. 그래서 호스트가 jq의 할당을 세어 상한
    (기본 64MiB, `archon_js`와 같음)을 넘으면 오류로 끝낸다. vendoring 파일은 고치지 않으므로 빌드 플래그로 jq 할당 함수를 호스트의
    세는 함수로 바꾸는 방식이고, Linux에서는 `setrlimit`을 2차 방어로 더한다. 방법은 7e가 정하되 두 플랫폼 모두에서 상한이 걸리는
    것을 시험으로 보인다. 매크로로 이름만 바꾸면 libc가 내부에서 할당한 메모리(`strdup` 등)를 바뀐 `free`로 풀어 깨질 수 있으므로,
    헤더 없는 계수(`malloc_usable_size`·`malloc_size`)나 링크 단계 가로채기처럼 libc 할당과 섞여도 안전한 방법을 쓰고, oniguruma의
    할당도 센다. 할 수 없으면 7e는 jq를 켜지 않고 BOSS에게 보고한다.
- **풀.** `Archon.Script.Pool`·`Worker`를 실행 파일·인자·허용 op를 받게 일반화하고, 이름이 다른 두 번째 풀(`Archon.Jq.Pool`,
  설정 `config :archon, Archon.Jq.Pool`, 기본 시간 4초·워커 수 스케줄러 수)을 띄운다. 요청마다 쿼리를 새로 컴파일한다(upstream의
  Caffeine 캐시는 성능용이라 옮기지 않는다).
- **태스크.** 입력은 `getTaskInputV2`(정의의 `inputTemplate`). upstream처럼 `queryExpression`을 포함한 입력 맵 전체가 `.`이다.
  `queryExpression`이 없으면 `"Missing 'queryExpression' in input parameters"`로 `FAILED`. 성공은 출력 `result`(첫 결과 또는 `null`)와
  `resultList`(전체), `COMPLETED`. 오류는 엔진 메시지를 출력 `error`와 `reasonForIncompletion`에 넣고 `FAILED`다. 일은 예약 때
  (`start`) 한다. upstream `execute`는 `start`를 다시 부르지만, `start`가 늘 종료 상태로 끝나 결정 루프의 미종료 검사에 걸리지 않으므로
  불리지 않는다. archon은 `execute`를 두지 않는다. `queryExpression`이 문자열이 아니면 결정 3 머리의 공통 규칙을 따른다
  (upstream은 예약 중 예외라 `"Error scheduling tasks: ..."` 종료로 보인다. 7a 캡처로 확인).
- **시간 상한.** jackson-jq에는 상한이 없다. archon은 풀의 시간 상한(기본 4초)을 넘으면 `Script not evaluated within <N> seconds,
  interrupted.`와 같은 모양의 jq 문구로 `FAILED`다(의도적 차이).
- **값 변환.** upstream `JsonJqTransform`처럼 정수인 수는 정수, 아닌 수는 실수다. jq와 jackson-jq의 함수·숫자·오류 문구 차이는
  로컬 Gradle 캐시의 jackson-jq jar를 JDK 프로브로 돌려 확인하고(ADR 0015 결정 7과 같은 방식), 맞추지 않기로 한 것만 "upstream과
  의도적으로 다른 점"에 더한다. 정답 기준은 골든 픽스처(결정 8)와 프로브 비교다.
- **타입 제약.** upstream `WorkflowTaskTypeConstraint`의 JSON_JQ_TRANSFORM 규칙(`queryExpression`이 입력이나 태스크 정의의
  `inputTemplate`에 있어야 함, 문구 `"inputParameters.queryExpression field is required for taskType: JSON_JQ_TRANSFORM taskName: <name>"`)을
  옮긴다. 태스크 정의 조회는 7a가 만든 연결(결정 2)을 쓴다(ADR 0014 결정 7이 미룬 부분).

### 7. 비동기 타입: START_WORKFLOW(조각 7f), HTTP(조각 7g)

upstream의 `SystemTaskWorker`·`AsyncSystemTaskExecutor`(타입 이름 큐를 폴링) 대신, 다른 비동기 타입처럼 워크플로우 프로세스가 직접
다룬다(ADR 0018 결정 1의 "워크플로우마다 프로세스"). 시스템 태스크 표의 `async?`가 참이면 `Step.Schedule`이 큐에 넣지 않고 `due`로
두고 `Step.Async`가 시작한다.

- **시작(7f).** `Step.Async`가 `SCHEDULED` 비동기 태스크를 시작할 때 upstream `AsyncSystemTaskExecutor`처럼 `pollCount`를 올리고
  `startTime`을 찍어 커밋한 뒤 일을 효과로 넘긴다.
- **시작이 멱등인 타입과 아닌 타입.** upstream은 `start`가 멱등인 SUB_WORKFLOW만 재전달 때 다시 실행하고, 나머지는 메시지를
  태스크의 `responseTimeoutSeconds`(0이면 1시간) 동안 예약해 두 번 실행하지 않는다(`isStartIdempotent`, `reserveSeconds`). 예약이 끝난
  뒤에도 `SCHEDULED`면 다시 실행하지 않고 `TIMED_OUT`(`"Task did not complete within its responseTimeout of <n>s"`)으로 둔다.
  archon은 시스템 태스크 표에 "시작 멱등" 성질을 두어 같게 한다.
  - START_WORKFLOW: archon에서는 멱등이다(아래, ID를 태스크로 정함). 그래서 SUB_WORKFLOW처럼 시작했는데 결과가 없는 태스크를
    복구(`Step.Recover`)가 바로 다시 시작한다. upstream은 START_WORKFLOW를 멱등으로 보지 않으므로 의도적 차이다.
  - HTTP: 멱등이 아니다. 시작한 태스크(`SCHEDULED`, `pollCount` > 0. `startTime`은 예약 때 이미 찍히므로 구분에 쓰지 않는다)는 결과가
    오기 전까지 다시 시작하지 않는다.
    워크플로우 프로세스는 진행 중인 요청의 태스크 ID 집합을 상태에 두고, `:wake`나 다른 이벤트에서 그 태스크를 `Step.Async.evaluate`에
    넘기지 않는다. `evaluate`는 시작 전에 `pollCount`를 올리므로, 거르기는 그보다 앞(평가할 태스크를 고르는 자리)이어야 한다. 그래야
    결과의 `pollCount`가 태스크와 같아 버려지지 않는다. 진행 중이거나 대기열에 있는 요청 동안 `:wake`가 오는 시험을 둔다. 프로세스가
    결과 전에 죽어 집합을 잃었으면, 복구는 그 태스크를 다시 보내지 않고 아래 마감에 `TIMED_OUT`으로 둔다(upstream과 같음). 이 고아
    태스크는 집합에 없으므로 고르는 자리에서 `pollCount > 0`으로 거른다. 진행 중이든 고아든 마감 전에는 거르고, 마감이 지나면
    `evaluate`에 넘겨 기존 응답 시간 초과 판정이 `TIMED_OUT`으로 둔다(동시 실행 한도에 걸리지 않으면. 아래)(그때 `pollCount`가 올라도 늦은 결과는 어차피 버려진다).
    진행 중 집합은 순수 단계인 `Step`에 `Step.Env`의 필드로 넘긴다(7a가 자리를 만든다). 살아 있는 프로세스에서 진행 중인 요청(실행기 대기열에서
    기다리는 것 포함)도 같은 마감에 `TIMED_OUT`으로 두고(동시 실행 한도에 걸리지 않으면), 그 뒤 온 결과는 다른 시도가 아니어도 태스크가 끝났으므로 버린다(upstream도
    예약이 끝나면 `TIMED_OUT`이다). 마감은 기존 `Step.Async`의 응답 시간 초과 판정처럼 `updateTime`(시작 커밋 시각, upstream
    `hasExceededResponseTimeout`과 같음)부터 잰다. 실행기 대기열에서 아직 보내지 않은 요청은 마감이 지나면 보내지 않고 버린다. 그 뒤 재시도는
    보통의 태스크 재시도 규칙이다.
  - 재평가 시각(`Step.Postpone`)은 진행 중인 HTTP 태스크의 위 마감이다.
  - 동시 실행 한도와 마감의 순서는 upstream `AsyncSystemTaskExecutor`와 같게 둔다(한도를 먼저 보고, 걸리면 미룬다. 지금
    `Step.Async.run`도 같은 순서다). 그래서 정의에 `concurrentExecLimit`이 있는 HTTP(DYNAMIC으로 만든 것)는 다른 태스크가 자리를
    쥐는 동안 마감을 넘겨도 `TIMED_OUT` 없이 미뤄질 수 있다. 그 사이 결과가 오면 같은 시도이므로 반영된다(한도에 걸린 평가는
    `pollCount`를 저장하지 않는다. upstream도 한도 검사가 `pollCount` 증가보다 앞이다). upstream과 같은 동작으로 받아들인다
    (BOSS 2026-11-02 결정).
  - **실행기 불변식(BOSS 2026-11-02 결정: 원칙만 정하고 세부는 7g).** 7g는 다음을 지키고, 고른 방법(취소를 보내는 자리, 상한 값과
    설정 키)을 이 결정에 갱신 기록한다.
    1. 진행 중 요청의 태스크를 다시 시작하지 않는다(위). 늦거나 다른 시도의 결과는 버린다(아래).
    2. 결과가 더는 쓰이지 않는 요청(태스크가 끝났거나 지워짐, 워크플로우가 끝났거나 지워져 프로세스가 정상 종료함)은 끊어 실행기
       자리를 돌려준다. 프로세스가 비정상 종료(예외 격리, 재시작)한 뒤의 결과는 끊지 않고 활성화한 새 프로세스가 받는다. 복구 뒤처럼
       끊을 수 없는 경우는 3이 막는다.
    3. 요청마다 전체 실행 시간 상한을 둔다. `readTimeOut`보다 짧은 간격으로 조금씩 보내는 대상이 자리를 오래 쥐지 못하게 하는 값이어야
       한다(upstream은 읽기 시간 상한만 있다. 의도적 차이).
    7g는 이 셋을 시험으로 보인다(취소로 자리 반납, 조금씩 보내는 대상이 상한에 끊김).
- **결과(7f·7g).** 결과는 이벤트로 돌아와 그 태스크가 아직 같은 시도(`SCHEDULED`, 같은 `pollCount`)일 때만 반영한다. 이미
  끝났거나(종료로 `CANCELED`, 위 `TIMED_OUT` 등) 다른 시도면 버린다. 태스크가 끝나면(또는 `asyncComplete`로 `IN_PROGRESS`가 되면) 그
  이벤트 처리가 결정을 돌린다.
- **START_WORKFLOW.** 매퍼는 `SCHEDULED`, `callbackAfterSeconds` = `startDelay`. 시작은 입력 `startWorkflow`를
  `StartWorkflowRequest`로 바꿔 검증하고(없으면 `"Missing 'startWorkflow' in input data."`, 검증 실패
  `"startWorkflow validation failed. ..."`, 변환 실패 `"Error reading StartWorkflowRequest. ..."`로 `FAILED`), 효과
  `{:start_workflow, task_id, start}`를 올린다. 커밋 뒤 `Effects.run`이 `Runtime.start_workflow_idempotent/1`로 시작하고 결과를 이벤트
  `{:workflow_started, task_id, result}`로 되먹인다(하위 워크플로우와 같은 경로). 되먹임은 같은 메시지 처리 안이라 그 사이 다른
  시도가 끼지 않으므로 이벤트에 `pollCount`를 싣지 않는다. 새 워크플로우 ID는 `child_id/2`와 같은 방식의 해시
  (`startworkflow:<워크플로우 ID>:<태스크 ID>:<재시도 횟수>:<scheduledTime>`, 조각 7f에서 `scheduledTime`을 더함)라 효과가 다시
  돌아도 하나만 생긴다. 이미 있는 워크플로우를 돌려받아도
  소유권은 확인하지 않는다. upstream·archon 모두 `triggeringWorkflowId`를 워크플로우에 저장하지 않아 비교할 값이 없고, 그 ID는
  `startworkflow:` 접두의 해시이며 `StartWorkflowRequest`에는 워크플로우 ID 필드가 없어 시작 REST의 호출자가 ID를 정할 수 없으므로
  다른 호출자가 같은 ID를 먼저 만들 수 없다. 요청의 `idempotencyKey`·`idempotencyStrategy`는 upstream처럼 읽기만 하고 시작에 쓰지
  않는다(`Archon.Domain.StartWorkflowRequest`와 같음). 같은 실행 안의 재실행은 고정 ID가 막는다.
  `taskToDomain`·`correlationId` 기본값은 시작한 워크플로우의 것이고, `triggeringWorkflowId`만 적고 부모 필드는 넣지 않는다(upstream처럼
  따로 도는 워크플로우). 성공은 출력 `workflowId`, `COMPLETED`. 일시적 오류(`{:error, {:exit, _}}` 등)는 태스크를 `SCHEDULED`로 두고 다시
  시도하며, 그 밖의 오류는 메시지로 `FAILED`다. 검증 위반이 여럿이면 upstream은 Java `Set` 순서로 잇는다. archon은 경로 순으로
  정렬해 잇는다(의도적 차이. 픽스처는 위반 하나로 캡처한다).
  다른 워크플로우를 시작하는 일을 outbox가 아니라 `Effects`로 하는 것은 하위 워크플로우 시작과 같은 선택이다(ADR 0021 결정 4는
  다른 워크플로우에 대한 알림·종료를 outbox로 보낸다). 멱등 ID와 복구 재시작이 같은 보장을 준다.
- **HTTP(BOSS 결정: 대상 제한 없음).**
  - 매퍼는 upstream `HTTPTaskMapper`대로 `SCHEDULED`다. upstream은 입력을 풀기 **전에** 정의의 `inputParameters`에 `asyncComplete` =
    `workflowTask.asyncComplete`를 넣는다. 그래서 사용자가 `inputParameters.asyncComplete`에 준 표현식은 덮이고, 정의 객체도 바뀐다
    (DYNAMIC과 같은 정의 변경 문제. 7a 캡처의 `workflowDefinition`으로 확인해 결정 4와 같이 처리). 입력은 `getTaskInputV2`(태스크 정의).
    `retryCount`, `callbackAfterSeconds` = `startDelay`, 정의가 있으면 빈도 한도·`isolationGroupId`·`executionNameSpace`를 옮긴다. 태스크
    정의는 필요 없다(없으면 재시도 0). upstream `HTTPTaskMapper`는 `responseTimeoutSeconds`를 정하지 않으므로(정하는 매퍼는
    SIMPLE·DYNAMIC뿐) 직접 정의한 HTTP의 진행 중 마감과 복구 `TIMED_OUT`은 정의와 상관없이 1시간이다. DYNAMIC으로 만든 HTTP는
    태스크 정의의 값이다. archon HTTP 매퍼도 이 필드를 옮기지 않는다.
  - 요청은 입력 `http_request`, 없으면 입력 전체다. 필드 `uri`, `method`, `headers`(값은 문자열로, `null` 건너뜀), `body`, `accept`(문자열
    또는 목록, 기본 `application/json`), `contentType`(기본 `application/json`), `connectionTimeOut`·`readTimeOut`(기본 3000ms).
    `vipAddress`·`appName`은 upstream 기본 제공자처럼 쓰지 않는다. `uri` 없음 `"Missing HTTP URI.  See documentation for HttpTask for
    required input parameters"`, `method` 없음 `"No HTTP method specified"`로 `FAILED`. `workerId`는 upstream이 서버 ID를 넣으므로
    archon은 노드 이름을 넣고 재생에서 `ignore`한다.
  - 실행은 워크플로우 프로세스를 막지 않는다. 효과 `{:http_request, task_id, poll_count, request}`를 `Archon.Runtime.HttpTask` 실행기가
    감독 Task(`Task.Supervisor.async_nolink`)로 돌린다. 결과는 pid가 아니라 워크플로우 ID로 `WorkflowServer`의 API를 통해 이벤트
    `{:http_completed, task_id, poll_count, result}`로 보낸다(프로세스가 그 사이 바뀌었으면 활성화한 새 프로세스가 받는다). 진행 중인
    요청이 있는 프로세스는 `evict_after`로 끝내지 않는다. 실행기는 동시 요청 수 상한(`config :archon, Archon.Runtime.HttpTask,
    max_concurrency:`, 기본 스케줄러 수 × 2, upstream 시스템 태스크 스레드 수와 같은 뜻)을 두고 넘는 요청은 차례로 기다리게 한다.
    태스크 정의의 동시 실행 한도(`concurrentExecLimit`)는 worker 태스크의 기존 판정을 써서 넘으면 미룬다. 빈도 한도는 archon worker
    경로에도 아직 없으므로 이 Phase에서도 적용하지 않는다(결과 절).
  - HTTP 클라이언트는 **Finch**(Mint 기반, 새 의존성)다. 연결 시간 상한은 `connectionTimeOut`, 받기 시간 상한은 `readTimeOut`이다.
    응답 body는 `max_response_bytes`(기본 10 MiB, upstream 태스크 출력 하드 한도 10240KB와 같은 크기)까지만 읽고, 넘으면 태스크를
    `FAILED`로 끝낸다(의도적 차이).
  - 응답 처리는 upstream `HttpTask`를 따른다. 2xx면 출력 `response` = `{body, headers, statusCode, reasonPhrase}`, `COMPLETED`(또는
    `asyncComplete`면 `IN_PROGRESS`). body는 JSON 배열·객체면 목록·맵, 수면 실수(upstream `Double`), 그 밖에는 글자, 파싱 실패는
    원문이다. `headers`는 이름마다 값 목록이고 Mint가 이름을 소문자로 바꾼다(upstream은 서버가 보낸 대소문자, 의도적 차이).
    `reasonPhrase`는 Spring `HttpStatus`의 문구표다. Spring 표에 없는 2xx 코드(예: 299)는 upstream `HttpStatus.valueOf`가
    `IllegalArgumentException`을 내 아래 실패 경로로 간다.
  - 실패는 upstream이 `RestClientException`을 `new Exception(ex.getLocalizedMessage())`로 다시 감싸므로 `reasonForIncompletion`이
    `"Failed to invoke HTTP task due to: java.lang.Exception: <Spring 메시지>"`이고 출력 `response`는 문자열
    `"java.lang.Exception: <Spring 메시지>"`, `FAILED`다. 4xx·5xx의 Spring 메시지는 `<코드> <문구>: "<응답 body>"`(body가 없으면
    `[no body]`, 긴 body는 Spring이 줄임)이다. 이 형식과 줄임 규칙은 긴 body를 포함한 stub 픽스처로 맞춘다. 연결 거부·시간 초과 같은
    전송 오류의 Spring 메시지(`I/O error on <METHOD> request for "<uri>": ...`)는 앞부분만 맞추고 원인 문구는 archon 문구다(의도적
    차이). 리다이렉트처럼 `RestTemplate`의 전송 세부에 기대는 동작은 결정 8의 stub 픽스처로 정한다.
  - 대상 주소 제한은 없다(upstream과 같음). 정의를 등록할 수 있는 호출자는 서버가 닿는 어떤 주소로든 요청을 보낼 수 있다. 이는
    ADR 0024 결정 4(인증 없음, 기본 주소 `127.0.0.1`)의 신뢰 모델 안의 일이고, 대상 허용 목록은 인증 ADR에서 함께 본다.
    **상속 위험(SSRF).** HTTP 포트에 닿는 호출자는 루프백 서비스나 클라우드 메타데이터 주소를 부르는 정의를 등록하고 응답을 태스크
    출력으로 읽을 수 있다. 이 신뢰 의존을 7h가 README 호환성·배포 절에 경고로 적는다(포트를 외부에 열면 인증하는 역프록시 뒤에 두고
    나가는 요청도 망에서 제한할 것).
  - 타입 제약: upstream HTTP 규칙(`http_request`, 최상위 `uri`·`method`, 또는 태스크 정의 `inputTemplate`의 `http_request` 중 하나,
    문구 `"inputParameters.http_request or inputParameters.uri field is required for taskType: HTTP taskName: <name>"`)을 옮긴다(7a의
    조회 연결을 쓴다).

- **조각 7f에서 정한 것(2026-11-03).**
  - 공통 비동기 경로: 시작이 프로세스 밖의 일인 타입은 `Step.Async`의 시작 모듈 표(`SUB_WORKFLOW` → `Step.SubWorkflow`,
    `START_WORKFLOW` → `Step.StartWorkflow`)에 있고, 모듈은 `start(state, task) :: {:started, state} | {:failed, task}`다. `:started`는
    효과를 올리고, 효과는 `pollCount`·`startTime` 커밋 뒤에 돈다. 결과 이벤트는 `Async.attempt(state, task_id, poll_count)`로 태스크를
    찾고(`SCHEDULED`이고, 이벤트에 `pollCount`가 있으면 같을 때만. 아니면 버림) `Async.finish/2`로 끝낸다. 결정하지 않고 끝나면(일시적
    오류) 그 태스크의 재평가 시각으로 타이머를 당긴다(`Postpone.wake_at`). 7g는 HTTP 시작 모듈을 이 표에 넣고
    `{:http_completed, task_id, poll_count, result}`를 `attempt/3`에 `poll_count`를 넘겨 거른다.
  - 응답 시간 초과의 예외는 `SUB_WORKFLOW` 이름 대신 표의 `start_idempotent?`다(upstream `isStartIdempotent`).
  - 복구는 `Async.pass(state, :recover)`다. `:wake`처럼 지연이 끝난 태스크를 평가하고, 시작 멱등 타입의 `SCHEDULED`·`pollCount` > 0
    태스크는 지연과 상관없이 바로 다시 시작한다(`startDelay`가 있는 `START_WORKFLOW`도 바로). 그래서 시작 오류로 기다리던
    `SUB_WORKFLOW`(`subWorkflowLaunchError`)도 복구에서는 바로 다시 시작한다. `:wake`는 지금처럼 지연을 지킨다. 멱등이 아닌 타입은
    복구가 다시 시작하지 않는다. 진행 중 HTTP를 고르는 자리에서 거르는 것과 그 마감(`Step.Postpone`)은 7g 몫이다.
    `Postpone.compute/2`(upstream `computePostpone`)는 바꾸지 않았다.
  - 최상위 시작(`POST /api/workflow`)의 첫 결정이 올린 `START_WORKFLOW` 시작은 `SUB_WORKFLOW`처럼 답한 뒤로 미룬다. 같은 단계에서
    태스크가 끝나면(종료) 시작 효과를 버린다.
  - `START_WORKFLOW`의 표 항목은 `module: nil`(upstream 기본 `execute`), `async_complete: :by_task`(upstream 기본)다.
  - 변환 실패 문구는 archon codec의 첫 오류다(`"Error reading StartWorkflowRequest. must be object"`). Jackson 문구는 재현하지 않는다
    (의도적 차이, 7h가 목록에 옮긴다). 시작 REST(`WorkflowController`)처럼 정의 없이 이름이 공백이면 `"Workflow name must be
    specified when searching for a definition"`, 입력 없이 외부 입력 경로가 있으면 `"Unable to download payload from external
    storage path: <path>"`로 `FAILED`다. 일시적 오류는 upstream처럼 `reasonForIncompletion`·출력을 바꾸지 않는다.
  - ID에 태스크의 `scheduledTime`을 넣는다(위 문장을 고침). 처음에는 `startworkflow:<워크플로우 ID>:<태스크 ID>:<재시도 횟수>`만
    썼는데, 제자리 재실행(rerun은 태스크 ID와 재시도 횟수를 그대로 둔다)에서 고정 ID가 첫 실행의 워크플로우를 돌려주어 upstream
    rerun처럼 새 워크플로우가 생기지 않았다. 돌려받은 워크플로우의 `createTime`과 태스크의 `scheduledTime`을 비교해 rerun을 가리는
    방식은 같은 밀리초의 rerun(Codex 교차 r1 P2)과 노드 재시작 사이 시계 역행(자체 리뷰 r1 P2)에서 틀려 VER-005 상향 조건이 되었고,
    조정 세션이 이 안을 골랐다(2026-11-03). `scheduledTime`은 태스크와 함께 저장되므로 크래시 뒤 효과 재실행과 복구 재시작은 같은
    워크플로우를 받고, rerun은 `scheduledTime`을 새로 찍어 새 워크플로우를 만든다. rerun의 `finalizeRerun`이 다시 `SCHEDULED`로
    두는 다른 참조의 `START_WORKFLOW`(`scheduledTime`을 새로 찍지 않음)는, 워크플로우를 만든 뒤 취소된 경우 그 워크플로우로
    `COMPLETED`가 된다.
  - 픽스처: `START_WORKFLOW` 재생 단계는 NOOP에 기대므로 7b가 머지되기 전에는 건너뛴다. 시작하는 쪽은 `Archon.StepReplay` 방식의
    단계 시험이 `p7_start_workflow_get`·`_invalid_get`·`_missing_get`과 같다(`test/archon/runtime/step/start_workflow_test.exs`).

### 8. 골든 픽스처와 재생(조각 7a가 한 번에 캡처)

- 7a가 열두 타입의 시나리오 전부를 `scripts/contract/capture_fixtures.sh` 끝에 더하고 upstream 서버(기준 SHA 빌드, 빈 SQLite)에서
  기존 픽스처와 함께 한 번에 다시 캡처한다. 기존 픽스처는 `normalize/1` 기준으로 같아야 하고, 다르면 PR에서 검토한다(ADR 0025
  결정 7과 같음). 다른 조각은 스크립트·픽스처·픽스처 등록을 고치지 않는다. 빠진 것은 기록해 두고 7h가 더해 다시 캡처한다.
- 시나리오는 정의 등록 → 시작 → 끝난 워크플로우 GET의 모양이다. 타입마다 성공 하나와 upstream이 실패·종료로 가는 경우 하나
  이상을 넣는다. 특히:
  - 문자열이 아닌 입력(결정 3 머리): TERMINATE `terminationStatus`, INLINE `evaluatorType`·`expression`, JSON_JQ_TRANSFORM `queryExpression`
  - TERMINATE의 세 상태와 `workflowOutput`의 맵·맵 아닌 값, 진행 중 형제 태스크의 `CANCELED`, 실패 워크플로우
  - SET_VARIABLE의 덮어쓰기와 크기 초과(`FAILED_WITH_TERMINAL_ERROR`)
  - HUMAN을 `POST /api/tasks`로 끝내기, EXCLUSIVE_JOIN의 `defaultExclusiveJoinTask`와 실패
  - DYNAMIC의 정의 없음, 대상이 시스템 타입인 경우, FORK_JOIN_DYNAMIC의 세 입력 형태, 다음이 JOIN이 아닌 정의, 동적 가지 태스크의
    rerun·retry
  - INLINE의 `javascript`·`value-param`·모르는 평가기·스크립트 오류, LAMBDA
  - JSON_JQ_TRANSFORM의 여러 결과, `null` 결과, 문법 오류, `queryExpression` 없음
  - START_WORKFLOW의 성공(시작된 워크플로우 GET 포함)과 검증 실패
  - HTTP의 2xx JSON·글자·수 body, 표에 없는 2xx 코드, 4xx(짧은 body·긴 body·body 없음), 5xx, `asyncComplete`, `inputParameters`의
    `asyncComplete` 표현식, `uri`·`method` 없음, 연결 거부
  - 등록 검사: HTTP·JSON_JQ_TRANSFORM 규칙의 400
- **HTTP 대상 stub.** 캡처와 재생이 같은 응답을 받도록 고정 응답 HTTP stub(Plug, `test/support/`)을 둔다. 캡처 스크립트는 그 stub를
  띄워 upstream 서버의 HTTP 태스크가 부르게 하고, 재생은 같은 stub를 시험 안에서 띄운다. 포트가 다르므로 재생 도우미는 픽스처의
  요청·응답 값에 든 캡처 stub 주소를 시험 stub 주소로 바꿔 비교한다. stub는 요청 헤더(`User-Agent`, `Accept` 등 클라이언트마다
  다른 값)를 응답에 싣지 않는다. 응답 헤더 중 시각처럼 정해지지 않는 값과 `workerId`는 `ignore`로 적는다.
- **정의 변경 확인.** DYNAMIC·HTTP 매퍼가 정의 객체를 바꾸는지(결정 4·7) 보도록, 그 타입의 시나리오는 끝난 워크플로우 GET의
  `workflowDefinition`을 비교 대상에 둔다.
- **아직 구현하지 않은 타입의 재생.** 7a가 새 단계마다 쓰는 워크플로우 태스크 타입을 단계 옵션 `types: [...]`로 적고, 재생
  도우미는 매퍼 표(결정 2)에 없는 타입이 있는 단계를 건너뛴다. 뒤 단계가 앞 단계에 기대면 그 단계도 같은 타입을 적는다. 그래서 각 조각은 매퍼 표에 자기
  타입을 넣으면 자기 단계가 켜지고, 시나리오를 고치지 않는다. 7h가 이 옵션을 없앤다.
- 결정 루프 단위의 재생(`Archon.StepReplay`)도 타입마다 더한다. 이것은 각 조각이 자기 시험 파일로 한다.

- **조각 7a에서 정한 것과 캡처에서 확인한 것(2026-11-02).** 픽스처는 `p7_<타입>_*` 160개다(기존 360개와 한 번에 캡처, 모두
  520개). 기존 픽스처는 `normalize/1` 기준으로 같았고, 다른 것은 순서뿐이다(bulk 오류 맵의 키, 순서 없는 목록
  `workflow_correlated_paused_closed`·Later 경로 `route_later_tasks_search`). `task_update_v2_invalid_both`의 두 오류 순서는
  6a처럼 기존 캡처를 남겼다. 재생 장치는 단계 옵션 `types:`, `until: :settled`(워크플로우 상태·태스크 수·각 태스크 상태가
  픽스처와 같을 때까지 다시 읽음), stub 주소 치환(`new_state(http_stub: url)`, 캡처 주소 `http://127.0.0.1:18299`)이다.
  stub는 Plug가 모르는 상태 코드 299의 사유 문구를 `config :plug, :statuses`(시험 설정)로 준다.
  캡처에서 이 ADR의 서술과 다르거나 서술이 없던 upstream 응답(그 응답이 정답):
  - TERMINATE의 문자열이 아닌 `terminationStatus`는 정의 검사가 막는다. 수 `5`도, 표현식 `${workflow.input.status}`도 등록이
    400이다(`p7_terminate_register_not_string`, `_expression`). 그래서 REST로는 `"given termination status is not valid"`에 닿지 않는다.
  - EXCLUSIVE_JOIN의 실패: `permissive` 태스크를 `FAILED`로 갱신하면 태스크는 `FAILED`로 저장되고 `POST /api/tasks`가
    `NullPointerException` 500(`Cannot invoke "...TaskModel.getStatus()" because "t" is null`)이며 워크플로우는 `RUNNING`에 남는다
    (`p7_exclusive_join_failed_*`). permissive가 아닌 실패는 EXCLUSIVE_JOIN 전에 워크플로우를 끝내므로 다른 실패 경로가 없다.
  - DYNAMIC 정의 없는 이름은 결정 4 끝.
  - FORK_JOIN_DYNAMIC: retry는 두 가지를 다시 예약한다. upstream의 JOIN 평가(시스템 태스크 워커)가 retry와 경합하면 워크플로우가
    바로 다시 `FAILED`가 될 수 있어, 캡처는 retry가 버틴 경우를 기다린다(아니면 캡처 실패). 끝난 뒤 한 가지의 마지막 시도에서
    rerun하면 그 가지와 함께 다른 가지의 첫 시도(`retryCount` 0)가 `SCHEDULED`가 되고 JOIN은 `COMPLETED`로 남는다
    (`p7_fjd_rerun_branch_get`). 종료 뒤 FORK 태스크에서 rerun하면 가지가 새로 만들어진다(`p7_fjd_rerun_fork_get`).
  - INLINE의 문자열이 아닌 `evaluatorType`·`expression`은 시작 요청이 500(`class java.lang.Integer cannot be cast to class
    java.lang.String ...`)이다. 시작이 결정까지 같은 요청에서 하므로 워크플로우 ID를 받지 못한다(`p7_inline_*_not_string_start`).
  - JSON_JQ_TRANSFORM의 문자열이 아닌 `queryExpression`은 워크플로우 `FAILED`, `"Error scheduling tasks: [<태스크 ID>], for
    workflow: <워크플로우 ID>"`, 태스크 `CANCELED`다(`p7_jq_not_string_get`).
  - HTTP: Spring 표에 없는 2xx(299)는 `"Failed to invoke HTTP task due to: java.lang.IllegalArgumentException: No matching constant
    for [299]"`이고 출력 `response`도 그 예외 문자열이다(`java.lang.Exception:`으로 감싸지 않음). 연결 거부는
    `"... java.lang.Exception: I/O error on GET request for \"<uri>\": Connect to http://127.0.0.1:9 failed: Connection refused (connect
    failed)"`. 긴 body(1,010바이트)는 Spring이 줄여 끝 따옴표 없이 끝난다(`p7_http_long_400_get`). 수 body는 `42.0`. `workerId`는
    서버 호스트 이름이라 재생에서 뺀다. stub(Bandit)가 헤더 이름을 소문자로 보내므로 캡처의 헤더 이름도 소문자다.
  - START_WORKFLOW 검증 실패 문구는 `"startWorkflow validation failed. 'name' -> Workflow name cannot be null or empty. "`이다.
  - SET_VARIABLE 크기 초과는 `variables`를 되돌리고 크기를 바이트로 적는다(`270021`).

### 9. 구현 조각

| 조각 | 범위 | 시험·정답 기준 | 선행 | 건드리는 파일·모듈 |
|---|---|---|---|---|
| 7a | 결정 2의 두 표와 behaviour, 주입 함수 셋과 설정 자리, `Step.Env`의 진행 중 집합 자리(결정 7), 타입 제약의 태스크 정의 조회 연결, 결정 8의 캡처 전부·HTTP stub·`types:` 건너뛰기, 캡처에서 정의 변경이 보이면 Decider 계약(결정 4) | 기존 시험·재생 전부 그대로 통과(동작 무변경), 기존 픽스처 재캡처 비교, 건너뛰기를 뺀 전체 재생 | Phase 6 조각 6h 머지(같은 재생 장치·픽스처 등록·재캡처를 고친다) | `lib/archon/decider.ex`, `lib/archon/decider/{system_tasks,system_task,mapper,retry,context,outcome}.ex`, `lib/archon/decider/system_task/*`, `lib/archon/runtime/step/{schedule,async,postpone,recover,lifecycle,decide,env}.ex`, `lib/archon/runtime/tasks.ex`, `lib/archon/domain/{workflow_task,workflow_def,start_workflow_request,task_type_constraint}.ex`(조회 옵션), `lib/archon/metadata.ex`, `lib/archon/runtime.ex`(시작 검증의 조회), `config/config.exs`, `test/support/step_replay.ex`, `scripts/contract/capture_fixtures.sh`, `test/fixtures/contract/*`, `test/fixtures/contract/README.md`, `test/support/contract.ex`, `test/support/archon_web/contract_case.ex`, `test/archon_web/contract_case_test.exs`, `test/support/http_stub.ex`, `test/archon/contract_test.exs`, `test/archon/domain/contract_round_trip_test.exs` |
| 7b | 결정 3: TERMINATE, SET_VARIABLE, NOOP, HUMAN, EXCLUSIVE_JOIN | upstream `TestDeciderService`·`TerminateTest`·`SetVariableTest`·`ExclusiveJoinTest` 등에서 옮긴 사례, FORK 가지 끝 SET_VARIABLE의 저장 시험, StepReplay, 픽스처 재생 | 7a | `lib/archon/decider/mapper/{terminate,set_variable,noop,human,exclusive_join}.ex`, `lib/archon/decider/system_task/{terminate,set_variable,noop,human,exclusive_join}.ex`, 두 표의 자기 줄, 해당 시험 |
| 7c | 결정 4: DYNAMIC, FORK_JOIN_DYNAMIC, rerun의 동적 포크 분기, SUB_WORKFLOW 매퍼의 `workflow_def_lookup` 사용 | `DynamicTaskMapperTest`·`ForkJoinDynamicTaskMapperTest`에서 옮긴 사례, 동적 가지 rerun·retry 시험과 갱신이 늘 결정하는 회귀 시험(두 백엔드), 픽스처 재생 | 7a | `lib/archon/decider/mapper/{dynamic,fork_join_dynamic}.ex`, `lib/archon/decider/mapper/fork_join.ex`(공용 함수 꺼내기), `lib/archon/decider/mapper/sub_workflow.ex`(`latest_workflow_versions`에 없는 이름의 조회), `lib/archon/runtime/step/lifecycle.ex`(rerun 분기), 매퍼 표의 자기 줄, 해당 시험 |
| 7d | 결정 5: INLINE, LAMBDA | GraalJS 오라클 비교, `InlineTest`·`LambdaTest` 사례, 픽스처 재생 | 7a | `lib/archon/decider/mapper/{inline,lambda}.ex`, `lib/archon/decider/system_task/{inline,lambda}.ex`, 두 표의 자기 줄, 해당 시험 |
| 7e | 결정 6: jq vendoring, `archon_jq`, 풀 일반화와 `Archon.Jq.Pool`, JSON_JQ_TRANSFORM, 그 타입 제약 | jackson-jq 프로브 비교, `JsonJqTransformTest` 사례, 격리 시험(`$ENV`, `import`, 시간·출력 상한), 픽스처 재생 | 7a | `c_src/jq/*`, `c_src/archon_jq/*`, `Makefile`, `NOTICE`, `.github/workflows/ci.yml`(sanitize 빌드), `config/*.exs`, `lib/archon/script/{pool,worker}.ex`, `lib/archon/jq.ex`, `lib/archon/application.ex`, `lib/archon/decider/mapper/json_jq_transform.ex`, `lib/archon/decider/system_task/json_jq_transform.ex`, `lib/archon/domain/task_type_constraint.ex`(JQ 규칙 절), 두 표의 자기 줄, 해당 시험 |
| 7f | 결정 7의 공통 비동기 경로(시작 멱등 성질, 결과 이벤트와 시도 확인, 복구·재평가 시각)와 START_WORKFLOW | 비동기 시작·결과 버림·복구 재시작 시험(두 백엔드), `StartWorkflowTest` 사례, 픽스처 재생 | 7a | `lib/archon/runtime/step/{async,event,effect,recover,postpone,start_workflow}.ex`, `lib/archon/runtime/step.ex`, `lib/archon/runtime/effects.ex`, `lib/archon/runtime/workflow_server.ex`, `lib/archon/decider/mapper/start_workflow.ex`, 두 표의 자기 줄, 해당 시험 |
| 7g | 결정 7의 HTTP(진행 중 집합, `evict_after` 예외, 결과 전달 API) | stub 대상 시험(성공·4xx·5xx·시간 초과·body 상한·동시 상한·진행 중 재시작 안 함·프로세스 교체 뒤 결과·`TIMED_OUT`), `HttpTaskTest` 사례, 픽스처 재생 | 7e, 7f | `mix.exs`·`mix.lock`(Finch), `lib/archon/runtime/http_task.ex`, `lib/archon/runtime/step/http.ex`, `lib/archon/runtime/step/{async,event,recover,postpone}.ex`(HTTP 분기), `lib/archon/runtime/workflow_server.ex`, `lib/archon/application.ex`, `config/*.exs`, `lib/archon/decider/mapper/http.ex`, `lib/archon/domain/task_type_constraint.ex`(HTTP 규칙 절), 두 표의 자기 줄, 해당 시험 |
| 7h | 통합: `types:` 건너뛰기 제거와 전체 재생(두 백엔드), 빠진 픽스처, README 호환성 절(지원 타입 표, 의도적 차이, HTTP SSRF 경고), `TaskTypeConstraint` moduledoc, ADR 0003 결정 4 비고, 이 ADR `승인` | `mix test` 전부(두 백엔드), CI | 7b~7g | `test/support/archon_web/contract_case.ex`, `test/archon_web/contract_case_test.exs`, `README.md`, `docs/adr/{0003,0026,README}.md`, 빠진 픽스처가 있으면 7a의 픽스처 파일들 |

- **병렬로 진행할 수 있는 묶음.**
  - 1차: 7a(Phase 6 마지막 조각 6h가 머지된 뒤).
  - 2차: 7b, 7c, 7d, 7e, 7f. 새 타입 모듈은 각자 새 파일이다. 함께 고치는 곳은 두 표(`mapper.ex`, `system_tasks.ex`)의 자기 타입
    줄뿐이다. 7a가 `Decider.Context`·`Step.Env`의 주입 함수·설정 자리와 타입 제약의 조회 연결을 먼저 만들므로 7c·7e는 그 파일을
    고치지 않는다. 같은 줄을 고치지 않으므로 겹쳐도 `gh pr update-branch`로 푸는 작은 충돌이다.
  - 3차: 7g(7f 뒤. 같은 비동기 파일을 고친다. 7e 뒤. `application.ex`·`config`·`task_type_constraint.ex`를 함께 고친다).
  - 마지막: 7h.
- 각 조각은 자기 타입을 매퍼 표에 넣어 재생 단계를 켠다(결정 8). 구현하다 자기 단계의 옵션(`ignore` 등)을 더 고쳐야 하면 그 단계
  줄만 고친다(ADR 0025 결정 8과 같음).
- 각 조각은 이 ADR의 결정 번호와 조각 이름을 PR에 적는다. 조각 중에 결정이 바뀌면 이 ADR의 해당 결정과 날짜 줄에 갱신 사실을
  적는다.

## upstream과 의도적으로 다른 점

ADR 0023·0025의 목록에 더해 다음이 생긴다.

- **비동기 시스템 태스크의 실행 위치**(결정 7): upstream은 타입 이름의 큐를 시스템 태스크 워커가 50ms마다 꺼낸다. archon은 워크플로우
  프로세스가 바로 시작하고 결과를 이벤트로 받는다. 그래서 `HTTP`·`START_WORKFLOW` 큐가 없고, 큐 크기 조회 등에 나타나지 않는다.
  결과 상태는 같고 반영이 더 이르다.
- **START_WORKFLOW의 시작 멱등**(결정 7): upstream은 START_WORKFLOW를 멱등으로 보지 않아 시작 중 죽으면 `responseTimeout` 뒤
  `TIMED_OUT`이다. archon은 태스크로 정해지는 ID로 멱등 시작하고 복구가 바로 다시 시작한다. 검증 위반 여럿의 순서는 경로 순이다.
- **HTTP 응답 body 상한**(결정 7): 10 MiB를 넘으면 `FAILED`. upstream은 다 읽은 뒤 출력 크기 한도(외부 저장소 임계값)로 다룬다.
- **HTTP 응답 헤더 이름**(결정 7): 소문자다(Mint). upstream은 서버가 보낸 대소문자다.
- **HTTP 전송 오류 문구**(결정 7): 연결 거부·시간 초과는 Spring 메시지의 앞부분만 맞추고 원인 문구는 archon 문구다. 4xx·5xx의
  메시지는 맞춘다.
- **HTTP 요청의 전체 시간 상한과 취소**(결정 7): 쓰이지 않는 요청을 끊고 요청마다 전체 시간 상한을 둔다. upstream은 읽기 시간 상한만 있다. 값과 방법은 7g가 결정 7에 적는다.
- **HTTP 빈도 한도**(결정 7): `rateLimitPerFrequency`를 적용하지 않는다(worker 태스크와 같음).
- **INLINE의 `python` 평가기**(결정 1): 없다(ADR 0015 결정 5).
- **INLINE 평가기 풀 오류**(결정 5): upstream에 대응이 없다. 재시도 가능한 `FAILED`다.
- **FORK_JOIN_DYNAMIC 오류 문구의 Java `toString`**(결정 4): 재현하지 않는다.
- **JQ 엔진**(결정 6): jackson-jq 대신 jqlang. 시간 상한(기본 4초)이 있다. 프로브가 찾은 차이 중 맞추지 않은 것은 조각 7e가 여기에 더한다.
- **HUMAN의 결정 큐**(결정 3): `humanTaskPreventsDeciderQueue`에 대응하는 것이 없다. 결과 상태는 같다.
- **비밀 값 치환**(결정 1): 하지 않는다.

## 대안

- **다른 주제:** 검색·색인과 task log(UI 목록 화면), 스케줄러(upstream 기본 켜짐), 이벤트 핸들러를 먼저 할 수 있었다. 이 타입들 없이는
  흔한 정의가 시작부터 끝나거나 멈추므로 BOSS가 태스크 타입을 먼저 골랐다. 조사 내용은 결과 절에 남긴다.
- **HTTP를 다음 단계로:** 외부 호출과 비동기 실행기를 따로 볼 수 있지만, 가장 많이 쓰는 시스템 태스크라 이번에 연다(BOSS 결정).
- **엔진 없는 타입만:** 조각이 셋으로 줄지만 INLINE·JQ·HTTP를 쓰는 정의가 계속 돌지 않는다.
- **jq 엔진으로 실행 환경의 `jq` 바이너리:** 빌드는 가볍지만 환경마다 버전·동작이 달라지고 격리 조건(`$ENV`, `import`)을 호스트가
  보장하지 못한다. **Elixir 구현이나 NIF:** 완성된 Elixir jq가 없고, NIF는 엔진 버그가 BEAM을 멈춘다(ADR 0015와 같은 이유). BOSS가
  vendoring을 골랐다.
- **HTTP 대상 허용 목록(기본 빈 목록):** 안전하지만 upstream 정의가 그대로 돌지 않는다. BOSS가 upstream과 같게 제한 없이 두고 인증
  ADR에서 함께 보기로 했다.
- **비동기 타입을 upstream처럼 큐와 폴러로:** 큐 의미가 같아지지만 워크플로우 프로세스가 이미 상태를 쥐고 있는데 큐를 한 번 더
  거치게 되고, 결과 반영을 위해 다시 프로세스를 깨워야 한다. 프로세스가 직접 시작하는 쪽이 ADR 0018의 모델과 맞다.
- **HTTP를 워크플로우 프로세스 안에서 동기로:** 하위 워크플로우 시작처럼 `Effects.run`에서 부를 수 있지만 `readTimeOut` 동안 그
  워크플로우의 다른 이벤트(종료, 다른 태스크 갱신)가 막힌다.
- **HTTP 클라이언트로 OTP `:httpc`나 Req:** `:httpc`는 의존성이 없지만 연결·받기 시간 상한을 따로 다루기 어렵고 TLS 검증 설정을
  직접 해야 한다. Req는 Finch 위의 편의 계층이라 이 용도에는 더하는 것이 없다.
- **정의 조회를 미리 하기(동적 이름):** `Decider`가 이름이 필요하다고 돌려주면 런타임이 읽고 다시 부르는 방식은 매퍼 중간에서 멈춰야
  해서 Decider를 재개 가능한 상태 기계로 만든다(ADR 0015 결정 3과 같은 이유). 읽기 전용 주입 함수를 쓴다.
  모든 태스크 정의를 결정마다 미리 읽는 방식은 정의 수에 비례하는 읽기를 매 결정에 더한다.

## 결과

- 이 ADR은 결정만 담는다. 구현은 결정 9의 조각 7a~7h로 하고, 마지막 조각 7h의 PR에서 `승인`으로 바꾼다.
- [ADR 0003](0003-porting-strategy.md) 단계 표에 Phase 7을 더한다. 결정 4의 "나머지 타입은 그 뒤에"는 이 ADR이 연 타입만큼 줄어든다
  (7h가 비고를 단다). [ADR 0001](0001-api-contract-scope.md)의 경로 분류는 바뀌지 않는다(새 경로 없음).
- [ADR 0014](0014-phase2-decider.md) 결정 2("`task_defs`는 호출자가 미리 채운다")와 [ADR 0015](0015-script-evaluator.md) 결정 3의
  주입 함수 예외를 metadata 읽기 조회 둘(`task_def_lookup`, `workflow_def_lookup`)과 jq 평가까지 넓힌다(결정 2).
- [ADR 0014](0014-phase2-decider.md) 결정 7이 미룬 HTTP·JSON_JQ_TRANSFORM 타입 제약과 [ADR 0015](0015-script-evaluator.md)가 미룬
  INLINE·LAMBDA를 이 ADR이 다룬다. ADR 0025 "의도적으로 다른 점"의 rerun 동적 FORK 분기는 7c가 닫는다.
- 새 의존성: Finch(와 Mint, NimblePool, NimbleOptions), vendoring한 jqlang·oniguruma. `mix deps.audit`와 `NOTICE`가 다룬다.
- 아직 범위 밖: EVENT·KAFKA_PUBLISH·PULL_WORKFLOW_MESSAGES 타입, `python` 평가기, 비밀 값 치환, 빈도 한도, 입력·출력 스키마 강제
  (`enforceSchema`, `/api/schema`), task log, 검색·색인과 `bulk/search`, 이벤트 핸들러, 외부 payload 저장소, 큐 관리·admin, 스케줄러,
  인증(ADR 0024 결정 4), 여러 노드, `POST /api/workflow/test`, 배포 절차.
- 이 Phase의 후보 조사(2026-11-02, upstream 기준 SHA)에서 다음을 확인했다. 다음 단계를 고를 때 쓴다.
  - upstream 기본 서버(`conductor.indexing.type=sqlite`)의 `SqliteIndexDAO`는 검색 넷(`search`, `search-v2`, `search-by-tasks`,
    `search-by-tasks-v2`)과 task log를 실제 SQL로 구현한다. 아무 일도 하지 않는 것은 ADR 0025 맥락이 적은 `get`·`updateWorkflow`·
    `updateTask`와 비동기 변형 등이다. `POST /api/workflow/bulk/search`는 색인을 쓰지 않고 ID 목록으로 실행 DAO를 읽는다.
  - 스케줄러는 기본 켜짐(`conductor.scheduler.enabled=true`, core 약 2,756줄, SQLite 표 넷, 경로 13개).
  - 이벤트 핸들러는 `conductor:` 큐(QueueDAO)만 기본으로 동작하고 브로커 모듈은 모두 기본 꺼짐이다.
  - 외부 payload 저장소의 기본은 임시 디렉터리에 쓰는 `DummyPayloadStorage`다.
  - environment·secrets는 `CONDUCTOR_ENV_`·`CONDUCTOR_SECRET_` 접두 환경 변수를 읽기만 한다. upstream OSS 서버에는 인증이 없다.
  - 알려진 archon 결함 후속(단계와 별개): Postgres outbox의 `notify_parent`가 커밋 시점 자식 스냅샷을 실어, 자식 종료 알림 전달 전에
    자식을 재시도하면 부모가 끝나고 재시도된 자식까지 다시 종료될 수 있다. `sub_workflow_test`의 `child_of`가 Postgres에서 가끔 실패한다.
