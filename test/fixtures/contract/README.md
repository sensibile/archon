# Golden contract fixtures

실제 upstream Conductor 서버에 요청을 보내 받은 요청·응답 쌍이다. 손으로 만들거나 고치지 않는다.

- 서버: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`, 기본 `application.properties`
  (SQLite), 빈 DB에서 시작. 자세한 빌드·실행 방법은 [priv/contract/README.md](../../../priv/contract/README.md).
- 생성 스크립트: [`scripts/contract/capture_fixtures.sh`](../../../scripts/contract/capture_fixtures.sh)

```bash
BASE_URL=http://localhost:18080 scripts/contract/capture_fixtures.sh
```

HTTP 태스크 픽스처는 고정 응답 stub([`test/support/http_stub.ex`](../../support/http_stub.ex))를 부른다. 스크립트가
`MIX_ENV=test mix run`으로 `127.0.0.1:18299`에 띄운다(그 주소에 이미 떠 있으면 `HTTP_STUB=http://127.0.0.1:18299`. 다른 주소는
거절한다). 재생은 픽스처의 이 주소를 시험 안에서 띄운 stub 주소로 바꾼다. stub의 상태 코드 299 사유 문구는 Plug의 컴파일 시간
설정(`config/test.exs`의 `config :plug, :statuses`)이라, 그 줄이 없던 `_build/test`에서는 `MIX_ENV=test mix deps.compile plug
--force`가 한 번 필요하다.

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

아래는 마지막 조각 5f가 앞 조각들이 시험에 손으로 적은 upstream 응답을 캡처해 더한 것이다(40개, 모두 127개). 상태를
바꾸지 않는 오류를 먼저, 큐에 태스크를 남기는 시작을 마지막에 둔다.

| 접두사·이름 | 내용 |
|---|---|
| `*_missing_body`, `*_null_body` | 빈 body와 `null` body의 `"Required request body is missing: <handler>"`(500), body를 받는 경로 여덟 개에 하나씩 |
| `metadata_register_workflow_no_name`, `metadata_register_workflow_overwrite_invalid`, `metadata_update_taskdef_invalid` | 검증 접두사 `registerWorkflowDef.arg0`, `overwrite=true`의 `updateWorkflowDef.arg0`, `updateTaskDef.arg0` |
| `metadata_update_workflows_null_element`, `metadata_register_taskdefs_null_element` | `[null]`: 일괄 갱신은 400, TaskDef 등록은 upstream `NullPointerException` 문구 500 |
| `*_wrong_type`, `workflow_start_not_object` | Jackson이 바꾸지 못하는 값(500). 재생은 `message`를 뺀다(Archon 문구는 ADR 0023 결정 4) |
| `*_query_not_{number,boolean}` | `overwrite`, `version`, `includeOutput` 쿼리 변환 실패(500) |
| `task_update_v2_invalid_both` | `update-v2`의 두 필드 모두 실패(`" with 2 errors"`) |
| `task_batch_poll_{timeout_too_long,count_zero}`, `task_poll_domain_empty` | `timeout=5001` 400, `count=0`의 `[]`, 도메인 큐가 빈 poll 204 |
| `workflow_start_request_{no_name,priority_too_high,invalid_definition}`, `workflow_start_priority_too_low` | 시작 검증 400(`startWorkflow.arg0`, `startWorkflow.arg3`) |
| `workflow_start_request_{blank_name,null_input,external_input}`, `workflow_start_version_not_found` | 공백 이름 400, `input: null` 400, 외부 입력 경로 500, 없는 버전 404 |
| `workflow_get_status_no_correlation`, `workflow_terminate_terminated` | `correlationId` 없는 상태 요약, `TERMINATED` 재종료 200 |
| `workflow_start_request_{defaults,inline_other_name}`, `workflow_start_options`, `workflow_get_{request_defaults,options}` | `priority`·`taskToDomain`의 `null`은 기본값, 이름이 다른 인라인 정의 시작, `version`·`correlationId`·`priority` 쿼리 |

5f에서 다시 캡처한 기존 87개는 `normalize/1` 기준으로 하나만 달랐다(`metadata_register_taskdefs_coerced`의
`validationErrors` 순서, Hibernate가 정하지 않는 순서라 재생은 순서 없이 비교한다). 새 픽스처가 앞 단계의 워크플로우 ID를
쓰므로 127개 모두 같은 캡처에서 가져왔다.

캡처하지 않은 것과 그 이유. 이 경우들은 각 컨트롤러의 단위 시험이 본다.

| 경우 | 이유 |
|---|---|
| 정의별 실패가 섞인 `BulkResponse` | upstream SQLite에서 만들 수 없다(이름 `null`만 DAO에서 실패하고 `@Valid`가 먼저 막는다). Archon의 스키마 거절·저장 예외에서만 생긴다 |
| 스키마 거절 400(등록, 시작) | Archon만의 거절이다(ADR 0023 결정 5). upstream은 받거나 다른 400을 준다 |
| `DELETE /api/metadata/taskdefs/{tasktype}` | Later 경로이고 upstream에서 정의를 지운다 |
| JSON이 아닌 `Content-Type` | upstream 문구를 `ArchonWeb.Request` 단위 시험이 본다. 캡처 스크립트는 JSON만 보낸다 |
| 같은 경우의 다른 표본(빈 body와 `null`을 모든 경로에, 코덱 타입 오류의 다른 필드, `%20` 이름, 같은 쿼리의 다른 값, 클래스 단위 정의 오류 `startWorkflow.arg0.workflowDef`·`updateTaskDef.arg0`, 오류가 둘 이상인 검증) | 경로·규칙마다 표본 하나를 캡처했다. 나머지는 같은 규칙의 변형이라 단위 시험에 둔다 |

아래는 Phase 6(워크플로우 운영 REST, [ADR 0025](../../../docs/adr/0025-phase6-workflow-operations-rest.md) 결정 7)의 첫 조각
6a가 이 Phase의 경로 33개 시나리오를 한 번에 캡처해 더한 것이다(233개, 모두 360개). 앞 시나리오가 큐에 남긴 태스크와 섞이지
않도록 자기 태스크 타입(`archon_ops_*`)과 정의를 쓰고, 한 타입에 태스크가 하나만 있을 때 poll한다. 나머지 태스크는 워크플로우
GET이 답한 태스크 ID로 갱신한다. 상태를 바꾸지 않는 오류를 먼저, 지우기·bulk·정의 삭제를 마지막에 둔다.

| 접두사·이름 | 내용 |
|---|---|
| `metadata_register_ops_*`, `metadata_register_workflow_ops*` | 태스크 정의 7개(SUB_WORKFLOW용 `archon_ops_sub`는 재시도 1번), 워크플로우 정의 12개(`archon_ops` 두 버전, WAIT 다섯 개, SWITCH 하나로 바로 끝나는 것, DO_WHILE, 자식·중간·최상위 SUB_WORKFLOW 사슬 등) |
| `metadata_list_workflows*`, `metadata_workflow_{names_and_versions,names,latest_versions,versions*}` | 목록 다섯 경로, `classifier` 거르기 |
| `metadata_validate_workflow*`, `metadata_get_workflow_not_validated` | validate 성공 200(저장하지 않음)과 400(`validateWorkflowDef.arg0`) |
| `metadata_delete_*_not_found`, `metadata_delete_workflow_version_not_number` | 없는 정의 삭제 500 둘, 버전 변환 실패 500 |
| `workflow_{pause,resume,retry,restart,rerun,skiptask,resetcallbacks,remove,terminate_remove}_*` | 없는 워크플로우 404, 끝난 워크플로우(409·500·400), 실행 중 워크플로우의 오류. resume은 `RUNNING`이면 200, 끝났으면 500이다. retry는 끝난 것 409, 실행 중 404다 |
| `workflow_tasks*` | `{id}/tasks`의 `status` 거르기(값 하나의 쉼표는 나누고, 반복한 값은 나누지 않는다), 페이징, 음수 `count` 400·음수 `start` 500·끝을 넘은 `start` |
| `workflow_correlated*`, `workflow_running*` | correlated 두 경로(`includeClosed`, `includeTasks`, 목록 body), `running/{name}`의 버전 무시와 넓은 고정 시간 구간(`startTime=1&endTime=4102444800000`), `PAUSED` 포함·제외 |
| `task_ref_update*`, `task_signal*` | ref 갱신과 signal: 대상 없음(비동기 200, sync 404), 없는 워크플로우, 상태 변환 실패, DO_WHILE 반복 ref, WAIT 다섯 개를 따라 네 전략, 시간 초과, 자식의 WAIT |
| `route_unsupported_workflow_decide`, `route_later_{tasks_requeue,workflow_bulk_search,task_log}` | 새 매개변수 경로와 모양이 같은 Later·Unsupported 경로의 upstream 응답 |
| `workflow_execute*` | 동기 실행의 네 전략, 버전 0, 끝난 워크플로우의 `BLOCKING_TASK`(500), `waitUntilTaskRef`, 시간 초과의 `TARGET_WORKFLOW`·`BLOCKING_TASK`, 인라인 정의 |
| `workflow_*pause*`, `*resume*`, `*skip*`, `*callback*`, `*retry*`, `*restart*` | 생명주기 흐름과 그 뒤의 GET. skiptask는 correlationId와 우선순위 7인 워크플로우, resetcallbacks는 `callbackAfterSeconds` 3600으로 미룬 태스크 |
| `*rerun*`, `workflow_get_{parent,top,mid,child}*` | rerun의 세 경우(이 워크플로우의 태스크, 처음부터, 자기 SUB_WORKFLOW, 자식의 태스크)와 재시도된 SUB_WORKFLOW의 첫 자식 안 태스크 rerun(최상위·중간·자식). upstream에서는 중간이 다시 결정해 두 번째 시도의 `FAILED`로 실패하고 첫 자식을 종료하며, 최상위는 `RUNNING`으로 남는다 |
| `workflow_*remove*` | remove(`archiveWorkflow` 기본과 거짓), terminate-remove, 지운 뒤 GET 404 |
| `workflow_bulk_*` | 빈 목록·1001개 400, 빈 body 500, 단일 값, 섞인 결과, `terminate-remove`의 중복 성공과 `COMPLETED` |
| `metadata_delete_{workflow,taskdef}`, `metadata_get_*_deleted`, `metadata_get_workflow_after_delete` | 정의 삭제와 그 뒤 GET |

6a가 다시 캡처한 기존 127개는 `normalize/1` 기준으로 하나만 달랐다(`route_later_tasks_search`, upstream 태스크 검색의 결과
순서. 재생은 404를 기대하므로 비교하지 않는다). upstream 타이밍이 정하는 값이 둘 더 있어서, 같은 스크립트를 빈 서버에서 여러 번
돌려 기존 픽스처와 같은 값이 나온 캡처를 골랐다.

- `workflow_get_completed_fork`의 JOIN `pollCount`: upstream 시스템 태스크 작업자가 JOIN을 몇 번 돌렸는지다(관측 2, 3, 11).
  Archon은 3을 낸다.
- `task_update_v2_invalid_both`의 두 필드 오류 순서(Spring이 정하지 않는다). Archon은 `taskId`를 먼저 쓴다(5e).

새 픽스처 중 다시 캡처해 바뀌는 값은 `lastRetriedTime`(이번에 시각 키로 더했다), bulk 오류 맵의 키(워크플로우 ID, 재생은 키도
바꿔 비교한다), `workflow_execute_completed_blocking_task`의 문구에 든 JVM 람다 클래스 이름(재생은 `message`를 뺀다)이다. 두 번
캡처해 비교했다.

Phase 6 단계는 조각 6a~6g가 구현하는 동안 미구현 액션으로 가는 단계를 건너뛰었고, 6h가 그 장치를 없애 지금은 모든 단계가 돈다.
6a가 캡처하면서 찾은 Archon의 차이 하나(`workflow_get_top_failed`:
실패한 자식의 출력을 합친 SUB_WORKFLOW 태스크의 `subWorkflowId`)는 upstream `toTask`처럼 맞췄고(ADR 0024 결정 6), 재생은 그
경로도 비교한다.

아래는 Phase 7(MVP 밖 시스템 태스크 타입, [ADR 0026](../../../docs/adr/0026-phase7-system-task-types.md) 결정 8)의 첫 조각
7a가 열두 타입의 시나리오를 한 번에 캡처해 더한 것이다(160개, 모두 520개). 이름은 모두 `p7_<타입>_*`이고 정의 이름은
`archon_p7_*`, 워커 태스크는 `archon_p7_worker`다. 시나리오는 정의 등록 → 시작 → 멈춘 워크플로우 GET이고, GET은
`workflowDefinition`까지 비교한다(DYNAMIC·HTTP 매퍼의 정의 변경). 캡처에서 ADR과 다르게 확인한 upstream 응답은 ADR 0026 결정
4·8 끝에 있다.

| 접두사 | 내용 |
|---|---|
| `p7_register_taskdefs` | `archon_p7_worker`와 DYNAMIC의 시스템 타입 대상용 `NOOP` 태스크 정의 |
| `p7_terminate_*` | 세 상태, `workflowOutput`의 맵·수·없음, 진행 중 형제 `CANCELED`, 문자열이 아니거나 표현식인 `terminationStatus` 등록 400 |
| `p7_set_variable_*` | 덮어쓰기와 출력의 `${workflow.variables}`, 256 KB 초과(`FAILED_WITH_TERMINAL_ERROR`), FORK 가지 끝 |
| `p7_noop_*`, `p7_human_*` | NOOP, `POST /api/tasks`로 끝내는 HUMAN |
| `p7_exclusive_join_*` | SWITCH 뒤 case 태스크, `defaultExclusiveJoinTask`, permissive 실패(upstream NPE 500) |
| `p7_dynamic_*` | 워커 태스크, 정의 없는 이름, 이름 없음, 시스템 타입(NOOP) |
| `p7_fjd_*` | FORK_JOIN_DYNAMIC 세 입력 형태, JOIN이 뒤따르지 않는 정의, 동적 가지의 retry·가지 rerun·FORK rerun |
| `p7_inline_*`, `p7_lambda_*` | javascript, value-param, 모르는 평가기, 스크립트 오류, 문자열이 아닌 `evaluatorType`·`expression`(시작 500), LAMBDA 결과·오류·빈 식 |
| `p7_jq_*` | 여러 결과, `null` 결과, 문법 오류, `queryExpression` 없음, 문자열이 아닌 것, 등록 400 |
| `p7_start_workflow_*` | 시작한 워크플로우(GET 포함), 검증 실패, `startWorkflow` 없음 |
| `p7_http_*` | stub 대상 JSON·POST(헤더 포함)·글자·수 body, 299, 4xx 짧은·긴·빈 body, 503, 연결 거부, `uri`·`method` 없음, `asyncComplete`, 덮이는 `inputParameters.asyncComplete`, 등록 400 |

7a가 다시 캡처한 기존 360개는 `normalize/1` 기준으로 순서만 달랐다(bulk 오류 맵의 키, `workflow_correlated_paused_closed`,
`route_later_tasks_search`). `task_update_v2_invalid_both`는 두 오류 순서가 바뀌어 기존 캡처를 남겼다. Phase 7 단계는
`types:` 옵션을 달아 그 타입의 매퍼가 생길 때까지 건너뛴다(7h가 옵션을 없앤다).

Archon이 일부러 다르게 답하는 픽스처(Later 경로와 405는 404, Jackson 문구)는 재생 도우미
`test/support/archon_web/contract_case.ex`의 시나리오에 단계 옵션으로 적혀 있다.

## 가변 필드

다시 캡처하면 값이 바뀌는 필드다. 같은 시나리오를 빈 DB로 두 번 캡처해 비교해서 확인했다.

| 종류 | 필드 |
|---|---|
| 생성 ID(UUID) | `workflowId`, `workflowInstanceId`, `taskId`, 요청 `path`의 ID, `text/plain` 응답 body(시작한 workflow ID, 갱신한 task ID) |
| 시각(epoch ms) | `createTime`, `updateTime`, `startTime`, `endTime`, `scheduledTime`, `lastRetriedTime` |
| 시각에서 나온 값 | `queueWaitTime` |
| 캡처 환경 | HTTP 태스크의 `workerId`(서버 호스트 이름), stub 응답 헤더 `date` |

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
