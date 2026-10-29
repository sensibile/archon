---
name: taeguk-validation-health
description: "Run the full AGENTS.md validation on the latest origin/main every day without any code change, record each suite's status with toolchain versions and durations, rerun failures once to separate deterministic failures from suspected flaky tests, and report to BOSS; never edit code, open PRs or change test settings."
---

# taeguk-validation-health

CI runs only on push and pull request, so `main` gets no validation on a day without changes. The scheduled workers validate with this Mac's local toolchain, which can change under unchanged code. This run checks once a day, before the daily cleanup, whether `main` still passes here and whether any test fails intermittently.

## Authority

On 2026-10-29 BOSS approved this worker with its proposed defaults: a daily local scheduled run before the daily cleanup, report only. It grants no authority to change code, tests, test settings, toolchains or CI, to open PRs or issues, or to message anyone outside the session report. It does not gate the cleanup or test-gap workers. Delivery documents and their authority are unchanged.

## Where it runs

The Taeguk repository (`sensibile/taeguk`) only. An installed project runs it only when that project records a BOSS authorization for this worker (its schedule and report location); its own AGENTS.md validation commands and `.taeguk/validation-health/` replace the Taeguk ones named below.

## Run

1. Fetch and record the `origin/main` SHA. Create a detached worktree at that SHA under `taeguk-worktrees/` so the main checkout and other workers' worktrees stay untouched.
2. Record the toolchain: `python3 --version`, `rustc --version`, `cargo --version`, `elixir --version` (Elixir and OTP), and the OS version. Compare with the latest report under `.taeguk/validation-health/` in the main checkout (ignored by Git) and mark every version that changed.
3. Run each validation suite from AGENTS.md separately, recording its exit status, duration and the tail of its output:
   - `python3 scripts/check_rules.py`
   - `python3 -m unittest discover -s tests -v`
   - `cargo test --manifest-path tools/taeguk-cli/Cargo.toml --locked`
   - in `apps/taeguk`: `mix deps.get`, `mix format --check-formatted`, then the DB-backed `mix test` with `TAEGUK_REQUIRE_STATE_TESTS=1`, a fresh `TAEGUK_DATABASE_PATH` in a temporary directory whose file name ends in `-test.sqlite3` (the state tests refuse other names), and a locally generated throwaway `TAEGUK_API_TOKEN`, after `mix ecto.migrate` on that database (see `docs/workflow-state-usage.md`). Never point it at `.taeguk/state.sqlite3` or another existing database. A plain `mix test` skips state tests and is not PASS.
   - the system skill-creator validator on every `codex/skills/taeguk-*` skill.
4. Rerun each failing suite once on the same SHA and toolchain. Fails again: deterministic FAIL. Passes on rerun: suspected flaky; name the failing tests from the first run. Rerun only the suite, never with retries added or tests excluded.
5. A suite that could not start (missing tool, failed dependency fetch, no network) is NOT_RUN with the cause, not FAIL and not PASS. A suite whose result cannot be read is UNKNOWN.
6. Remove the worktree and every temporary database and token file.
7. Write the report to `.taeguk/validation-health/<date>.md`: SHA, toolchain with changes marked, each suite's status, duration and duration change against the previous report, rerun results, suspected flaky tests with how many past reports also listed them, and failure output tails. Write no secret or token value.

## Judgment

- A deterministic FAIL on unchanged `main` with a changed toolchain points to the environment; without a toolchain change it points to the code, a date or time dependency, or an external service. Say which evidence supports it; do not guess a fix.
- A test listed as suspected flaky in two or more reports is reported as a flaky candidate with those dates. Fixing it is ordinary work that needs its own task.
- Durations are trend evidence only. Report a suite that took more than twice its median over past reports; set no threshold that fails the run.
- Do not edit code, tests, lockfiles or toolchains to make a suite pass.

## Report

Tell BOSS in Korean: the SHA, each suite's status as PASS, FAIL, UNKNOWN, NOT_RUN or NOT_APPLICABLE, toolchain changes, deterministic failures with evidence, flaky candidates, and notable duration changes. All PASS is reported as "validation on this SHA and toolchain passed today", not as code quality. A run that could not start is NOT_RUN with the cause, never a silent skip.
