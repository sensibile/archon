# ADR 0014: Phase 2 Decider 설계

- 상태: 제안
- 날짜: 2026-10-29 (2b에서 결정 1·2·5 갱신)
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`

## 맥락

[ADR 0003](0003-porting-strategy.md)은 Phase 2를 "Decider를 부수효과 없는 순수 함수로"로 정하고, 단계를
시작할 때 설계 결정을 따로 남기도록 했다. [ADR 0002](0002-domain-model-representation.md)는 태스크
타입별 필수 필드 검증(`WorkflowTaskTypeConstraint`)과 `WorkflowDef`의 탐색 메서드를 Phase 2로 넘겼다.

upstream의 결정 로직은 다음에 흩어져 있다.

- `core/.../execution/DeciderService.java`(1,059줄): `decide`, `startWorkflow`, `retry`, 타임아웃 검사,
  `checkForWorkflowCompletion`, `getTasksToBeScheduled`.
- `core/.../utils/ParametersUtils.java`(557줄): `${...}` 입력 참조를 Jayway JsonPath 2.4.0으로 해석한다.
- `core/.../execution/mapper/*TaskMapper.java`: `WorkflowTask` 하나를 예약할 `TaskModel` 목록으로 바꾼다.
- `core/.../execution/tasks/*.java`: SWITCH·JOIN·DO_WHILE 등 시스템 태스크의 실행 단계.

`DeciderService`는 순수 함수가 아니다. 넘겨받은 `WorkflowModel`과 `TaskModel`을 직접 고치고
(`setStatus`, `setExecuted`, `setOutput`), 그 밖에도 다음 다섯 가지 바깥 상태를 읽는다.

| 의존 | 쓰는 곳 |
|---|---|
| `System.currentTimeMillis()` | 워크플로우·태스크·폴링·응답·전체 타임아웃, 재시도 지연 |
| `IDGenerator.generate()` | 새 태스크와 재시도 태스크의 `taskId` |
| `MetadataDAO.getTaskDef` | 태스크에 정의가 붙어 있지 않을 때의 재시도 정책 조회 |
| `ExternalPayloadStorageUtils.downloadPayload` | 완료 시 외부 저장소에 있는 마지막 태스크 출력 |
| `SystemTaskRegistry` | 시스템 태스크 여부, `isAsyncComplete` |

또 upstream의 내부 모델(`core/.../model/TaskModel`, `WorkflowModel`)에는 Phase 1 struct에 없는 필드가 있고,
Decider가 이 필드를 읽는다(`TaskModel.firstScheduledTime`, `waitTimeout`, `loopTaskId`, `callbackAfterMs`,
`WorkflowModel.previousStatus`, `failedTaskId`).

## 결정

### 1. Decider는 값을 받아 값을 돌려준다

```elixir
@spec decide(Workflow.t(), Context.t()) ::
        {:ok, Outcome.t()} | {:terminate, Termination.t(), Outcome.t()}
```

- `Outcome`은 upstream `DeciderOutcome`의 네 필드(`tasks_to_be_scheduled`, `tasks_to_be_updated`,
  `complete?`, `terminate_task`)에 갱신된 `workflow`를 더한다. upstream이 제자리에서 바꾸던 상태
  (`executed`, `COMPLETED_WITH_ERRORS`, 타임아웃 표시, 완료 시 `output`)는 갱신된 `workflow` 안에 담긴다.
- upstream이 `TerminateWorkflowException`을 던지는 곳은 `{:terminate, termination, outcome}`을 돌려준다.
  `Termination`은 예외의 세 값 `reason`(upstream 문구 그대로), `status`(워크플로우가 갈 상태, 기본
  `:failed`), `task`(원인 태스크, 없으면 `nil`)를 담는다. 처음 제안은 `reason` 문자열만 돌려주는
  것이었지만, upstream 런타임(`WorkflowExecutorOps#terminate`)이 `status`로 `COMPLETED`·`TIMED_OUT`·
  `TERMINATED`를 가르고 `task`로 실패 태스크를 기록하므로 2b에서 구조체로 바꿨다. 예외로 흐름을 끊지
  않으므로 그 시점까지의 `outcome`도 함께 준다. 이미 바뀐 태스크 상태(타임아웃 표시 등)와, 재시도가
  끝나 종료할 때 upstream이 먼저 채우는 `output`이 `outcome.workflow`에 들어 있다.
- `complete?`가 참이면 `outcome.workflow.output`은 upstream `completeWorkflow`가 부르는
  `updateWorkflowOutput(workflow, null)`의 결과다. 상태를 `COMPLETED`로 바꾸고 `endTime`을 찍는 일은
  런타임이 한다.
- 저장, 큐 투입, 하위 워크플로우 시작, 알림은 Decider가 하지 않는다. `Outcome`을 받은 Phase 3 런타임이
  수행한다.

### 2. 바깥 상태는 `Context`로 주입한다

| 필드 | 대체하는 upstream 의존 | 비고 |
|---|---|---|
| `now :: integer()` | `System.currentTimeMillis()` | 한 번의 `decide` 안에서 같은 값을 쓴다 |
| `new_id :: (-> String.t())` | `IDGenerator.generate()` | 기본값은 UUID v4, 테스트는 결정적 생성기 |
| `task_defs :: %{String.t() => TaskDef.t()}` | `MetadataDAO.getTaskDef` | 호출자가 정의에 나오는 이름으로 미리 채운다. 없으면 upstream의 `null`과 같다 |
| `system_tasks` | `SystemTaskRegistry` | 타입 → `isAsyncComplete` 규칙(`:by_task` 또는 고정 값). 기본은 MVP 시스템 태스크 `DECISION`, `SWITCH`, `FORK`, `JOIN`, `DO_WHILE`, `SUB_WORKFLOW`(항상 `true`), `WAIT` |
| `jitter :: (max -> 0..max)` | `ThreadLocalRandom` | 2b에서 추가. 재시도 지연의 `backoffJitterMs`. 기본은 균등 난수, 테스트는 고정 함수 |

`new_id`와 `jitter`는 Decider가 받는 입력 중 결정적이지 않은 값이다. 테스트에서는 결정적 생성기를 넣으므로
같은 입력에 같은 결과가 나온다. "부수효과 없음"은 I/O·영속성·큐·프로세스 메시지가 없다는 뜻으로 쓴다.

외부 payload 저장소는 [ADR 0001](0001-api-contract-scope.md)에서 Later로 분류했다. Archon은
`externalOutputPayloadStoragePath`를 만들지 않으므로 Phase 2 Decider는 그 필드를 보지 않는다.
외부 저장소를 들일 때 `Context`에 조회 함수를 추가한다.

### 3. 내부 실행 필드는 기존 struct에 넣고 wire에는 내보내지 않는다

`Task`와 `Workflow` struct에 위 내부 필드를 추가하고, 필드 표에 `wire: false` 옵션을 둔다.

- `to_json/1`(REST 응답)은 지금처럼 upstream wire 형태만 낸다. 골든 픽스처 왕복 테스트는 그대로 통과해야 한다.
- `from_json/2`는 이 필드를 읽지 않는다.
- Phase 4 영속화용으로 내부 필드를 포함하는 인코딩 모드를 따로 둔다. 이름과 형식은 Phase 4 ADR에서 정한다.

별도의 `TaskModel` struct를 두지 않는 이유: 필드의 90% 이상이 같아서 두 struct 사이의 변환 코드가
upstream `TaskModel.toTask()`처럼 커지고, Decider·런타임·REST가 서로 다른 타입을 다루게 된다.

### 4. 입력 파라미터 해석은 upstream 규칙을 옮기고, JsonPath는 일부만 지원한다

`Archon.Decider.Parameters`가 `ParametersUtils.getTaskInputV2`를 옮긴다.

- 컨텍스트 문서는 upstream과 같은 키로 만든다. `workflow.{input, output, status, workflowId, parentWorkflowId,
  parentWorkflowTaskId, workflowType, version, correlationId, reasonForIncompletion, schemaVersion, variables}`,
  그리고 태스크 참조명마다 `{input, output, taskType, status, referenceTaskName, retryCount, correlationId,
  pollCount, taskDefName, scheduledTime, startTime, endTime, workflowInstanceId, taskId,
  reasonForIncompletion, callbackAfterSeconds, workerId, iteration}`. 루프 안 태스크는 반복 접미사를 뗀
  참조명을 키로 쓴다.
- 표현식 탐색은 upstream `findExpressions`를 따른다. `$${`는 리터럴 `${`이고, 중첩 `${...${...}...}`은 안쪽부터
  해석하며, 깊이 제한은 `MAX_EXPRESSION_DEPTH`와 같다. 문자열 전체가 표현식 하나이면 값의 타입을 그대로
  유지하고, 아니면 Java `toString` 규칙으로 이어 붙인다(`null`은 `"null"`, 실수는 `Double#toString`,
  맵은 `{k=v, ...}`). 맵의 키 순서는 보존하지 않으므로 정렬해서 쓴다(ADR 0002).
- `TaskDef.inputTemplate`은 빠진 키를 채우고, 해석 결과가 `null`인 키를 다시 채운다.
- 시스템 파라미터 `CPEWF_TASK_ID`는 태스크 ID로 바꾼다. `NETFLIX_ENV`·`NETFLIX_STACK`과 JVM 시스템
  프로퍼티·OS 환경 변수는 조회하지 않는다. 결과는 upstream 서버에 해당 변수가 하나도 설정되지 않았을 때와
  같다: `${NETFLIX_ENV}`·`${NETFLIX_STACK}`은 그대로 남고, 다른 이름은 JsonPath 조회로 넘어간다
  (아래 "upstream과 의도적으로 다른 점").
- `${workflow.secrets.*}`는 upstream처럼 리터럴로 남긴다. secrets 공급자가 없을 때 upstream
  `substituteSecrets`도 입력을 그대로 돌려준다. `${workflow.env.*}`는 environment 공급자가 없을 때의
  upstream 동작대로 JsonPath 조회로 넘어가서 `null`이 된다.
- 경로 문법은 다음만 지원한다: 선택적 `$` 루트, 점 표기 `a.b.c`, 따옴표 괄호 `['a b']`·`["a"]`(루트 바로
  뒤 `['a']`·`$.['a']` 포함, 백슬래시 이스케이프와 `\uXXXX` 해석), 정수 인덱스 `[0]`·`[-1]`, 와일드카드 `[*]`·`.*`. 와일드카드가 있는 경로는 Jayway처럼 닿은 값의 목록을
  돌려주고, 풀리지 않는 가지는 건너뛴다. upstream `TestDeciderService#testGetTaskInputV2Partial`이
  `${workflow.output.names[*].year}`를 쓰므로 부분집합에 넣었다. 지원하지 않는 문법(deep scan `..`, 필터,
  슬라이스, 합집합, 함수, `@` 루트)과 잘못된 경로는 `null`이다. 지원 문법의 결과는 로컬 캐시의
  `json-path-2.4.0.jar`로 같은 문서에서 확인했다. upstream은 `SUPPRESS_EXCEPTIONS` 설정이라 없는
  경로와 컴파일되지 않는 경로가 `null`이 된다.
- `getTaskInputV1`(`schemaVersion` 1)은 옮기지 않는다. upstream `WorkflowDef`가 이미 `@Min(2)`·`@Max(2)`로
  2만 받고, Archon `WorkflowDef.validate/2`도 같은 검사를 한다.

새 JsonPath 의존성은 들이지 않는다. Hex의 JsonPath 구현들은 Jayway와 문법·결과가 같다는 보장이 없고,
MVP 정의에서 쓰는 경로는 위 부분집합 안에 있다.

### 5. 태스크 매퍼는 behaviour, 시스템 태스크 실행은 Phase 3

- `Archon.Decider.Mapper` behaviour: `map(WorkflowTask.t(), Mapper.Context.t()) :: {:ok, [Task.t()]} | {:terminate, String.t()}`.
  타입 문자열로 모듈을 고르고, 등록되지 않은 타입은 upstream처럼 `USER_DEFINED` 매퍼
  (`UserDefinedTaskMapper`)로 간다. 매퍼의 종료 문구는 `Decider`가 `status: :failed`인 `Termination`으로
  감싼다. `Mapper.Context`는 upstream `TaskMapperContext`이고, 시계·ID·태스크 정의는 `decider` 필드의
  `Context`에서 읽는다.
- SIMPLE 매퍼는 upstream처럼 `WorkflowTask`에 박힌 태스크 정의만 본다(없으면 `TaskDef` 기본값). 정의를
  박아 넣는 일(upstream `MetadataMapperService`)은 워크플로우를 시작하는 런타임이 한다.
- MVP 매퍼: SIMPLE, SWITCH(`DECISION` 포함), FORK_JOIN, JOIN, DO_WHILE, SUB_WORKFLOW, WAIT.
- SWITCH·JOIN·DO_WHILE의 "실행" 단계(upstream `WorkflowSystemTask.execute`)에서 상태만 판정하는 부분은
  순수 함수로 Phase 2에 둔다. 하위 워크플로우 시작처럼 바깥과 통신하는 부분은 Phase 3에서 붙인다.

### 6. 평가기는 `value-param`만 먼저 구현한다

- SWITCH의 `evaluatorType`이 `value-param`이면 upstream `ValueParamEvaluator`를 옮긴다.
- `javascript`·`graaljs`·`python`과 DO_WHILE의 `loopCondition`(upstream `ScriptEvaluator.evalBool`)은 JS 엔진을
  어떻게 들일지 정하는 별도 ADR에서 다룬다. 그 전까지 SWITCH에서 이 평가기를 쓰면 upstream
  `SwitchTaskMapper`가 등록되지 않은 평가기에 쓰는 문구(`No evaluator registered for type: <type>`)로
  워크플로우를 종료시킨다. DO_WHILE은 2e 전까지 매퍼를 등록하지 않는다.

### 7. 정의 탐색과 타입 제약

- `WorkflowDef`에 `next_task/2`, `contains_type?/2`를, `WorkflowTask`에 `next/3`, `has?/2`, `get/2`를 추가한다.
  `collect_tasks/1`, `task_by_ref_name/2`는 Phase 1에 있다.
- `WorkflowTaskTypeConstraint`(core, 590줄)를 `Archon.Domain.TaskTypeConstraint`로 옮기고
  `WorkflowTask.errors/1`에서 부른다. upstream이 `constraints.xml`로 모든 `WorkflowTask`에 거는 제약이라
  MVP 타입에 한정하지 않고 EVENT, DECISION, SWITCH, DYNAMIC, FORK_JOIN_DYNAMIC, FORK_JOIN, TERMINATE,
  DO_WHILE, SUB_WORKFLOW, WAIT 규칙을 옮긴다. 메시지는 upstream 문구를 그대로 쓴다.
- 다음은 아직 옮기지 않는다. HTTP·KAFKA_PUBLISH·JSON_JQ_TRANSFORM 규칙은 `MetadataDAO`에서 태스크 정의를
  찾아야 하므로 영속성이 생긴 뒤에 붙인다. DECISION `caseExpression`과 `javascript` SWITCH `expression`의
  스크립트 문법 검사는 결정 6의 평가기 ADR에서 다룬다.
- WAIT `until`은 upstream 날짜 패턴(`yyyy-MM-dd HH:mm`, `yyyy-MM-dd HH:mm z`, `yyyy-MM-dd`)의 모양만 검사한다.
  관대한 `SimpleDateFormat`이 범위 밖 값(13월 등)을 넘겨 받는 동작은 재현하지 않는다.

### 8. 구현 순서와 정답 기준

| 조각 | 범위 | 정답 기준 |
|---|---|---|
| 2a | 결정 4, 7, 결정 3의 필드 추가 | upstream `ParametersUtilsTest`, `TestWorkflowDef`, `WorkflowTaskTypeConstraintTest`, `TestDeciderService`(입력 해석·`getNextTask`)에서 옮긴 사례 |
| 2b | 결정 1, 2와 SIMPLE: 시작, 다음 태스크, 재시도, 타임아웃, 완료 판정 | `workflow_get_completed_simple.json` 재현, upstream `TestDeciderService` |
| 2c | SWITCH(`value-param`), FORK_JOIN, JOIN | `workflow_get_completed_switch.json`, `workflow_get_completed_fork.json` 재현 |
| 2d | SUB_WORKFLOW, WAIT의 결정 부분 | upstream 매퍼 테스트 |
| 2e | DO_WHILE | 결정 6의 평가기 ADR 이후 |

"재현"은 시작 요청과 `task_update_*` 픽스처의 결과를 차례로 넣으며 `decide`를 반복했을 때, 마지막
`Workflow`가 해당 `workflow_get_completed_*` 픽스처와 같다는 뜻이다. `taskId`·시각 필드는 비교에서 뺀다.
upstream 테스트에서 옮긴 사례는 테스트 파일에 원본 테스트 클래스와 메서드 이름을 적는다.

## upstream과 의도적으로 다른 점

- 한 번의 `decide`에서 현재 시각을 한 번만 읽는다. upstream은 검사마다 `currentTimeMillis()`를 다시 부르므로
  경계 시각에서 판정이 1ms 단위로 달라질 수 있다.
- 입력을 직접 바꾸지 않는다. upstream 호출자가 `decide` 뒤에 같은 객체를 다시 읽던 부분은 `Outcome.workflow`를
  읽는다.
- JsonPath는 결정 4의 부분집합만 지원한다. 범위 밖 문법은 upstream에서는 값이 나올 수 있지만 Archon에서는
  `null`이다.
- `NETFLIX_ENV`·`NETFLIX_STACK`, JVM 시스템 프로퍼티, OS 환경 변수를 `${...}`로 노출하지 않는다.
  upstream은 이름이 일치하는 서버 환경 변수를 그대로 태스크 입력에 넣는데, 이는 서버 비밀을 워크플로우
  정의로 꺼낼 수 있는 경로다. 정의 등록 시 `${...}` 참조 검사(ADR 0002의 `WorkflowDef.validate/2`)는
  upstream처럼 환경 변수 존재를 참조 유효성으로 인정하므로, 그런 정의는 등록되지만 실행 시 값은 `null`이다.
- `javascript`·`graaljs`·`python` 평가기와 DO_WHILE은 별도 ADR 전까지 동작하지 않는다.
- 완료 직전 permissive 태스크 실패가 여럿이면 upstream은 `HashMap` 순회 순서(Java 해시)로 메시지를
  잇는다. Archon은 워크플로우의 태스크 순서로 잇는다. 실패가 하나면 같다.
- 정의의 모든 태스크가 SKIPPED여서 시작할 태스크가 없으면 upstream은 `NullPointerException`을 낸다.
  Archon은 아무것도 예약하지 않는다.
- upstream `filterNextLoopOverTasks`는 넘겨받은 태스크 객체의 참조명을 제자리에서 바꾸므로, 워크플로우에
  이미 있는 객체를 넘기면 워크플로우 안의 태스크도 바뀐다. `Decider`는 매퍼가 새로 만든 태스크만 넘기므로
  결과는 같고, upstream 테스트 `testFilterNextLoopOverTasks`만 새 태스크로 고쳐 옮겼다.
- 그대로 따른 upstream 부수효과: 재시도에서 `TaskModel.copy()`가 `inputData` 맵을 공유하므로 실패한
  원래 태스크의 입력에서도 `subWorkflowId`가 빠진다. `tasks_to_be_updated`의 원래 태스크에 같은 변화를
  담는다.

## 대안

- **`DeciderService`를 메서드 단위로 옮기기:** 제자리 변경과 예외 흐름을 그대로 가져오게 되어 ADR 0003의
  "의미를 추출해 다시 설계" 원칙과 맞지 않는다.
- **Decider 안에서 `MetadataDAO`에 해당하는 조회 함수를 호출:** 단순하지만 Decider가 저장소 상태에 따라
  결과가 바뀐다. 필요한 정의는 워크플로우 정의에서 미리 알 수 있으므로 스냅샷으로 넘긴다.
- **ID를 Decider 밖에서 붙이기:** 재시도 시 이전 태스크의 `retriedTaskId`와 시스템 파라미터 `CPEWF_TASK_ID`가
  새 ID를 알아야 하므로, 예약 후에 ID를 붙이면 두 번 고쳐 써야 한다.
- **별도 `TaskModel`/`WorkflowModel` struct:** 결정 3에 이유를 적었다.
- **Hex JsonPath 라이브러리 채택:** 결정 4에 이유를 적었다. 부분집합으로 부족한 정의가 확인되면 다시 검토한다.

## 결과

- 2a(결정 3의 필드, 결정 4, 결정 7)를 첫 PR로 구현했다. 2b(결정 1, 2, SIMPLE·USER_DEFINED 매퍼)를 두 번째
  PR로 구현했다. 2c~2e는 아직 구현하지 않았다. 조각마다 PR을 올리고, 마지막 조각이 머지되면 이 ADR을
  `승인`으로 바꾼다.
- 2b의 재현 테스트(`test/archon/decider/simple_replay_test.exs`)는 런타임 역할을 테스트 안에서 흉내 낸다.
  시작 시 태스크 정의 박아 넣기, `seq`·`firstScheduledTime` 부여, `tasks_to_be_updated`와 새 태스크만 저장,
  완료 시 태스크를 갱신하지 않고 상태·출력만 저장하는 동작은 upstream `WorkflowExecutorOps`를 따랐고,
  Phase 3 런타임이 같은 규칙을 지켜야 픽스처와 같아진다. 마지막 태스크의 `executed: false`가 그 결과다.
- 결정 3의 내부 필드 중 `first_scheduled_time`, `callback_after_ms`는 2b Decider가 읽고 쓴다.
  `wait_timeout`, `loop_task_id`, `previous_status`, `failed_task_id`는 2c 이후와 Phase 3에서 쓴다.
- 입력 해석은 upstream처럼 결과 크기에 상한이 없다. `${workflow.input.x}`를 정의에 여러 번 쓰고 큰 `x`를 넣으면
  결과 문자열이 두 크기의 곱만큼 커진다(2a 로컬 보안 리뷰 지적). upstream도 같은 성질이고 아직 이를 부르는
  REST 경로가 없으므로 2a에서는 동작을 바꾸지 않는다. Phase 5에서 요청 본문 크기 제한과 함께 확장 상한을
  정하고, 그때 upstream과 다른 점으로 기록한다.
- DO_WHILE과 스크립트 평가기는 별도 ADR이 필요하다. 그 ADR이 나오기 전까지 Phase 2는 완료가 아니다.
- Phase 3 런타임은 `Outcome`을 받아 저장·큐 투입·하위 워크플로우 시작을 수행하는 쪽으로 설계한다.
- Phase 4는 결정 3의 내부 필드를 포함하는 저장용 인코딩을 정한다.
