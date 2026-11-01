# ADR 0025: Phase 6 워크플로우 운영 REST 설계

- 상태: 제안
- 날짜: 2026-11-01
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`
- 비고: 설계 갈림길 다섯 가지(범위, 동기 대기, remove의 의미, L3와 `:invalid_state`, 픽스처)는 2026-11-01 BOSS가 이 문서의
  추천안으로 정했다.

## 맥락

Phase 5([ADR 0023](0023-phase5-rest.md))는 [ADR 0001](0001-api-contract-scope.md)의 MVP 19개 경로를 열었다. BOSS는 Phase 6
주제로 "워크플로우 운영 REST"를 골랐다. 운영자와 SDK가 실행 중인 워크플로우를 멈추고, 다시 돌리고, 지우고, 찾는 경로다.
태스크 타입 확장, 검색·UI 호환, 인증·배포는 이번 범위가 아니다.

후보는 ADR 0001의 Later 경로 중 새 백엔드(검색 색인, 이벤트 큐, 외부 payload 저장소)가 필요 없는 것이다. upstream 기본 서버
(`server/src/main/resources/application.properties`)는 SQLite 실행 DAO와 `SqliteIndexDAO`를 쓴다. `SqliteIndexDAO`의
`get`·`updateWorkflow`·`updateTask`는 로그만 남기고 아무 일도 하지 않는다(`sqlite-persistence/.../dao/SqliteIndexDAO.java`).
그래서 아래 경로의 응답은 색인 없이 실행 DAO·metadata DAO·큐만으로 정해진다. 예외는 task 실행 로그다. upstream은 로그를
실행 DAO가 아니라 색인 DAO(`task_execution_logs` 표)에 쓰고 읽는다(`ExecutionDAOFacade.addTaskExecLog`, `getTaskExecutionLogs`).

archon에 이미 있는 것과 새로 필요한 것은 다음과 같다(archon `5d4d969` 기준).

| 묶음 | archon에 있는 것 | 새로 필요한 것 |
|---|---|---|
| pause, resume, retry, restart | `Archon.Runtime.Lifecycle`(ADR 0018 결정 9) | 컨트롤러 |
| rerun, skiptask, resetcallbacks | 없음(ADR 0018이 범위 밖으로 둠) | 워크플로우 프로세스 이벤트 |
| remove, terminate-remove | `Store.remove_workflow/1`(시작 실패 정리용) | 살아 있는 프로세스를 멈추고 지우는 이벤트 |
| `{id}/tasks` | `Runtime.get_workflow/2` | 페이징 |
| correlated 2개, `running/{name}` | `Store.running_workflow_ids/0`(이름 필터 없음) | 저장소 조회 콜백, Postgres 컬럼 |
| ref 기반 task 갱신, signal | `Tasks.update/1` | 대기 태스크 찾기, 동기 응답 |
| `execute/{name}/{version}` | `Runtime.start_workflow/1` | 동기 응답 |
| metadata 목록·삭제·validate | `Archon.Metadata`, `WorkflowDef.validate/2` | metadata behaviour 콜백 |
| bulk | 단건 함수 | 1000개 한도와 정의별 결과 |

## 결정

### 1. 범위: task 실행 로그를 뺀 운영 경로 33개

| 묶음 | 메서드·경로 | upstream 핸들러 |
|---|---|---|
| 생명주기 | `PUT /api/workflow/{workflowId}/pause`, `PUT .../resume` | `pauseWorkflow`, `resumeWorkflow` |
| | `POST /api/workflow/{workflowId}/retry`, `POST .../restart`, `POST .../rerun` | `retry`, `restart`, `rerun` |
| | `PUT /api/workflow/{workflowId}/skiptask/{taskReferenceName}`, `POST .../resetcallbacks` | `skipTaskFromWorkflow`, `resetWorkflow` |
| 정리 | `DELETE /api/workflow/{workflowId}/remove`, `DELETE .../terminate-remove` | `delete`, `terminateRemove` |
| 조회 | `GET /api/workflow/{workflowId}/tasks` | `getExecutionStatusTaskList` |
| | `GET /api/workflow/{name}/correlated/{correlationId}`, `POST /api/workflow/{name}/correlated` | `getWorkflows` 두 개 |
| | `GET /api/workflow/running/{name}` | `getRunningWorkflow` |
| 동기 실행 | `POST /api/workflow/execute/{name}/{version}` | `executeWorkflow` |
| ref 갱신 | `POST /api/tasks/{workflowId}/{taskRefName}/{status}`, `.../sync` | `updateTask`, `updateTaskSync` |
| signal | `POST /api/tasks/{workflowId}/{status}/signal`, `.../signal/sync` | `signalWorkflowTaskAsync`, `signalWorkflowTaskSync` |
| metadata | `GET /api/metadata/workflow`, `GET .../workflow/names-and-versions`, `.../names`, `.../latest-versions`, `.../{name}/versions` | `getAll`, `getWorkflowNamesAndVersions`, `getWorkflowNames`, `getAllWorkflowsWithLatestVersions`, `getWorkflowVersions` |
| | `DELETE /api/metadata/workflow/{name}/{version}`, `DELETE /api/metadata/taskdefs/{tasktype}` | `unregisterWorkflowDef`, `unregisterTaskDef` |
| | `POST /api/metadata/workflow/validate` | `validate` |
| bulk | `PUT /api/workflow/bulk/{pause,resume}`, `POST /api/workflow/bulk/{restart,retry,terminate}`, `DELETE /api/workflow/bulk/{remove,terminate-remove}` | `WorkflowBulkResource` 일곱 개 |

- 경로·쿼리 이름·기본값은 upstream 컨트롤러(`WorkflowResource`, `WorkflowBulkResource`, `TaskResource`, `MetadataResource`)에서
  그대로 옮긴다. 응답은 결정 7의 골든 픽스처가 정답이다.
- **Later로 남는 것.** `POST /api/tasks/{taskId}/log`와 `GET /api/tasks/{taskId}/log`는 색인 DAO에 기대므로 검색·색인 ADR과 함께
  연다. 그때까지 `TaskResult.logs`도 지금처럼 저장하지 않는다. `POST /api/workflow/bulk/search`, 검색, 이벤트, 외부 저장소,
  큐 관리(`/api/tasks/queue/*`, `/api/queue/*`), admin, `POST /api/workflow/test`, `/api/schema` 등 ADR 0001의 나머지 Later도
  그대로다(BOSS 결정).
- `GET /api/workflow/running/{name}`과 `GET /api/metadata/workflow/{names-and-versions,names,latest-versions}`는 ADR 0023 결정 2가
  매개변수 경로보다 먼저 404로 보내던 Later 리터럴이다. 이 Phase가 연다. 라우터에 남는 Later·Unsupported 리터럴은 `WorkflowResource`의
  검색·외부 저장소 경로, `POST /api/workflow/test`, `PUT /api/workflow/decide/{workflowId}`, `TaskResource`의 검색·외부 저장소 경로,
  `POST /api/tasks/queue/requeue/{taskType}`이다(아래 겹침 목록).
- **새 경로끼리, 또 Later와 겹치는 모양.** Spring은 리터럴이 더 많은(더 구체적인) 패턴을 고른다. archon 라우터는 같은 결과가
  나오게 다음 순서를 지킨다.
  - bulk 리터럴(`PUT /api/workflow/bulk/pause` 등)은 `{workflowId}/pause`·`/resume`·`/restart`·`/retry`·`/remove`·`/terminate-remove`
    보다 먼저 둔다. 그러지 않으면 `bulk`라는 워크플로우의 단건 작업이 된다.
  - `GET /api/workflow/running/{name}`은 `GET /api/workflow/{workflowId}/tasks`보다 먼저다(`running/tasks`).
  - `POST /api/tasks/{workflowId}/{status}/signal`과 `.../signal/sync`는 `POST /api/tasks/{workflowId}/{taskRefName}/{status}`와
    `.../sync`보다 먼저다(`wf/COMPLETED/signal`).
  - Unsupported인 `PUT /api/workflow/decide/{workflowId}`는 `PUT /api/workflow/{workflowId}/pause`·`/resume`과 모양이 같다
    (`decide/pause`). Spring은 decide로 보내므로 archon은 리터럴로 먼저 두고 404로 보낸다.
  - Later인 `POST /api/tasks/queue/requeue/{taskType}`은 ref 갱신 경로와 모양이 같으므로 리터럴로 먼저 두고 404로 보낸다.
    `POST /api/workflow/bulk/search`는 겹치는 새 경로가 없어 없는 경로 그대로 404다. task log 두 경로(Later)는 세그먼트 수가 달라
    겹치지 않는다.
  - 정확한 목록은 조각 6a가 upstream 컨트롤러의 모든 매핑과 대조해 라우터 시험으로 고정한다. 라우터 시험은 응답이 아니라 경로
    해석(메서드와 경로 → 컨트롤러와 액션, `Phoenix.Router.route_info/4`)만 본다. 그래야 뒤 조각이 액션을 구현해도 시험을 고치지 않는다.
- 컨트롤러는 ADR 0023 결정 2의 경계(`Archon.Runtime`, `Archon.Runtime.Tasks`, `Archon.Metadata`)와 생명주기 API
  `Archon.Runtime.Lifecycle`(ADR 0018 결정 9, ADR 0023 결정 2가 이미 런타임 API로 부름)만 부른다. 저장소·큐·`WorkflowServer`를 직접
  부르지 않는다. 새 런타임 기능은 이 모듈들의 함수로 더한다. 생명주기와 정리(rerun, skiptask, resetcallbacks, remove,
  terminate-remove)는 `Archon.Runtime.Lifecycle`에, 조회는 `Archon.Runtime`에 둔다. 그래서 `lib/archon/runtime.ex`는 6b만 고친다.

### 2. 생명주기: 이미 있는 넷과 새 이벤트 셋

- **오류 변환**은 ADR 0023 결정 4의 표 그대로다. 런타임 생명주기 오류는 upstream 예외 종류를 그대로 담고 있다
  (`Archon.Runtime.Step.Lifecycle`의 `:conflict`·`:not_found`·`:invalid_state`). `:invalid_state`(`IllegalStateException`)는 upstream
  매퍼에 없어 500이다(BOSS 결정). resume의 `"The workflow <id> is not PAUSED so cannot resume. Current status is <STATUS>"`와
  skiptask의 세 문구가 이 경우다. 픽스처로 상태 코드와 문구를 확인한다.
- **응답 코드.** pause·resume·skiptask는 200 body 없음, retry·restart·resetcallbacks는 204(`@ResponseStatus(NO_CONTENT)`),
  rerun은 200 `text/plain;charset=UTF-8` workflowId다.
- **pause, resume, retry(`resumeSubworkflowTasks`, 기본 false), restart(`useLatestDefinitions`, 기본 false)**는
  `Archon.Runtime.Lifecycle`을 그대로 부른다. 메서드 검증(`@NotEmpty "WorkflowId cannot be null or empty."`)은 경로 변수가 비지
  않으므로 닿지 않는다.
- **L3는 유지한다(BOSS 결정).** `resumeSubworkflowTasks=true`로 내려간 끝이 실행 중인 자식이면 archon은 404
  `"Workflow is still running.  status=<STATUS>"`(upstream 최상위 검사와 같은 예외·문구)를 주고, upstream은 그 자식을 검사 없이
  재시도한다(`WorkflowExecutorOps.retry` → private `retry(WorkflowModel)`). 자식을 재시도·재시작하면 `updateAndPushParents`가 부모도
  되살리므로 REST만으로 이 상태를 만들기 어렵다. 픽스처는 없고 "upstream과 의도적으로 다른 점"에 적는다. ADR 0021의 L3 행은 이
  결정으로 닫는다.
- **rerun(새 기능).** upstream `WorkflowExecutorOps.rerun`·`rerunWF`·`finalizeRerun`의 의미를 워크플로우 프로세스 이벤트로 옮긴다.
  body는 `RerunWorkflowRequest`(`reRunFromWorkflowId`는 경로 값으로 덮음, `workflowInput`, `reRunFromTaskId`, `taskInput`,
  `correlationId`)이고 도메인 코덱 모델로 더한다.
  - 끝나지 않은 워크플로우는 409 `"Workflow: <name>.<version>/<id>.<STATUS> is not in terminal state, unable to rerun."`이다.
  - `reRunFromTaskId`가 없으면 태스크를 모두 지우고 처음부터 다시 결정하고(입력·correlationId를 주면 바꾼다) 부모를 되살린다.
  - 있으면 그 태스크를 찾는다. 이 워크플로우에 없으면 SUB_WORKFLOW 태스크의 자식으로 내려가 찾는다(upstream은 자식에게
    `taskInput`만 넘기고 입력·correlationId는 넘기지 않는다). upstream은 SUB_WORKFLOW 태스크마다 자식을 차례로 깊이 우선으로
    내려가므로, 대상이 없는 자식이라도 끝나지 않았으면 위와 같은 409, 없으면 404로 전체가 멈춘다. 자식으로
    내려갈 때는 ADR 0024 결정 2의 소유권 확인(자식의 부모가 이 워크플로우와 그 태스크)을 지키고, 소유하지 않은 자식은 없는 자식으로
    본다. 어디에도 없으면 400 `"Task <id> not found"`(`IllegalArgumentException`)다.
  - 찾은 다음은 upstream `rerunWF`처럼 세 경우로 나뉜다. 어느 경우든 워크플로우는 `RUNNING`이 되고 실패 필드를 지우며, 준 입력·
    correlationId를 반영한다.
    1. **대상이 이 워크플로우의 SUB_WORKFLOW가 아닌 태스크:** `seq`가 대상보다 큰 태스크를 지우고, 대상을 처음 상태로 되돌린다
       (예약 시각은 지금, 시각·출력·`pollCount`는 0이나 빈 값). `taskInput`이 있으면 대상 입력을 바꾼다. 동기 시스템 태스크면 그
       자리에서 시작하고, 아니면 `SCHEDULED`로 큐에 넣는다. 그다음 `finalizeRerun`: ref(`referenceTaskName`)가 다르고 성공하지 않은 채
       끝난 태스크(`CANCELED` 포함)를 되살리고(JOIN·DO_WHILE과
       동기 시스템 태스크는 `IN_PROGRESS`, SUB_WORKFLOW는 자식 ID를 지움, 나머지는 `SCHEDULED`로 큐에) 결정하고 부모를 되살린다.
    2. **대상이 이 워크플로우의 SUB_WORKFLOW 태스크:** `seq`로 지우지 않는다(upstream 주석: 병렬 FORK 가지를 지우지 않기 위해).
       태스크를 제자리에서 되돌리고(출력과 자식 ID를 지우고 `SCHEDULED`) 새 자식을 시작한 뒤 `finalizeRerun`을 한다. `taskInput`은
       쓰지 않는다. 자식 시작은 ADR 0018 결정 5의 자식 시작 경로를 쓴다.
    3. **대상이 자식 안에 있음:** 대상을 가진 자식이 위 1·2로 rerun하고, 그 위 워크플로우들은 자식으로 가는 SUB_WORKFLOW 태스크를
       `IN_PROGRESS`로 되돌려 결정할 뿐 `seq`로 지우거나 `finalizeRerun`을 하지 않는다.
  - **rerun의 실행 순서.** `Archon.Runtime.Lifecycle.rerun`이 `retry(id, true)`처럼 프로세스 밖에서 다음 순서로 한다.
    1. 읽기만으로 검증한다: 최상위가 끝나지 않았으면 409, 그다음 위의 깊이 우선 순서로 자식마다 409·404·소유권을 보고 대상을 가진
       가장 깊은 워크플로우를 정한다. 대상이 없으면 400.
    2. 그 워크플로우에 경우 1·2의 이벤트를 보낸다. 이벤트는 프로세스 안에서 끝났는지와 대상이 있는지를 다시 본다(1은 읽기만
       했으므로). 이 이벤트는 부모 되살림(`child_revived`)을 outbox에 남긴다.
    3. 그 답을 받은 뒤 경로에 있는 위 워크플로우마다, 대상의 부모부터 최상위까지 차례로 경우 3의 이벤트(`RUNNING`, 자식으로 가는
       SUB_WORKFLOW 태스크의 `retried`를 거짓으로 하고 `IN_PROGRESS`, 결정)를 보내고 마지막 답 뒤에 응답한다. 입력·correlationId는
       최상위의 이벤트에만 싣는다(upstream도 재귀 호출에는 `null`을 넘긴다). 그래서 응답 때 경로의 워크플로우는 모두 `RUNNING`이고
       최상위에 준 입력이 반영돼 있다. `child_revived`만으로 두지 않는 것은, 경로가 재시도된 SUB_WORKFLOW 태스크(이전 시도의 자식)를
       지나면 `child_revived`가 그 태스크를 건너뛰어(`Step.Lifecycle.child_revived/2`) 중간 워크플로우가 `FAILED`로 남기 때문이다.
       upstream `rerunWF`는 재시도된 태스크도 찾고 모든 단계에서 경우 3을 한다.
    4. 경우 3의 이벤트는 이미 `RUNNING`인 워크플로우도 받는다(2가 남긴 `child_revived`가 먼저 닿았을 수 있다). 그 SUB_WORKFLOW 태스크가
       아직 있는지만 본다. 경로 밖의 조상(최상위의 부모 등)은 `child_revived`로 따라온다. 같은 워크플로우가 경우 3과
       `child_revived`로 두 번 되살려지는 것이 결과를 바꾸지 않는지, 재시도된 자식 안의 대상을 rerun하는 경우를 조각 6f가 시험한다.
       자식이 아직 `FAILED`일 때 위가 결정하지 않도록 2의 답(자식 커밋과 결정 저장)을 받은 뒤에 3을 보낸다.
  - 같은 ID를 돌려준다. 동적 FORK(`FORK_JOIN_DYNAMIC`)는 MVP 태스크 타입이 아니므로(ADR 0003 결정 4) 그 분기는 옮기지 않는다.
- **skiptask(새 기능).** upstream `skipTaskFromWorkflow`다. `RUNNING`이 아니면, 정의에 그 ref가 없으면, 이미 그 ref의 태스크가
  있으면 각각 upstream 문구의 `:invalid_state`(500)다. 통과하면 `SKIPPED` 태스크(`taskType`은 정의 태스크의 `name`, 새 ID,
  `endTime`이 지금)를 더하고 결정한다.
  `SkipTaskRequest`는 upstream 핸들러에 `@RequestBody`가 없어 JSON body가 무시된다(Spring `@ModelAttribute` 바인딩). archon도 body를
  읽지 않고 `taskInput`·`taskOutput` 없이 만든다. 쿼리로 맵을 채우는 Spring 바인딩은 옮기지 않는다(의도적 차이).
  upstream의 건너뛴 태스크에는 `seq`가 없다(0). archon 저장소는 태스크를 `seq` 순으로 읽으므로 조각 6d가 다른 태스크와의 순서를
  픽스처(조회 응답의 태스크 순서)로 확인하고 정한다.
- **resetcallbacks(새 기능).** upstream `resetCallbacksForWorkflow`다. 끝난 워크플로우는 409
  `"Workflow is in terminal state. Status = <STATUS>"`다. 시스템 태스크가 아니고 `SCHEDULED`이며 `callbackAfterSeconds > 0`인 태스크마다
  큐 메시지의 지연을 없애고(큐 `postpone`을 0으로), 큐에 그 메시지가 있어 지연을 없앴을 때만(upstream `resetOffsetTime`이 참일 때)
  `callbackAfterSeconds`를 0으로 저장한다. archon의 내부 필드 `callback_after_ms`(`wire: false`)도 같은 의미이므로 함께 0으로 한다.
  큐에 메시지가 있는지는 규칙이 직접 읽지 않고 `WorkflowServer.env/2`가 이 이벤트의 환경으로 채운다(ADR 0018의 Env 방식). 성공은 204다.
- 새 이벤트 셋은 `Archon.Runtime.Step.Lifecycle`(규칙)과 `Archon.Runtime.Lifecycle`(API), `WorkflowServer`(메시지)에 더한다.
  ADR 0018 결정 9의 방식(이벤트 하나가 커밋 하나, 답은 커밋과 그 뒤 결정이 저장된 뒤)을 따른다.

### 3. 정리: remove는 upstream SQLite 서버와 같은 결과를 낸다

- **`DELETE /api/workflow/{workflowId}/remove?archiveWorkflow=true`**(BOSS 결정).
  - `archiveWorkflow`가 참(기본)이면 끝난 워크플로우만 지운다. 아니면 400 `"Cannot archive workflow: <id> with status: <STATUS>"`
    (`ExecutionDAOFacade.removeWorkflowIndex`의 `IllegalArgumentException`)다. upstream은 이어서 끝나지 않은 태스크(`SCHEDULED` 제외)도
    400 `"Cannot archive task: <taskId> of workflow: <wfId> with non-terminal status: <STATUS>"`로 막는다. archon도 같은 순서로 본다.
  - 거짓이면 상태와 상관없이 지운다.
  - 지우는 것: 워크플로우, 태스크, outbox, 태스크의 큐 메시지. 살아 있는 워크플로우 프로세스와 타이머도 끝낸다. 보관본은 없다.
    upstream 기본 서버도 `archiveWorkflow=true`일 때 색인에 보관본을 쓰지 못하므로(no-op) 지운 뒤 GET은 404다.
  - 자식·부모는 건드리지 않는다(upstream과 같음). 자식이 나중에 지워진 부모에게 진행을 알리면 부모가 없는 경우로 처리한다
    (ADR 0024 결정 2의 "자식 없음"과 같은 방향의 "부모 없음"). 이 경로가 지금 무엇을 하는지 조각 6d가 시험으로 고정한다.
  - 지우기는 그 워크플로우의 프로세스가 하는 이벤트다. 프로세스는 저장소에서 지우고(`Store.remove_workflow/1`) 큐 메시지를 지운 뒤
    멈춘다. 프로세스가 없으면 `WorkflowServer`의 기존 활성화 경로로 띄운 뒤 같은 이벤트를 보낸다. 같은 워크플로우의 다른
    이벤트와 순서가 섞이지 않게 하기 위해서다. Postgres 백엔드의 펜스(ADR 0021 결정 7)도 그대로 받는다.
  - **outbox가 빈 뒤에만 지운다.** archon은 종료의 자식 종료(`terminate_sub_workflow`), 부모 알림(`notify_parent`), 실패 워크플로우
    시작을 outbox로 비동기 전달하고, 이 전달은 호출자가 답을 받은 뒤에 돈다(ADR 0021 결정 4). upstream은 이 일을 종료 안에서
    동기로 끝낸 뒤 지운다. outbox를 같이 지우면 이 전달이 사라지므로 다음처럼 한다.
    1. 프로세스는 지우기 이벤트를 받은 그 자리에서 판정하고 바로 답한다. 기다리거나 답을 미루지 않는다(그 사이 outbox 실행기의
       결과와 재시도 메시지를 처리해야 하고, 미룬 답은 호출자 timeout 뒤에 지우는 일을 만든다). outbox 실행기 상태
       `runner`가 `nil`이 아니거나(`{:running, _}`, `{:blocked, _, _}`, `{:delayed, _}`, 프로세스가 멈출 수 있는지 보는 `ending?`와 같은
       조건) `pending_outbox`가 비어 있지 않으면 지우지 않고 "전달 대기" 오류로 답한다. 비어 있으면 그 자리에서 `archiveWorkflow` 조건을
       본 뒤 지우고 `:ok`로 답한 다음 멈춘다.
    2. `Archon.Runtime.Lifecycle.remove`는 "전달 대기"를 받으면 짧은 간격(100ms)으로 같은 이벤트를 다시 보낸다. 마감(호출 timeout보다
       짧게, 예 10초)까지 비지 않으면 아무것도 지우지 않고 500 `retryable` 참으로 답한다. 판정이 매번 프로세스 안에서 새로 되므로
       그 사이 다른 클라이언트의 retry·restart가 워크플로우를 되살렸으면 `archiveWorkflow` 조건이 다시 걸린다.
    3. "전달 대기"는 `ArchonWeb.Errors`가 `TransientException`처럼 바꾸는 새 오류 태그다(고정 문구, ADR 0023 결정 4). 같이,
       `WorkflowServer.call/4`가 exit를 바꾼 `{:error, :timeout}`이 지금 `retryable` 거짓 500인 것(ADR 0023 결정 4 표의 "호출
       timeout·exit"와 어긋난 Phase 5 코드)도 6d가 `retryable` 참으로 고치고 시험한다. timeout만이 아니라 `call/4`가 돌려주는 모든 exit(`:shutdown`, `:killed`, 두 번째 시도의
       `:noproc` 등)와 활성화 실패 `{:error, :unavailable}`도 `{:error, {:exit, 이유}}`로 바꿔 `retryable` 참으로 한다(`ArchonWeb.Errors`가
       이미 그렇게 다룬다. outbox의 `Outbox.classify`는 둘 다 재시도로 보므로 동작이 같다). 이 수정은 종료 등 기존 경로의 응답도 바꾼다.
    그래서 `Store.remove_workflow/1`이 outbox를 지울 때 남은 항목은 없다. 조각 6d는 "실행 중 자식이 있는 부모의
    terminate-remove"(자식이 종료됨)와 "부모가 기다리는 자식의 terminate-remove"(부모 태스크가 반영됨)를 두 백엔드에서 시험한다.
  - 성공은 200 body 없음이다(terminate-remove도 같다).
- **`DELETE /api/workflow/{workflowId}/terminate-remove?reason=&archiveWorkflow=true`**는 upstream `WorkflowServiceImpl.terminateRemove`
  처럼 종료(`Runtime.terminate_workflow/2`) 다음에 지우기다. `COMPLETED` 워크플로우는 종료가 409 `"Cannot terminate a COMPLETED
  workflow."`이므로 지우지 않는다. `FAILED`·`TIMED_OUT`은 종료가 상태를 `TERMINATED`로 바꾼 뒤 지운다(upstream과 같음).

### 4. 조회

- **`GET /api/workflow/{workflowId}/tasks?start=0&count=15&status=`**: 응답은 `SearchResult<Task>`(`{"totalHits", "results"}`)다.
  태스크 전체를 `seq` 순으로 읽고(`Runtime.get_workflow(id, true)`), `status`(반복 또는 `,`로 나눈 목록, 대문자로 바꿔 비교)로 거른 뒤
  메모리에서 자른다. `totalHits`는 거른 개수다. 자르기는 upstream 산식(`from = min(start, total)`, `to = min(start + count, total)`,
  `subList(from, to)`)과 Java `subList`의 검사 순서(`from < 0`이나 `to > size`는 `IndexOutOfBoundsException` 500, `from > to`는
  `IllegalArgumentException` 400)를 그대로 옮긴다. 그래서 음수 `count`가 늘 400인 것은 아니다(`start=5, count=-1`이고 태스크가 셋이면
  200 빈 결과). 문구는 픽스처로 확인한다. `SearchResult`는 도메인 코덱 모델로 더한다.
- **correlated 두 경로.** upstream SQLite DAO는 색인이 아니라 실행 DAO에서 `correlationId`와 정의 이름(모든 버전)으로 찾는다
  (`SqliteExecutionDAO.getWorkflowsByCorrelationId`). `includeClosed=false`(기본)면 `RUNNING`만 남긴다(`PAUSED`도 빠진다).
  `includeTasks=false`(기본)면 태스크 없이, 참이면 `seq` 순 태스크와 함께 돌려준다. 없으면 `[]`다. POST는 body의 correlationId
  목록마다 같은 조회를 해서 `{correlationId: [Workflow]}`를 돌려준다(빈 목록 body는 `{}`).
- **`GET /api/workflow/running/{name}?version=1&startTime=&endTime=`**: `startTime`과 `endTime`이 둘 다 있고 0이 아니면 이름이
  같은 워크플로우 중 `createTime`이 그 사이이고 버전이 같은 것을 상태와 상관없이 돌려준다(upstream `getWorkflowsByType` 분기). 아니면
  이름이 같은 끝나지 않은 워크플로우(`RUNNING`, `PAUSED`)를 **버전과 상관없이** 돌려준다. upstream SQLite DAO가 `version`을 보지
  않기 때문이다(`SqliteExecutionDAO.getRunningWorkflowIds`). 응답은 workflowId 목록이다.
- **목록 순서.** upstream은 순서를 정하지 않는다(병렬 스트림, 표 순서). archon은 `createTime`, 그다음 workflowId의 바이트 순이다.
  재생은 이 응답들을 순서 없이 비교한다.
- **저장소 조회 콜백.** `Archon.Runtime.Store`에 이름·correlationId로 찾는 콜백과 이름(과 선택한 시간 구간)으로 찾는 콜백을 더한다.
  메모리 구현, Postgres 구현, 저장소 계약 시험을 함께 고친다. Postgres는 `workflow` 표에 `workflow_name`, `workflow_version`,
  `correlation_id`, `create_time` 컬럼과 조회 색인을 새 마이그레이션으로 더하고, 기존 행은 `json_data`에서 채운다. 커밋이 이 컬럼을
  함께 쓴다. 컨트롤러가 부를 API는 `Archon.Runtime`의 함수다.

### 5. ref 갱신, signal, 동기 응답

- **`POST /api/tasks/{workflowId}/{taskRefName}/{status}?workerid=`**: body는 출력 맵이다. 워크플로우의 첫 번째 끝나지 않은 태스크
  중 ref가 같은 것(없으면 DO_WHILE 반복 접미사 `__<n>`를 뗀 ref가 같은 것)을 찾아 `TaskResult`를 만들고(기존 출력에 body를 합침,
  `workerid`가 공백이 아니면 바꿈) `Tasks.update/1`로 갱신한다. 200 `text/plain` taskId이고, 대기 태스크가 없거나 워크플로우가
  없으면 200 빈 body다(upstream은 `null`을 돌려준다). `status`는 `TaskResult.Status` 값이고 아니면 Spring 변환 실패 500이다.
- **`.../sync`**: 대기 태스크가 없으면 404 `"Found no running task <ref> of workflow <id> to update"`. `workerid`가 없으면 `null`로
  덮는다(비동기와 다름, upstream 그대로). 갱신은 메서드 검증을 거친다. 응답은 갱신과 그 뒤 결정이 끝난 워크플로우(태스크 포함)다.
- **signal**: 대상은 워크플로우 태스크 순서로 첫 번째 끝나지 않은 `WAIT` 태스크, 없으면 끝나지 않은 SUB_WORKFLOW의 자식으로 깊이
  우선 내려가 찾은 첫 `WAIT`다. 자식으로 내려갈 때는 ADR 0024 결정 2의 소유권 확인을 지킨다. 워크플로우 상태는 보지 않는다.
  없는 워크플로우는 404 `"No such workflow found by id: <id>"`, 대상이 없으면 비동기는 200 body 없음, sync는 404
  `"Found no blocked task in workflow <id> to signal"`이다.
- **동기 응답기(BOSS 결정: 100ms 폴링).** `execute`와 `signal/sync`는 upstream `WorkflowSignalResponder.awaitSignalResponse`처럼
  100ms마다 `Runtime.get_workflow(id, true)`로 읽는다. 워크플로우가 끝났거나 막힌 태스크가 생기면 답한다. 막힌 태스크는
  끝나지 않았고 `waitTimeout`이 0인 `WAIT`(무기한 WAIT)이거나, `waitUntilTaskRef`(쉼표 목록)에 든 ref의 끝난 태스크다. 끝나지 않은
  SUB_WORKFLOW의 자식으로 내려가 찾는다(소유권 확인 포함, 읽기 실패는 건너뜀). 시간 초과(`execute`의 `waitForSeconds` 기본 10과
  0은 10, `signal/sync`의 `timeoutMillis` 기본 5000)는 막힌 태스크가 없는 결과(`signalTimeout: true`)로 답하고 워크플로우는 그대로
  돈다. 그래서 `TARGET_WORKFLOW`·`BLOCKING_WORKFLOW`는 200이고, `BLOCKING_TASK*`는 아래의 실패와 같다.
  - 응답은 `returnStrategy`(기본 `TARGET_WORKFLOW`)에 따라 `WorkflowRun`이나 `TaskRun`이다(upstream `NotificationResult.toResponse`).
    막힌 태스크가 없는데 `BLOCKING_TASK`·`BLOCKING_TASK_INPUT`이면 upstream은 `null`을 Reactor에 넘겨 실패한다. 그 응답(상태 코드와
    문구)은 픽스처로 확인해 맞춘다.
  - 모델 `SignalResponse`(`WorkflowRun`, `TaskRun`)와 `WorkflowSignalReturnStrategy`는 도메인 코덱 모델로 더한다. 필드는
    `common/src/main/java/org/conductoross/conductor/model/`에서 옮긴다.
  - 대기는 요청을 처리하는 프로세스에서 한다. 워크플로우 프로세스에 구독 경로를 만들지 않는다.
- **`POST /api/workflow/execute/{name}/{version}`**: body는 `StartWorkflowRequest`이고 경로의 이름과 버전(`0`은 최신)으로 덮는다.
  쿼리는 `requestId`(공백이면 새 UUID, 응답에 그대로), `waitUntilTaskRef`, `waitForSeconds`, `consistency`(읽기만 하고 쓰지 않음,
  upstream과 같음), `returnStrategy`다. 시작은 `POST /api/workflow`와 같은 경로(ADR 0023 결정 3·4의 검증과 오류, ADR 0024 결정 4)를
  쓴다. 인라인 정의에 태스크가 있으면 upstream은 입력에 `_systemMetadata.dynamic = true`를 넣는다(입력이 `null`이면 NPE 500). archon도
  같은 입력을 만든다.

### 6. metadata와 bulk

- **목록.** `Archon.Runtime.Metadata`에 모든 워크플로우 정의를 읽는 콜백, 정의 하나와 태스크 정의 하나를 지우는 콜백을 더한다
  (메모리·Postgres·계약 시험). `Archon.Metadata`가 upstream `MetadataServiceImpl`과 `MetadataDAO`의 기본 구현을 옮긴다.
  - `GET /api/metadata/workflow?classifier=`: 모든 버전을 이름, 버전 순으로. `classifier`가 공백이 아니면
    `WorkflowClassifier.classifierOf`(정의 `metadata`의 `classifier` 문자열, `agent_sdk`·`agentDef`가 있으면 `"agent"`, 아니면
    `"workflow"`)와 대소문자 없이 비교해 거른다.
  - `names`: 이름을 중복 없이 정렬한 목록. `{name}/versions`: 그 이름의 `{name, version, createTime}` 요약을 버전 순으로(없으면 `[]`,
    `updateTime`은 없음). `names-and-versions`: 이름별 요약 목록(`updateTime` 포함, 이름·버전 순). `latest-versions`: 이름마다 가장
    큰 버전의 정의(upstream은 순서가 없고 archon은 이름 순). `WorkflowDefSummary`는 도메인 코덱 모델로 더한다.
- **삭제.** `DELETE /api/metadata/workflow/{name}/{version}`과 `DELETE /api/metadata/taskdefs/{tasktype}`은 실행 중인 워크플로우나
  정의 참조를 보지 않고 지운다(upstream과 같음). 없는 정의는 upstream SQLite DAO의 `NotFoundException`이 트랜잭션 도우미에서
  `NonTransientException`으로 감싸여 **500**이고 문구는 `"No such workflow definition: <name> version: <v>"`,
  `"No such task definition"`이다. 픽스처로 확인하고 그대로 맞춘다. `version`이 숫자가 아니면 Spring 변환 실패 500이다.
  정의를 지우면 그 정의로 이미 도는 워크플로우는 저장된 정의로 계속 돈다(archon은 시작 때 정의를 워크플로우에 박는다).
- **`POST /api/metadata/workflow/validate`**: 등록과 같은 `WorkflowDef.validate/2` 전부(이름, 태스크 목록, `schemaVersion`, ref
  유일성, 입력 매개변수 참조, 태스크 타입 제약 등)와 ADR 0023 결정 5의 `check_schema`만 하고 저장하지 않는다. 성공은 200 body 없음, 실패는 400 `validationErrors`(접두사 `validateWorkflowDef.arg0`, 픽스처로
  확인)다. 이름이 있는 정의인지, 이미 있는지는 보지 않는다. ADR 0023 결정 5의 스키마 거절도 여기서 400으로 준다. upstream은
  통과시키지만, archon에서 통과한 정의가 등록 때 거절되지 않게 하기 위해서다(의도적 차이).
- **bulk.** body는 workflowId 목록이다(단일 값은 원소 하나의 목록, ADR 0023 결정 2). 메서드 검증은 `@NotEmpty "WorkflowIds list
  cannot be null."`와 `@Size(max = 1000) "Cannot process more than 1000 workflows. Please use multiple requests."`(400)다. 응답은 기존
  `Archon.Domain.BulkResponse`(이름 자리에 workflowId)다. ID마다 차례로 단건 함수를 부르고, 실패는 그 ID의 문구로 넣고 계속한다.
  `retry`는 `resumeSubworkflowTasks`가 늘 거짓이다. 쿼리는 upstream 그대로다: `restart`의 `useLatestDefinitions`(기본 false),
  `terminate`의 `reason`, `remove`의 `archiveWorkflow`(기본 true), `terminate-remove`의 `archiveWorkflow`(기본 true)와 `reason`.
  `remove`·`terminate-remove`는 단건과 같은 `Archon.Runtime.Lifecycle` 함수를 ID마다 부르므로 결정 3의 전달 대기도 ID마다 한다. `terminate-remove`는 upstream
  `WorkflowBulkServiceImpl`의 두 `try`를 그대로 따른다: 종료와 지우기 각각이 성공하면 ID를 성공 목록에 더하므로(성공한 ID는 두 번
  나옴) `COMPLETED` 워크플로우는 종료 실패로 오류에 들어가면서도 지워진다. 단건 terminate-remove와 다르지만 upstream 응답 그대로다.
  오류 문구가 없는 오류(`null` 메시지)는 upstream처럼 값이 `null`인 항목이다. Elixir 용어를 내보내지 않는 규칙(ADR 0023 결정 4)은
  여기도 같다.

### 7. 골든 픽스처와 재생(BOSS 결정: 6a가 한 번에 캡처)

- 첫 조각 6a가 이 Phase의 새 경로 시나리오 전부를 `scripts/contract/capture_fixtures.sh` 끝에 더하고 upstream 서버(기준 SHA 빌드,
  빈 SQLite)에서 127개 기존 픽스처와 함께 한 번에 다시 캡처한다. 기존 127개는 `normalize/1` 기준으로 같아야 하고, 다르면 PR에서
  검토한다(ADR 0023 결정 6). 시나리오는 앞 단계 상태를 바꾸지 않는 오류를 먼저, 지우기·bulk처럼 상태를 크게 바꾸는 것을 뒤에 둔다.
- 다른 조각은 스크립트·픽스처·픽스처 등록(`contract_test.exs`, `contract_round_trip_test.exs`, `Archon.Contract.fixture_schemas/0`)을
  고치지 않는다. 빠진 픽스처는 기록해 두고 마지막 조각 6h가 더해 다시 캡처한다.
- **새 픽스처의 모델 분류.** `contract_round_trip_test.exs`는 픽스처마다 도메인 모듈을 정하고 `from_json/1`을 부른다. 6a는 이미 있는
  모델(`Workflow`, `Task`, `WorkflowDef`, `ErrorResponse`, `BulkResponse`, `StartWorkflowRequest` 등)로 나타낼 수 있는 body는 그 모델로,
  뒤 조각이 만들 모델(`SearchResult`, `WorkflowDefSummary`, `SignalResponse`·`WorkflowRun`·`TaskRun`, `RerunWorkflowRequest`)의 body는
  분류 없음(`[]`)으로 등록한다. 6h가 그 픽스처를 새 모델로 바꾼다. 그래서 2차·3차 조각은 픽스처 등록 파일을 고치지 않는다.
- 캡처 목록에는 최소한 다음을 넣는다.
  - 경로마다 성공 하나와 upstream이 다른 상태 코드를 주는 오류 하나 이상. 특히 `:invalid_state` 500(resume·skiptask), 재시도의
    409 두 가지, restart의 409·404, rerun의 409·400, remove의 400(실행 중, `archiveWorkflow` 기본), terminate-remove의 409
  - `{id}/tasks`의 `status` 거르기와 페이징, 음수 `count`·`start`
  - correlated와 `running/{name}`의 버전 무시, 시간 구간 분기, `PAUSED` 포함·제외. 시간 구간은 재생 때 다시 맞출 수 없는
    캡처 시각 대신 넓은 고정 구간(예: `startTime=1&endTime=<먼 미래>`)으로 캡처한다
  - signal·ref 갱신의 대상 없음(비동기 200과 sync 404), DO_WHILE 반복 ref
  - `execute`와 `signal/sync`의 네 전략, 시간 초과(`signalTimeout`)의 `TARGET_WORKFLOW`와 `BLOCKING_TASK`, 끝난 워크플로우의
    `BLOCKING_TASK`
  - metadata 목록 다섯 개, 없는 정의 삭제 500 둘, `validate`의 성공과 400
  - bulk의 빈 목록·1001개 400, 섞인 결과, `terminate-remove`의 중복 성공과 `COMPLETED`
  - 지운 뒤 GET 404
- 시간·대기에 기대는 응답(시간 초과, 폴링 시점의 태스크 상태)은 캡처에서 상태가 정해지게 시나리오를 짠다(무기한 WAIT를 쓰거나
  워크플로우가 끝난 뒤 부름). 정해지지 않는 필드는 재생에서 `ignore`로 적는다.
- **아직 구현하지 않은 단계의 재생.** 6a는 새 단계를 `ArchonWeb.ContractCase.scenario/0`에 모두 넣고, 새 액션마다 컨트롤러 골격을
  만든다. 골격은 액션마다 없는 경로와 같은 404로 답하고, 아직 구현하지 않은 액션 목록을 그 컨트롤러 안에 둔다. 재생 도우미는 이
  목록에 든 액션으로 가는 단계를 건너뛴다. 뒤 단계가 앞 단계의 상태 변화(예: pause 뒤의 조회, remove 뒤의 목록)에 기대는지는
  기계로 알 수 없으므로, 6a가 새 단계마다 기대는 액션을 단계 옵션 `requires: [{컨트롤러, 액션}, ...]`으로 적고 재생 도우미는 그중
  하나라도 미구현이면 그 단계도 건너뛴다. 새 단계는 시나리오 끝에 두므로 기존 MVP 단계는 Phase 6 단계 뒤에 오지 않는다.
  그래서 다른 조각은 시나리오를 고치지 않고 자기 컨트롤러의 목록만 비운다. 6h가 이 장치를 없앤다.

### 8. 구현 조각

새 액션 33개는 다음 컨트롤러에 둔다. 6a가 골격을 모두 만들고, 각 컨트롤러는 한 조각(rerun만 6f)이 채운다.

| 컨트롤러 | 액션 | 채우는 조각 |
|---|---|---|
| `ArchonWeb.WorkflowLifecycleController` | pause, resume, retry, restart, skiptask, resetcallbacks, remove, terminate-remove / rerun | 6d / 6f |
| `ArchonWeb.WorkflowQueryController` | `{id}/tasks`, correlated GET·POST, `running/{name}` | 6b |
| `ArchonWeb.SignalController` | ref 갱신과 sync, signal과 sync, `execute/{name}/{version}` | 6e |
| `ArchonWeb.MetadataController`(기존) | 목록, names-and-versions, names, latest-versions, versions, 정의 삭제, 태스크 정의 삭제, validate | 6c |
| `ArchonWeb.WorkflowBulkController` | bulk 일곱 개 | 6g |

| 조각 | 범위 | 시험·정답 기준 | 선행 | 건드리는 파일·모듈 |
|---|---|---|---|---|
| 6a | 픽스처 캡처 전부(결정 7), 라우터(33개 경로와 남는 Later·Unsupported 리터럴), 새 컨트롤러 골격과 미구현 목록, 재생 도우미의 건너뛰기와 `requires:` | 기존 127개 재캡처 비교, 경로 해석 라우터 시험(결정 1), 건너뛰기를 뺀 전체 재생 | 없음 | `scripts/contract/capture_fixtures.sh`, `test/fixtures/contract/*`, `test/fixtures/contract/README.md`, `test/archon/contract_test.exs`, `test/archon/domain/contract_round_trip_test.exs`, `test/support/contract.ex`, `test/support/archon_web/contract_case.ex`, `lib/archon_web/router.ex`, `lib/archon_web/controllers/{workflow_lifecycle,workflow_query,signal,workflow_bulk}_controller.ex`(골격), `lib/archon_web/controllers/metadata_controller.ex`(새 액션 골격만), `test/archon_web/router_test.exs` |
| 6b | 결정 4: 저장소 조회 콜백과 Postgres 마이그레이션, `{id}/tasks`·correlated 둘·`running/{name}`, `SearchResult` 모델 | 조회 픽스처 재생(두 백엔드), 저장소 계약 시험, 마이그레이션의 기존 행 채우기 시험 | 6a | `lib/archon/runtime/store.ex`, `lib/archon/runtime/store/{memory,postgres}.ex`, `priv/repo/migrations/*`(새 파일), `test/support/runtime/store_contract.ex`, `lib/archon/runtime.ex`(조회 함수), `lib/archon/domain/search_result.ex`, `lib/archon_web/controllers/workflow_query_controller.ex` |
| 6c | 결정 6의 metadata: behaviour 콜백 셋, `Archon.Metadata`의 목록·삭제·validate, `WorkflowDefSummary` 모델, Metadata 컨트롤러 여덟 액션 | `metadata_*` 새 픽스처 재생, 메타데이터 계약 시험 | 6a | `lib/archon/runtime/metadata.ex`, `lib/archon/runtime/metadata/{memory,postgres}.ex`, `test/support/runtime/metadata_contract.ex`, `lib/archon/metadata.ex`, `lib/archon/domain/workflow_def_summary.ex`, `lib/archon_web/controllers/metadata_controller.ex`, `test/archon/metadata_test.exs`, `test/archon_web/metadata_controller_test.exs` |
| 6d | 결정 2·3: pause·resume·retry·restart 컨트롤러, skiptask·resetcallbacks·remove 이벤트, remove·terminate-remove, "전달 대기" 오류와 호출 timeout의 `retryable` | 생명주기·정리 픽스처 재생, 이벤트 단위 시험(두 백엔드), 지운 부모에게 자식이 알리는 시험, terminate-remove의 outbox 시험(결정 3), 대기 중 retry 경합 | 6a | `lib/archon/runtime/step/lifecycle.ex`, `lib/archon/runtime/lifecycle.ex`, `lib/archon/runtime/workflow_server.ex`, `lib/archon/runtime/step.ex`, `lib/archon/runtime/step/event.ex`, `lib/archon_web/errors.ex`, `lib/archon_web/controllers/workflow_lifecycle_controller.ex`, 해당 시험 |
| 6e | 결정 5: ref 갱신 둘, signal 둘, 동기 응답기, `execute`, `SignalResponse`·`WorkflowRun`·`TaskRun`·`WorkflowSignalReturnStrategy` 모델 | ref·signal·execute 픽스처 재생, 응답기 단위 시험(시간 초과, 자식으로 내려가기, 소유권) | 6a | `lib/archon/runtime/tasks.ex`, `lib/archon/domain/{signal_response,workflow_run,task_run}.ex`, `lib/archon_web/signal_responder.ex`, `lib/archon_web/controllers/signal_controller.ex`, 해당 시험 |
| 6f | 결정 2의 rerun과 `RerunWorkflowRequest` 모델 | rerun 픽스처 재생, 자식 안의 태스크 rerun과 부모 되살림 시험(두 번 되살림 포함, 두 백엔드) | 6d | `lib/archon/runtime/step/lifecycle.ex`, `lib/archon/runtime/lifecycle.ex`, `lib/archon/runtime/workflow_server.ex`, `lib/archon/runtime/step.ex`, `lib/archon/runtime/step/event.ex`, `lib/archon/domain/rerun_workflow_request.ex`, `lib/archon_web/controllers/workflow_lifecycle_controller.ex`(rerun 액션) |
| 6g | 결정 6의 bulk 일곱 경로 | bulk 픽스처 재생, 1000개 한도 시험 | 6d | `lib/archon_web/controllers/workflow_bulk_controller.ex`, 해당 시험 |
| 6h | 통합: 건너뛰기 장치 제거와 전체 재생(두 백엔드), 빠진 픽스처, 새 모델 픽스처의 분류(결정 7), 서버 연기 시험에 생명주기 하나, README 호환성 절의 경로 표와 의도적 차이, ADR 0001 분류(구현한 경로를 MVP처럼 "Phase 6"으로), 이 ADR `승인`, ADR 0021 L3 행 비고 | `mix test` 전부(두 백엔드), CI | 6b, 6c, 6e, 6f, 6g | `test/support/archon_web/contract_case.ex`, 각 컨트롤러의 미구현 목록, `test/archon_web/server_test.exs`, `README.md`, `docs/adr/{0001,0021,0025,README}.md`, `docs/adr/0003-porting-strategy.md`(비고), `test/archon/domain/contract_round_trip_test.exs`, `test/support/contract.ex`, 빠진 픽스처가 있으면 6a의 픽스처 파일들 |

- **병렬로 진행할 수 있는 묶음.**
  - 1차: 6a.
  - 2차: 6b, 6c, 6d, 6e. 런타임 파일(저장소, metadata, 생명주기·`WorkflowServer`, `Tasks`)과 컨트롤러 파일이 서로 겹치지 않는다.
    6a가 컨트롤러 골격, 라우터, 라우터 시험, 픽스처 등록을 모두 만들었으므로 이 파일들도 고치지 않는다. 함께 고칠 수 있는 파일은
    `contract_case.ex`의 자기 단계 옵션 줄뿐이다(아래).
  - 3차: 6f(6d 뒤, 같은 생명주기 파일)와 6g(6d 뒤, 단건 remove·terminate-remove를 부름).
  - 마지막: 6h.
- 각 조각은 자기 컨트롤러의 미구현 목록만 비우고 `contract_case.ex`의 시나리오는 고치지 않는다(결정 7). 6a가 캡처를 보고 알 수 있는
  `ignore`는 미리 적는다. 구현하다 자기 단계의 옵션(`ignore` 등)을 더 고쳐야 하면 그 단계 줄만 고친다(ADR 0023 결정 7과 같음). 다른
  조각과 같은 줄을 고치지 않으므로, 겹쳐도 `gh pr update-branch`로 푸는 작은 충돌이다.
- 각 조각은 이 ADR의 결정 번호와 조각 이름을 PR에 적는다. 조각 중에 결정이 바뀌면 이 ADR의 해당 결정과 날짜 줄에 갱신 사실을
  적는다(ADR 0023과 같은 방식).

## upstream과 의도적으로 다른 점

ADR 0023의 목록에 더해 다음이 생긴다.

- **L3**(결정 2): `resumeSubworkflowTasks`로 내려간 끝이 실행 중인 자식이면 archon은 404, upstream은 재시도한다.
- **skiptask의 요청**(결정 2): Spring `@ModelAttribute` 바인딩(쿼리로 `taskInput`·`taskOutput` 채우기)을 옮기지 않는다.
- **remove의 보관본**(결정 3): 없다. upstream 기본 서버도 보관본을 읽지 못하므로 응답은 같다. 색인이 있는 upstream 설정과는 다르다.
- **목록 순서**(결정 4·6): correlated, `running/{name}`, `latest-versions`는 정해진 순서다. upstream은 순서를 정하지 않는다.
- **`validate`의 스키마 거절**(결정 6): ADR 0023 결정 5의 거절을 등록 전에 알려 준다. upstream은 통과시킨다.
- **rerun의 동적 FORK 분기**(결정 2): MVP 태스크 타입 밖이라 옮기지 않는다.
- **remove의 전달 대기 500**(결정 3): outbox 전달이 마감(예 10초)까지 끝나지 않으면 `archiveWorkflow`와 상관없이 아무것도 지우지
  않고 500 `retryable` 참이다. upstream은 종료의 부수 효과를 동기로 끝내므로 이 응답이 없다. bulk remove·terminate-remove는 ID마다
  이 대기를 하므로 전달이 계속 실패하는 ID가 많으면 요청이 길어진다(받아들이는 비용).
- **task 실행 로그**(결정 1): Later. `TaskResult.logs`를 저장하지 않는다(Phase 5와 같음).

## 대안

- **범위를 더 좁히기(생명주기·정리·`{id}/tasks`만, 또는 signal·execute를 Later로):** 조각이 줄지만, SDK의 `WorkflowClient`가 부르는
  correlated·running·bulk와 사람 태스크 흐름의 signal이 빠진다. BOSS가 task log만 빼기로 했다.
- **task 실행 로그도 포함:** archon 저장소에 표 하나면 되지만, upstream은 색인 DAO의 일부로 두고 remove·검색과 함께 움직인다.
  검색·색인 ADR에서 저장 위치와 크기 한도(`taskExecLogSizeLimit`)를 함께 정한다.
- **동기 대기를 프로세스 구독으로:** 응답이 빠르지만 워크플로우 프로세스에 구독자 관리와 정리 경로가 생기고, 자식까지 내려가는
  막힌 태스크 판정은 어차피 여러 워크플로우를 읽어야 한다. BOSS가 upstream과 같은 100ms 폴링을 골랐다.
- **동기 실행을 Later로:** ADR 0001 비고("GenServer 구조에 잘 맞지만 MVP 이후")대로 미룰 수 있었지만 응답기를 signal/sync와 함께 쓰므로
  같이 연다.
- **remove의 보관 표:** `archiveWorkflow=true`면 보관본을 남겨 GET이 읽게 할 수 있다. upstream 기본 서버와 응답이 달라진다.
- **실행 중 워크플로우 remove 거절:** 안전하지만 `archiveWorkflow=false`의 upstream 계약과 다르다.
- **L3를 upstream처럼:** 실행 중인 자식을 다시 시도하면 그 자식 프로세스의 실행 중 태스크와 새 태스크가 겹친다. 오류로 두는 지금이
  안전하고, REST로 닿기 어렵다.
- **조각마다 픽스처 캡처:** 전체 재캡처가 조각마다 겹치고 앞 단계 ID에 기대는 새 픽스처는 부분 복사가 안 된다(ADR 0023 결정 6 5f).
- **resume·skiptask의 `IllegalStateException`을 409로:** 더 맞는 코드지만 upstream 계약과 다르다. BOSS가 500을 유지했다.

## 결과

- 이 ADR은 결정만 담는다. 구현은 결정 8의 조각 6a~6h로 하고, 마지막 조각 6h의 PR에서 `승인`으로 바꾼다.
- [ADR 0003](0003-porting-strategy.md) 단계 표에 Phase 6을 더한다. [ADR 0001](0001-api-contract-scope.md)의 분류 표에는 이 Phase가 여는
  33개 경로의 비고에 "Phase 6(ADR 0025)"를 적는다. 구현이 끝나면 6h가 분류를 고친다.
- ADR 0018 결정 9의 생명주기 API에 rerun, skip, 콜백 초기화, 지우기가 더해진다. ADR 0018의 "범위 밖" 목록 중 이 셋은 이 ADR이 다룬다.
- ADR 0021의 L3(수용)는 결정 2로 의도적 차이로 닫고, 6h가 ADR 0021 L3 행에 비고를 단다.
- 아직 범위 밖: task 실행 로그, 검색·색인과 `bulk/search`, 이벤트, 외부 payload 저장소, 큐 관리·admin, 스케줄러, 인증(ADR 0024 결정 4),
  스키마 검증기와 `/api/schema`, 여러 노드, 배포 절차, MVP 밖 태스크 타입.
