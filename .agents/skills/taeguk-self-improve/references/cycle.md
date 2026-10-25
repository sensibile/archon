# Improvement cycle contract

Use the installed Rust `taeguk state` client with the project's SQLite API. Preserve the existing token outside files/Git. See the checkout's `docs/workflow-state-usage.md` for ordinary create/observe/reuse/run operations. No extra CLI executable or model runtime is required.

The normal create payload gains optional `improvement`:

```json
{
  "source_ref": "retrospective:commit#observed-problem",
  "problem_ref": "baseline-log:sha256",
  "baseline_ref": "exact-initial-artifact-ref",
  "rollback_ref": "git:exact-baseline-commit",
  "verification_checks": ["V1"],
  "effect_check": "E1"
}
```

All references are nonempty. baseline_ref equals the initial artifact_ref. Verification IDs and the distinct effect ID refer to required checks in the fixed create payload. The effect check accepts only PASS; a non-applicable measurement is not evidence of improvement. Checks can be tool/llm/mixed as justified by their oracle. The API does not decide which oracle is correct.

For each phase write JSON and run `taeguk state command WORK_ID FILE.json`:

```json
{
  "command_id": "fresh-command-uuid",
  "expected_revision": 1,
  "actor": "improver",
  "operation": "improvement",
  "phase": "baseline",
  "status": "PASS",
  "artifact_ref": "current-artifact-ref",
  "environment_ref": "current-environment-ref",
  "plan_ref": "fixed-plan-ref",
  "evidence": [{"location":"raw-result.json","sha256":"actual-lowercase-sha256"}],
  "reason": "what was observed and what remains unknown"
}
```

Read the current revision/context using GET before each new command. Same command ID and identical payload replay the original ACK; use GET for current state. A failure or transport timeout is not a reason to invent a new command ID and blindly rerun a mutation.

- baseline: record the characterized baseline. Non-PASS can be stored, but cannot advance. Runs must first be ended. It can be re-characterized while still targeting the baseline.
- retarget: ordinary command selects the candidate artifact/environment. It invalidates later progress and retains the original baseline event/reference. Verification criteria stay fixed.
- verified: designated verification checks must have acceptable current observations.
- applied: only from verified, after actual authorized application. Existing verification must still pass.
- evaluated: only after applied. The effect check must have a fresh observation revision later than applied, with no reused_from. For mixed checks both layers must be fresh. Status must match the current registered effect. Missing effect is NOT_RUN; FAIL and UNKNOWN remain open and may be reevaluated after new observation.
- complete: requires all required observations and evaluated PASS with current verification/effect. A new failing observation blocks completion even after evaluated PASS.

Stage metadata is stored in work.document.improvement_progress; every accepted mutation has an immutable command event. `taeguk state history WORK_ID AFTER_REVISION` pages 25 events. Retarget resets progress to the original baseline. Inspect context and actually reapply/reobserve before advancing again. There is no automatic rollback, scheduling, candidate selection, patch generation or commonization in the backend. Those are agent actions under the skill and the current user's authorization.
