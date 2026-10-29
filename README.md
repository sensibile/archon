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
