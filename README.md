# Archon

A Conductor-compatible workflow orchestration engine in Elixir, running each workflow as a
supervised OTP process with durable state and API-level compatibility with existing workers and SDKs.

> Status: early development. Nothing is usable yet.

## Goals

- Keep the Conductor REST API and JSON schemas (`WorkflowDef`, `TaskDef`, `Workflow`, `Task`)
  so existing workers, SDKs, and the UI keep working.
- Run each workflow instance as a supervised OTP process instead of relying on sweeper polling.
- Start with PostgreSQL for persistence and queues; add other backends later.

## Development

```bash
mix deps.get
mix test
```

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Archon is derived from [Conductor OSS](https://github.com/conductor-oss/conductor)
(Copyright Conductor Authors). "Conductor" is used here only to describe compatibility;
Archon is not affiliated with or endorsed by the Conductor project or Netflix.
