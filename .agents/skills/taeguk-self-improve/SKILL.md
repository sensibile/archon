---
name: taeguk-self-improve
description: "Carry an observed Taeguk workflow problem through a bounded repair, verification, authorized application and measured effect; use when self-improvement is requested."
---

# taeguk-self-improve

Use a concrete retrospective signal, not a speculative list of improvements. Separate product defects from Taeguk defects and select one Taeguk problem with raw evidence and a reproducible baseline. Work only within the user's assigned scope. Rule meaning, thresholds, exceptions and execution authority changes remain proposals until BOSS confirms them. Do not alter an oracle to make a candidate pass.

Read [cycle contract](references/cycle.md) to register the cycle through `taeguk state create/command/get/history`. The API must be running with a dedicated project database and local token. It records evidence and gates progress; it does not call models, execute a patch, approve rules or establish the truth of a report. If unavailable, report that the persistent loop has not run rather than claiming completion from prose alone.

1. Connect the problem to user burden and preserve source, baseline version, reproduction, effect oracle, observation conditions and rollback reference. Fix the verification and effect checks before implementation. Register one improvement work item and record `baseline` only after the reproduction is observed. PASS here means the baseline was successfully characterized, not that the original product was correct.
2. Apply the project's worktree workflow. Make a single-intent repair using `taeguk-implement-small-change`. Record the candidate's exact artifact/environment with `retarget`. Execute the designated verification checks and register their observations. Reuse unaffected evidence only with an explicit reason. Record `verified` when these checks pass.
3. Apply the verified version within existing authorization and preserve delivery/installation evidence. Record `applied` only after that effect is observed. A candidate running in a test fixture alone is not production application. Keep local and production claims distinct.
4. Repeat the original effect measurement on the applied version, using comparable inputs and observation conditions. Collect a fresh effect observation after application; do not reuse the baseline or candidate result as the effect. Distinguish a tool-detectable improvement from measured human burden or Mission value. Register PASS/FAIL/UNKNOWN honestly, then record `evaluated` with the corresponding status.
5. If verification or effect fails, investigate and repair the same bounded problem with affected checks. If reverting, actually restore the referenced baseline, retarget to it and verify restoration; registration itself does not revert files or processes. Preserve failed attempts. Keep unresolved effect open; complete only with current passing verification and confirmed effect.

Report the source problem, before/after evidence, exact version, application scope, unresolved effects and next action. A successful cycle is not automatic permission to update other projects or the common Taeguk baseline. Commonization needs evidence that the change transfers to their conditions.
