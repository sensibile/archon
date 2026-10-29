---
name: taeguk-test-gap
description: "Find untested behavior by using coverage as a measuring instrument, classify each gap against approved requirements, and either report test proposals (report mode) or add up to three fault-checked tests that Codex agrees are needed through the PR flow (reinforce mode, daily); never raise coverage as a goal."
---

# taeguk-test-gap

Coverage shows which code no test executed. It does not show whether a test checks the right thing, and a coverage number set as a target invites tests that execute code without checking behavior. This run uses coverage only to locate gaps, then judges each gap against approved requirements.

## Authority

On 2026-10-29 BOSS approved two modes:

- **Report mode**: BOSS starts the run; it writes a report and nothing else. The only edit is the temporary fault injection in step 6, which BOSS confirmed the same day. Nothing is committed.
- **Reinforce mode**: runs daily after the daily cleanup, like the cleanup worker. It adds at most three tests per run, only for confirmed requirement-linked gaps, and carries the tests Codex agrees are needed through the PR flow to merge. It changes test code only. Product code changes, test deletions, threshold changes and fixes for defects it finds are reported to BOSS, never made.

## Where it runs

The Taeguk repository (`sensibile/taeguk`), and an installed project only when that project records a BOSS authorization for this worker: its schedule, its merge authority, and standing authority to send diffs to Codex for review. On 2026-10-29 BOSS chose archon (`sensibile/archon`) as the first such project; other pilot projects need the Codex transmission authority extended first. Without a recorded authorization, a run in an installed project is report mode at most, and without Codex transmission authority reinforce mode stops before review as NOT_RUN. In an installed project, its own AGENTS.md validation commands, worktree rules, delivery document and test locations replace the Taeguk ones named below, and its run reports go under its own `.taeguk/test-gap/`.

## Coverage is not a target

- Do not state a coverage percentage as a result, goal, threshold or improvement. Report gaps, not ratios.
- A gap is worth a test only when a defect there would break an approved requirement, a public contract or a safety boundary. Executing a line is never the reason.
- The expected value of a proposed test comes from a requirement, contract, rule or BOSS answer, never from what the code currently returns. A gap whose expected behavior has no such source is a question, not a test.
- A proposed test must name the fault that would make it fail. A test that would still pass with the behavior broken does not close the gap.
- When reading the code suggests the current behavior contradicts its requirement, report a suspected defect. Do not propose a test that pins the current behavior.

## Measurement

Measure every language the project tests. Record each measurement's command, base SHA, tool version and status (VER-003). A missing tool or failed run is NOT_RUN or FAIL for that language, never "no gaps". Keep raw output outside the checkout, under `.taeguk/test-gap/<date>/` in the main checkout (ignored by Git).

| Language | Command | Known threats (MET-001) |
|---|---|---|
| Python | `coverage run --rcfile=<rc> -m unittest discover -s tests`, then `coverage combine --rcfile=<rc>` and `coverage report --rcfile=<rc> -m` | Write one rc file outside the checkout with `branch = True`, `parallel = True`, `source` listing `scripts` and every `codex/skills/*/scripts` (otherwise skill scripts vanish from the denominator) and `data_file` in the run directory. Tests run scripts in subprocesses, which read only the rc file, not the parent's command-line options: point `COVERAGE_PROCESS_START` at the rc file and put a `sitecustomize.py` calling `coverage.process_startup()` on `PYTHONPATH`. Umask tests leave data files with mode 000; make them readable before combining and record the combined, skipped and errored counts |
| Rust | `cargo llvm-cov --manifest-path tools/taeguk-cli/Cargo.toml --locked`, then `cargo llvm-cov report --manifest-path tools/taeguk-cli/Cargo.toml --show-missing-lines` for locations and `--json` for unexecuted functions (needs `llvm-tools-preview`) | The default output is a per-file summary without locations. Line and region counts differ; report uncovered functions and lines, not the region ratio |
| Elixir | DB-backed `mix test --cover` in `apps/taeguk` with `TAEGUK_REQUIRE_STATE_TESTS=1` (see `docs/workflow-state-usage.md`) | Without the state DB, state tests skip and their modules look untested; a plain run is not a measurement. `mix.exs` sets the coverage summary threshold to 0, so the exit code reflects test results only; if a run still fails on a coverage threshold, record the measurement from the cover output and do not treat it as a test failure. Generated modules (`Router.Helpers`, error views) report 0% by construction |

The table is for the Taeguk repository. In an installed project, build the equivalent commands from its validation commands and handle the same threats: every source directory in the denominator, subprocesses followed, required integration suites actually running rather than skipping, and a coverage threshold never turning a passing suite into a failed measurement.

Use an isolated virtual environment for `coverage`, such as `.taeguk/test-gap/venv`; do not install into a shared interpreter. Run every test suite with the same flags as the AGENTS.md validation commands so the measured run is the run that gates delivery.

## Run

1. Fetch and record the `origin/main` SHA. Read the latest run report under `.taeguk/test-gap/` in the main checkout for its rejected and questioned gaps. Measure in a clean detached worktree at that SHA under `taeguk-worktrees/` (in an installed project, its worktree location), never in the main checkout or another task's worktree; its temporary fault-injection edits are measurement edits under DEV-003, not development edits. In reinforce mode, first check for an open PR labeled `test-gap`; never open a second one. Resume it only when a local run report records its number and head SHA, it was opened by this account, and its commits match that report or later reports; otherwise report it to BOSS and stop. To resume, disable auto-merge, update the branch if it is behind `main`, then apply steps 10 to 12 to every test in the full current range on the new head. Fault results from an earlier head may be reused only when the test and the product code it covers are unchanged since then; record that reason (REQ-006). Write the report with the checkpoint unchanged and stop.
2. Run the measurements above and record their statuses and threats observed in this run.
3. Group uncovered lines, branches and functions into gaps by enclosing function or clause. Read the code and the tests around each gap; an uncovered line inside a function whose behavior a test already checks through another path is still a gap only if a distinct behavior is unchecked.
4. Classify each gap:
   - **requirement-linked**: a requirement, rule, contract document or installation guarantee states what must happen. Cite it.
   - **no caller**: a search shows nothing reaches it. Record the search as evidence; it becomes a daily cleanup candidate, not a test.
   - **expected behavior unknown**: no source states what it should do. Put the question to BOSS.
   - **environment-bound**: reaching it needs a condition the test environment cannot create safely (real home directory, network, signals across sessions). Record the condition and whether a fake or fixture could create it.
   - **measurement artifact**: the code runs in a test the tool could not follow. Show the test that runs it.
5. For each requirement-linked gap, write a proposal: the oracle source, the input or state, the expected observation, the fault to inject (the edit that would break the behavior) and the expected test failure. Rank proposals by the consequence of a defect there, such as overwriting unowned files, lost workflow state, an authorization bypass or a false PASS, not by line count.
6. Confirm the top proposals: inject the fault in the measurement worktree, run the suite that covers it with the validation flags, record the result, then restore the file and check `git status` is clean. The suite must pass on the unmodified tree first, and the mutant must build and run. The suite still passing confirms the gap. Only a test assertion failing on the mutant shows that another test already guards the behavior; then reclassify the gap as a measurement artifact and name that test. A build error, crash or environment failure on the mutant is UNKNOWN for that gap, not detection. This is a source edit in a local test run, not operational fault injection; it is never committed.
7. Report mode stops here and writes the report (step 13).

Reinforce mode continues:

8. Pick at most three confirmed gaps from the top of the ranking. Skip a gap an earlier run recorded as rejected by Codex or waiting for a BOSS answer, unless there is new evidence or the answer arrived.
9. Create a worktree and a `test/test-gap-<date>` branch from the recorded SHA. Write one test per gap, one commit per gap, in the project's test locations (for Rust, the `#[cfg(test)]` module or `tests/`). The expected value comes from the cited source, not from running the code.
10. Check each test: it passes on the unmodified product code, and it fails by assertion when the step 6 fault is injected; restore the fault and confirm `git status` is clean. Separately confirm that the cumulative diff from the recorded SHA touches only test code: test files, and inside a source file only lines within its `#[cfg(test)]` module or equivalent test-only block. A test that fails on unmodified code is a suspected defect: drop the test, keep the product code as it is, and report it with the requirement it contradicts. A test that still passes with the fault does not close the gap; drop it. Then run the validation commands that apply.
11. First run the self-review loop of the project's PR flow step 2 (`docs/repository-operations.md` in Taeguk) on the branch range until VER-005 ends it; drop or fix tests it rejects and record each round. Then ask Codex whether each test is needed: run `/taeguk-codex-local-review` on the branch range with the test adequacy focus from its review prompts together with the cross review focus, and the security review. Remove every test Codex judges unneeded, implementation-derived or not checking the cited requirement, and every test where its judgment is missing or unclear. Record rejections and do not argue them again in the same run. If tests were removed, rerun validation, the self-review loop and the Codex review on the new head.
12. If any test is left, open a PR labeled `test-gap` whose body lists, per test, the gap, the oracle source, the injected fault and its result, and Codex's judgment, and continue with the project's PR flow including auto-merge. Apply VER-005 to review findings.
13. Write the report to `.taeguk/test-gap/<date>.md`: mode, base SHA, measurements with commands, versions, statuses and threats, every gap with its location, classification and evidence, ranked proposals with their fault check results, tests added, dropped or rejected with reasons, PR number and head SHA after every push, questions for BOSS, cleanup candidates, and suspected defects.

## Scope check

Codex judgment and this skill's text do not stop an out-of-scope change from merging. Before every time auto-merge is enabled, on a new PR or a resumed one, run the scope check on the exact range and head that was reviewed. Run the checker as it is at the recorded base commit, copied outside the PR checkout and started with `python3 -I`, so neither a changed checker nor a module the PR adds next to it can run in its place:

```sh
checker="$(mktemp -d)/check_worker_scope.py"
git show <recorded base SHA>:scripts/check_worker_scope.py > "$checker"
python3 -I "$checker" test-gap --base <recorded base SHA> --head <reviewed head SHA>
```

Run it from the PR worktree, which only supplies the Git objects. If the base commit has no checker, the result is UNKNOWN.

Enable auto-merge only on exit 0 with status PASS. On FAIL, drop the rejected tests, rerun validation and the step 11 review on the new head, and check again. On UNKNOWN or any other exit, do not enable auto-merge; report the PR to BOSS. The check covers paths, file modes, binary content and, for Rust sources, edits outside the trailing `#[cfg(test)]` module; it does not judge necessity or correctness. In an installed project, use the scope check its delivery document names; without one, open the PR without auto-merge and report it to BOSS.

## Report

Tell BOSS in Korean what was merged or opened, the top remaining proposals, the questions that block a proposal, suspected defects and which measurements did not run. A stopped run is NOT_RUN or FAIL with its cause, never a silent skip. A run that found no requirement-linked gap says so; that is not PASS for test adequacy, since coverage cannot see an assertion that checks the wrong thing.
