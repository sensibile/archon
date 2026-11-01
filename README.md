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

## REST compatibility

Phase 5 serves the MVP routes of [ADR 0001](docs/adr/0001-api-contract-scope.md) with the same paths,
query parameters, JSON fields, status codes and error bodies as upstream
([ADR 0023](docs/adr/0023-phase5-rest.md)). Every golden fixture is replayed against Archon in capture
order on both backends (`test/archon_web/contract_replay_test.exs`).

| Area | Routes |
|---|---|
| Health | `GET /health`, `GET /api/health` |
| Metadata | `POST`, `PUT /api/metadata/workflow`, `GET /api/metadata/workflow/{name}`, `POST`, `PUT`, `GET /api/metadata/taskdefs`, `GET /api/metadata/taskdefs/{tasktype}` |
| Workflow | `POST /api/workflow`, `POST /api/workflow/{name}`, `GET /api/workflow/{workflowId}`, `GET /api/workflow/{workflowId}/status`, `DELETE /api/workflow/{workflowId}` |
| Task | `GET /api/tasks/poll/{tasktype}`, `GET /api/tasks/poll/batch/{tasktype}`, `POST /api/tasks`, `POST /api/tasks/update-v2`, `GET /api/tasks/{taskId}` |

Deliberate differences from upstream (the full list is in ADR 0023, "upstream과 의도적으로 다른 점"):

- Every route outside the MVP, Later routes included, answers upstream's 404 body for a missing
  path. A known path with another method is also a 404, not upstream's 405, and `OPTIONS` is a 404.
- A definition that enforces an inline, external or nameless JSON schema is refused with a 400:
  Archon has no schema validator yet. Name references are accepted, as upstream does.
- A worker's `subWorkflowId` in a task update is not applied
  ([ADR 0024](docs/adr/0024-worker-input-trust-and-auth.md)).
- Messages of Jackson parse errors and of unexpected 500s are Archon's own; request bodies over 8 MB
  are a 413; `GET /api/metadata/taskdefs` is ordered by name.

**No authentication.** Like upstream OSS, the MVP REST API has no authentication or authorization
([ADR 0024](docs/adr/0024-worker-input-trust-and-auth.md), decision 4). It listens on
`127.0.0.1:8080` by default; `ARCHON_HTTP_IP` and `PORT` open another address. Listening on another
interface is a deployment decision: put the server behind a private network or an authenticating
proxy.

```bash
mix run --no-halt                      # 127.0.0.1:8080, in-memory backend
ARCHON_HTTP_IP=0.0.0.0 PORT=8081 mix run --no-halt
```

Not implemented yet (Later): lifecycle routes (pause, resume, retry, restart), search, events,
the other metadata and admin routes, JSON schema validation and `/api/schema`, authentication,
running on several nodes. Routes that depend on upstream internals (sweeper, Java configuration)
are Unsupported; see ADR 0001.

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
