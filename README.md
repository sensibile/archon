# Archon

[![CI](https://github.com/sensibile/archon/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/sensibile/archon/actions/workflows/ci.yml)

A Conductor-compatible workflow orchestration engine in Elixir, running each workflow as a
supervised OTP process with durable state and API-level compatibility with existing workers and SDKs.

> Status: early development. The REST routes listed below (19 MVP routes and 33 workflow operations
> routes) and the task types listed below run on an in-memory or PostgreSQL backend; everything else
> is not implemented yet.

## Goals

- Keep the Conductor REST API and JSON schemas (`WorkflowDef`, `TaskDef`, `Workflow`, `Task`)
  so existing workers, SDKs, and the UI keep working.
- Run each workflow instance as a supervised OTP process instead of relying on sweeper polling.
- Start with PostgreSQL for persistence and queues; add other backends later.

## API contract

The upstream contract Archon targets is pinned in [`priv/contract/`](priv/contract/README.md)
(JSON schemas and an OpenAPI snapshot) and in golden fixtures captured from a live upstream server
([`test/fixtures/contract/`](test/fixtures/contract/README.md)). Which endpoints are in scope is
decided in [ADR 0001](docs/adr/0001-api-contract-scope.md).

Design and operations decisions are recorded in [`docs/adr/`](docs/adr/README.md).
Agent working rules are in [AGENTS.md](AGENTS.md).

## REST 호환성

Phase 5는 [ADR 0001](docs/adr/0001-api-contract-scope.md)의 MVP 경로를 upstream과 같은 경로, 쿼리 매개변수,
JSON 필드, 상태 코드, 오류 body로 제공한다([ADR 0023](docs/adr/0023-phase5-rest.md)). 모든 골든 픽스처를 캡처 순서대로
두 백엔드에서 Archon에 재생한다(`test/archon_web/contract_replay_test.exs`).

| 영역 | 경로 |
|---|---|
| Health | `GET /health`, `GET /api/health` |
| Metadata | `POST`, `PUT /api/metadata/workflow`, `GET /api/metadata/workflow/{name}`, `POST`, `PUT`, `GET /api/metadata/taskdefs`, `GET /api/metadata/taskdefs/{tasktype}` |
| Workflow | `POST /api/workflow`, `POST /api/workflow/{name}`, `GET /api/workflow/{workflowId}`, `GET /api/workflow/{workflowId}/status`, `DELETE /api/workflow/{workflowId}` |
| Task | `GET /api/tasks/poll/{tasktype}`, `GET /api/tasks/poll/batch/{tasktype}`, `POST /api/tasks`, `POST /api/tasks/update-v2`, `GET /api/tasks/{taskId}` |

Phase 6은 워크플로우 운영 경로 33개를 같은 방식으로 더했다([ADR 0025](docs/adr/0025-phase6-workflow-operations-rest.md)).

| 영역 | 경로 |
|---|---|
| 생명주기 | `PUT /api/workflow/{workflowId}/pause`, `.../resume`, `POST .../retry`, `.../restart`, `.../rerun`, `PUT .../skiptask/{taskReferenceName}`, `POST .../resetcallbacks` |
| 정리 | `DELETE /api/workflow/{workflowId}/remove`, `.../terminate-remove` |
| 조회 | `GET /api/workflow/{workflowId}/tasks`, `GET /api/workflow/{name}/correlated/{correlationId}`, `POST /api/workflow/{name}/correlated`, `GET /api/workflow/running/{name}` |
| 동기 실행 | `POST /api/workflow/execute/{name}/{version}` |
| ref 갱신·signal | `POST /api/tasks/{workflowId}/{taskRefName}/{status}`, `.../sync`, `POST /api/tasks/{workflowId}/{status}/signal`, `.../signal/sync` |
| Metadata | `GET /api/metadata/workflow`, `.../names-and-versions`, `.../names`, `.../latest-versions`, `.../{name}/versions`, `DELETE /api/metadata/workflow/{name}/{version}`, `DELETE /api/metadata/taskdefs/{tasktype}`, `POST /api/metadata/workflow/validate` |
| Bulk | `PUT /api/workflow/bulk/pause`, `.../resume`, `POST .../restart`, `.../retry`, `.../terminate`, `DELETE .../remove`, `.../terminate-remove` |

Phase 7은 MVP 밖 시스템 태스크 타입 12개를 열었다([ADR 0026](docs/adr/0026-phase7-system-task-types.md)). 새 REST 경로는
없고, 새 타입은 기존 경로의 정의·워크플로우·태스크 JSON 안에서 보인다. 픽스처 재생은 이 타입들의 시나리오도 모두 돈다.

| 분류 | 태스크 타입 |
|---|---|
| MVP | `SIMPLE`, `SWITCH`, `DECISION`, `FORK_JOIN`, `JOIN`, `DO_WHILE`, `SUB_WORKFLOW`, `WAIT` |
| 엔진 없는 동기 타입 | `TERMINATE`, `SET_VARIABLE`, `NOOP`, `HUMAN`, `EXCLUSIVE_JOIN` |
| 동적 매핑 | `DYNAMIC`, `FORK_JOIN_DYNAMIC` |
| 스크립트(QuickJS-ng) | `INLINE`(`javascript`, `graaljs`, `value-param`), `LAMBDA` |
| jq(jqlang) | `JSON_JQ_TRANSFORM` |
| 비동기 | `START_WORKFLOW`, `HTTP` |
| Later | `EVENT`, `KAFKA_PUBLISH`, `PULL_WORKFLOW_MESSAGES` 등. 지금처럼 이름이 같은 태스크 정의의 워커 태스크로 다룬다 |

upstream과 의도적으로 다른 점(전체 목록은 ADR 0023, ADR 0025, ADR 0026의 "upstream과 의도적으로 다른 점"):

- 구현하지 않은 경로는 Later 경로를 포함해 모두 upstream이 없는 경로에 주는 404 body로 답한다. 있는 경로에 다른 메서드로
  보내도 upstream의 405가 아니라 404이고, `OPTIONS`도 404다.
- 인라인, 외부 참조, 이름 없는 JSON 스키마를 강제하는 정의는 400으로 거절한다. Archon에는 아직 스키마 검증기가 없다.
  이름 참조는 upstream처럼 받는다.
- 태스크 갱신의 worker `subWorkflowId`는 반영하지 않는다([ADR 0024](docs/adr/0024-worker-input-trust-and-auth.md)).
- Jackson 파싱 오류와 예상하지 못한 500의 문구는 Archon 문구다. 8 MB를 넘는 요청 body는 413이다.
  `GET /api/metadata/taskdefs`는 이름순이다.
- remove와 terminate-remove는 그 워크플로우가 다른 워크플로우에 남긴 일(자식 종료, 부모 알림)이 전달된 뒤에만 지운다. 10초 안에
  끝나지 않으면 아무것도 지우지 않고 500 `retryable` 참으로 답한다. bulk remove·terminate-remove는 ID마다 이 대기를 한다.
- body를 읽지 않는 retry·restart·resetcallbacks는 브라우저가 교차 출처로 표시한 요청(`Sec-Fetch-Site`, 없으면 `Origin`과
  `Host`)을 403으로 거절한다. SDK·curl처럼 그 헤더를 보내지 않는 클라이언트는 upstream과 같다.
- `resumeSubworkflowTasks` retry가 실행 중인 자식에 닿으면 404다(upstream은 그 자식을 재시도한다). skiptask는 쿼리로
  `taskInput`·`taskOutput`을 채우는 Spring 바인딩을 옮기지 않는다. remove는 보관본을 남기지 않는다(upstream 기본 서버와 같은 응답).
- correlated, `running/{name}`, `latest-versions` 목록은 정해진 순서다. `validate`는 Archon이 거절하는 스키마 정의를 등록 전에
  400으로 알려 준다. bulk의 소수 ID는 부동소수 글자로 바뀐다. task 실행 로그(`/api/tasks/{taskId}/log`)는 Later다.

Phase 7 태스크 타입(ADR 0026):

- `START_WORKFLOW`·`HTTP`는 타입 이름의 큐를 거치지 않고 워크플로우 프로세스가 바로 시작해 결과를 이벤트로 받는다. 큐 크기 조회에
  나타나지 않는다. `START_WORKFLOW`는 태스크로 정해지는 ID로 멱등 시작하고 복구가 바로 다시 시작한다. 검증 위반 여럿은 경로
  순으로 잇고, 변환 실패 문구는 Archon 문구다. 같은 밀리초의 제자리 rerun은 `scheduledTime`이 1ms 늦다.
- upstream에서 예외가 결정이나 요청 밖으로 새는 입력은 Archon이 예외 없이 처리한다. 문자열이 아닌 `TERMINATE`
  `terminationStatus`(정의 검사를 거치지 않은 태스크)는 태스크 `FAILED`, `INLINE` `evaluatorType`·`expression`은 시작 200과 태스크
  `FAILED`(upstream은 시작 500), 실행되지 않은 ref가 있는 `EXCLUSIVE_JOIN`의 permissive 실패는 `COMPLETED` 뒤 워크플로우
  `FAILED`(upstream은 NPE로 멈춤), 동적 포크 rerun의 매핑 종료와 끝없는 동적 포크 매핑은 워크플로우 종료다. `FORK_JOIN_DYNAMIC`의
  문자열이 아닌 간단 형태 필드는 글자로 읽고 `forkTaskInputs`의 `null` 원소는 `{"input": null}` 가지로 만들며, 옛 형태의 변환
  실패는 워크플로우 종료다.
- 한 FORK 안에서 같은 ref를 만드는 동적 포크는 종료한다(upstream은 하나를 버린다).
- DO_WHILE 반복의 첫 `DYNAMIC`은 정의 변경을 저장된 `workflowDefinition`에 반영하지 않는다. `FORK_JOIN_DYNAMIC` 오류 문구의 예외
  메시지는 Archon 문구다.
- `INLINE`의 `python` 평가기와 시스템 태스크 입력의 비밀 값 치환이 없다. 평가기 풀이 받지 못한 요청은 재시도 가능한 `FAILED`다.
  `HUMAN`은 결정 큐를 쓰지 않는다(결과 상태는 같다).
- jq 엔진은 jackson-jq가 아니라 jqlang이다. jqlang에만 있는 함수·문법이 결과를 내고, 수학 함수의 정수 결과는 정수, 산술은
  double, `long` 밖의 정수는 실수, 오류 문구는 jq의 것이다. `import`·`include`는 거절하고 시간(4초)·메모리(64 MiB)·결과
  크기(16 MiB)·깊이(1,000) 상한이 있다.
- `HTTP`: 응답 헤더 이름은 소문자다. 4xx·5xx 문구의 상태 문구는 Spring 표의 것이고 URI 템플릿 확장은 없다. charset은
  ISO-8859-1과 UTF-8만 읽고 쓴다. JSON 값 뒤 군더더기, 수 길이 경계, double 범위 밖의 수는 원문 글자다. 연결 거부 밖의 전송
  오류 원인 문구는 Archon 문구다. 요청마다 전체 시간 상한(60초)이 있고 결과가 더 쓰이지 않는 요청은 끊는다. 응답 body는 10 MiB
  (푼 body와 리다이렉트한 응답 포함)를 넘으면 `FAILED`다. 빈도 한도(`rateLimitPerFrequency`)는 적용하지 않는다. rerun이 다시
  예약하는 HTTP의 `pollCount`는 0이다. HttpClient의 쿠키 저장소와 `User-Agent`는 재현하지 않는다.

**인증 없음.** upstream OSS처럼 MVP REST에는 인증·인가가 없다([ADR 0024](docs/adr/0024-worker-input-trust-and-auth.md) 결정 4).
기본으로 `127.0.0.1:8080`에서 듣고, `ARCHON_HTTP_IP`와 `PORT`로 다른 주소를 연다. 다른 인터페이스에서 듣는 것은 배포의
결정이다. 서버를 사설 네트워크나 인증 프록시 뒤에 둔다.

**HTTP 태스크의 대상 제한 없음(SSRF).** upstream처럼 `HTTP` 태스크는 서버가 닿는 어떤 주소로든 요청한다([ADR 0026](docs/adr/0026-phase7-system-task-types.md)
결정 7). REST 포트에 닿는 호출자는 루프백 서비스나 클라우드 메타데이터 주소를 부르는 정의를 등록하고 그 응답을 태스크 출력으로 읽을
수 있다. 리다이렉트도 같다. 목적지를 제한하지 않고 따라가며, 헤더 없는 `GET`으로 바뀌는 리다이렉트(`GET`·`HEAD`가 아닌
요청의 `303`, `POST`의 `301`·`302`) 밖에는 원래 body와 헤더(`X-API-Key` 같은)를 다른 호스트로도 그대로 보낸다. 그런 리다이렉트에
`Authorization`·`Cookie` 헤더가 있으면 다른 호스트·포트로는 따라가지 않고 태스크가 `FAILED`다. 같은 호스트·포트면 `https`에서 `http`로 바뀌어도 그 자격 헤더를 싣는다. 비밀을
헤더나 body에 넣는 정의는 리다이렉트를 보안 경계로 삼을 수 없다. 응답 body 상한(10 MiB) 안에서도 디코딩한 JSON은 메모리에서 수십 배로 커질 수 있으므로
필요하면 `config :archon, Archon.Runtime.HttpTask, max_response_bytes:`로 낮춘다. 포트를 외부에 열면 인증하는 역프록시 뒤에 두고,
서버가 나가는 요청도 망(방화벽, egress 정책)에서 제한한다.

```bash
mix run --no-halt                      # 127.0.0.1:8080, 메모리 백엔드
ARCHON_HTTP_IP=0.0.0.0 PORT=8081 mix run --no-halt
```

아직 구현하지 않은 것(Later): 검색과 `bulk/search`, task 실행 로그, 이벤트와 `EVENT`·`KAFKA_PUBLISH`·`PULL_WORKFLOW_MESSAGES`
태스크, 외부 payload 저장소, 큐 관리·admin 경로,
JSON 스키마 검증과 `/api/schema`, 인증, 여러 노드 실행. upstream 내부 구조(sweeper, Java 설정)에 기대는 경로는
Unsupported다. ADR 0001을 본다.

## Development

```bash
mix deps.get
mix test
mix credo --strict
mix dialyzer
mix deps.audit
```

CI runs the same checks. Credo findings are also uploaded to GitHub code scanning.

Merging does not wait for a GitHub Codex review gate. Before pushing, the Claude Code session driving
a pull request first reviews the exact range with its own review agent, repeating until the Taeguk
VER-005 end condition holds. It then runs a local Codex cross review (`gpt-6-sol`, `high` effort) and,
for changes that affect runtime behavior, a local security review of the same head; a change made for a
Codex finding restarts the self-review. It then enables squash auto-merge bound to the reviewed commit;
GitHub merges when the required checks (`test`, `credo`, `dialyzer`, `audit`) pass, review threads are
resolved and the branch is up to date. Draft pull requests and those labeled `no-auto-merge` are left
alone. See [ADR 0011](docs/adr/0011-local-review-auto-merge.md) and
[ADR 0016](docs/adr/0016-taeguk-review-order-and-model.md).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Archon is derived from [Conductor OSS](https://github.com/conductor-oss/conductor)
(Copyright Conductor Authors). "Conductor" is used here only to describe compatibility;
Archon is not affiliated with or endorsed by the Conductor project or Netflix.
