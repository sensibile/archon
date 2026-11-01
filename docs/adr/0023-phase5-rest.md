# ADR 0023: Phase 5 REST 설계 (MVP 엔드포인트)

- 상태: 제안
- 날짜: 2026-11-01
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`
- 비고: 설계 갈림길 네 가지(웹 계층, worker 입력 신뢰와 인증, 스키마 검증, MVP 범위)는 2026-11-01 BOSS가 이 문서와
  [ADR 0024](0024-worker-input-trust-and-auth.md)의 추천안으로 정했다.
- 갱신: 2026-11-01 조각 5a가 upstream 서버에서 확인한 사실로 결정 1(HEAD), 결정 2(404 문구, 끝 슬래시), 결정 3(요청 body·쿼리 변환,
  `ArchonWeb.Request`), 결정 4(검증 오류의 `instance`, `update-v2`의 검증 실패 500, 오류 종류 두 개), 결정 6(캡처 결과와
  재생 도우미 세부), 결정 7(5a 파일 목록, 5e의 선행 조건)과 "upstream과 의도적으로 다른 점"을 보강했다.
- 갱신: 2026-11-01 조각 5c가 결정 2(`Archon.Metadata`의 세부, 목록 순서, 단건 body를 목록으로 받기), 결정 4(코덱 타입 오류,
  정의 오류 경로 접두사), 결정 5(판정 함수와 거절 지점의 순서), 결정 6(재생 옵션 `only:`, 정의 지우기)과 "upstream과 의도적으로
  다른 점"을 보강했다. 새로 확인한 사실은 upstream 서버(기준 SHA 빌드, 빈 SQLite)에서 관측했다.
- 갱신: 2026-11-01 조각 5e가 결정 4(`update-v2` 검증 실패 문구를 Spring 문구 그대로 만듦, 태스크 갱신의 404 문구 구분, 코덱 타입
  오류)와 결정 7(5e의 재생 선행 조건을 실제로 한 방식)을 upstream 서버 관측으로 보강하고, 결정 3에 코덱 오류 수 한도를 더했다.
- 갱신: 2026-11-01 조각 5d가 결정 3(`StartWorkflowRequest`·`WorkflowStatus`의 세부, 코덱 타입 오류 함수를 `ArchonWeb.Request`로
  옮김, 시작 정의 채우기의 선형화), 결정 4(워크플로우 경로의 오류 문구와 검사 순서)와 결정 7(5d 파일 목록과 재생 방식)과
  "upstream과 의도적으로 다른 점"을 upstream 서버(기준 SHA 빌드, 빈 SQLite) 관측으로 보강했다.

## 맥락

[ADR 0003](0003-porting-strategy.md)은 Phase 5를 "Phoenix REST: MVP 엔드포인트부터"로 정했다. 앞 단계가 남긴 조건은
다음과 같다.

- [ADR 0001](0001-api-contract-scope.md): MVP는 경로 19개(메서드 18개)다. Later 경로는 구현 전까지 404로 답하고 응답 형태를
  지어내지 않는다. 골든 픽스처(`test/fixtures/contract/`, JSON 36개)가 응답 형태의 기준이다.
- [ADR 0002](0002-domain-model-representation.md): 도메인 struct와 필드 표 코덱(`from_json/2`·`to_json/1`), 디코딩과 분리한
  `validate/2`(upstream 어노테이션 문구). JSON은 내장 `JSON` 모듈이다.
- [ADR 0018](0018-phase3-otp-runtime.md) 결정 7: REST 컨트롤러는 `Archon.Runtime`과 `Archon.Runtime.Tasks`의 함수만 부른다.
  결과 절은 정의 등록 REST를 열기 전에 스키마 검증을 정하라고 했다.
- [ADR 0021](0021-phase4-postgres-persistence.md) 결과 절: REST는 백엔드와 무관하게 런타임 API만 부른다. worker가 준
  `subWorkflowId`를 믿는 경로(L7·L8)는 태스크 갱신 REST가 열리기 전에 닫아야 한다. L3는 REST가 오류 코드를 맞출 때 다시 본다.

upstream REST의 구성은 다음과 같다(경로는 `rest/src/main/java/com/netflix/conductor/rest/` 아래).

| upstream | 하는 일 |
|---|---|
| `config/RequestMappingConstants.java` | `API_PREFIX = "/api/"`와 컨트롤러 경로 상수 |
| `controllers/MetadataResource.java` | 정의 등록·조회. `create`의 `overwrite`와 409, `PUT /workflow`의 `BulkResponse` |
| `controllers/WorkflowResource.java` | 시작 두 가지(`text/plain`), 조회, 상태 요약, 종료 |
| `controllers/TaskResource.java` | poll(없으면 204), batch poll, 갱신(`text/plain` taskId), `update-v2`(다음 태스크 또는 204), 조회 |
| `controllers/HealthCheckResource.java` | `/health`, `/api/health` |
| `controllers/ApplicationExceptionMapper.java` | 예외 → 상태 코드. `NotFoundException` 404, `ConflictException` 409, `IllegalArgumentException` 400, `NoResourceFoundException` 404, 그 밖 500. body는 `ErrorResponse`, `retryable`은 `TransientException`일 때만 참 |
| `controllers/ValidationExceptionMapper.java` | `ConstraintViolationException` → 400, `"Validation failed, check below errors for detail."`과 `validationErrors` |

서비스 계층은 `core/src/main/java/com/netflix/conductor/service/`의 `MetadataService(Impl)`, `WorkflowService(Impl)`,
`TaskService(Impl)`이다. 인터페이스의 제약 어노테이션(`@NotNull`, `@Size`, `@Valid` 등)이 Spring 메서드 검증으로
`ConstraintViolationException`을 만든다. 응답 모델은 `common/.../common/validation/ErrorResponse.java`,
`common/.../common/model/BulkResponse.java`, `common/.../org/conductoross/conductor/model/WorkflowStatus.java`,
`common/.../common/metadata/workflow/StartWorkflowRequest.java`다.

## 결정

### 1. 웹 계층은 Phoenix(API 전용)와 Bandit이다

- 의존성은 `phoenix`와 `bandit`이다. HTML, LiveView, 에셋, `phoenix_ecto`, 생성기 골격은 들이지 않는다.
- 모듈은 `ArchonWeb.Endpoint`, `ArchonWeb.Router`, 컨트롤러 `ArchonWeb.{Health,Metadata,Workflow,Task}Controller`,
  오류 변환 `ArchonWeb.Errors`다. 디렉터리는 `lib/archon_web/`다.
- JSON은 내장 `JSON`이다(`config :phoenix, :json_library, JSON`). Jason은 들이지 않는다. 요청 body는 `Plug.Parsers`의
  JSON 파서로 맵을 만들지 않고, 컨트롤러가 원문을 읽어 디코딩하고(`ArchonWeb.Request`, OTP `:json`. Jackson과 맞추는 세부는
  결정 3) 도메인 코덱 `from_json/2`로 바꾼다. 누락 키와
  `null`을 구분하는 코덱 규칙(ADR 0002)을 지키고, 배열 body(`POST /api/metadata/taskdefs`)를 `_json` 같은 감싼 키 없이 받기
  위해서다.
- Endpoint에는 `Plug.Head`를 둔다. Spring은 GET 매핑마다 HEAD를 body 없이 같은 응답으로 준다(upstream `curl -I /health`는 200).
  OPTIONS는 따르지 않는다(upstream은 `Allow` 헤더로 200, Archon은 결정 2의 404).
- `Archon.Application`은 런타임 다음에 `ArchonWeb.Endpoint`를 띄운다. 기본 주소는 `127.0.0.1:8080`(upstream 기본 포트)이고,
  다른 주소는 설정으로만 연다(ADR 0024 결정 4). 시험 설정은 `server: false`이고 `Phoenix.ConnTest`로 부른다.
- 대안은 아래 "대안" 절.

### 2. 라우팅과 MVP 경로

| 경로 | 컨트롤러 액션 | 런타임·서비스 호출 | 성공 응답 |
|---|---|---|---|
| `GET /health`, `GET /api/health` | `Health.check` | 없음 | 200 JSON(모양은 픽스처로 고정, 결정 6) |
| `POST /api/metadata/workflow` | `Metadata.create_workflow` | `Archon.Metadata` 등록(`overwrite` 쿼리) | 200, body·`Content-Type` 없음. 이미 있으면 409 |
| `PUT /api/metadata/workflow` | `Metadata.update_workflows` | 정의마다 갱신 | 200 `BulkResponse` |
| `GET /api/metadata/workflow/{name}` | `Metadata.get_workflow` | `version` 쿼리, 없으면 최신 | 200 `WorkflowDef` |
| `POST /api/metadata/taskdefs` | `Metadata.create_task_defs` | 배열 등록 | 200, body 없음 |
| `PUT /api/metadata/taskdefs` | `Metadata.update_task_def` | 단건 갱신, 없으면 404 | 200, body 없음 |
| `GET /api/metadata/taskdefs` | `Metadata.list_task_defs` | 전체 목록 | 200 `[TaskDef]` |
| `GET /api/metadata/taskdefs/{tasktype}` | `Metadata.get_task_def` | | 200 `TaskDef` |
| `POST /api/workflow` | `Workflow.start` | `StartWorkflowRequest` → `Runtime.start_workflow/1` | 200 `text/plain;charset=UTF-8` workflowId |
| `POST /api/workflow/{name}` | `Workflow.start_by_name` | `version`·`correlationId`·`priority` 쿼리, body는 입력 맵 | 같음 |
| `GET /api/workflow/{workflowId}` | `Workflow.get` | `Runtime.get_workflow/2`(`includeTasks`, 기본 true) | 200 `Workflow` |
| `GET /api/workflow/{workflowId}/status` | `Workflow.status` | 같은 조회로 `WorkflowStatus` 요약(`includeOutput`·`includeVariables`) | 200 JSON |
| `DELETE /api/workflow/{workflowId}` | `Workflow.terminate` | `Runtime.terminate_workflow/2`(`reason` 쿼리) | 200, body 없음 |
| `GET /api/tasks/poll/{tasktype}` | `Task.poll` | `Tasks.poll/3`(`workerid`, `domain`) | 200 `Task`, 없으면 204 |
| `GET /api/tasks/poll/batch/{tasktype}` | `Task.batch_poll` | `Tasks.batch_poll/5`(`count` 기본 1, `timeout` 기본 100) | 200 `[Task]`(없으면 `[]`) |
| `POST /api/tasks` | `Task.update` | `Tasks.update/1` | 200 `text/plain` taskId |
| `POST /api/tasks/update-v2` | `Task.update_v2` | `Tasks.update_v2/1` | 200 `Task`, 없으면 204 |
| `GET /api/tasks/{taskId}` | `Task.get` | `Tasks.get/1` | 200 `Task` |

- 경로·쿼리 이름·기본값은 위 upstream 컨트롤러에서 그대로 옮긴다. `/api/tasks/poll/batch/{tasktype}`는 `/api/tasks/{taskId}`보다
  먼저 둔다(같은 접두사).
- **MVP가 아닌 요청은 모두 404다.** 라우터에 없는 경로, MVP 경로에 없는 메서드(Later인 `GET /api/metadata/workflow`,
  `DELETE /api/metadata/taskdefs/{tasktype}` 포함), Unsupported 경로는 upstream이 없는 경로에 주는 응답(`NoResourceFoundException`
  → 404 `ErrorResponse`)과 같은 모양으로 답한다. 모양은 픽스처로 캡처해 고정한다. ADR 0001의 "Later는 404"가 이 응답이다.
  upstream은 경로가 있고 메서드만 다르면 405(`HttpRequestMethodNotSupportedException`)를 주지만, Archon은 405를 따로 만들지
  않는다(아래 "upstream과 의도적으로 다른 점").
  404 문구는 `"No static resource <경로>."`이고 경로는 percent 인코딩을 그대로 두고 앞 `/`와 빈 세그먼트를 뺀다(`/api//x/`는
  `api/x`). 끝에 `/`가 붙은 경로는 MVP 경로라도 404다(Spring 6는 끝 슬래시를 매칭하지 않는다, upstream `POST /api/workflow/`는 404).
  Phoenix 라우터는 끝 슬래시를 매칭하므로 Endpoint가 라우터 앞에서 막는다(조각 5a에서 upstream으로 확인).
- **매개변수 경로가 Later 경로를 삼키지 않게 한다.** 다음 Later 경로는 MVP의 `{name}`·`{workflowId}`·`{taskId}` 경로와 모양이
  같아서 그대로 두면 MVP 액션으로 들어간다(예: `POST /api/workflow/test`가 "test"라는 워크플로우를 시작). 라우터는 이 리터럴
  경로를 매개변수 경로보다 먼저 두고 404로 보낸다. 목록은 upstream 컨트롤러에서 옮긴다.
  - `WorkflowResource`: `GET /api/workflow/{search,search-v2,search-by-tasks,search-by-tasks-v2,externalstoragelocation,
    external-storage-location}`, `GET /api/workflow/running/{name}`(이름이 `status`면 `/{workflowId}/status`와 겹친다),
    `POST /api/workflow/test`
  - `MetadataResource`: `GET /api/metadata/workflow/{names-and-versions,names,latest-versions}`
  - `TaskResource`: `GET /api/tasks/{search,search-v2,externalstoragelocation,external-storage-location}`
  
  Later 경로를 여는 조각은 그 경로를 이 목록에서 빼고 액션으로 보낸다.
- 정의 서비스. 런타임에는 정의 등록 API가 없다(ADR 0018 결정 7의 표는 워크플로우·태스크뿐). `Archon.Metadata`가 upstream
  `MetadataService` 인터페이스의 검증(`validate/2`, 일괄 갱신은 목록 원소마다 `@Valid`라 한 원소라도 실패하면 요청 전체가
  400)과 `MetadataServiceImpl`의 의미(생성·갱신 시각 `createTime`·`updateTime`, TaskDef 갱신만 기존 `createTime`·`createdBy` 보존,
  없는 TaskDef 갱신의 404, 일괄 갱신에서 서비스 단계 예외의 정의별 실패 `BulkResponse`)를 맡고, 결정 5의 스키마 거절을 더한다.
  `POST /api/metadata/workflow`의 이름 없는 정의 처리와 `overwrite`·409는 upstream에서 `MetadataResource.create`에 있으므로
  컨트롤러가 같은 순서로 한다.
  저장은 `Archon.Runtime.Metadata` behaviour를 그대로 쓰고, 목록 조회를 위해 콜백 `get_all_task_defs/0`을 더한다(메모리·Postgres
  구현과 계약 시험).
- **`Archon.Metadata`의 세부(조각 5c).**
  - 함수: `register_task_defs/1`, `update_task_def/1`, `get_task_def/1`, `get_task_defs/0`, `register_workflow_def/1`,
    `update_workflow_def/1`, `update_workflow_defs/1`(`{:ok, BulkResponse}`), `get_workflow_def/2`(문구 있는 404),
    `find_workflow_def/2`(문구 없는 `:not_found`, `version`이 `nil`이면 최신). 메서드 검증 실패는 인자 기준 경로의
    `{:invalid, [{경로, 문구}]}`이고 접두사는 컨트롤러가 붙인다.
  - 감사 필드: 등록한 TaskDef는 `createdBy`가 client app(인증이 없으므로 `""`, upstream 픽스처와 같음), `createTime`이 지금,
    `updatedBy`는 없음, `updateTime`은 0이다(upstream은 `null`을 넣고 getter가 0을 쓴다). WorkflowDef 등록은 `createTime`만,
    갱신은 `updateTime`만 바꾸고 나머지 감사 필드는 받은 그대로다(`overwrite`·일괄 갱신 뒤 `createTime`이 0인 픽스처).
  - `GET /api/metadata/taskdefs`의 순서는 이름의 바이트 순이다. upstream DAO는 `ORDER BY` 없이 읽어 순서가 정해져 있지 않다
    (SQLite는 삽입 순). Postgres 구현은 `ORDER BY name COLLATE "C"`다.
  - 목록 body(`POST /api/metadata/taskdefs`, `PUT /api/metadata/workflow`)는 배열이 아닌 값을 원소 하나의 목록으로 받는다.
    upstream 설정 `spring.jackson.deserialization.accept-single-value-as-array=true` 때문이다(5a 픽스처
    `metadata_register_taskdefs_single`, `PUT /api/metadata/workflow`의 단건은 서버에서 확인).
  - 목록의 `null` 원소: `PUT /api/metadata/workflow`는 원소 제약 `@NotNull`로 요청 전체가 400(경로
    `updateWorkflowDef.arg0[i].<list element>`, 문구 `WorkflowDef cannot be null`)이다. `POST /api/metadata/taskdefs`는 `@Valid`가
    `null`을 건너뛰어 검증을 통과하고, 앞 원소를 저장한 뒤 그 원소에서 upstream의 `NullPointerException` 문구로 500이다
    (`Cannot invoke "...TaskDef.setCreatedBy(String)" because "taskDefinition" is null`). 둘 다 upstream 관측 그대로다.
  - 일괄 갱신에서 정의 하나의 저장이 예외(Postgres의 NUL 이름, 펜스)나 exit(호출 timeout, 멈춘 저장소 서버)를 내면 upstream처럼 그 정의만 실패로 넣고 나머지를
    저장한다. 문구는 Elixir 용어를 내보내지 않도록 고정 문구 `"Internal server error"`이고 자세한 내용은 로그에 남긴다.
- 컨트롤러는 런타임 API와 `Archon.Metadata`만 부른다. 저장소·큐·`WorkflowServer`를 직접 부르지 않는다. ADR 0018 결정 7은
  REST가 부를 API를 `Archon.Runtime`·`Archon.Runtime.Tasks`로 정했으나 정의 등록 API가 없었으므로, 이 결정이 그 경계에
  `Archon.Metadata`를 더한다(아래 결과 절의 "일부 0023이 대체"). 백엔드는 런타임
  설정이 정하고 REST는 모른다(ADR 0021 결과 절).
- MVP 범위는 ADR 0001의 19개 그대로다. 생명주기 REST(pause, resume, retry, restart)는 런타임 API(`Archon.Runtime.Lifecycle`)가
  있지만 Later로 두고 Phase 5 뒤에 픽스처를 캡처해 연다(BOSS 결정).

### 3. JSON 인코딩과 필드 계약

- 응답 body는 도메인 struct의 `to_json/1` 결과를 `JSON.encode!/1`로 쓴다. 필드 이름, 생략 규칙(`NON_NULL`), 파생 키는 ADR 0002의
  코덱이 이미 `priv/contract/*.json` 스키마와 골든 픽스처에 맞춰 두었다. 컨트롤러는 키를 더하거나 빼지 않는다.
- REST에만 나오는 모델은 같은 필드 표 코덱으로 `Archon.Domain`에 더한다: `StartWorkflowRequest`(요청), `BulkResponse`,
  `WorkflowStatus`, `ErrorResponse`(`validationErrors`의 `ValidationError` 포함). 필드 이름과 기본값은 위 upstream 파일에서 옮긴다.
  `StartWorkflowRequest`의 `idempotencyKey`·`idempotencyStrategy`는 받되 upstream처럼 시작에 쓰지 않는다.
- `Content-Type`은 픽스처 그대로다: JSON 응답은 `application/json`, 문자열 응답은 `text/plain;charset=UTF-8`, body 없는 200·204는
  헤더 없음.
- 요청 body 디코딩 오류(JSON이 아님, 타입이 맞지 않음)의 상태 코드와 문구는 upstream 응답을 캡처해 정한다. upstream은
  Jackson 예외를 `ApplicationExceptionMapper`가 받으므로 대개 500이다. 짐작해 400으로 바꾸지 않는다.
- **요청 읽기(조각 5a, `ArchonWeb.Request`).** upstream 서버(기준 SHA 빌드, 빈 SQLite)에 직접 보내 확인한 규칙이다.
  - body: Jackson처럼 첫 JSON 값만 읽고 뒤는 무시한다(`{} x`는 `{}`). 객체의 같은 키는 마지막 값이다(내장 `JSON.decode/1`은 첫
    값이라 `:json.decode/3`에 디코더를 준다). 빈 body와 `null`은 `"Required request body is missing: <handler 시그니처>"`(500),
    공백뿐인 body는 `"JSON parse error: No content to map due to end-of-input"`(500)이다. JSON이 아닌 body는 500이고 문구는
    `"JSON parse error: "`로 시작하지만 그 뒤의 Jackson 문구는 옮기지 않는다(재생에서 `message`를 뺀다).
    body는 8 MB(`Plug.Parsers` 기본값)까지 읽고 넘으면 413이다.
  - 쿼리: Spring `@RequestParam` 변환(`CustomNumberEditor`, `CustomBooleanEditor`)을 따른다. 값이 없거나 정확히 `""`이면 기본값이다.
    숫자는 공백을 모두 지우고 `0x`·`#` 16진수를 받는다. primitive `int`는 공백뿐인 값이 `For input string: ""` 실패이고, boxed
    `Integer`(`version`)는 `null`이다. 불리언은 `true/on/yes/1`, `false/off/no/0`(대소문자, 앞뒤 공백 무시)이고 공백뿐인 값은 실패다.
    실패는 500 `"Method parameter '<이름>': Failed to convert value of type 'java.lang.String' to required type '<타입>'; <원인>"`이다
    (`MethodArgumentTypeMismatchException`은 매퍼에 없다). 같은 이름이 반복되면 숫자·불리언은 첫 값, 문자열은 `,`로 합친다. `%`
    escape가 깨진 쌍은 Tomcat처럼 버린다(`Plug.Conn.fetch_query_params/1`은 요청 전체를 400으로 만든다).
  - body 한도: 첫 JSON 값에서 배열·객체가 1000단을 넘거나 숫자가 1000자리(정수부·소수부·지수부 자릿수, 부호 제외)를 넘으면
    디코딩 전에 거절한다. upstream Jackson의 `StreamReadConstraints`(`getMaxNestingDepth`, `getMaxNumberLength`)와 같은 한도와
    문구(`"JSON parse error: Document nesting depth (1001) exceeds ..."`, `"JSON parse error: Number value length (<n>) exceeds ..."`)다.
    거대한 중첩·숫자를 만드는 데 드는 메모리·CPU를 막는다.
  - 코덱 오류 수 한도(조각 5e): 도메인 코덱의 목록·맵 디코딩(`Archon.Domain.Codec.collect/2`)은 오류가 100개에 이르면 나머지
    원소를 보지 않고, 오류 목록은 한 번에 잇는다. 원소마다 전체 목록에 덧붙이던 방식은 실패 원소 수의 제곱이라, 8 MB 안의
    `{"logs":[1,1,...]}` 같은 작은 body로 갱신 경로에서 CPU를 오래 잡을 수 있었다(Codex 보안 리뷰, 8만 원소 42초). 코덱 오류는 REST에서
    첫 오류만 500 문구에 쓰이고(결정 4), upstream Jackson도 첫 오류에서 멈추므로 응답은 바뀌지 않는다. REST 밖에서 오류 목록 전체가 보이는 곳은 인라인
    `subWorkflowDefinition`의 디코딩 실패 사유(`Archon.Runtime.Step.SubWorkflow`, `inspect` 문자열)뿐이고, 원소 100개 넘게 실패하면 그 문자열이 짧아진다.
    upstream은 이때도 첫 오류만 쓰므로 원래 다른 문자열이었다.
  - 코덱 타입 오류의 오류 변환(결정 4)은 세 컨트롤러가 같은 모양이라 조각 5d에서 `ArchonWeb.Request.codec_error/1`로 옮겼다
    (Metadata·Task 컨트롤러의 private 함수를 대신한다).
  - 시작 정의 채우기의 선형화(조각 5d): `POST /api/workflow`의 인라인 `workflowDef`는 클라이언트가 크기를 정하므로,
    `Archon.Runtime.populate/1`이 목록(`defaultCase`, `loopOver`, `forkTasks`의 가지와 그 안)을 `acc ++ [x]`로 잇던 것(목록 길이의
    제곱)을 앞에 붙이고 뒤집는 방식으로 바꿨다. 결과는 같다.
- **`StartWorkflowRequest`와 `WorkflowStatus`(조각 5d).** `Archon.Domain.StartWorkflowRequest`의 필드와 기본값은 upstream
  그대로다(`input`·`taskToDomain`은 키가 없으면 빈 맵, `null`이면 `null`, `priority`는 없으면 0, `null`이면 `null`).
  검증(`validate/2`)은 `name` `@NotNull`(빈 문자열은 통과), `priority` `@Min(0) @Max(99)`(`null`은 통과), `workflowDef`
  `@Valid`(`WorkflowDef.validate/2`를 `workflowDef` 아래에)다. `createdBy`·`idempotencyKey`·`idempotencyStrategy`는 받되
  시작에 쓰지 않는다(upstream `StartWorkflowInput`과 같다). 런타임의 시작 맵은 `to_start_input/1`이 요청 필드(`name`,
  `version`, 인라인 정의, `input`, `correlationId`, `priority`, `taskToDomain`)로만 만든다. 워크플로우 ID와 부모 필드
  (`parentWorkflowId`, `parentWorkflowTaskId` 등)는 body에 있어도 넣지 않는다(ADR 0024 결정 4). 인라인 정의가 있으면 이름과
  버전으로 찾지 않는다(upstream `resolveWorkflowDefinition`, 이름이 빈 문자열이거나 없는 정의여도 시작한다).
  `Archon.Domain.WorkflowStatus.new/3`은 upstream 생성자대로 빈 `correlationId`를 빼고 `output`·`variables`는 요청할 때만 넣는다.
  - `Content-Type`: 비어 있지 않은 body는 Spring의 JSON 변환기처럼 `application/json`이나 `application/*+json`(대소문자·매개변수
    무관)이어야 한다. 그 밖의 타입은 500 `"Content-Type '<타입>;<매개변수>' is not supported"`(charset이 없으면 `charset=UTF-8`을
    붙임), 헤더가 없으면 `application/octet-stream`으로 본 같은 500, `/`가 없으면 500 `Invalid mime type`, 와일드카드는 400이다(모두
    upstream 관측). 인증이 없는 MVP(ADR 0024 결정 4)에서 이 검사는 브라우저가 CORS preflight 없이 보내는 교차 출처 "단순 요청"
    (`text/plain`, 폼)이 액션에 닿지 않게 한다. `application/json` 교차 출처 요청은 preflight가 필요한데 Archon은 OPTIONS에 CORS
    헤더 없이 404로 답하므로 브라우저가 보내지 않는다. 부작용이 있는 GET(poll, batch poll은 태스크를 꺼내 `IN_PROGRESS`로 만든다)에
    대한 교차 출처 단순 요청(`<img src>` 등)과 DNS rebinding처럼 같은 출처로 위장하는 경로는 upstream과 같이 남고, 인증 ADR(Later)이
    다룬다. body 앞의 UTF-8 BOM은 Jackson처럼 건너뛴다. upstream은 `1e<999자리>`
    같은 큰 지수를 받지만 Archon은 실수로 만들 수 없어 500 parse error다. 루트가 스칼라면 뒤에 공백이나
    끝이 와야 한다(upstream은 `"123abc"`, `"01"`을 거절).

### 4. 오류 코드와 body

- 오류 body는 upstream `ErrorResponse`다: `status`, `message`, `instance`, `retryable`. 검증 실패는 `validationErrors`가 붙는다.
  `instance`는 서버 호스트 이름이다(`:inet.gethostname/0`, upstream `Utils.getServerId()`). 픽스처는 이 값을 가리므로 시험은 키만
  본다. 검증 실패(`ValidationExceptionMapper`)에는 `instance`가 없다(5a 픽스처).
- 런타임 오류 → 상태 코드는 `ArchonWeb.Errors` 한 곳에서 바꾼다.

  | 런타임 결과 | upstream 예외 | 상태 | `retryable` |
  |---|---|---|---|
  | `{:error, :not_found}`, `{:error, {:not_found, 문구}}` | `NotFoundException` | 404 | false |
  | `{:error, :conflict}`, `{:error, {:conflict, 문구}}` | `ConflictException` | 409 | false |
  | `{:error, {:invalid, 문구}}` | `IllegalArgumentException` | 400 | false |
  | `{:error, {:invalid, [{경로, 문구} ...]}}`, `validate/2`의 오류 목록 | `ConstraintViolationException` | 400, `validationErrors` | false(설정하지 않은 primitive 기본값) |
  | `{:error, {:invalid_state, 문구}}` | `IllegalStateException`(매핑 없음) | 500 | false |
  | `{:error, {:terminate, 문구}}`(시작 때 정의 없는 SUB_WORKFLOW) | `TerminateWorkflowException`(매핑 없음) | 500 | false |
  | `{:error, {:server_error, 문구}}`(요청 변환 실패, 결정 3) | Spring 예외(매핑 없음) | 500 | false |
  | `{:error, {:payload_too_large, 문구}}`(8 MB 넘는 body, 결정 3) | 없음(Archon만) | 413 | false |
  | 예외 격리(`{:commit \| :pre_effect \| :post_effect \| :env, _}`), 호출 timeout·exit, 저장소 오류 | `TransientException` | 500 | true |
  | 그 밖 | `Throwable` | 500 | false |

- **`validationErrors`의 원소**는 upstream `ValidationError`(`path`, `message`, `invalidValue`)다. `validate/2`의 오류 목록은
  `{경로, 문구}`뿐이므로, `ArchonWeb.Errors`는 오류 목록과 함께 `validate/2`가 검사한 디코딩된 struct를 받아 경로로 값을 찾는다.
  JSON 원문이 아니라 struct에서 찾는 것은 upstream이 Jackson 변환 뒤의 Java 필드 값을 쓰기 때문이다(예: `int` 필드의 JSON `null`은
  0, 정수 필드의 `1.5`는 1). 표기는 upstream `ValidationExceptionMapper.getViolationInvalidValue`를 따른다: `java.lang` 값(문자열, 정수,
  실수, 불리언)은 Java `toString` 표기의 문자열(`""`도 그대로, 정수 필드는 정수로), enum·struct·리스트·맵·`nil`은 `null`. 예:
  `POST /api/tasks`에 `taskId: ""`면 `invalidValue: ""`(`task_update_invalid`). upstream `path`의 메서드·인자 접두사는 픽스처로
  확인했다: `registerTaskDef.arg0`(배열이면 `[i]`가 붙음), `registerWorkflowDef.arg0`, `updateWorkflowDef.arg0`, `updateTask.arg0`.
  5c가 upstream 서버에서 더 확인했다: `PUT /api/metadata/taskdefs`는 `updateTaskDef.arg0`, `POST /api/metadata/workflow?overwrite=true`로
  있는 정의를 바꿀 때는 `updateWorkflowDef.arg0`(단건이라 `[i]` 없음), 이름 없는 정의는 `registerWorkflowDef.arg0.name`이다.
  값은 접두사 전의 경로로 찾는다. 경계 사례는 5a 픽스처 `metadata_register_taskdefs_coerced`(primitive 필드의 `null`은 `"0"`, 정수
  필드의 `-1.7`은 `"-1"`)와 `metadata_register_taskdefs_blank_name`(`""`)이다. 도메인 코덱에는 실수 필드가 없으므로 실수 표기는
  생기지 않는다.
- **`update-v2`의 검증 실패는 400이 아니라 500이다(5a 픽스처 `task_update_v2_invalid`).** `TaskResource.updateTaskV2`는
  컨트롤러 인자에 `@Valid`가 붙어 있어 서비스 메서드 검증보다 먼저 Spring `MethodArgumentNotValidException`이 나고, 매퍼에 없는
  클래스라 500이다. 문구는 Spring이 쓰는 긴 문자열(`"Validation failed for argument [0] in public ... updateTaskV2(...): [Field error
  ...]] "`)이다. `POST /api/tasks`의 같은 실패는 서비스 검증이라 400 `validationErrors`다.
  **조각 5e는 이 문구를 그대로 만든다**(재생에서 `ignore`하지 않는다). `TaskResult`의 제약은 `String` 필드 두 개의 `@NotEmpty`뿐이라
  문구가 오류 목록과 거부 값만으로 정해지기 때문이다. 모양은 Spring 6 `MethodArgumentNotValidException#getMessage`와
  `FieldError#toString`이다: `"Validation failed for argument [0] in <handler 시그니처>"`, 오류가 둘 이상이면 `" with <n> errors"`,
  `": "`, 오류마다 `"[Field error in object 'taskResult' on field '<필드>': rejected value [<값 또는 null>]; codes [...]; arguments
  [...]; default message [<문구>]] "`. 둘 다 실패하면 upstream 서버는 `taskId`를 먼저 썼다(`{}`, `""` body로 여러 번 관측).
  Hibernate가 정하지 않는 순서이므로 관측한 순서로 고정한다. `ArchonWeb.TaskController.spring_validation_message/2`가 만들고,
  두 오류 문구는 upstream 응답을 그대로 시험에 둔다.
- **태스크 갱신의 404 문구(조각 5e).** `Archon.Runtime.Tasks.update/1`은 없는 워크플로우와 없는 태스크를 모두 `:not_found`로
  돌려준다. upstream `WorkflowExecutorOps.updateTask`는 워크플로우를 먼저 읽고(`"No such workflow found by id: <id>"`) 그다음 태스크를
  읽는다(`"No such task found by id: <id>"`). `extendLease`는 태스크만 읽는다(`extendLease`). 그래서 컨트롤러는 `:not_found`를 받으면
  `extendLease`가 아니고 `Runtime.get_workflow/2`가 `:not_found`일 때만 워크플로우 문구를, 나머지는 태스크 문구를 쓴다. 런타임 API는
  바꾸지 않는다. 같은 태스크 ID가 다른 워크플로우에 있으면 upstream은 그 태스크를 찾지만 Archon은 워크플로우 프로세스 안에서만 찾으므로
  태스크 문구 404다(ADR 0024의 신뢰 모델과 무관한 기존 차이). `extendLease`도 같은 이유로 `workflowInstanceId`가 틀리거나 없으면 태스크 문구 404다(upstream은 `taskId`만으로
  리스를 늘린다). 워크플로우를 다시 읽다 저장소 오류가 나면 예외가 올라가 500(`retryable` 참)이다.
- **코덱 타입 오류(조각 5c).** body가 JSON이지만 도메인 코덱이 바꾸지 못하는 값(`"retryCount": "abc"`, 객체 자리의 배열)은
  upstream처럼 500이고 문구는 `"JSON parse error: "`로 시작한다. 그 뒤는 Jackson 문구(``Cannot deserialize value of type `int`
  from String "abc": not a valid `int` value``, Java 타입 이름과 원래 값) 대신 코덱의 첫 오류로 쓴다:
  `"JSON parse error: <경로> <이유>"`(경로가 비면 이유만, 예 `JSON parse error: [0].retryCount must be integer`). 아래 5e의
  `TaskResult` 규칙과 같은 모양이고 5d도 따른다. Jackson 문구를 옮기려면 필드마다 Java 타입과 Jackson의 값 표기를 다시 만들어야 해서
  맞추지 않는다. 지금 이 경우의 픽스처는 없고(5a가 관측만 함), 5f가 캡처하면 재생에서 `ignore: [["message"]]`로 둔다.
  숫자 문자열은 Jackson처럼 숫자 필드로 받는다(`"retryCount": "7"`은 7, upstream 관측, 코덱의 스칼라 강제 변환은 ADR 0002).
- **`TaskResult` 코덱 타입 오류(조각 5e).** 필드 타입이 맞지 않는 body(`status: "BAD"`, 배열 body)는 upstream처럼 500이고 문구는
  `"JSON parse error: "`로 시작하지만 그 뒤는 Jackson 문구가 아니라 코덱 오류의 경로와 이유다(결정 3의 JSON이 아닌 body와 같은 방식).
  관측한 upstream 문구 예: `"JSON parse error: Cannot deserialize value of type `com.netflix.conductor.common.metadata.tasks.TaskResult$Status`
  from String \"BAD\": ..."`.
- **워크플로우 경로의 오류(조각 5d).** 모두 upstream 서버에서 확인했다.
  - `POST /api/workflow`: 검증 실패는 400 `validationErrors`, 접두사 `startWorkflow.arg0`(예: `startWorkflow.arg0.name`,
    `startWorkflow.arg0.priority`의 `"priority: 100 should be maximum 99"`·`"priority: -1 should be minimum 0"`,
    `startWorkflow.arg0.workflowDef.tasks[0].taskReferenceName`, 클래스 단위 제약은 `startWorkflow.arg0.workflowDef`). 인라인 정의
    없이 이름이 빈 문자열이거나 공백뿐이면 400 `"Workflow name must be specified when searching for a definition"`
    (`MetadataMapperService.lookupWorkflowDefinition`의 `IllegalArgumentException`, Java `isBlank`)이다. 런타임은 이 경우를
    문구 없는 `:not_found`로 다루므로 컨트롤러가 런타임을 부르기 전에 본다. `input`이 `null`이면 400
    `"NULL input passed when starting workflow"`(런타임), 없는 정의는 404 `"No such workflow defined. name=<n>, version=<v>"`(런타임).
    `externalInputPayloadStoragePath`가 공백이 아니고 `input`이 없거나 비면 upstream은 외부 저장소에서 입력을 내려받으려다
    실패한다(외부 저장소가 없는 기본 서버, 500 `"Unable to download payload from external storage path: <p>"`). Archon은 외부
    저장소가 없으므로 같은 500으로 거절한다. `input`이 있으면 upstream처럼 경로를 쓰지 않는다.
  - `POST /api/workflow/{name}`: Spring은 인자를 선언 순서로 바꾸므로 쿼리(`version`, `priority`)가 body보다 먼저다(`priority=abc`와
    배열 body면 `priority` 변환 오류). 그다음 `priority` 검증(400, 경로 `startWorkflow.arg3`, `"0 is the minimum priority value"`·
    `"99 is the maximum priority value"`, 정의 확인보다 먼저), 그다음 `WorkflowServiceImpl`의 정의 확인이다. 없는 정의는 404
    `"No such workflow found by name: <n>, version: <v|null>"`(`Archon.Metadata.get_workflow_def/2`, 런타임의 문구와 다르다). body가
    객체가 아니면 코덱 타입 오류(`"JSON parse error: must be object"`).
  - 빈 body·`null`의 handler 시그니처: `public java.lang.String ...WorkflowResource.startWorkflow(...StartWorkflowRequest)`와
    `startWorkflow(java.lang.String,java.lang.Integer,java.lang.String,int,java.util.Map<java.lang.String, java.lang.Object>)`.
  - 조회·상태·종료의 없는 워크플로우는 404 `"No such workflow found by id: <id>"`(`ExecutionDAOFacade`가 서비스의
    `"Workflow with id: %s not found."`보다 먼저 던진다). `COMPLETED` 워크플로우 종료는 409 `"Cannot terminate a COMPLETED workflow."`,
    이미 `TERMINATED`면 200이다. 불리언 쿼리(`includeTasks`, `includeOutput`, `includeVariables`) 변환 실패는 결정 3의 500이다.
- 문구가 없는 오류(`:not_found`, `:conflict`)는 컨트롤러가 upstream 서비스·실행기의 문구를 붙인다. 예: 조회
  `"No such workflow found by id: <id>"`(픽스처), 정의 `"No such workflow found by name: %s, version: %d"`, 태스크 정의
  `"No such taskType found by name: %s"`, 등록 충돌 `"Workflow with %s already exists!"`(`key()`는 `name.version`). 문구는
  upstream 소스에서 옮기고 출처 줄을 시험 주석에 적는다. upstream의 `%d`에 `null`이 들어가는 경우(`version` 없음)도 Java
  `String.format`이 쓰는 그대로(`null`) 옮긴다.
- upstream 매퍼는 예외의 정확한 클래스로 찾는다(`getOrDefault(th.getClass())`). 그래서 `IllegalArgumentException`의 하위
  클래스(예: 쿼리 값의 숫자 변환 실패 `NumberFormatException`, 잘못된 enum 값)는 500이다. Archon도 같은 입력에 같은 코드를 내도록
  쿼리 변환 실패는 픽스처로 확인해 맞춘다. `SchemaValidationException` → 400 매핑은 결정 5로 Archon에 생기지 않는다.
- `ErrorResponse`에는 `code`·`metadata` 필드도 있다. upstream 매퍼가 채우지 않으므로 Archon도 내보내지 않는다(픽스처에 없음).
- 검사 순서도 upstream을 따른다. 서비스 인터페이스의 메서드 검증(예: `TaskService.updateTask`의 `@Valid TaskResult`,
  `MetadataService.registerTaskDef`의 `@Size(min = 1)`)이 먼저이고, 그다음 서비스·실행기의 검사다.
- 내부 오류 문구에 Elixir 용어(`inspect/1` 결과, 모듈 이름)를 그대로 내보내지 않는다. 500의 `message`는 upstream 쪽이 쓰는
  문구가 있으면 그것을, 없으면 짧은 고정 문구를 쓰고 자세한 내용은 로그에 남긴다.
- **L3 재검토.** L3(`resumeSubworkflowTasks`의 "still running" 오류)는 `POST /api/workflow/{id}/retry`에서만 드러나고, 그 경로는
  Later다. MVP는 L3에 닿지 않으므로 수용을 유지한다. retry REST를 여는 조각이 이 경우의 upstream 응답을 캡처하고 그때 오류
  종류(지금은 `:not_found`)를 맞춘다. 같은 조각이 생명주기 오류의 `:invalid_state`가 500인지 픽스처로 확인한다.

### 5. 스키마 검증: 검사할 수 없는 스키마를 강제하는 정의는 거절한다

ADR 0018 결과 절이 정의 등록 REST 전에 정하라고 한 스키마 검증을 이 결정으로 정한다(BOSS 결정).

- upstream은 정의의 `enforceSchema`가 참이고 `inputSchema`·`outputSchema`가 있으면 시작·태스크 갱신에서 검증한다
  (`WorkflowExecutorOps`, `org/conductoross/conductor/service/SchemaService.java`, networknt). 기본값은 `WorkflowDef`가 true,
  `TaskDef`가 false(primitive)다. `SchemaService.resolve`는 `data`가 있으면 인라인 스키마로 쓰고, `externalRef`가 있으면
  `SchemaValidationException`(400)을 던지며, 나머지는 이름으로 `/api/schema`(Later) 등록본을 찾는다. 못 찾으면 upstream도 검사하지
  않고 넘어간다("unresolvable reference leaves the payload unchecked"). 이름도 없으면 `SchemaValidationException`(400)이다. 그래서 Archon과
  upstream이 갈리는 것은 이름 참조가 아닌 스키마 전부다.
- 거절 대상은 `enforceSchema`가 참이고 `inputSchema` 또는 `outputSchema`가 이름 참조가 아닌 정의다. 이름 참조는 `data`와
  `externalRef`가 없고(JSON에 키가 없거나 `null`. 빈 객체 `{}`나 빈 문자열은 있는 것으로 본다, upstream의 `null` 검사) `name`이
  공백만으로 된 문자열도 아닌(upstream `StringUtils.isBlank`) 스키마다. 그래서 `data`가 있는 인라인 스키마, `externalRef`가 있는 스키마, 셋 다
  없는 스키마(upstream은 "neither an inline document nor a name"으로 400)를 거절한다. 문구는
  `"Schema validation is not supported yet: <정의 이름> <inputSchema|outputSchema>"`이고 400(`IllegalArgumentException` 모양,
  `retryable` false)이다. 이 판정은 도메인의 순수 함수(`WorkflowDef`·`TaskDef`)로 두고 다음 두 곳이 부른다.
  - `Archon.Metadata`의 등록·갱신: 최상위 정의와 그 안에 박힌 정의(`WorkflowTask.taskDefinition`,
    `subWorkflowParam.workflowDefinition`과 그 안의 태스크, 재귀) 모두. `PUT /api/metadata/workflow`에서는 서비스 단계 오류이므로 그
    정의만 `BulkResponse`의 실패로 들어간다.
  - `Archon.Runtime.start_workflow/1`·`start_workflow_idempotent/1`의 정의 확인(`new_workflow`): `StartWorkflowRequest.workflowDef`로
    들어온 정의, 런타임에 식으로 정해지는 하위 워크플로우 정의(`subWorkflowDefinition`), 그 안의 태스크 정의까지. 시작 오류
    `{:invalid, 문구}`로 돌려주므로 REST에서는 400, 하위 워크플로우 시작에서는 기존 분류대로 SUB_WORKFLOW 태스크 `FAILED`다.
- 이름 참조는 upstream처럼 받고 검사하지 않는다. `enforceSchema`가 거짓이면 어떤 스키마도 받는다
  (upstream도 검사하지 않는다).
- **판정 함수와 거절 지점(조각 5c).**
  - `Archon.Domain.SchemaDef.name_reference?/1`(공백 판정은 Java `Character.isWhitespace`라 no-break space는 공백이 아님),
    `Archon.Domain.TaskDef.check_schema/1`, `Archon.Domain.WorkflowDef.check_schema/1`이다. 반환은 `:ok` 또는
    `{:error, {:invalid, 문구}}`. 정의 이름이 없으면 문구의 이름은 `null`이다. WorkflowDef는 자기 스키마(`inputSchema`, 그다음
    `outputSchema`)를 먼저, 그다음 태스크를 순서대로 본다. 태스크 안의 목록(`decisionCases`, `defaultCase`, `forkTasks`, `loopOver`)은
    태스크 타입과 상관없이 모두 내려간다(`collectTasks`는 타입별 목록만 보지만 박힌 정의를 하나도 빠뜨리지 않기 위해서다).
    `subWorkflowParam.workflowDefinition`이 `${...}` 식이면 그 자리에서는 볼 것이 없다. 거절할 곳이 여럿이면 첫 거절만 문구에
    나오고, `decisionCases` 사이의 순서는 JSON 순서가 아니라 맵 순서다(ADR 0002의 키 순서 차이).
  - `Archon.Metadata`: 메서드 검증 다음에 본다. `POST /api/metadata/taskdefs`는 목록 전체를 본 뒤 하나라도 거절이면 아무것도
    저장하지 않는다. `PUT /api/metadata/taskdefs`는 없는 이름의 404 다음, `POST /api/metadata/workflow`는 409 판정 다음이다.
  - `Archon.Runtime.new_workflow`: 태스크 정의를 채운 정의(`populate`) 전체를 `NULL input` 검사 다음에 본다. 인라인
    `:definition`(`StartWorkflowRequest.workflowDef`, 식으로 정해진 `subWorkflowDefinition`)뿐 아니라 이름으로 찾은 등록본과 그
    태스크에 채운 등록 TaskDef도 함께 본다. 등록 때 이미 거절되므로 보통은 통과하지만, 이 결정 전에 저장된 정의나 저장소에 직접
    넣은 정의도 시작에서 막기 위해서다. 하위 워크플로우 시작에서는 `SubWorkflows.start_child`가 `{:invalid, 문구}`를 기존처럼
    SUB_WORKFLOW 태스크의 `FAILED`(`reasonForIncompletion`이 그 문구)로 바꾼다. `start_workflow_idempotent/1`도 저장된 같은 ID의
    자식을 찾기 전에 이 검사를 하므로, 이 결정 전에 그런 정의로 시작된 자식의 SUB_WORKFLOW 태스크를 다시 실행하면(복구, outbox)
    자식이 살아 있어도 태스크가 `FAILED`가 된다. 정의를 못 찾을 때(`:not_found`)와 같은 동작이고, 이 결정 전에 저장된 정의는 개발
    중의 시험 데이터뿐이라 받아들인다.
- 검증기 채택과 `/api/schema`는 Later의 별도 ADR이다. 그때 이 거절을 없앤다.

### 6. 골든 픽스처 기반 계약 시험

- **재생 시험.** `test/support/archon_web/contract_case.ex`의 재생 도우미가 픽스처 시나리오를 `Phoenix.ConnTest`로 보낸다.
  - 순서: 픽스처 파일에는 순서가 없고, 캡처 스크립트는 저장하지 않는 대기(`wait_status`)와 되풀이(`poll_until`, batch poll 반복)를
    한다. 그래서 재생 도우미가 시나리오 목록(픽스처 이름의 순서와 그 사이의 대기·되풀이)을 코드로 가진다. 목록 안의 순서
    (batch poll 결과 등)는 Archon도 같은 순서를 내는지 함께 확인하는 것이다.
  - ID 대응표: 캡처한 UUID가 응답에 처음 나오면 그 자리의 실제 값으로 대응을 정한다. 대응은 일대일이다. 새 캡처 UUID가 이미 다른
    캡처 UUID의 대응값으로 정해질 실제 값에 닿으면 실패한다. 응답보다 요청에 먼저 나오는 캡처 UUID(예: `workflow_get_not_found`의
    `00000000-...`)는 바꾸지 않고 그 자신으로 대응을 정한다. 요청에는 대응값을 넣는다.
  - 비교: 기대 body의 캡처 UUID를 대응값으로 바꾸고, 시각 필드만 `Archon.Contract.normalize/1`처럼 가린 뒤(UUID는 가리지 않는다.
    재생 도우미가 시각만 가리는 비교를 둔다) 상태 코드, `Content-Type`, body를 비교한다. 그래서 이미 대응이 정해진 ID가 다른 UUID로
    나오거나 서로 다른 ID가 같은 값으로 나오면 실패한다.
  - JSON 스키마 검사(`priv/contract`)도 함께 한다. 이 시험은 두 백엔드(ADR 0021 결정 9의 `ARCHON_BACKEND`)에서 돈다.
- **픽스처 보강.** 지금 픽스처가 다루지 않는 MVP 응답은 upstream 서버에서 캡처해 더한다(손으로 만들지 않는다, ADR 0001).
  조각 5a가 `scripts/contract/capture_fixtures.sh`에 시나리오를 더하고 한 번에 다시 캡처한다. 5c·5d·5e는 스크립트·픽스처·
  `test/archon/contract_test.exs`를 고치지 않는다. 그 조각에서 빠진 픽스처를 찾으면 기록해 두고, 마지막 조각 5f가 한 번에 더해
  다시 캡처한다. 최소 목록:
  - `/health`, `/api/health`
  - `PUT /api/metadata/workflow`(성공, 한 원소의 검증 실패로 전체 400, 서비스 단계 실패가 섞인 일괄), `PUT /api/metadata/taskdefs`(성공, 없는 이름 404),
    `GET /api/metadata/taskdefs`, `POST /api/metadata/workflow?overwrite=true`
  - 검증 실패 400: 이름 없는 TaskDef 배열, 빈 배열, 태스크 없는 WorkflowDef
  - 시작 오류: 없는 정의(404), `StartWorkflowRequest`의 인라인 `workflowDef` 시작
  - `GET /api/workflow/{id}?includeTasks=false`의 다른 상태, `status`의 `includeOutput`·`includeVariables`
  - 종료 오류: 없는 워크플로우, 완료된 워크플로우(409)
  - `GET /api/tasks/poll/batch/{tasktype}` 빈 큐(200 `[]`), `update-v2`가 다음 태스크를 돌려주는 경우, 없는 태스크 갱신·조회, `update-v2`의 검증 실패
  - 없는 경로 404, 위 매개변수 경로와 겹치는 Later 경로 표본, MVP 경로의 다른 메서드(upstream 405, Archon은 404로 차이 기록),
    JSON이 아닌 body, 숫자 쿼리에 문자
  - `invalidValue` 경계: 검증 실패 원소의 문자열 값, primitive 필드의 `null`, 정수 필드의 실수
- 다시 캡처한 기존 픽스처가 `normalize/1` 기준으로 바뀌면 그 차이를 PR에서 검토한다(`priv/contract/README.md` 절차).
- **5a 캡처 결과.** 위 목록을 51개 픽스처로 더했다(모두 87개). 기존 36개는 다시 캡처해도 `normalize/1` 기준 같았고, 새 캡처를
  빈 서버에서 한 번 더 받아 87개 모두 같음을 확인했다. 목록에서 다음은 그대로 캡처할 수 없었다.
  - "서비스 단계 실패가 섞인 일괄": upstream SQLite DAO의 `updateWorkflowDef`는 이름이 `null`일 때만 실패하는데, 그 정의는
    `@Valid`가 먼저 막는다. 그래서 정의별 실패가 섞인 `BulkResponse`는 Archon의 스키마 거절(결정 5)이나 저장 예외(결정 2)에서만
    생기고, 5c의 단위 시험이 맡는다.
  - "MVP 경로의 다른 메서드" 중 Later 경로와 겹치는 것(`DELETE /api/metadata/taskdefs/{tasktype}`)은 upstream에서 정의를 지우는
    부작용이 있어 캡처하지 않았다. `PATCH /api/workflow`, `PUT /api/tasks/{taskId}`(405)를 캡처했다.
- **재생 도우미 세부(5a).** `ArchonWeb.ContractCase.scenario/0`이 캡처 순서 전체이고, `steps/2`로 잘라 `replay/2`로 돌린다. 의도적인
  차이는 단계 옵션으로 적는다: `expect: :no_route`(Later 경로와 405 픽스처는 upstream 응답 대신 Archon의 404를 기대),
  `ignore: [["message"]]`(Jackson 문구). 대기(`wait_status`)는 REST가 아니라 `Archon.Runtime.get_workflow/2`로 본다. 앞 단계 없이
  준비한 상태(런타임으로 직접 시작한 워크플로우)는 `bind/3`으로 캡처 ID에 묶는다. `instance`는 있음·없음만, `validationErrors`는
  순서 없이 비교한다(Hibernate가 위반을 정해진 순서 없이 낸다). 픽스처별 스키마 분류는 `Archon.Contract.fixture_schemas/0`로
  옮겨 계약 시험과 재생이 함께 쓴다. 런타임은 다른 시험과 공유되므로 목록 응답(`metadata_list_taskdefs`)을 재생하는 조각은 다른
  시험의 정의를 걸러야 한다.
- **정의 픽스처 재생(조각 5c).** 단계 옵션 `only: :expected_names`는 Archon 목록 body에서 픽스처 목록에 이름이 있는 원소만 남긴다
  (`metadata_list_taskdefs`). 다른 시험(`Archon.RuntimeCase`)이 `archon_simple`·`archon_task_a`·`archon_task_b`를 등록해 두므로,
  `test/archon_web/metadata_controller_test.exs`는 재생 전에 Metadata 픽스처가 쓰는 정의 이름을 저장소에서 지우고(behaviour에 삭제가
  없어 메모리는 프로세스 상태, Postgres는 행을 직접 지운다) 끝나면 다시 지운 뒤 `RuntimeCase`의 정의를 되돌린다. 재생은 두
  구간(`metadata_register_taskdefs`~`metadata_get_workflow_not_found`, `metadata_list_taskdefs`~`metadata_update_workflows_empty`)이고,
  사이의 워크플로우 단계는 정의를 바꾸지 않으므로 둘째 구간 앞에서 첫 구간의 등록만 다시 한다.
- 시나리오 시험 밖의 단위 시험은 컨트롤러마다 오류 변환과 쿼리 기본값을 본다.

### 7. 구현 조각

| 조각 | 범위 | 시험·정답 기준 | 선행 | 건드리는 파일·모듈 |
|---|---|---|---|---|
| 5a | 결정 1·4·6의 기반: 의존성, Endpoint·Router(MVP 19개 경로 전부), `Health` 컨트롤러, `ArchonWeb.Errors`, `ErrorResponse` 모델, MVP가 아닌 요청의 404와 Later 리터럴 경로, 설정(주소·포트, ADR 0024 결정 4), 재생 도우미, 픽스처 보강 캡처. 나머지 세 컨트롤러는 모든 액션이 없는 경로와 같은 404로 답하는 골격만 둔다 | `/health` 픽스처, 오류 변환 단위 시험, 없는 경로 픽스처, 기존 픽스처 재캡처 비교 | 없음 | `mix.exs`, `mix.lock`, `config/{config,test,runtime}.exs`, `lib/archon/application.ex`, `test/test_helper.exs`·`test/support/postgres_case.ex`(시험에서 런타임 뒤에 Endpoint 띄우기), `lib/archon_web.ex`, `lib/archon_web/{endpoint,router,errors,error_json,request,response}.ex`, `lib/archon_web/controllers/{health,metadata,workflow,task}_controller.ex`(골격), `lib/archon/domain/{error_response,validation_error}.ex`, `lib/archon/domain/task_result.ex`(`__fields__/0`, `invalidValue` 찾기), `scripts/contract/capture_fixtures.sh`, `test/fixtures/contract/*`(추가), `test/fixtures/contract/README.md`, `test/archon/contract_test.exs`·`test/archon/domain/contract_round_trip_test.exs`(새 픽스처 등록), `test/support/contract.ex`(`fixture_schemas/0`, `mask_times/1`), `test/support/archon_web/contract_case.ex`, `test/archon_web/{health,errors,router,request,contract_case,endpoint}_test.exs` |
| 5b | [ADR 0024](0024-worker-input-trust-and-auth.md) 결정 1~3: SUB_WORKFLOW `subWorkflowId` 고정, 자식 소유권 확인, 조상 우회 코드 제거, ADR 0024 `승인`과 ADR 0018 목록 상태 | ADR 0024 결정 5의 시험, 기존 런타임 시험 전부(두 백엔드) | 없음 | ADR 0024 결정 5의 파일, `docs/adr/{0024,README}.md` |
| 5c | 결정 2·5의 정의: `Archon.Metadata` 서비스, `get_all_task_defs/0` 콜백(메모리·Postgres·계약), `BulkResponse` 모델, 스키마 판정 함수와 시작 경로의 거절, `Metadata` 컨트롤러 일곱 액션 | `metadata_*` 픽스처 재생, 스키마 거절 시험(박힌 정의, 시작의 인라인 정의, 식으로 정한 하위 워크플로우 정의), 저장소 계약 시험 | 5a | `lib/archon/metadata.ex`, `lib/archon/domain/{workflow_def,task_def}.ex`(판정 함수), `lib/archon/runtime.ex`(`new_workflow`의 거절), `test/archon/runtime/runtime_test.exs`, `lib/archon/runtime/metadata.ex`, `lib/archon/runtime/metadata/{memory,postgres}.ex`, `test/support/runtime/metadata_contract.ex`, `test/archon/runtime/{metadata,metadata_postgres}_test.exs`, `lib/archon/domain/bulk_response.ex`, `lib/archon_web/controllers/metadata_controller.ex`, `test/archon/metadata_test.exs`, `test/archon_web/metadata_controller_test.exs`. 구현에서 더한 것: `lib/archon/domain/{schema_def,validation}.ex`(이름 참조 판정, Java 공백 판정), `test/support/archon_web/contract_case.ex`(`only:` 옵션) |
| 5d | 결정 2·3의 워크플로우: `StartWorkflowRequest`·`WorkflowStatus` 모델, 시작 두 가지(시작 맵은 요청 필드로만 만들고 부모 필드를 넣지 않음, ADR 0024 결정 4), 조회, 상태 요약, 종료 | `workflow_*` 픽스처 재생, 시작 맵에 부모 필드가 없는 시험 | 5a, 5c | `lib/archon/domain/{start_workflow_request,workflow_status}.ex`, `lib/archon_web/controllers/workflow_controller.ex`, `test/archon/domain/{start_workflow_request,workflow_status}_test.exs`, `test/archon_web/workflow_controller_test.exs` |
| 5e | 결정 2의 태스크: poll, batch poll, 갱신, `update-v2`, 조회 | `task_*` 픽스처 재생, 검증 실패(`POST /api/tasks`는 400, `update-v2`는 500, 결정 4) | 5a, **5b** | `lib/archon_web/controllers/task_controller.ex`, `test/archon_web/task_controller_test.exs`, `lib/archon/domain/codec.ex`·`test/archon/domain/codec_test.exs`(코덱 오류 수 한도, 결정 3) |
| 5f | 통합: 전체 시나리오 재생(픽스처 전부, 두 백엔드), Later·Unsupported 경로 404 표본, 실제 HTTP로 띄운 엔드포인트의 연기 시험, README 호환성 절(ADR 0001 결과 절의 Unsupported 목록 링크, 인증 없음과 주소 기본값), ADR 0023 `승인`과 ADR 0018 목록 상태 | `mix test` 전부(두 백엔드), CI | 5c, 5d, 5e | `test/archon_web/contract_replay_test.exs`, `test/archon_web/server_test.exs`, 빠진 픽스처가 있으면 `scripts/contract/capture_fixtures.sh`·`test/fixtures/contract/*`·`test/archon/contract_test.exs`, `README.md`, `docs/adr/{0023,README}.md`, `docs/adr/0003-porting-strategy.md`(비고) |

- **병렬로 진행할 수 있는 묶음.**
  - 1차: 5a와 5b. 5a는 웹·설정·픽스처, 5b는 런타임 파일만 고친다.
  - 2차: 5c(5a 뒤)와 5e(5a·5b 뒤). 서로 파일이 겹치지 않는다.
  - 3차: 5d(5c 뒤). 시작의 인라인 정의 거절이 5c의 `runtime.ex` 변경에 기대기 때문이다.
  - 마지막: 5f.
- **태스크 갱신 REST는 5b 뒤에만 연다.** ADR 0021 결과 절의 출시 조건이다. ADR 0024는 이 ADR과 함께 머지되어 조각보다
  먼저 있고, 5e는 5b의 구현이 머지된 뒤 시작한다.
- 라우터와 컨트롤러 골격은 5a가 모두 만든다. 그래서 5c·5d·5e는 `router.ex`를 고치지 않고 자기 컨트롤러 파일 하나를 채운다.
  픽스처는 5a와 5f만 더한다(결정 6). 픽스처 등록(`contract_test.exs`, `contract_round_trip_test.exs`, `Archon.Contract.fixture_schemas/0`)도
  5a와 5f만 고친다. 재생 도우미(`contract_case.ex`)의 단계 옵션은 각 조각이 자기 픽스처에 맞게 고칠 수 있다.
- **5d의 실제 파일과 재생(조각 5d).** 표의 파일에 더해 `lib/archon/runtime.ex`(정의 채우기 선형화, 결정 3),
  `lib/archon_web/request.ex`와 `lib/archon_web/controllers/{metadata,task}_controller.ex`(`codec_error/1`, 결정 3)를 고쳤다.
  재생(`test/archon_web/workflow_controller_test.exs`)은 5e와 같은 setup(런타임 저장소에 정의를 넣고 큐를 비움)으로
  `workflow_start_simple`부터 `workflow_terminate_not_found`까지를 `metadata_*` 교환만 빼고 한 번에 돌린다. 워크플로우·태스크·
  `health` 교환과 대기가 모두 들어간다. 뒤쪽의 `workflow_get_status_all`이 앞쪽 SIMPLE 워크플로우를 읽으므로 나누지 않는다.
- **5e의 재생 선행 조건.** 태스크 픽스처는 정의 등록(5c)과 워크플로우 시작(5d) 뒤의 상태다. 5d보다 먼저 끝나는 5e는 정의와
  워크플로우를 `Archon.Metadata`·`Archon.Runtime`으로 직접 만들고 `bind/3`으로 캡처 ID에 묶은 뒤 태스크 단계만 재생한다.
  5e는 5c와 동시에 진행했으므로 `Archon.Metadata` 대신 런타임 저장소(`Archon.Runtime.metadata/0`)에 캡처된 정의(`Archon.RuntimeCase.register_definitions/0`,
  `metadata_get_workflow_{switch,fork}`, 갱신된 `archon_task_c`인 `metadata_get_taskdef_updated`)를 넣고,
  `Archon.Runtime.start_workflow/1`로 시작한 워크플로우를 시작 픽스처의 캡처 ID에 묶는다. 시나리오의 `metadata_*`·`workflow_*` 교환은
  빼고 대기(`wait_status`)는 남긴다. 태스크 큐는 다른 시험과 공유되므로 `Archon.RuntimeCase.isolate_queues/1`로 비운다.
- 각 조각은 이 ADR의 결정 번호와 조각 이름을 PR에 적는다. 조각 중에 결정이 바뀌면 이 ADR의 해당 결정과 날짜 줄에 갱신
  사실을 적는다(ADR 0018·0021과 같은 방식).

## upstream과 의도적으로 다른 점

- **이름 참조가 아닌 스키마(인라인, `externalRef`, 이름 없음)를 강제하는 정의를 등록 때 받지 않는다**(결정 5). upstream은 인라인이면
  받아서 검증하고, `externalRef`나 이름 없음이면 등록은 받되(스키마 필드에 `@Valid`가 없어 등록 때 검사하지 않는다) 그 정의로
  시작·태스크 갱신할 때 400을 준다.
- **MVP 경로의 다른 메서드도 405가 아니라 404다**(결정 2).
- **Later 경로는 없는 경로처럼 404다**(ADR 0001). upstream은 그 경로를 처리한다.
- **기본 주소가 `127.0.0.1`이다**(ADR 0024 결정 4). upstream Spring Boot는 모든 주소에서 듣는다.
- **SUB_WORKFLOW 태스크 갱신의 `subWorkflowId`를 반영하지 않는다**(ADR 0024 결정 1).
- **`/api` 밖의 없는 경로도 404다.** upstream은 UI 정적 파일을 내주므로 `GET /nope`에 index HTML(200)을 준다.
- **OPTIONS는 404다**(결정 1). upstream은 `Allow` 헤더로 200이다.
- **500의 문구.** `TransientException`·매핑 없는 예외로 가는 런타임 오류(결정 4 표의 마지막 두 줄)는 upstream이 `th.getMessage()`를
  주는 자리에 고정 문구(`"Temporary server error, retry the request"`, `"Internal server error"`)를 준다. Elixir 용어를 내보내지
  않기 위해서다. 400대 Plug 예외도 예외 문구 대신 HTTP 상태 문구를 준다.
- **요청 읽기의 차이**(결정 3): JSON이 아닌 body의 Jackson 문구를 옮기지 않고, 8 MB 넘는 body는 413이다(upstream은 제한이
  없다). 실수로 나타낼 수 없는 지수(`1e999`)는 500 parse error다
  (upstream은 `BigDecimal`로 받는다).
- **`GET /api/metadata/taskdefs`는 이름 순이다**(결정 2). upstream은 순서를 정하지 않는다(SQLite는 삽입 순).
- **일괄 갱신에서 저장 예외의 실패 문구는 고정 문구다**(결정 2). upstream은 예외의 `getMessage()`를 넣는다.
- **코덱 타입 오류의 문구는 Jackson 문구가 아니다**(결정 4).
- **외부 입력 경로의 거절이 런타임의 시작 검사보다 먼저다**(결정 4). upstream은 정의 확인, 태스크 정의 채우기, `NULL input`·스키마
  검사를 모두 마친 뒤 입력을 내려받다 실패한다. 그래서 그 검사 중 하나에 걸리는 시작(없는 정의, 정의 없는 SUB_WORKFLOW, Archon이
  거절하는 스키마)에 `externalInputPayloadStoragePath`도 주면 upstream은 그 검사의 오류(404·500·400)를, Archon은 500을 준다. 외부
  저장소는 범위 밖이다.
- **Java `int` 범위를 넘는 정수.** 도메인 코덱은 정수 필드의 범위를 보지 않으므로(ADR 0002 코덱, 5d 이전부터) `StartWorkflowRequest`의
  `priority`·`version`에 int 범위를 넘는 수를 주면 upstream은 500 `"JSON parse error: Numeric value ... out of range of int"`, Archon은
  검증 400(`priority`)이나 정의 404(`version`)다. 쿼리 값(`ArchonWeb.Request.int/4`)은 범위를 본다.
- JSON 객체 키 순서 등 코덱 차이는 ADR 0002의 목록 그대로다.

## 대안

- **Plug.Router + Bandit:** 의존성이 가장 적고 19개 경로에는 충분하다. 라우터 파이프라인, `Phoenix.ConnTest`, Endpoint 설정,
  텔레메트리를 직접 써야 하고, Later 69개 경로와 UI 정적 파일을 붙일 때 같은 틀을 다시 만든다. ADR 0003의 "Phoenix REST"도
  바꿔야 한다. BOSS가 Phoenix를 골랐다.
- **Phoenix 생성기 전체(HTML·LiveView·Ecto 연동):** 쓰지 않는 코드와 의존성이 많고, Ecto 스키마를 쓰지 않는 저장 방식(ADR 0002,
  0021)과 맞지 않는다.
- **Jason:** Phoenix의 기본 JSON 라이브러리지만 코덱이 이미 내장 `JSON`을 쓴다. 두 라이브러리의 숫자·문자열 처리 차이가 계약
  시험에 끼어들 수 있다.
- **`Plug.Parsers` JSON 파서로 body 받기:** 배열 body가 `_json`으로 감싸지고, 파서가 먼저 맵을 만들어 컨트롤러에 디코딩 오류를
  넘기기 번거롭다.
- **스키마 검증기를 지금 채택:** 계약 차이가 문구로 남고(networknt 메시지와 다름), 조각과 의존성 ADR이 는다. BOSS가 Later로
  미뤘다.
- **스키마를 검사 없이 실행:** 지금 런타임 동작이지만, upstream이 거절할 입력을 조용히 실행하는 계약 차이가 된다.
- **생명주기 REST를 Phase 5에 포함:** 런타임은 있지만 픽스처를 새로 캡처해야 하고 L3가 그때 드러난다. BOSS가 MVP 19개로
  유지했다.

## 결과

- 이 ADR은 결정만 담는다. 구현은 결정 7의 조각 5a~5f로 하며, 마지막 조각이 머지되면 `승인`으로 바꾼다.
- 정의 등록 REST를 열기 전에 스키마 검증을 정하라는 ADR 0018 결과 절의 조건은 결정 5로 채운다. 그 절은 검증기 채택을 요구했으나
  이 ADR은 거절로 대신한다. 또 ADR 0018 결정 7의 REST 호출 경계에 `Archon.Metadata`를 더한다(결정 2). 그래서 `승인`으로 바꿀 때
  ADR 0018의 목록 상태에 "일부 0023이 대체"(결과 절의 스키마 검증, 결정 7의 호출 경계)를 적는다.
- ADR 0021 결과 절의 Phase 5 출시 조건(L7·L8)은 [ADR 0024](0024-worker-input-trust-and-auth.md)와 조각 5b가 채운다. 5e는 5b 뒤다.
- 아직 범위 밖: 생명주기·검색·이벤트 등 Later 경로, 인증(ADR 0024 결정 4), 스키마 검증기와 `/api/schema`, 여러 노드(ADR 0021
  결정 7), 배포 절차(release 설정과 마이그레이션 실행 시점), ADR 0021 결정 6에 남은 이른 활성화의 `timeoutSeconds` 밀림(메모리
  백엔드의 `:all` 활성화와 프로세스 크래시 재시작 뒤).
