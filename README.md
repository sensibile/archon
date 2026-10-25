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

Pull requests from branches of this repository get squash auto-merge enabled when opened. They
merge once the required checks pass, including `codex-review`, which turns green only after Codex
has reviewed the latest commit with no unresolved findings. After pushing new commits, comment
`@codex review` to request a fresh review.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Archon is derived from [Conductor OSS](https://github.com/conductor-oss/conductor)
(Copyright Conductor Authors). "Conductor" is used here only to describe compatibility;
Archon is not affiliated with or endorsed by the Conductor project or Netflix.
