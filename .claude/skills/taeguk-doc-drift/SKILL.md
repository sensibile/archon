---
name: taeguk-doc-drift
description: "Find drift between Taeguk documents, skills, rules and the actual repository and schedules: run the mechanical drift scan, compare changed areas semantically, hand document-only drift to the daily cleanup as candidates, and report drift touching rules, approvals, requirements or authority to BOSS; never edit files or open PRs."
---

# taeguk-doc-drift

`check_rules.py` checks only the rule registry and links inside `docs/rules/`. Documents, skills and the operations record elsewhere can go stale while every check passes: a removed script still named, a skill procedure that no longer matches the operations document, a schedule time that differs from the registered task. This run finds such drift and routes it; it fixes nothing itself.

## Authority

On 2026-10-29 BOSS approved this worker with its proposed defaults: weekly, report only, document-only drift handed to the daily cleanup, drift touching rules, approvals, requirements or authority reported to BOSS. BOSS asked for the skill to be written without registering the scheduled task, so until a task is registered it runs only when BOSS starts it. It grants no authority to edit files, open PRs or issues, or decide which side of a rule or approval mismatch is correct.

## Where it runs

The Taeguk repository (`sensibile/taeguk`) only. The scan script lives in this repository and is not part of the installed bundle.

## Run

1. Fetch and record the `origin/main` SHA. Read the latest report under `.taeguk/doc-drift/` in the main checkout (ignored by Git); its `checkpoint` SHA starts the window. Without a report, start at the last `main` commit older than seven days. Work in a detached worktree at the recorded SHA under `taeguk-worktrees/`.
2. Run `python3 scripts/check_doc_drift.py`. Each finding is a candidate: confirm it by reading the line. A `rule_version` finding that cites an older version on purpose (a history or approval record) is dropped with that reason.
3. Compare semantically only the areas touched in the window (`git diff --name-only <checkpoint>...<sha>`) against the documents that describe them:
   - `docs/repository-operations.md` and `codex/skills/taeguk-work-contract/references/phases.md` against each periodic worker skill and against the registered scheduled tasks (task list, cron and the prompt's skill name), read without changing them;
   - `docs/installation.md` and `docs/codex-installation.md` against `scripts/taeguk_install.py`, `scripts/install_codex.py` and `installer/`;
   - AGENTS.md validation commands against `.github/workflows/rules.yml` and the validation-health skill;
   - skills that cite a rule ID and version against `docs/rules/registry.toml`.
   Mark each semantic finding as LLM judgment with the two locations and the exact differing statements.
4. Classify every confirmed finding:
   - **Document drift**: the document misdescribes something whose truth is the code, the installer, a registered schedule or another document that is not a rule. Write it as a cleanup candidate with its evidence.
   - **Rule or authority drift**: the mismatch involves a rule body, the registry, an approval, a requirement, a threshold or execution authority, or the code may be what is wrong. Do not name a fix; report both sides to BOSS.
5. Carry over the previous report's `## 정리 후보` items that no later daily cleanup report records as delivered or rejected: confirm each is still present at the recorded SHA, keep it with its original date, and drop it with the reason when the drift is gone. Semantic findings outside this window's changed areas would otherwise be lost, because the daily cleanup reads only the newest report and may skip collection while its own PR is open.
6. Remove the worktree and write the report to `.taeguk/doc-drift/<date>.md`: SHA, window, scan status, each finding with kind, locations, evidence, classification and whether it is tool or LLM judgment, dropped findings with reasons, and a `## 정리 후보` section listing only the document drift items, new and carried over. Set `checkpoint` to the SHA when every finding was classified or dropped; otherwise keep the previous checkpoint.

## Handoff to the daily cleanup

The daily cleanup reads the `## 정리 후보` section of the latest `.taeguk/doc-drift/` report as one of its candidate sources and derives the evidence again from the repository before acting, the same as for PR candidates. This run never opens the cleanup PR itself.

## Report

Tell BOSS in Korean: the SHA and window, how many findings were handed to the cleanup, every rule or authority drift with both sides quoted, and dropped findings. A run with no findings says so; it is not PASS for document accuracy. A run that could not scan is NOT_RUN with the cause.
