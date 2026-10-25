# Archon

[![CI](https://github.com/sensibile/archon/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/sensibile/archon/actions/workflows/ci.yml)

A Conductor-compatible workflow orchestration engine in Elixir, running each workflow as a
supervised OTP process with durable state and API-level compatibility with existing workers and SDKs.

> Status: early development. Nothing is usable yet.

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

## Development

```bash
mix deps.get
mix test
mix credo --strict
mix dialyzer
mix deps.audit
```

CI runs the same checks. Credo findings are also uploaded to GitHub code scanning.

The `codex-review` required status turns green only after Codex has reviewed the head commit with
no unresolved findings. When new commits arrive after an earlier review, the gate workflow comments
`@codex review` once per head. Once `codex-review` succeeds, the workflow enables squash auto-merge
bound to that reviewed commit; GitHub merges when the other required checks pass and review threads
are resolved. Draft pull requests and those labeled `no-auto-merge` are left alone. See
[ADR 0008](docs/adr/0008-codex-review-gate-hardening.md).

If Codex gives no verdict for the head, a scheduled run asks again every 10 minutes. After three
unanswered requests the gate passes `codex-review` when Codex has no unresolved review threads
([ADR 0009](docs/adr/0009-codex-review-time-rule.md)).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Archon is derived from [Conductor OSS](https://github.com/conductor-oss/conductor)
(Copyright Conductor Authors). "Conductor" is used here only to describe compatibility;
Archon is not affiliated with or endorsed by the Conductor project or Netflix.
