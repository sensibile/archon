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
| bulk | `POST /api/workflow/bulk/search` | `searchWorkflow` | `BulkResponse<WorkflowModel>` |

- 쿼리 이름·기본값은 upstream 컨트롤러에서 그대로 옮긴다(`start=0`, `size=100`, `sort`, `freeText=*`, `query`, 워크플로우 search의
  `classifier`·`topLevelOnly=false`, bulk/search의 `includeTasks=true`). 응답은 결정 7의 골든 픽스처가 정답이다.
- `classifier`는 upstream처럼 `classifier IN (...)` 절로, `topLevelOnly=true`는 `parentWorkflowId=""` 절로 질의에 덧붙인다.
  `classifier=agent`일 때 upstream이 앞에 붙이는 `agentHierarchy:DESC` 정렬(재귀 CTE, AI 에이전트 계층)은 옮기지 않는다(의도적 차이).
- `size` 상한 5000은 upstream처럼 workflow `search`·`search-v2`에만 둔다(`@Max(5_000)`). bulk/search는 1000개 한도
  (`WorkflowBulkService.MAX_REQUEST_ITEMS`)와 Phase 6 bulk와 같은 검증 순서를 따른다.
- 라우터의 Later 리터럴(`@later_workflow_gets`의 `search`, `search-v2`, `search-by-tasks`, `search-by-tasks-v2`와 `@later_task_gets`의
  `search`, `search-v2`)은 매개변수 경로보다 먼저 두는 자리 그대로 실제 액션으로 바꾼다. `externalstoragelocation` 리터럴들은 Later
  404로 남는다.
- **Later로 남는 것.** 외부 payload 저장소, 이벤트, 스케줄러, 큐 관리·admin, 인증, 스키마, `POST /api/workflow/test` 등 ADR 0001의
  나머지 Later.

### 2. 색인 표와 쓰기(BOSS 결정: 별도 색인 표, 같은 트랜잭션)

- **요약은 Step이 만들어 커밋에 싣는다.** upstream은 `ExecutionDAOFacade`가 `createWorkflow`·`updateWorkflow`·`updateTask`를 부를 때
  그 자리에서 요약을 만든다(`TaskSummary`의 `queueWaitTime`처럼 그때의 시각에 기대는 값도 있다). archon의 저장소는 시각을 찍지 않고
  (ADR 0021 결정 3) 어느 태스크 저장이 upstream의 `updateTask`에 해당하는지도 모른다. 그래서 `Archon.Runtime.Step`이 커밋을 만들 때
  `Commit`의 새 필드에 요약을 담는다.
  - `index_workflow`: 이 커밋에서 upstream이 `indexWorkflow`를 부르는 경우(워크플로우 생성, 워크플로우 저장)의 `WorkflowSummary`.
  - `index_tasks`: upstream이 `updateTask`·`updateTasks`로 색인하는 태스크의 `TaskSummary` 목록. `createTasks`만 거치는 태스크(예약만
    되고 갱신되지 않은 worker 태스크, skiptask가 만든 태스크)와 `extendLease`(색인하지 않음)는 빠지고, 생성 직후 같은 결정에서
    시작·실행된 동기 시스템 태스크(SWITCH, FORK, SET_VARIABLE 등, upstream `scheduleTask`의 `updateTask`와 결정 루프의
    `tasksToBeUpdated`)는 들어간다. 정확한 자리는 upstream `WorkflowExecutorOps`가 기준이고 8a 캡처가 정답이다.
  - 요약의 시각 값(`queueWaitTime` 등)은 그 Step의 `now`로 계산한다.
- **표.** 새 Postgres 마이그레이션이 upstream SQLite 스키마(`sqlite-persistence/.../migration_sqlite/` V1·V2·V5·V7)와 같은 열의
  `workflow_index`, `task_index`, `task_execution_logs`를 만든다. 인덱스는 upstream과 같은 열에 두고, 모든 검색이 `seq`로 끝나는
  정렬을 쓰므로 `seq`에도 둔다. 차이는 다음뿐이다.
  - 시각 열은 `bigint` epoch 밀리초(upstream은 UTC 글자). 끝나지 않은 실행의 `end_time`은 0(upstream 기본값 epoch와 같은 뜻).
  - `json_data`는 `jsonb`가 아니라 `text`다. freeText가 요약 JSON 글자에 대한 부분 문자열이므로(결정 4) 키 순서·공백이 응답 직렬화
    그대로 남아야 한다.
  - 기본 순서용 `seq bigserial`(결정 4).
  - 열 값은 Phase 6 질의 열과 같은 규칙(`Archon.Runtime.Store`의 저장 불가 값은 `NULL`, `20261102000000_add_workflow_query_columns.exs`의
    `queryable`)으로 넣어, NUL 글자가 든 `correlationId` 같은 값이 커밋을 막지 않게 한다. 그래서 ID 밖의 열은 NULL을 허용한다.
    `parent_workflow_id`는 부모가 없으면 `""`(upstream 기본값, `topLevelOnly`의 `parentWorkflowId=""` 절이 기댄다).
- **쓰기.** `Store.commit/2`가 같은 트랜잭션에서 `index_workflow`·`index_tasks`를 upsert한다(메모리 저장소도 같은 커밋 안에서).
  upstream처럼 새 `update_time`이 같거나 클 때만 바꾸고, 태스크 행은 충돌 때 `start_time`·`workflow_type`을 바꾸지 않는다
  (`SqliteIndexDAO.java:178-183`). `delete_task_ids`(DO_WHILE `keepLastN`)는 색인을 지우지 않는다(upstream과 같음).
- **지우기.** upstream 기본 서버와 같다.
  - `archiveWorkflow=true`: upstream은 `indexDAO.updateWorkflow(..., "archived")`(SQLite에서 아무 일도 안 함)만 부르므로 색인 행이
    남는다. 그 뒤 `search`는 지운 워크플로우의 요약을 계속 돌려주고, `-v2`는 다시 읽기에 실패해 빼고 `totalHits`를 줄인다.
  - `archiveWorkflow=false`: upstream은 비동기로 워크플로우 행과 지울 때의 `workflow.getTasks()` 태스크 행·로그를 지운다
    (`ExecutionDAOFacade.java:443-444, 627-628`, `SqliteIndexDAO.java:345-355, 370-385`). archon은 같은 트랜잭션에서 지운다.
    `keepLastN`으로 이미 지운 태스크의 색인 행은 남는다(upstream과 같음).
  - 그래서 `Store.remove_workflow/1`이 archive 여부를 받도록 바뀐다(`remove_workflow/2`, `WorkflowServer`의 호출 자리 포함).
- **기존 데이터(BOSS 2026-11-04 결정: 시계 비교 없이 한 번만).** 마이그레이션은 표와 완료 표시용 작은 표만 만든다. 요약은 앱
  코드(결정 3)가 만들어야 하므로 `Archon.Release.backfill_search_index/0`이 채운다. 이 함수는 릴리스의 마이그레이션 단계(`Archon.Release.migrate/0`
  바로 뒤, 앱이 워크플로우를 처리하기 전)에서 한 번 돌고, 끝나면 완료 표시를 남긴다. 완료 표시가 있으면 아무것도 하지 않는다. 그때
  저장소에 있는 행은 모두 배포 전 행이므로 시각을 비교하지 않고 모든 워크플로우와 태스크를 `create_time`·ID 순 배치로
  `ON CONFLICT DO NOTHING`으로 채운다(중단되면 완료 표시가 없으니 다시 돌려 이어서 채운다). 배포 전 태스크는 처음 저장 뒤 갱신됐는지
  알 수 없으므로 모두 채운다(백필 한 번의 차이). 부르는 자리(릴리스 절차, `docs/operations.md`)는 8c가 정해 적는다. 백필은
  마이그레이션처럼 앱 기동 전 릴리스 작업이라 노드 펜스를 거치지 않는다.
- **비용.** 색인은 요약 JSON(입력·출력 포함)을 한 번 더 저장하므로 쓰기량이 늘어난다. upstream 기본 서버와 같은 비용이며 받아들인다.
  비동기 색인 설정(`asyncIndexingEnabled`)은 옮기지 않는다.

### 3. 요약 모델

- `Archon.Domain.WorkflowSummary`와 `Archon.Domain.TaskSummary`를 upstream 생성자(`new WorkflowSummary(WorkflowModel)`,
  `new TaskSummary(TaskModel)`)대로 만든다. 필드 순서는 upstream Jackson 직렬화 순서다. upstream getter로 직렬화되는 파생 값도
  포함한다(`inputSize`·`outputSize`는 Java `String.length()`, 곧 UTF-16 단위 길이).
- 시각은 `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`(GMT) 글자. `WorkflowSummary`의 `startTime`은 `createTime`, `endTime`은 0보다 클 때만,
  `executionTime`은 끝 − 시작. `TaskSummary`의 시각은 0이어도 epoch 글자로 찍는다. `queueWaitTime`은 upstream `Task` 계산을 따르되
  현재 시각은 Step의 `now`다(결정 2).
- `input`·`output`은 upstream 기본 설정(`summary-input-output-json-serialization.enabled=false`)처럼 Java `Map.toString()` 글자다
  (`{a=1, b=[x, y], c={d=e}}`). 기존 `Archon.Decider.Parameters.java_string/1`을 쓴다. 맵의 키 순서는 archon이 JSON 키 순서를
  보존하지 않으므로([ADR 0002](0002-domain-model-representation.md)) `java_string/1`처럼 정렬 순이다([ADR 0014](0014-phase2-decider.md)
  결정 4). upstream은 입력 순서(LinkedHashMap)라 키가 여럿이면 글자가 다를 수 있다(의도적 차이). `failedTaskNames`(집합)도 정렬 순이다.
- `classifier`는 upstream `WorkflowClassifier.classifierOf(정의 metadata)`대로(metadata의 `classifier`, 에이전트 표지면 `agent`, 아니면
  `workflow`). `failedReferenceTaskNames`(쉼표로 이은 글자, 기본 `""`), `parentWorkflowId`(기본 `""`) 등 기본값도 upstream 그대로다.
- 요약 JSON 인코딩은 응답과 `json_data`가 같은 함수를 쓴다.

### 4. 질의 파서와 실행(BOSS 결정: freeText는 기본 SQLite 서버와 같게)

- `Archon.Search.Query`가 `query`·`freeText`·`sort`를 맥락 절의 문법대로 구문 트리(절 목록, freeText, 정렬 목록)로 바꾼다. 순수
  모듈이고 두 저장소가 같이 쓴다. `SqliteIndexQueryBuilder`의 세부를 그대로 옮긴다: camelCase → snake_case, `,`로 나눈 뒤 공백을
  자르지 않음과 Java `split`의 끝 빈 항목 버림, `_time` 값 변환이 허용 목록 검사보다 먼저이고 첫 값만 변환(숫자가 아니면 오류. 둘째부터의 값은 upstream에서 변환되지 않은 글자라
  UTC 시각 글자와 맞지 않으므로 archon도 그 값을 맞지 않는 값으로 다룬다),
  모르는 필드의 절과 잘못된 정렬 항목은 버림.
- **오류.** 잘못된 절(`IllegalArgumentException`), 숫자가 아닌 시각 값(`NumberFormatException`), 허용 목록에 있지만 그 표에 없는
  필드·정렬 필드(upstream SQLite의 SQL 오류)의 HTTP 상태와 문구는 8a 캡처가 정답이고 그대로 맞춘다.
- Postgres는 구문 트리를 매개변수 SQL로 바꾼다(값은 모두 바인드, 필드·정렬 이름은 허용 목록에서만 나와 SQL 주입이 없다).
  메모리 저장소는 같은 트리를 Elixir로 평가한다.
- **freeText.** 비었거나 `*`가 아니면 요약 JSON 글자의 대소문자 무시 부분 문자열(`lower(json_data) LIKE '%' || lower(?) || '%' ESCAPE ''`).
  upstream SQLite처럼 `%`·`_`는 와일드카드로 두고, SQLite LIKE에 없는 이스케이프 문자를 Postgres에서도 끈다(`ESCAPE ''`, json_data에
  많은 `\`가 글자 그대로 맞게). SQLite `lower()`는 ASCII만 바꾸고 Postgres `lower()`는 유니코드를 바꾼다(의도적 차이).
- `=`의 `*` 와일드카드도 대소문자 무시 LIKE(SQLite와 같음, 같은 `ESCAPE ''`).
- **순서.** upstream SQLite는 `ORDER BY`가 없거나 동점일 때 실행 계획에 따라 순서가 정해진다(ID만 고르는 `-v2`는 기본 키 순, 요약을
  고르면 rowid 순, `IN`은 값별, 인덱스 열 정렬의 동점은 rowid 역순 등). archon은 계획에 기대지 않고 `ORDER BY <sort 항목>, seq`로
  정한다(정렬이 없으면 `seq`, 처음 색인한 순서). NULL의 자리는 SQLite와 같게 `ASC`는 `NULLS FIRST`, `DESC`는 `NULLS LAST`다(Postgres
  기본값의 반대, 메모리 평가도 같다). 정해지지 않은 순서는 의도적 차이로 두고, 8a 시나리오는 그 순서에 기대지 않게
  짠다(유일한 정렬 키, 결과 하나, 또는 재생의 `unordered: true`).
- **페이징.** `LIMIT size OFFSET start`. upstream SQLite처럼 음수 `size`는 제한 없음, 음수 `start`는 0으로 다룬다(Postgres는 음수를
  오류로 내므로 바꿔 넣는다). `totalHits`는 같은 조건의 개수.

### 5. 서비스 경로

`Archon.Runtime`에 검색 함수를 두고 컨트롤러는 그것만 부른다(Phase 5·6의 경계).

- `search`: 색인의 요약 JSON 글자를 그대로 결과 원소로 돌려준다(다시 직렬화하지 않음).
- `search-v2`: 색인에서 ID만 찾고 `Runtime.get_workflow(id, false)`로 각 워크플로우를 읽어, 못 읽은 것은 빼고 `totalHits`에서 뺀다.
  upstream 병렬 스트림의 `collect`는 만난 순서를 지키므로 결과 순서는 색인 순서다.
- `search-by-tasks`: 태스크 색인에서 요약을 찾고 각 `workflowId`의 워크플로우를 읽어 `WorkflowSummary`를 새로 만든다. 중복을 지우고
  `totalHits`에서 못 읽은 수와 중복으로 줄어든 수를 뺀다(`ExecutionService.java:524-551`). `-v2`는 태스크 ID로 태스크를 다시 읽은
  뒤 같은 일을 하고 `Workflow`를 돌려준다.
- `tasks/search`·`-v2`: 태스크 색인. `-v2`는 태스크 조회로 다시 읽는다.
- `bulk/search`: 색인 없이 ID마다 워크플로우를 읽어 `BulkResponse<WorkflowModel>`로 돌려준다. upstream은 `workflowExecutor.getWorkflow`의
  `WorkflowModel`을 직렬화하므로 `Workflow`와 모양이 다르다(`previousStatus` 등 내부 필드, `failed*`의 NON_EMPTY, 태스크는 `TaskModel`).
  8e가 `WorkflowModel`·`TaskModel` 모양 인코더를 만들고 골든 픽스처로 맞춘다. 지금 문자열만 담는 `BulkResponse`와 태스크만 담는
  `SearchResult`는 8e가 원소 타입을 받게 일반화한다.

### 6. task 실행 로그

- **쓰기 경로 셋(upstream과 같음).**
  1. 태스크 갱신의 `TaskResult.logs`: `Archon.Runtime.Tasks.update/1` → `WorkflowServer` → `Step`(`step/tasks.ex`)이 갱신 커밋의 새
     `Commit` 필드 `task_logs`에 담아 같은 트랜잭션에서 넣는다. 각 로그의 `taskId`는 갱신한 태스크로 채우고, 한 번에
     `task_exec_log_size_limit`(기본 10, `config :archon, Archon.Runtime`)개까지만 앞에서부터 남긴다. upstream은 `null` 원소에서 태스크를
     저장한 뒤 NPE(500)를 내지만, archon은 `null` 원소를 버린다(의도적 차이).
  2. 하위 워크플로우의 restart·retry·rerun: upstream `updateAndPushParents(workflow, op)`는 부모의 SUB_WORKFLOW 태스크에
     `"Sub workflow <이름.버전/ID[ -> ...]> <restarted|retried|reran>."` 로그를 쓴다(`WorkflowExecutorOps.java:313-353`, rerun은
     `:2343, 2346, 2399, 2532`). 부모가 이 글을 쓰려면 동작(`restarted`·`retried`·`reran`)과 위로 이어지는 하위 워크플로우 식별자 사슬이
     필요하다. archon은 그 정보를 전달 경로에 싣는다.
     - restart·retry: 되살림 효과 `{:revive_parent, parent_id, parent_task_id}`(outbox에 저장)와 이벤트 `{:child_revived, task_id}`에
       동작과 사슬을 더한다(`{:revive_parent, parent_id, parent_task_id, op, chain}` 등). 이미 저장된 옛 3-튜플은 동작·사슬 없음으로
       읽고 그때는 로그를 쓰지 않는다(옛 outbox 항목의 호환).
     - rerun: 위로 전하는 `Lifecycle.rerun_parent/2`의 요청에 사슬을 넣는다.
     - 부모는 그 이벤트·요청을 처리하는 커밋의 `task_logs`에 글을 넣는다. 글자는 8a 캡처가 정답이다.
  3. `POST /api/tasks/{taskId}/log`: 워크플로우 프로세스를 거치지 않고 `Archon.Runtime.Tasks`의 로그 함수가 저장소에 바로 쓴다
     (로그는 워크플로우 상태가 아니지만, ADR 0021 결정 7대로 Postgres 쓰기 트랜잭션은 모두 노드 펜스를 거치므로 이 쓰기도 커밋과 같은 펜스
     확인을 한다. 펜스에 걸리면 기존 오류 경로처럼 500이다). `createdTime`은 지금. upstream처럼 태스크가 있는지
     확인하지 않는다.
- **POST body.** upstream `@RequestBody String`은 Content-Type과 상관없이 body 글자를 그대로 받는다(JSON 문자열이면 따옴표째).
  archon도 Content-Type을 보지 않고 body 글자를 그대로 저장한다. 한도는 기존 `ArchonWeb.Request`의 8MB이고, 텍스트를 읽는 함수를
  `request.ex`에 더한다. 빈 body의 상태는 8a 캡처를 따른다. Content-Type을 보지 않으므로 브라우저의 교차 출처 단순 요청이 닿는다.
  그래서 ADR 0025의 `refuse_cross_origin`(`Sec-Fetch-Site`·`Origin` 거절, 지금 `WorkflowLifecycleController`의 private 함수)을 공용
  plug로 옮겨 이 액션에 붙인다(ADR 0023 결정 3, ADR 0025 의도적 차이와
  같은 기준). 임의 태스크 ID로 로그를 쌓을 수 있는 것은 upstream과 같은 신뢰 모델이고 인증 ADR(ADR 0024 결정 4)이 다룬다.
- **읽기.** `GET`은 `created_time`, `log_id` 순 목록, 없으면 204 body 없음.
- 로그 API는 `Archon.Runtime.Tasks`에 둔다(8e의 `Archon.Runtime` 검색 함수와 나뉜다). 로그는 결정 2의 지우기 규칙으로 태스크 색인
  행과 함께 지워진다.

### 7. 골든 픽스처와 재생(8a가 한 번에 캡처)

- 8a가 이 Phase의 시나리오 전부를 `scripts/contract/capture_fixtures.sh` 끝에 더하고 upstream 서버에서 기존 픽스처와 함께 다시
  캡처한다(ADR 0025 결정 7, ADR 0026 결정 8과 같음). 다른 조각은 스크립트·픽스처·등록을 고치지 않는다.
- 기존 시나리오에서 이 Phase가 여는 경로를 Archon의 404로 기대하던 단계(`contract_case.ex`의 `route_later_workflow_search`,
  `route_later_tasks_search`, `route_later_workflow_bulk_search`, `route_later_task_log`)는 8a가 걸러진 새 시나리오로 바꾸거나 지운다
  (지금 픽스처는 걸러지지 않은 캡처 DB 전체의 결과다).
- 결과가 캡처 DB의 다른 워크플로우에 흔들리지 않게, 질의는 이 섹션이 만든 고유 워크플로우 이름(`p8_*`)과 상관 ID로 거른다.
- 시나리오에 최소한 다음을 넣는다.
  - 각 경로의 성공, `size`·`start` 페이징과 음수, `sort`의 ASC·DESC·여러 항목·잘못된 항목·표에 없는 필드, `freeText`의 부분 문자열·
    대소문자·`%`·`\`
  - 질의: `=`, `IN`(하나·여럿), `>`·`<`(시각), 숫자가 아닌 시각, `*` 와일드카드, 모르는 필드, 잘못된 절, 표에 없는 허용 필드,
    `classifier`, `topLevelOnly`
  - 태스크 색인 시점: 예약만 된 worker 태스크와 폴링된 태스크, 첫 태스크가 동기 시스템 태스크인 워크플로우, SWITCH·FORK, skiptask,
    `extendLease`
  - remove(`archiveWorkflow` 참·거짓, 거짓은 비동기라 대기) 뒤의 `search`·`-v2`·태스크 검색·로그 GET
  - `TaskResult.logs` 11개 갱신(상한 10), `POST` 로그(`text/plain`, `application/json` 문자열, 빈 body), 없는 태스크의 `POST`·`GET`,
    로그 없는 GET 204, 자식 retry·restart·rerun 뒤 부모 SUB_WORKFLOW 태스크의 로그
  - `size` 5001(workflow search), bulk/search 빈 목록·1001개·섞인 결과·`includeTasks=false`
  - 요약의 `input`·`output` Java 표기(키 하나짜리 중첩 맵·목록·수·`null`, 키 여럿은 정렬 순과 같게), 시각 글자, `failed*`,
    `inputSize`·`outputSize`, `classifier`
- 시각 글자(요약의 `startTime`, `queueWaitTime` 등)는 재생 때 다시 맞출 수 없으므로 `normalize/1`에 요약 시각 키를 더하거나 `ignore`로
  적는다.
- **아직 구현하지 않은 액션의 재생.** ADR 0025 결정 7의 장치(컨트롤러의 미구현 목록, 재생의 건너뛰기, 단계 옵션 `requires:`)를
  다시 쓴다. 장치는 조각 6a(`c39f066`, sensibile/archon#68)가 만들고 6h(`5c2355f`, #77)가 지웠으니 그 diff로 되살린다. 8a가 컨트롤러
  골격·목록·`requires:`를 만들고, 각 조각은 자기 액션을 목록에서 빼면 단계가 켜진다. 8f가 장치를 없앤다.

### 8. 구현 조각

| 조각 | 범위 | 시험·정답 기준 | 선행 | 건드리는 파일·모듈 |
|---|---|---|---|---|
| 8a | 결정 7의 캡처 전부, 기존 `route_later_*` 단계 교체, 라우터(9개), 컨트롤러 골격·미구현 목록·`requires:` 건너뛰기, 픽스처 등록, 요약 시각 정규화 | 기존 픽스처 재캡처 비교, 라우터 시험(`route_info/4`), 건너뛰기를 뺀 전체 재생 | 없음 | `scripts/contract/capture_fixtures.sh`, `test/fixtures/contract/*`, `test/fixtures/contract/README.md`, `test/support/contract.ex`, `test/support/archon_web/contract_case.ex`, `test/archon_web/contract_case_test.exs`, `test/archon/contract_test.exs`, `test/archon/domain/contract_round_trip_test.exs`, `lib/archon_web/router.ex`, `lib/archon_web/controllers/{search,task_log}_controller.ex`(골격), `lib/archon_web/controllers/workflow_bulk_controller.ex`(bulk/search 골격만), `test/archon_web/router_test.exs` |
| 8b | 결정 3·4의 순수 모듈: `WorkflowSummary`·`TaskSummary`, `Archon.Search.Query`(파서, 메모리 평가, SQL 조각 생성) | upstream `SqliteIndexQueryBuilder` 사례, JDK 프로브(시각 형식, `String.length()`), 단위 시험 | 없음 | `lib/archon/domain/{workflow_summary,task_summary}.ex`, `lib/archon/search/*`, 해당 시험 |
| 8c | 결정 2: `Commit`의 `index_workflow`·`index_tasks`와 Step이 채우는 자리, 색인 마이그레이션, `Archon.Release.backfill_search_index/0`, `Store.commit/2`의 색인 쓰기(두 백엔드), `remove_workflow/2`와 지우기 규칙, 저장소 검색 콜백 | 저장소 계약 시험(두 백엔드), 색인 시점 시험(동기 첫 태스크, skiptask, extendLease), `update_time` 가드·remove·백필 시험 | 8b | `lib/archon/runtime/commit.ex`, `lib/archon/runtime/step/*`(`State.save_task`·워크플로우 저장을 부르는 자리 전부의 색인 표시), `lib/archon/runtime/workflow_server.ex`(remove 호출, 커밋 `empty?/1`의 새 필드), `lib/archon/release.ex`, `priv/repo/migrations/*`(새 파일), `lib/archon/runtime/store.ex`, `lib/archon/runtime/store/{memory,postgres}.ex`, `test/support/runtime/store_contract.ex`, 해당 시험 |
| 8d | 결정 6: `Commit`의 `task_logs`, 쓰기 경로 셋(되살림 효과·이벤트·rerun 요청의 동작과 사슬, 옛 outbox 항목 호환), 로그 저장소 콜백, `Request`의 텍스트 읽기, `POST`·`GET` 로그 액션과 공용 `refuse_cross_origin` plug | 로그 픽스처 재생, 상한·204·지우기·되살림 로그(restart·retry·rerun, 옛 outbox 항목)·교차 출처 시험(두 백엔드) | 8a, 8c | `lib/archon/runtime/commit.ex`, `lib/archon/runtime/tasks.ex`, `lib/archon/runtime/lifecycle.ex`, `lib/archon/runtime/step.ex`, `lib/archon/runtime/step/{tasks,state,lifecycle,effect}.ex`, `lib/archon/runtime/{outbox,sub_workflows,workflow_server}.ex`(커밋 `empty?/1`의 `task_logs` 포함), `lib/archon/runtime/store.ex`·`store/{memory,postgres}.ex`(로그 콜백 절, 효과 인코딩 절), `test/support/runtime/store_contract.ex`, `lib/archon_web/request.ex`, `lib/archon_web/plugs/refuse_cross_origin.ex`(새), `lib/archon_web/controllers/{task_log,workflow_lifecycle}_controller.ex`, 해당 시험 |
| 8e | 결정 1·5: 검색 여섯 액션과 bulk/search, `Archon.Runtime`의 검색 함수, `SearchResult`·`BulkResponse` 일반화, `WorkflowModel`·`TaskModel` 인코더 | 검색 픽스처 재생(두 백엔드), 쿼리 매개변수·5000·1000 검증 시험 | 8a, 8c | `lib/archon/runtime.ex`(검색 함수), `lib/archon/domain/{search_result,bulk_response}.ex`, `lib/archon/domain/workflow_model_json.ex`(새), `lib/archon_web/controllers/search_controller.ex`, `lib/archon_web/controllers/workflow_bulk_controller.ex`(bulk/search 액션), 해당 시험 |
| 8f | 통합: 건너뛰기 장치 제거와 전체 재생(두 백엔드), 빠진 픽스처, README 호환성 절, ADR 0001 분류("Phase 8"), 이 ADR `승인` | `mix test` 전부(두 백엔드), CI | 8d, 8e | `test/support/archon_web/contract_case.ex`, `test/archon_web/contract_case_test.exs`, 각 컨트롤러의 미구현 목록, `README.md`, `docs/adr/{0001,0003,0027,README}.md` |

- **병렬로 진행할 수 있는 묶음.**
  - 1차: 8a ∥ 8b(시험·라우터·골격 대 순수 lib 모듈, 파일이 겹치지 않는다).
  - 2차: 8c(8b의 요약·파서를 쓴다).
  - 3차: 8d ∥ 8e. 8d는 `Commit`·Step·저장소 로그 콜백·`Runtime.Tasks`·로그 컨트롤러, 8e는 `Archon.Runtime`·도메인 결과 모델·검색
    컨트롤러로 나뉜다. 8e가 `BulkResponse`를 일반화하고 8d는 그 파일을 고치지 않는다.
  - 마지막: 8f.
- 각 조각은 자기 컨트롤러 액션만 미구현 목록에서 빼면 단계가 켜지므로 `contract_case.ex`를 고칠 필요가 없다. 구현하다 자기 단계의
  옵션(`ignore` 등)을 더 고쳐야 할 때만 그 단계 줄을 고친다(ADR 0025 결정 8과 같음). 3차의 8d·8e가 이 파일의 서로 다른 줄을 고치는
  것은 위 파일 분리의 예외다. 떨어진 줄이면 `gh pr update-branch`로 합쳐지고, 붙은 줄이면 손으로 합친다. 어느 쪽이든 AGENTS.md
  4번 절차(auto-merge 끄기, 새 head 재리뷰, 다시 켜기)를 따른다.
- 각 조각은 이 ADR의 결정 번호와 조각 이름을 PR에 적는다. 조각 중에 결정이 바뀌면 이 ADR의 해당 결정 끝에 "조각 8x에서 정한
  것(날짜)"으로 적는다. ADR이 "캡처가 정답"이라 한 세부는 조각이 캡처대로 맞추고 그 사실만 적는다.

## upstream과 의도적으로 다른 점

ADR 0023·0025·0026의 목록에 더해 다음이 생긴다.

- **색인 시각 열**(결정 2): epoch 밀리초 `bigint`. upstream SQLite는 UTC 글자다. 질의 결과는 같다.
- **정해지지 않은 순서**(결정 4): archon은 `ORDER BY <sort>, seq`로 늘 정해진 순서다. upstream SQLite는 실행 계획에 따른다.
- **`lower()`의 범위**(결정 4): Postgres는 비ASCII도 대소문자를 무시한다. upstream SQLite는 ASCII만.
- **요약 `input`·`output`의 맵 키 순서와 `failedTaskNames`·`failedReferenceTaskNames` 순서**(결정 3): 정렬 순. upstream은 입력 순서·
  `HashSet` 순서다.
- **`agentHierarchy` 정렬**(결정 1): 옮기지 않는다(AI 에이전트 계층, ADR 0001 Unsupported의 AI 컨트롤러와 같은 범위).
- **`TaskResult.logs`의 `null` 원소**(결정 6): 버린다. upstream은 태스크를 저장한 뒤 500이다.
- **비동기 색인과 요약 JSON 직렬화 설정**(결정 2·3): 옮기지 않는다. upstream 기본값의 동작만 있다.
- **archiveWorkflow=false의 색인 삭제 시점**(결정 2): 같은 트랜잭션. upstream은 비동기다.
- **백필한 태스크 색인**(결정 2): 배포 전부터 있던 태스크는 갱신 여부와 상관없이 모두 색인한다.
- **POST 로그의 교차 출처 거절**(결정 6): 브라우저가 교차 출처로 표시한 요청은 403. 두 헤더를 보내지 않는 클라이언트는 upstream과 같다.
  상속 위험: HTTP 포트에 닿는 브라우저 밖 클라이언트는 임의 태스크 ID에 요청마다 8MB까지 로그를 쌓을 수 있다(upstream과 같은 신뢰
  모델, ADR 0024 결정 4). 8f가 README 배포 절에 적는다(포트를 외부에 열면 인증하는 역프록시 뒤에 둘 것).

## 대안

- **다른 주제:** 스케줄러(upstream 기본 켜짐), 이벤트 핸들러, 인증을 먼저 할 수 있었다. UI 목록 화면과 로그 패널이 가장 넓게 쓰이고
  새 백엔드가 필요 없어 BOSS가 검색을 골랐다.
- **기존 표에 열을 더해 질의:** 표가 늘지 않지만 freeText가 요약 JSON 글자를 보므로 요약을 질의 때마다 만들어야 하고, 태스크의
  색인 시점(upstream `updateTask`만)과 remove 뒤 남는 색인(upstream 결과)을 낼 수 없다.
- **저장소가 요약을 만들기:** `Commit`이 가벼워지지만 저장소는 시각을 찍지 않고(`queueWaitTime`) 어느 태스크 저장이 upstream의
  `updateTask`인지 모른다. Step이 만든다.
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
- `Archon.Runtime.Commit`에 `index_workflow`·`index_tasks`·`task_logs`가 더해지고(ADR 0021 결정 3의 커밋 단위), `Store.remove_workflow`가
  archive 여부를 받는다.
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
