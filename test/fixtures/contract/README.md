# Golden contract fixtures

실제 upstream Conductor 서버에 요청을 보내 받은 요청·응답 쌍이다. 손으로 만들거나 고치지 않는다.

- 서버: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`, 기본 `application.properties`
  (SQLite), 빈 DB에서 시작. 자세한 빌드·실행 방법은 [priv/contract/README.md](../../../priv/contract/README.md).
- 생성 스크립트: [`scripts/contract/capture_fixtures.sh`](../../../scripts/contract/capture_fixtures.sh)

```bash
BASE_URL=http://localhost:18080 scripts/contract/capture_fixtures.sh
```

## 형식

파일 하나가 HTTP 교환 하나다.

```json
{
  "request": {"method": "POST", "path": "/api/workflow/archon_simple?correlationId=...", "body": {}},
  "response": {"status": 200, "content_type": "text/plain;charset=UTF-8", "body": "<workflow-id>"}
}
```

- 요청 body가 없으면 `null`, JSON이 아니면 보낸 문자열 그대로.
- 응답 body는 `application/json`이면 파싱한 값, 그 밖(`text/plain`)이면 문자열, 비어 있으면 `null`.
- `content_type`은 응답 `Content-Type` 헤더 그대로이며 헤더가 없으면 `null`.

## 시나리오

| 접두사 | 내용 |
|---|---|
| `metadata_*` | TaskDef 2개, WorkflowDef 3개(SIMPLE 순차, SWITCH, FORK_JOIN/JOIN) 등록·조회, 409·404 |
| `workflow_*_simple`, `task_*_simple_*` | 시작 → poll → `POST /api/tasks` → poll → `POST /api/tasks/update-v2` → 완료 |
| `*_switch*` | `StartWorkflowRequest`로 시작, `route=b` 분기 |
| `*_fork*` | batch poll, 두 분기 완료 후 JOIN 완료 |
| `workflow_terminate`, `workflow_get_terminated` | `DELETE /api/workflow/{workflowId}` 후 `TERMINATED`, 진행 중 task는 `CANCELED` |
| `*_not_found`, `task_poll_empty` | 404 오류 body, 큐가 비었을 때 204 |

아래는 Phase 5 REST를 위해 더한 시나리오다([ADR 0023](../../../docs/adr/0023-phase5-rest.md) 결정 6, 조각 5a).

| 접두사·이름 | 내용 |
|---|---|
| `health`, `health_api` | `GET /health`, `GET /api/health` |
| `metadata_list_taskdefs`, `metadata_*taskdef*` | 목록, 배열 자리에 객체 하나(`_single`), 단건 갱신과 없는 이름 404 |
| `metadata_register_taskdefs_{empty,no_name,blank_name,coerced}`, `metadata_register_workflow_no_tasks` | 검증 실패 400. `coerced`는 primitive의 `null`(→ `"0"`)과 정수 필드의 실수(→ `"-1"`)의 `invalidValue` |
| `metadata_*overwrite*`, `metadata_get_workflow_version_not_found` | `overwrite=true` 덮어쓰기, 없는 버전 404 |
| `metadata_update_workflows*`, `metadata_get_workflow_bulk_*` | `PUT /api/metadata/workflow`: 성공 `BulkResponse`, 한 원소 실패로 전체 400(유효한 원소도 저장되지 않음), 빈 배열 |
| `workflow_start_*not_found`, `*inline*` | 없는 정의로 시작(두 경로), `StartWorkflowRequest.workflowDef` 인라인 시작 |
| `workflow_get_running_without_tasks`, `workflow_get_status_*` | 실행 중 `includeTasks=false`, 상태 요약의 기본값과 `includeOutput`·`includeVariables` |
| `task_update_v2_next` | `update-v2`가 같은 타입의 다음 태스크를 돌려줌 |
| `workflow_terminate_{completed,not_found}`, `task_*not_found` | 완료된 워크플로우 종료 409, 없는 워크플로우·태스크 |
| `task_update_invalid`, `task_update_v2_invalid` | 같은 검증 실패가 `POST /api/tasks`는 400, `update-v2`는 500(Spring `MethodArgumentNotValidException`) |
| `route_*` | 없는 경로 404, MVP 매개변수 경로와 모양이 같은 Later 경로의 upstream 응답, MVP 경로의 다른 메서드(405) |
| `request_*` | JSON이 아닌 body, 숫자·불리언 쿼리에 변환되지 않는 값(500) |

Archon이 일부러 다르게 답하는 픽스처(Later 경로와 405는 404, Jackson 문구)는 재생 도우미
`test/support/archon_web/contract_case.ex`의 시나리오에 단계 옵션으로 적혀 있다.

## 가변 필드

다시 캡처하면 값이 바뀌는 필드다. 같은 시나리오를 빈 DB로 두 번 캡처해 비교해서 확인했다.

| 종류 | 필드 |
|---|---|
| 생성 ID(UUID) | `workflowId`, `workflowInstanceId`, `taskId`, 요청 `path`의 ID, `text/plain` 응답 body(시작한 workflow ID, 갱신한 task ID) |
| 시각(epoch ms) | `createTime`, `updateTime`, `startTime`, `endTime`, `scheduledTime` |
| 시각에서 나온 값 | `queueWaitTime` |

픽스처에는 캡처한 값을 그대로 둔다. 숫자 타임스탬프를 문자열 placeholder로 바꾸면 스키마 검사가
깨지기 때문이다. 비교가 필요하면 `Archon.Contract.normalize/1`을 양쪽에 적용한다. 시각 키는
`"<volatile>"`로, 문자열 안의 UUID는 위치와 상관없이 `"<uuid>"`로 바꾼다. 두 번의 캡처는
`normalize/1` 적용 후 모든 파일이 같았다.

예외로 하나만 캡처 후 가공한다. 오류 body의 `instance`에는 서버 호스트 이름이 들어가므로
스크립트가 `"<redacted-hostname>"`으로 바꾼다. 키는 남겨 응답 형태는 유지한다.

## 검사

`test/archon/contract_test.exs`가 모든 픽스처를 분류해 검사한다. 새 픽스처를 추가하면
`Archon.Contract.fixture_schemas/0`(`test/support/contract.ex`) 또는 그 테스트의 `@unschematized`, 그리고
`test/archon/domain/contract_round_trip_test.exs`의 `@models`에 등록해야 테스트가 통과한다. 재생 순서는
`ArchonWeb.ContractCase.scenario/0`에 캡처 스크립트와 같은 순서로 더한다.
