# ADR 0001: API 계약 범위

- 상태: 승인 (PR #5 머지, 2026-10-25)
- 날짜: 2026-10-25
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`
- 비고: 2026-11-01 [ADR 0025](0025-phase6-workflow-operations-rest.md)가 Phase 6에서 열 Later 경로 33개의 비고에 "Phase 6"을 적었다.
  분류는 구현이 끝날 때 바꾼다(결과 절).

## 맥락

Archon은 기존 Conductor 워커·SDK·UI가 그대로 붙는 REST/JSON 호환 엔진을 목표로 한다. upstream
핵심 REST 모듈(`rest/src/main/java/com/netflix/conductor/rest/controllers/`)에는 `*Resource`
컨트롤러 12개, 핸들러 메서드 89개가 있고, 한 메서드가 두 경로를 받는 경우 3건(`/health`·`/api/health`,
`externalstoragelocation`·`external-storage-location` 2쌍)을 펼치면 경로는 92개다. 처음부터 전부 구현하지
않고, 도메인 모델과 런타임 설계(Phase 1~3)가 기대야 할 최소 계약을 먼저 고정한다.

## 결정

엔드포인트를 세 범주로 나눈다.

- **MVP**: Phase 5에서 처음 구현하고, 골든 픽스처로 응답 형태를 고정한다. workflow·task 정의 등록과
  조회, workflow 시작·조회·종료, 워커의 poll·update 루프.
- **Later**: 경로와 의미를 그대로 유지할 계획이지만 MVP 이후에 구현한다. 구현 전까지 Archon은 이
  경로에 응답하지 않는다(404). 응답 형태를 지어내지 않는다.
- **Unsupported**: upstream 내부 구조(sweeper, 분산 저장소 정합성, Java 설정 노출)를 전제로 해서
  Archon 설계에 대응하는 동작이 없다. 구현하지 않으며, 필요해지면 새 ADR로 다시 판단한다.

집계(경로 기준): MVP 19, Later 69, Unsupported 4. MVP 19개 중 `/api/health`는 `/health`의 별칭이라
메서드로는 18개다.

### 분류 원칙

1. 경로는 컨트롤러 어노테이션(`@RequestMapping` + `@GetMapping` 등)에서 그대로 옮겼다.
   클래스 경로 상수는 `rest/config/RequestMappingConstants.java`(`API_PREFIX = "/api/"`)에서 풀었다.
   표의 경로는 실행 중인 서버의 OpenAPI 스냅샷(`priv/contract/openapi.json`)과 대조해 92개 중 91개가
   일치했다. 남은 하나 `POST /api/workflow/{workflowId}/messages`는 `@ConditionalOnProperty`로 기본
   비활성이라 스냅샷에 없다.
2. 워커 SDK가 실행 루프에서 부르는 경로는 MVP다(`GET /api/metadata/taskdefs`, poll, batch poll,
   `POST /api/tasks`, `POST /api/tasks/update-v2`).
3. 인덱싱 백엔드가 필요한 검색, 외부 payload 저장소, 이벤트 큐에 기대는 경로는 해당 백엔드를 들일 때까지
   Later다.
4. workflow를 바깥에서 다시 결정하게 만드는 API(`decide`, `sweep/requeue`)는 워크플로우 인스턴스마다
   GenServer가 상태 전이를 직접 맡는 Archon 구조와 맞지 않아 Unsupported다.

### MVP 계약에서 픽스처로 확인한 사실

`test/fixtures/contract/`의 실제 응답에서 확인한 것이다. Archon은 이 형태를 그대로 따른다.

- `POST /api/workflow`, `POST /api/workflow/{name}`: `200`, `text/plain;charset=UTF-8`, body는 workflowId.
- `POST /api/tasks`: `200`, `text/plain;charset=UTF-8`, body는 갱신한 taskId.
- `POST /api/tasks/update-v2`: 같은 타입의 다음 task가 없으면 `204`, body 없음.
- `GET /api/tasks/poll/{tasktype}`: task가 없으면 `204`, body 없음(2.x 클라이언트 호환).
- `POST /api/metadata/workflow`, `POST /api/metadata/taskdefs`, `DELETE /api/workflow/{workflowId}`:
  `200`, body와 `Content-Type` 없음.
- 같은 name·version으로 다시 `POST /api/metadata/workflow`: `409`.
- 없는 workflow·정의 조회: `404`. 오류 body는 `{"status", "message", "instance", "retryable"}`.
- terminate된 workflow의 진행 중 task는 `CANCELED`가 된다.

## 엔드포인트 분류

표의 경로는 컨트롤러 소스에서 자동 추출했다. `rest/src/main/java/org/conductoross/conductor/controllers/`
와 다른 모듈의 컨트롤러는 그 아래 따로 정리했다.

### AdminResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| Unsupported | `GET` | `/api/admin/config` | `getAllConfig` | Java 서버 설정 맵 노출. Archon 설정 모델과 대응 없음 |
| Later | `GET` | `/api/admin/task/{tasktype}` | `view` | 관리용 대기 task 조회 |
| Unsupported | `POST` | `/api/admin/sweep/requeue/{workflowId}` | `requeueSweep` | sweeper 큐 전제. 워크플로우당 프로세스 구조에는 sweeper가 없음 |
| Unsupported | `POST` | `/api/admin/consistency/verifyAndRepair/{workflowId}` | `verifyAndRepairWorkflowConsistency` | 분산 저장소 정합성 복구용. Postgres 트랜잭션으로 대체 |
| Later | `GET` | `/api/admin/queues` | `getEventQueues` | 이벤트 큐 목록 |

### EnvironmentResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| Later | `GET` | `/api/environment` | `getAll` | 환경 변수 저장소 |
| Later | `GET` | `/api/environment/{key}` | `get` |  |

### EventResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| Later | `POST` | `/api/event` | `addEventHandler` | 이벤트 핸들러는 이벤트 큐 연동 이후 |
| Later | `PUT` | `/api/event` | `updateEventHandler` |  |
| Later | `DELETE` | `/api/event/{name}` | `removeEventHandlerStatus` |  |
| Later | `GET` | `/api/event` | `getEventHandlers` |  |
| Later | `GET` | `/api/event/{event}` | `getEventHandlersForEvent` |  |

### HealthCheckResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| MVP | `GET` | `/health` | `doCheck` | 운영 헬스체크 |
| MVP | `GET` | `/api/health` | `doCheck` | 같은 핸들러의 별칭 |

### MetadataResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| MVP | `POST` | `/api/metadata/workflow` | `create` | WorkflowDef 등록(`overwrite` 쿼리) |
| Later | `POST` | `/api/metadata/workflow/validate` | `validate` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| MVP | `PUT` | `/api/metadata/workflow` | `update` | SDK의 일괄 등록·갱신 경로. `BulkResponse` 반환 |
| MVP | `GET` | `/api/metadata/workflow/{name}` | `get` | WorkflowDef 조회(`version` 쿼리) |
| Later | `GET` | `/api/metadata/workflow` | `getAll` | 목록·UI용(`classifier` 쿼리). Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `GET` | `/api/metadata/workflow/names-and-versions` | `getWorkflowNamesAndVersions` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `GET` | `/api/metadata/workflow/names` | `getWorkflowNames` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `GET` | `/api/metadata/workflow/{name}/versions` | `getWorkflowVersions` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `GET` | `/api/metadata/workflow/latest-versions` | `getAllWorkflowsWithLatestVersions` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `DELETE` | `/api/metadata/workflow/{name}/{version}` | `unregisterWorkflowDef` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| MVP | `POST` | `/api/metadata/taskdefs` | `registerTaskDef` | TaskDef 일괄 등록(배열 body) |
| MVP | `PUT` | `/api/metadata/taskdefs` | `registerTaskDef` | TaskDef 단건 갱신 |
| MVP | `GET` | `/api/metadata/taskdefs` | `getTaskDefs` | 워커 SDK가 시작 시 조회 |
| MVP | `GET` | `/api/metadata/taskdefs/{tasktype}` | `getTaskDef` |  |
| Later | `DELETE` | `/api/metadata/taskdefs/{tasktype}` | `unregisterTaskDef` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |

### QueueAdminResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| Later | `GET` | `/api/queue/size` | `size` | WAIT task 외부 완료용 큐 |
| Later | `GET` | `/api/queue/` | `names` |  |
| Later | `POST` | `/api/queue/update/{workflowId}/{taskRefName}/{status}` | `update` |  |
| Later | `POST` | `/api/queue/update/{workflowId}/task/{taskId}/{status}` | `updateByTaskId` |  |

### SecretResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| Later | `GET` | `/api/secrets` | `listSecretNames` | 시크릿 저장소 |

### TaskResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| MVP | `GET` | `/api/tasks/poll/{tasktype}` | `poll` | task 없으면 204 |
| MVP | `GET` | `/api/tasks/poll/batch/{tasktype}` | `batchPoll` | task 없으면 빈 배열 |
| MVP | `POST` | `/api/tasks` | `updateTask` | `TaskResult` body, taskId를 text/plain으로 반환 |
| MVP | `POST` | `/api/tasks/update-v2` | `updateTaskV2` | 갱신 후 같은 타입 다음 task 반환, 없으면 204 |
| Later | `POST` | `/api/tasks/{workflowId}/{taskRefName}/{status}` | `updateTask` | ref name 기반 갱신. Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/tasks/{workflowId}/{taskRefName}/{status}/sync` | `updateTaskSync` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/tasks/{workflowId}/{status}/signal` | `signalWorkflowTaskAsync` | signal 계열. Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/tasks/{workflowId}/{status}/signal/sync` | `signalWorkflowTaskSync` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/tasks/{taskId}/log` | `log` | task 실행 로그 |
| Later | `GET` | `/api/tasks/{taskId}/log` | `getTaskLogs` |  |
| MVP | `GET` | `/api/tasks/{taskId}` | `getTask` | task 단건 조회 |
| Later | `GET` | `/api/tasks/queue/sizes` | `size` | upstream에서도 deprecated |
| Later | `GET` | `/api/tasks/queue/size` | `taskDepth` |  |
| Later | `GET` | `/api/tasks/queue/all/verbose` | `allVerbose` |  |
| Later | `GET` | `/api/tasks/queue/all` | `all` |  |
| Later | `GET` | `/api/tasks/queue/polldata` | `getPollData` |  |
| Later | `GET` | `/api/tasks/queue/polldata/all` | `getAllPollData` |  |
| Later | `POST` | `/api/tasks/queue/requeue/{taskType}` | `requeuePendingTask` |  |
| Later | `GET` | `/api/tasks/search` | `search` | 인덱싱 백엔드 필요 |
| Later | `GET` | `/api/tasks/search-v2` | `searchV2` |  |
| Later | `GET` | `/api/tasks/externalstoragelocation` | `getExternalStorageLocation` | 외부 payload 저장소 |
| Later | `GET` | `/api/tasks/external-storage-location` | `getExternalStorageLocation` |  |

### WorkflowBulkResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| Later | `PUT` | `/api/workflow/bulk/pause` | `pauseWorkflow` | bulk 계열은 단건 lifecycle 이후. Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `PUT` | `/api/workflow/bulk/resume` | `resumeWorkflow` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/workflow/bulk/restart` | `restart` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/workflow/bulk/retry` | `retry` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/workflow/bulk/terminate` | `terminate` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `DELETE` | `/api/workflow/bulk/remove` | `deleteWorkflow` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `DELETE` | `/api/workflow/bulk/terminate-remove` | `terminateRemove` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/workflow/bulk/search` | `searchWorkflow` |  |

### WorkflowMessageQueueResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| Later | `POST` | `/api/workflow/{workflowId}/messages` | `pushMessage` | 기본 비활성(`conductor.workflow-message-queue.enabled=false`) |

### WorkflowResource

| 분류 | 메서드 | 경로 | 핸들러 | 비고 |
|---|---|---|---|---|
| MVP | `POST` | `/api/workflow` | `startWorkflow` | `StartWorkflowRequest` body, workflowId를 text/plain으로 반환 |
| MVP | `POST` | `/api/workflow/{name}` | `startWorkflow` | input map body, `version`·`correlationId`·`priority` 쿼리 |
| Later | `POST` | `/api/workflow/execute/{name}/{version}` | `executeWorkflow` | 동기 실행. GenServer 구조에 잘 맞지만 MVP 이후. Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `GET` | `/api/workflow/{name}/correlated/{correlationId}` | `getWorkflows` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `GET` | `/api/workflow/{workflowId}/tasks` | `getExecutionStatusTaskList` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/workflow/{name}/correlated` | `getWorkflows` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| MVP | `GET` | `/api/workflow/{workflowId}` | `getExecutionStatus` | `includeTasks` 쿼리(기본 true) |
| MVP | `GET` | `/api/workflow/{workflowId}/status` | `getWorkflowStatusSummary` | 같은 상태에서 만드는 요약 |
| Later | `DELETE` | `/api/workflow/{workflowId}/remove` | `delete` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `GET` | `/api/workflow/running/{name}` | `getRunningWorkflow` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Unsupported | `PUT` | `/api/workflow/decide/{workflowId}` | `decide` | 외부에서 decide를 트리거하는 sweeper 전제 API. Archon은 프로세스가 스스로 결정 |
| Later | `PUT` | `/api/workflow/{workflowId}/pause` | `pauseWorkflow` | lifecycle. Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `PUT` | `/api/workflow/{workflowId}/resume` | `resumeWorkflow` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `PUT` | `/api/workflow/{workflowId}/skiptask/{taskReferenceName}` | `skipTaskFromWorkflow` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/workflow/{workflowId}/rerun` | `rerun` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/workflow/{workflowId}/restart` | `restart` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/workflow/{workflowId}/retry` | `retry` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `POST` | `/api/workflow/{workflowId}/resetcallbacks` | `resetWorkflow` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| MVP | `DELETE` | `/api/workflow/{workflowId}` | `terminate` | terminate(`reason` 쿼리) |
| Later | `DELETE` | `/api/workflow/{workflowId}/terminate-remove` | `terminateRemove` | Phase 6([ADR 0025](0025-phase6-workflow-operations-rest.md)) |
| Later | `GET` | `/api/workflow/search` | `search` | 인덱싱 백엔드 필요 |
| Later | `GET` | `/api/workflow/search-v2` | `searchV2` |  |
| Later | `GET` | `/api/workflow/search-by-tasks` | `searchWorkflowsByTasks` |  |
| Later | `GET` | `/api/workflow/search-by-tasks-v2` | `searchWorkflowsByTasksV2` |  |
| Later | `GET` | `/api/workflow/externalstoragelocation` | `getExternalStorageLocation` | 외부 payload 저장소 |
| Later | `GET` | `/api/workflow/external-storage-location` | `getExternalStorageLocation` |  |
| Later | `POST` | `/api/workflow/test` | `testWorkflow` | mock 데이터 테스트 실행 |

### 핵심 REST 모듈 밖의 컨트롤러

기본 설정 서버의 OpenAPI 스냅샷에 함께 나오는 컨트롤러다. 모두 위 12개 컨트롤러와 별개 기능이라
경로 단위가 아니라 묶음 단위로 분류한다.

| 분류 | 컨트롤러(upstream 경로) | 경로 접두사 | 비고 |
|---|---|---|---|
| Later | `SchemaResource` (`rest/.../org/conductoross/conductor/controllers/`) | `/api/schema` | input/output schema 강제(`enforceSchema`)와 함께 |
| Later | `VersionResource` (같은 패키지) | `/api/version` | `@Hidden`이라 OpenAPI 스냅샷에는 없다 |
| Later | `SchedulerResource`, `SchedulerBulkResource` (`scheduler/core`) | `/api/scheduler` | 스케줄러는 별도 단계 |
| Unsupported | `FileResource` (같은 패키지) | `/api/files` | 기본 비활성(`conductor.file-storage.enabled`) |
| Unsupported | AI·agentspan·A2A 컨트롤러 (`ai/`, `agentspan/`) | `/api/agent`, `/api/a2a`, `/api/providers`, agentspan `SecretController`의 `/api/secrets` 하위 경로 | LLM 통합은 범위 밖. `conductor.integrations.ai.enabled=true`(기본값)일 때 켜진다 |
| Unsupported | `AgentSpanUiContextController` (`server/`) | `/context.js` | UI 번들용 |
| Unsupported | `ExternalPostgresPayloadResource` (`postgres-external-storage`) | — | 기본 비활성 |

## 결과

- Phase 1 도메인 모델은 MVP 응답에 나오는 `WorkflowDef`, `TaskDef`, `Workflow`, `Task` 필드를 우선
  모델링하고, `priv/contract/*.json` 스키마와 `Archon.Contract` 테스트 헬퍼로 직렬화 결과를 검증한다.
- Later 경로를 구현할 때마다 같은 방식으로 upstream 픽스처를 추가하고, 이 ADR의 분류를 갱신한다.
- Unsupported 경로를 호출하는 클라이언트(일부 UI 관리 화면)는 Archon에서 동작하지 않는다. README의
  호환성 설명에 이 목록을 링크한다.
- upstream 기준 커밋을 올릴 때는 경로 추출과 OpenAPI 스냅샷을 다시 만들고 이 표와 차이를 검토한다.
