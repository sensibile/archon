# Archon

[![CI](https://github.com/sensibile/archon/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/sensibile/archon/actions/workflows/ci.yml)

A Conductor-compatible workflow orchestration engine in Elixir, running each workflow as a
supervised OTP process with durable state and API-level compatibility with existing workers and SDKs.

> Status: early development. The MVP REST API (19 routes, below) runs on an in-memory or PostgreSQL
> backend; everything else is not implemented yet.

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

upstream과 의도적으로 다른 점(전체 목록은 ADR 0023과 ADR 0025의 "upstream과 의도적으로 다른 점"):

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
- `resumeSubworkflowTasks` retry가 실행 중인 자식에 닿으면 404다(upstream은 그 자식을 재시도한다). rerun은 MVP 밖 태스크
  타입인 동적 FORK 분기를 옮기지 않는다. skiptask는 쿼리로
  `taskInput`·`taskOutput`을 채우는 Spring 바인딩을 옮기지 않는다. remove는 보관본을 남기지 않는다(upstream 기본 서버와 같은 응답).
- correlated, `running/{name}`, `latest-versions` 목록은 정해진 순서다. `validate`는 Archon이 거절하는 스키마 정의를 등록 전에
  400으로 알려 준다. bulk의 소수 ID는 부동소수 글자로 바뀐다. task 실행 로그(`/api/tasks/{taskId}/log`)는 Later다.

**인증 없음.** upstream OSS처럼 MVP REST에는 인증·인가가 없다([ADR 0024](docs/adr/0024-worker-input-trust-and-auth.md) 결정 4).
기본으로 `127.0.0.1:8080`에서 듣고, `ARCHON_HTTP_IP`와 `PORT`로 다른 주소를 연다. 다른 인터페이스에서 듣는 것은 배포의
결정이다. 서버를 사설 네트워크나 인증 프록시 뒤에 둔다.

```bash
mix run --no-halt                      # 127.0.0.1:8080, 메모리 백엔드
ARCHON_HTTP_IP=0.0.0.0 PORT=8081 mix run --no-halt
```

아직 구현하지 않은 것(Later): 검색과 `bulk/search`, task 실행 로그, 이벤트, 외부 payload 저장소, 큐 관리·admin 경로,
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
