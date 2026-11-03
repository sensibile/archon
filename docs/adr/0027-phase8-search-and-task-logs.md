# ADR 0027: Phase 8 검색·색인과 task 실행 로그 설계

- 상태: 제안
- 날짜: 2026-11-04
- 기준 upstream: conductor-oss `1488804170d159021c7e62dce61514b8f31ef9ff`
- 비고: 설계 갈림길 네 가지(주제, 색인 저장 방식, freeText 의미, 경로 범위)는 2026-11-04 BOSS가 이 문서의 추천안으로 정했다.

## 맥락

Phase 7([ADR 0026](0026-phase7-system-task-types.md))까지 archon은 MVP·운영 REST와 시스템 태스크 타입을 갖췄다. 남은 Later 중
검색·색인과 task 실행 로그는 UI와 SDK가 가장 많이 부르는 경로다. 레거시 UI와 upstream Docker 이미지의 ui-next는 워크플로우 목록을
`GET /api/workflow/search`로, 태스크 목록을 `GET /api/tasks/search`로, 로그 패널을 `GET /api/tasks/{taskId}/log`로 채운다(`ui/src/data/`,
`ui-next/src/utils/query.ts`). archon은 지금 이 경로에 404로 답한다(`ArchonWeb.Router`의 `@later_workflow_gets`·`@later_task_gets`).

upstream 기본 서버(`conductor.indexing.type=sqlite`)는 색인 DAO `SqliteIndexDAO`(455줄)와 `SqliteIndexQueryBuilder`(357줄)로 이 경로를
실제로 구현한다. [ADR 0025](0025-phase6-workflow-operations-rest.md) 맥락이 적은 "아무 일도 하지 않는" 메서드는 `get`·`updateWorkflow`·
`updateTask`와 비동기 변형 등이고, 검색 넷과 task 로그는 SQL이다.

- 색인 표: `workflow_index`(workflow_id, correlation_id, workflow_type, start_time, end_time, update_time, status, parent_workflow_id,
  classifier, json_data = `WorkflowSummary` JSON), `task_index`(task_id, task_type, task_def_name, status, start/end/update_time,
  workflow_type, json_data = `TaskSummary` JSON), `task_execution_logs`(log_id, task_id, log, created_time).
- 쓰기(`ExecutionDAOFacade`, 비동기 색인 기본 꺼짐): 워크플로우 생성·갱신마다 `indexWorkflow`(동기), 태스크 **갱신**마다 `indexTask`
  (`createTasks`는 색인하지 않는다). upsert는 `update_time`이 같거나 새로울 때만 바꾼다. task 로그는 `TaskResult.logs`(갱신 때)와
  `POST /api/tasks/{taskId}/log`로 쓰고, 한 번에 `taskExecLogSizeLimit`(기본 10)개까지만 앞에서부터 남긴다.
- 질의 문법(SQLite와 upstream Postgres 색인이 같다): `query`를 `" AND "`로 나누고 각 절은 `^([a-zA-Z]++)\s*(=|>|<|IN)\s*(.*)$`. 값의
  따옴표·괄호를 지우고 `,`로 나눈다. 필드는 허용 목록(workflowId, correlationId, workflowType, startTime, endTime, status, taskId,
  taskType, taskDefName, updateTime, jsonData, parentWorkflowId, classifier)만 쓰고 모르는 필드는 **조용히 버린다**. `*_time`의 값은
  epoch 밀리초. `=`의 `*`는 대소문자 무시 LIKE. 하나짜리 `IN`은 `=`. `classifier`가 `workflow`면 `NULL`도 맞는다. OR·괄호·NOT은 없다.
  `freeText`가 비었거나 `*`가 아니면 `lower(json_data) LIKE %text%`. `sort`는 `|`로 나눈 `필드:ASC|DESC`, 잘못된 항목은 버린다.
- `-v2`는 색인에서 ID만 찾고 실행 DAO에서 각 객체를 다시 읽어, 못 읽은 것은 빼고 `totalHits`를 줄인다. `search-by-tasks`는 태스크
  색인에서 찾고 각 태스크의 워크플로우를 읽어 `WorkflowSummary`로 만든다(중복 제거). `bulk/search`는 색인을 쓰지 않고 ID 목록을
  실행 DAO에서 읽는다.

archon에 이미 있는 것(`541865c` 기준):

- Postgres `workflow`·`task` 표(json_data), Phase 6이 더한 질의 열(`workflow_name`, `workflow_version`, `correlation_id`, `create_time`),
  `Archon.Runtime.Store`의 `commit/2`(한 트랜잭션: `create`, `workflow`, `upsert_tasks`, `delete_task_ids`, outbox, 큐), 메모리 저장소.
- `Archon.Domain.TaskResult.logs`(디코드만 하고 버림), `Archon.Domain.TaskExecLog` 구조체, `SearchResult`(Phase 6 6b), `BulkResponse`.
- 없는 것: 요약 모델(`WorkflowSummary`, `TaskSummary`), 색인 표, 질의 파서, 로그 저장.

## 결정

### 1. 범위: 경로 아홉 개

| 묶음 | 메서드·경로 | upstream 핸들러 | 응답 |
|---|---|---|---|
| 워크플로우 검색 | `GET /api/workflow/search` | `search` | `SearchResult<WorkflowSummary>` |
| | `GET /api/workflow/search-v2` | `searchV2` | `SearchResult<Workflow>` |
| | `GET /api/workflow/search-by-tasks` | `searchWorkflowsByTasks` | `SearchResult<WorkflowSummary>` |
| | `GET /api/workflow/search-by-tasks-v2` | `searchWorkflowsByTasksV2` | `SearchResult<Workflow>` |
| 태스크 검색 | `GET /api/tasks/search` | `search` | `SearchResult<TaskSummary>` |
| | `GET /api/tasks/search-v2` | `searchV2` | `SearchResult<Task>` |
| task 로그 | `POST /api/tasks/{taskId}/log` | `log` | 200 body 없음(body는 날 문자열) |
| | `GET /api/tasks/{taskId}/log` | `getTaskLogs` | `List<TaskExecLog>`, 없으면 204 |
| bulk | `POST /api/workflow/bulk/search` | `searchWorkflow` | `BulkResponse<Workflow>` |

- 쿼리 이름·기본값은 upstream 컨트롤러에서 그대로 옮긴다(`start=0`, `size=100`, `sort`, `freeText=*`, `query`, 워크플로우 search의
  `classifier`·`topLevelOnly=false`, bulk/search의 `includeTasks=true`). 응답은 결정 7의 골든 픽스처가 정답이다.
- `classifier`는 upstream처럼 `classifier IN (...)` 절로, `topLevelOnly=true`는 `parentWorkflowId=""` 절로 질의에 덧붙인다.
  `classifier=agent`일 때 upstream이 앞에 붙이는 `agentHierarchy:DESC` 정렬(재귀 CTE, AI 에이전트 계층)은 옮기지 않는다(의도적 차이).
- `size` 상한 5000은 upstream처럼 workflow `search`·`search-v2`에만 둔다(`@Max(5_000)`). bulk/search는 1000개 한도
  (`WorkflowBulkService.MAX_REQUEST_ITEMS`)와 Phase 6 bulk와 같은 검증 순서를 따른다.
- 라우터의 Later 리터럴(`search`, `search-v2`, `search-by-tasks`, `search-by-tasks-v2`)은 매개변수 경로보다 먼저 두는 자리 그대로
  실제 액션으로 바꾼다. `externalstoragelocation` 두 리터럴은 Later 404로 남는다.
- **Later로 남는 것.** 외부 payload 저장소, 이벤트, 스케줄러, 큐 관리·admin, 인증, 스키마, `POST /api/workflow/test` 등 ADR 0001의
  나머지 Later.

### 2. 색인 표와 쓰기(BOSS 결정: 별도 색인 표, 같은 트랜잭션)

- **표.** 새 Postgres 마이그레이션이 upstream SQLite 스키마(`sqlite-persistence/.../migration_sqlite/` V1·V2·V5·V7)와 같은 열의
  `workflow_index`, `task_index`, `task_execution_logs`를 만든다. 차이는 다음뿐이다.
  - 시각 열은 `bigint` epoch 밀리초(upstream은 UTC 글자). 질의 결과는 같다.
  - `json_data`는 `jsonb`가 아니라 `text`다. freeText가 요약 JSON 글자에 대한 부분 문자열이므로(결정 4) 키 순서·공백이 upstream
    직렬화 그대로 남아야 한다.
  - 기본 순서용 `seq bigserial`을 둔다. upstream SQLite는 `ORDER BY`가 없으면 rowid(처음 넣은 순서, upsert는 rowid 유지) 순이다.
  - 인덱스는 질의에 쓰는 열마다 btree(upstream과 같은 열).
- **쓰기 시점.** `Store.commit/2`가 같은 트랜잭션에서 색인을 쓴다(메모리 저장소도 같은 커밋 안에서).
  - `create`와 `workflow`가 있으면 그 워크플로우의 `WorkflowSummary`를 upsert한다.
  - `upsert_tasks` 중 **이미 저장돼 있던 태스크**의 `TaskSummary`만 upsert한다. 처음 저장되는 태스크는 색인하지 않는다(upstream
    `createTasks`). 그래서 예약만 되고 갱신되지 않은 태스크는 태스크 검색에 나오지 않는다(upstream과 같음, 결정 7의 캡처로 확인).
  - upsert는 upstream처럼 새 `update_time`이 같거나 클 때만 바꾼다.
  - `delete_task_ids`(DO_WHILE `keepLastN`)는 upstream이 색인을 지우지 않으므로 색인을 그대로 둔다(캡처로 확인).
- **지우기.** Phase 6의 remove(`Store.remove_workflow/1`)에서 색인을 어떻게 할지는 upstream 기본 서버의 결과를 따른다.
  `archiveWorkflow=true`는 upstream이 `indexDAO.updateWorkflow(..., "archived")`(SQLite에서 아무 일도 안 함)만 부르므로 색인 행이
  남고, 그 뒤 `search`는 지운 워크플로우의 요약을 계속 돌려주며 `-v2`는 다시 읽기에 실패해 빼고 `totalHits`를 줄인다.
  `archiveWorkflow=false`의 비동기 색인 삭제가 SQLite에서 실제로 지우는지는 소스만으로 확정하지 않는다. 두 경우 모두 8a 캡처가
  정답이고, 8c가 그에 맞춘다(지울 때는 태스크 행과 그 로그도).
- **기존 데이터.** 마이그레이션이 기존 `workflow`·`task` 행으로 색인을 배치로 채운다(Phase 6 질의 열 마이그레이션과 같은 방식,
  요약은 Elixir 코드로 만든다). 태스크는 처음 저장 뒤 갱신됐는지 알 수 없으므로 모든 태스크를 채운다(백필 한 번의 차이).
- **커밋 크기.** 색인은 요약 JSON(입력·출력 포함)을 한 번 더 저장하므로 쓰기량이 늘어난다. upstream 기본 서버와 같은 비용이며
  받아들인다. 비동기 색인 설정(`asyncIndexingEnabled`)은 옮기지 않는다.

### 3. 요약 모델

- `Archon.Domain.WorkflowSummary`와 `Archon.Domain.TaskSummary`를 upstream 생성자(`new WorkflowSummary(WorkflowModel)`,
  `new TaskSummary(TaskModel)`)대로 만든다. 필드 순서는 upstream Jackson 직렬화 순서(결정 2의 `text` json_data와 응답이 같게).
- 시각은 `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`(GMT) 글자. `WorkflowSummary`의 `startTime`은 `createTime`, `endTime`은 0보다 클 때만,
  `executionTime`은 끝 − 시작. `TaskSummary`의 시각은 0이어도 epoch 글자로 찍는다(upstream과 같음).
- `input`·`output`은 upstream 기본 설정(`summary-input-output-json-serialization.enabled=false`)처럼 Java `Map.toString()` 글자다
  (`{a=1, b=[x, y], c={d=e}}`). 중첩 맵·목록·`null`·수(`1.0` 등)의 Java 표기는 골든 픽스처로 맞춘다. JSON 직렬화 설정은 옮기지 않는다.
- `failedReferenceTaskNames`(쉼표로 이은 글자, 기본 `""`), `failedTaskNames`(집합), `parentWorkflowId`(기본 `""`) 등 기본값도 upstream
  그대로다.

### 4. 질의 파서와 실행(BOSS 결정: freeText는 기본 SQLite 서버와 같게)

- `Archon.Search.Query`가 `query`·`freeText`·`sort`를 결정 맥락의 문법대로 구문 트리(절 목록, freeText, 정렬 목록)로 바꾼다. 순수
  모듈이고 두 저장소가 같이 쓴다.
  - 잘못된 절은 upstream `IllegalArgumentException`처럼 오류다. HTTP 상태와 문구는 8a 캡처를 따른다(`ApplicationExceptionMapper`는
    `IllegalArgumentException`을 400으로 바꾸지만 DAO가 감싸면 500일 수 있다).
  - 모르는 필드의 절은 버린다. 허용 목록에 있지만 그 표에 없는 필드(예: 태스크 검색의 `workflowId`)는 upstream SQLite에서 SQL
    오류다. 같은 결과(상태·문구)를 8a 캡처로 정해 맞춘다.
- Postgres는 구문 트리를 매개변수 SQL로 바꾼다(값은 모두 바인드, 필드·정렬 이름은 허용 목록에서만 나와 SQL 주입이 없다).
  메모리 저장소는 같은 트리를 Elixir로 평가한다.
- **freeText.** 비었거나 `*`가 아니면 요약 JSON 글자의 대소문자 무시 부분 문자열(`lower(json_data) LIKE '%' || lower(text) || '%'`).
  upstream SQLite처럼 `%`·`_`를 이스케이프하지 않는다(사용자가 쓴 `%`·`_`는 와일드카드). SQLite `lower()`는 ASCII만 바꾸고
  Postgres `lower()`는 유니코드를 바꾼다(의도적 차이, 비ASCII 대소문자만 다르다).
- `=`의 `*` 와일드카드도 대소문자 무시 LIKE(SQLite와 같음, upstream Postgres 색인은 대소문자를 구분한다).
- 정렬이 없으면 결정 2의 `seq` 순, 있으면 그 순서 다음 `seq`. 페이징은 `LIMIT size OFFSET start`, `totalHits`는 같은 조건의 개수.

### 5. 서비스 경로

`Archon.Runtime`에 검색 함수를 두고 컨트롤러는 그것만 부른다(Phase 5·6의 경계).

- `search`: 색인의 요약 JSON을 그대로 돌려준다(다시 직렬화하지 않음).
- `search-v2`: 색인에서 ID만 찾고 `Runtime.get_workflow(id, false)`로 각 워크플로우를 읽어, 못 읽은 것은 빼고 `totalHits`에서 뺀다.
  upstream은 병렬 스트림이지만 결과 순서는 색인 순서다(병렬 수집의 순서는 픽스처로 확인).
- `search-by-tasks`: 태스크 색인에서 요약을 찾고 각 `workflowId`의 워크플로우를 읽어 `WorkflowSummary`를 새로 만든다(중복 제거).
  `-v2`는 태스크 ID로 태스크를 다시 읽은 뒤 같은 일을 하고 `Workflow`를 돌려준다. `totalHits`의 계산은 upstream 소스와 캡처를 따른다.
- `tasks/search`·`-v2`: 태스크 색인. `-v2`는 `Runtime` 태스크 조회로 다시 읽는다.
- `bulk/search`: 색인 없이 ID마다 `Runtime.get_workflow(id, include_tasks)`, `BulkResponse<Workflow>`(Phase 6 bulk와 같은 모양).

### 6. task 실행 로그

- **쓰기.** `Archon.Runtime.Tasks.update/1`이 받은 `TaskResult.logs`를 태스크 갱신 커밋에 담아 같은 트랜잭션에서
  `task_execution_logs`에 넣는다(`Commit`에 로그 필드를 더한다). 각 로그의 `taskId`는 갱신한 태스크로 채운다. 한 번에
  `task_exec_log_size_limit`(기본 10, `config :archon, Archon.Runtime`)개까지만 앞에서부터 남긴다(upstream과 같음).
- `POST /api/tasks/{taskId}/log`는 body 글자 하나로 `createdTime` = 지금인 로그를 넣는다. upstream처럼 태스크가 있는지 확인하지
  않는다(캡처로 확인). 워크플로우 프로세스를 거치지 않고 저장소에 바로 쓴다(로그는 워크플로우 상태가 아니다).
- **읽기.** `GET`은 `created_time` 순 목록, 없으면 204 body 없음.
- 로그 하나의 크기 상한은 upstream에 없다. archon도 따로 두지 않고 요청 body 크기 한도(Plug 파서)에 맡긴다.
- 로그는 그 태스크의 색인 행과 함께 지워진다(결정 2의 지우기 규칙을 따름).

### 7. 골든 픽스처와 재생(8a가 한 번에 캡처)

- 8a가 이 Phase의 시나리오 전부를 `scripts/contract/capture_fixtures.sh` 끝에 더하고 upstream 서버에서 기존 픽스처와 함께 다시
  캡처한다(ADR 0025 결정 7, ADR 0026 결정 8과 같음). 다른 조각은 스크립트·픽스처·등록을 고치지 않는다.
- 결과가 캡처 DB의 다른 워크플로우에 흔들리지 않게, 질의는 이 섹션이 만든 고유 워크플로우 이름(`p8_*`)과 상관 ID로 거른다.
  재생도 같은 시나리오 순서로 같은 상태를 만든다.
- 시나리오에 최소한 다음을 넣는다.
  - 각 경로의 성공, `size`·`start` 페이징, `sort`의 ASC·DESC·여러 항목·잘못된 항목, `freeText`의 부분 문자열·대소문자·`%`
  - 질의: `=`, `IN`(하나·여럿), `>`·`<`(시각), `*` 와일드카드, 모르는 필드, 잘못된 절, 표에 없는 허용 필드, `classifier`,
    `topLevelOnly`
  - 예약만 된 태스크와 폴링된 태스크의 태스크 검색(결정 2의 "갱신만 색인")
  - remove(`archiveWorkflow` 참·거짓) 뒤의 `search`·`-v2`·태스크 검색·로그 GET
  - `TaskResult.logs` 11개 갱신(상한 10), `POST` 로그, 없는 태스크의 `POST`·`GET`, 로그 없는 GET 204
  - `size` 5001(workflow search 400), bulk/search 빈 목록·1001개·섞인 결과·`includeTasks=false`
  - 요약의 `input`·`output` Java 표기(중첩 맵·목록·수·`null`), 시각 글자, `failed*` 필드
- 시각 글자(요약의 `startTime` 등)는 재생 때 다시 맞출 수 없으므로 `normalize/1`에 요약 시각 키를 더하거나 `ignore`로 적는다.
- **아직 구현하지 않은 액션의 재생.** ADR 0025 결정 7의 장치(컨트롤러의 미구현 목록과 단계 옵션 `requires:`)를 다시 쓴다. 8a가
  컨트롤러 골격·목록·`requires:`를 만들고, 각 조각은 자기 액션을 목록에서 빼면 단계가 켜진다. 8f가 장치를 없앤다.

### 8. 구현 조각

| 조각 | 범위 | 시험·정답 기준 | 선행 | 건드리는 파일·모듈 |
|---|---|---|---|---|
| 8a | 결정 7의 캡처 전부, 라우터(9개), 컨트롤러 골격·미구현 목록·`requires:` 건너뛰기, 픽스처 등록, 요약 시각 정규화 | 기존 픽스처 재캡처 비교, 라우터 시험(`route_info/4`), 건너뛰기를 뺀 전체 재생 | 없음 | `scripts/contract/capture_fixtures.sh`, `test/fixtures/contract/*`, `test/fixtures/contract/README.md`, `test/support/contract.ex`, `test/support/archon_web/contract_case.ex`, `test/archon_web/contract_case_test.exs`, `test/archon/contract_test.exs`, `test/archon/domain/contract_round_trip_test.exs`, `lib/archon_web/router.ex`, `lib/archon_web/controllers/{search,task_log}_controller.ex`(골격), `lib/archon_web/controllers/workflow_bulk_controller.ex`(bulk/search 골격만), `test/archon_web/router_test.exs` |
| 8b | 결정 3·4의 순수 모듈: `WorkflowSummary`·`TaskSummary`(Java `Map.toString` 포함), `Archon.Search.Query`(파서, 메모리 평가, SQL 조각 생성) | upstream `SqliteIndexQueryBuilder` 사례와 JDK 프로브(Java `toString`·시각 형식), 단위 시험 | 없음 | `lib/archon/domain/{workflow_summary,task_summary}.ex`, `lib/archon/search/*`, 해당 시험 |
| 8c | 결정 2: 색인 마이그레이션·백필, `Store.commit/2`의 색인 쓰기(두 백엔드), 지우기 규칙, 저장소 검색 콜백 | 저장소 계약 시험(두 백엔드), 백필 시험, "갱신만 색인"·`update_time` 가드·remove 시험 | 8b | `priv/repo/migrations/*`(새 파일), `lib/archon/runtime/store.ex`, `lib/archon/runtime/store/{memory,postgres}.ex`, `test/support/runtime/store_contract.ex`, 해당 시험 |
| 8d | 결정 6: `Commit` 로그 필드, `Tasks.update/1`의 로그, 로그 저장소 콜백, `POST`·`GET` 로그 액션 | 로그 픽스처 재생, 상한·204·지우기 시험(두 백엔드) | 8a, 8c | `lib/archon/runtime/commit.ex`, `lib/archon/runtime/tasks.ex`, `lib/archon/runtime/store.ex`·`store/{memory,postgres}.ex`(로그 콜백 절), `priv/repo/migrations/*`(필요하면 새 파일), `lib/archon_web/controllers/task_log_controller.ex`, 해당 시험 |
| 8e | 결정 1·5: 검색 여섯 액션과 bulk/search, `Archon.Runtime`의 검색 함수 | 검색 픽스처 재생(두 백엔드), 쿼리 매개변수·5000·1000 검증 시험 | 8a, 8c | `lib/archon/runtime.ex`(검색 함수), `lib/archon_web/controllers/search_controller.ex`, `lib/archon_web/controllers/workflow_bulk_controller.ex`(bulk/search 액션), 해당 시험 |
| 8f | 통합: 건너뛰기 장치 제거와 전체 재생(두 백엔드), 빠진 픽스처, README 호환성 절, ADR 0001 분류("Phase 8"), 이 ADR `승인` | `mix test` 전부(두 백엔드), CI | 8d, 8e | `test/support/archon_web/contract_case.ex`, `test/archon_web/contract_case_test.exs`, 각 컨트롤러의 미구현 목록, `README.md`, `docs/adr/{0001,0003,0027,README}.md` |

- **병렬로 진행할 수 있는 묶음.**
  - 1차: 8a ∥ 8b(시험·라우터·골격 대 순수 lib 모듈, 파일이 겹치지 않는다).
  - 2차: 8c(8b의 요약·파서를 쓴다).
  - 3차: 8d ∥ 8e. 저장소 파일은 8d의 로그 콜백 절만 고치고 8e는 고치지 않는다. `Archon.Runtime`(8e)과 `Runtime.Tasks`(8d)로 나뉜다.
  - 마지막: 8f.
- 각 조각은 자기 컨트롤러 액션만 미구현 목록에서 빼고, 자기 단계 옵션 줄만 고친다(ADR 0025 결정 8과 같음).
- 각 조각은 이 ADR의 결정 번호와 조각 이름을 PR에 적는다. 조각 중에 결정이 바뀌면 이 ADR의 해당 결정 끝에 "조각 8x에서 정한
  것(날짜)"으로 적는다.

## upstream과 의도적으로 다른 점

ADR 0023·0025·0026의 목록에 더해 다음이 생긴다.

- **색인 시각 열**(결정 2): epoch 밀리초 `bigint`. upstream SQLite는 UTC 글자다. 질의 결과는 같다.
- **`lower()`의 범위**(결정 4): Postgres는 비ASCII도 대소문자를 무시한다. upstream SQLite는 ASCII만.
- **`agentHierarchy` 정렬**(결정 1): 옮기지 않는다(AI 에이전트 계층, ADR 0001 Unsupported의 AI 컨트롤러와 같은 범위).
- **비동기 색인과 요약 JSON 직렬화 설정**(결정 2·3): 옮기지 않는다. upstream 기본값의 동작만 있다.
- **백필한 태스크 색인**(결정 2): 마이그레이션 전부터 있던 태스크는 갱신 여부와 상관없이 모두 색인한다.

## 대안

- **다른 주제:** 스케줄러(upstream 기본 켜짐), 이벤트 핸들러, 인증을 먼저 할 수 있었다. UI 목록 화면과 로그 패널이 가장 넓게 쓰이고
  새 백엔드가 필요 없어 BOSS가 검색을 골랐다.
- **기존 표에 열을 더해 질의:** 표가 늘지 않지만 freeText가 요약 JSON 글자를 보므로 요약을 질의 때마다 만들어야 하고, 태스크의
  "갱신만 색인" 의미와 remove 뒤 남는 색인(upstream 결과)을 낼 수 없다.
- **outbox로 비동기 색인:** 커밋이 가벼워지지만 갱신 직후 검색이 옛 상태를 돌려줄 수 있다. upstream 기본(동기 색인)과 다르다.
- **freeText를 upstream Postgres 색인처럼(tsquery·JSONB 포함):** archon이 Postgres를 쓰니 자연스럽지만 골든 픽스처를 내는 기본 SQLite
  서버와 결과가 다르고, upstream Postgres 색인은 `-v2` 검색이 동작하지 않는다(`searchWorkflows`가 `null`).
- **UI가 부르는 경로만:** 조각이 줄지만 SDK의 `search-v2`·`bulk/search`가 빠진다.
- **Elasticsearch 문법(OR·괄호):** upstream ES 색인의 파서(1,062줄)는 기본 서버가 쓰지 않는다. 기본 서버의 평탄한 `AND` 문법만 옮긴다.

## 결과

- 이 ADR은 결정만 담는다. 구현은 결정 8의 조각 8a~8f로 하고, 마지막 조각 8f의 PR에서 `승인`으로 바꾼다.
- [ADR 0003](0003-porting-strategy.md) 단계 표에 Phase 8을 더한다. [ADR 0001](0001-api-contract-scope.md)의 분류 표에는 이 Phase가
  여는 9개 경로의 비고에 "Phase 8(ADR 0027)"을 적는다. 구현이 끝나면 8f가 분류를 고친다.
- ADR 0025 결정 1이 Later로 둔 task 로그와 `TaskResult.logs` 저장을 이 ADR이 다룬다.
- 아직 범위 밖: 외부 payload 저장소, 이벤트 핸들러·EVENT, 스케줄러, 큐 관리·admin, 인증과 HTTP 대상 허용 목록(ADR 0024 결정 4,
  ADR 0026 결정 7), 스키마 강제, 여러 노드, `POST /api/workflow/test`.
- 이 Phase의 후보 조사에서 다음을 확인했다(2026-11-04). 다음 단계를 고를 때 쓴다.
  - 스케줄러: `scheduler/` 6,490줄(core `SchedulerService` 1,226), 경로 13개와 bulk 2개, Spring 6자리 cron(초 먼저, 기본 UTC), 큐
    `conductor_system_scheduler`를 100ms 폴링, 시작 입력에 `_startedByScheduler` 등 키, Postgres 표 넷. ui-next가
    `/api/scheduler/search/executions`를 부른다.
  - 이벤트 핸들러: `conductor:` 큐는 큐 DAO 이름 `<워크플로우 이름>:<ref>`, 핸들러는 60초마다 새로 읽음, 액션 중
    `terminate_workflow`·`update_workflow_variables`는 upstream도 `UnsupportedOperationException`.
  - 인증: OSS 서버에는 `/api/token`이 없다. Orkes 계열 SDK(`conductor-client` 5.0.1의 `OrkesAuthentication`)는 키·시크릿이 있으면
    `POST /api/token`으로 토큰을 받아 `X-Authorization`으로 보낸다.
  - upstream Postgres 색인 DAO는 `searchWorkflows`·`searchTasks`가 `null`이라 `-v2` 계열이 동작하지 않고, task 색인 GIN 인덱스가
    `workflow_index`에 잘못 걸려 있다.
