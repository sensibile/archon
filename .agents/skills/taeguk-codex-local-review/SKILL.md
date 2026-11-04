---
name: taeguk-codex-local-review
description: "Run a local Codex CLI review of an exact change range for cross review or security review, and record the output as LLM judgment with its limits; use when a codex reviewer role is assigned."
---

# taeguk-codex-local-review

Run `codex exec review` from the local Codex CLI against one exact target and record what it reported. The output is a model judgment, not tool evidence or approval.

## Authority

Running the CLI sends the diff, the prompt and repository context to OpenAI. Whether Codex may run in a repository is set in the Codex CLI's own configuration (login and its settings), not by a repository list in this skill; on 2026-10-30 BOSS removed the earlier list. If the CLI refuses to run in the repository, record the review as NOT_RUN with the CLI's reason. This skill grants no other external effect.

## Before running

1. Confirm the self-review loop has finished for this exact target (head SHA, or the working-tree content fingerprint): the session's own review agent (for example `taeguk_llm_reviewer`, or a review subagent in Claude Code) reviewed the same range repeatedly, with fixes re-reviewed, until the VER-005 end condition held. BOSS set this order on 2026-10-29. If the loop has not ended, do not run Codex; when the VER-005 escalation condition holds, report to BOSS instead.
2. Fix the target as exact SHAs: a range `<base_sha>...<head_sha>` (diff from their merge-base), one commit, or the working tree against HEAD including untracked files. Record the base SHA, head SHA, `git status --short` and a content fingerprint of the working tree, since status and HEAD stay the same when an already modified or untracked file changes again:

   ```sh
   { git diff HEAD --binary; git ls-files -o --exclude-standard -z | xargs -0 shasum -a 256 --; } | shasum -a 256
   ```
3. Read the diff that will be sent. If it contains secrets, credentials, tokens or personal data, do not run; report NOT_RUN and the location without repeating the value.
4. Check `codex --version`. A missing CLI or failed login is NOT_RUN, not a product failure.
5. Write the purpose context from [review prompts](references/review-prompts.md): purpose, requirements, expected-value source, out-of-scope items with their decision records, and reachability. Take purpose, requirements, expected-value source and out-of-scope items from the work contract, approved requirements and decision records, not from the implementation; for a scheduled worker run, the worker skill and the BOSS decision it records are the work contract, and the expected-value source is "no behavior change" for cleanup items and the cited source of each test for test-gap tests. Take reachability from observed callers, routes and entry points with their paths, since decision records rarely state it. Without this context Codex reviews against generic practice and its findings cannot be assessed against what the change is for. If the purpose or expected-value source is not recorded anywhere, do not invent one; ask the assigner, and record the review as NOT_RUN if it stays missing.
6. On a rerun for the same PR or worker run, add the prior adjudications: every earlier Codex finding that was not fixed, with its head SHA, status and reason. Worker items removed after Codex judged them unneeded are not findings and need no entry.
7. Apply the check of step 3 to the finished prompt file as well.

## Run

Use a read-only sandbox, no saved session, and keep the prompt file, the final message and the run record as evidence outside the reviewed tree. Run each review through the [record helper](scripts/review_record.py), which executes exactly this command and writes a JSON record computed from the run (`codex --version`, resolved target SHAs, prompt sha256, exit code, start and end time, HEAD, `git status --short` and the content fingerprint before and after):

```sh
codex exec review -c 'model="gpt-6-sol"' -c 'model_reasoning_effort="high"' -c 'sandbox_mode="read-only"' --ephemeral -o "$OUT" - < "$PROMPT"
```

```sh
python3 <skill-directory>/scripts/review_record.py run --kind cross --target "<base_sha>...<head_sha>" \
  --model gpt-6-sol --effort high --prompt "$PROMPT" --output "$OUT" --record "$RECORD"
```

`--kind` is `cross` or `security`; `--target` is the range, one commit SHA, or `uncommitted`, written exactly as in the prompt's target line; for a range or commit, check out its head first, since Codex also reads the repository (the block warns when HEAD differs); the record flags a prompt whose first line is not that target line. The helper refuses evidence paths inside the reviewed tree, an output or record path that already exists or whose directory is missing, and one file for both. It exits 0 when the run completed, 1 when HEAD, the tree or the target SHAs changed during the review (FAIL), and 2 for NOT_RUN, UNKNOWN or bad input. Run it in the foreground or as a tracked background command.

On 2026-10-29 BOSS set cross and security reviews to `gpt-6-sol` with `high` effort for cost, replacing the 2026-10-28 `gpt-6-astra`/`medium` pin. The pin lives in this command and its `--model`/`--effort` arguments, not in the role TOML, so roles keep inheriting the session model. Record the model and effort with the result; a run without them does not follow this procedure.

In codex-cli 0.164.0 the target flags `--base`, `--commit` and `--uncommitted` cannot be combined with a custom prompt (exit 2, observed 2026-10-28); 0.166.0 still rejects each of them with a prompt at argument parsing, exit 2, before anything is sent (observed 2026-11-04). So state the target inside the prompt file as the exact `git diff` command for the SHAs above, followed by the purpose context, the focus and, on a rerun, the prior adjudications, in the order given in [review prompts](references/review-prompts.md).

## After running

- Confirm HEAD, `git status --short` and the content fingerprint are unchanged. A change made during the review is a FAIL of the review run; report it and do not keep the edits silently. A change from another writer means the result belongs to an older version; rerun on the new one.
- Keep the run record next to the prompt and output; it holds the command, CLI version, target SHAs, exit code, prompt path and sha256, output path and sha256, start and end time. Without the prompt it cannot be checked later what purpose Codex was given.
- Exit 0 with no findings means "Codex reported no findings for this target". It is not PASS for correctness or security. A non-zero exit, timeout or empty output is NOT_RUN or UNKNOWN.
- Report each finding with location, Codex's claim, severity and your assessment: reproduced, plausible, rejected with reason, or needs reproduction. Send claims needing execution to `taeguk_tool_verifier`.
- The next two items apply VER-005 1.1 to work started after its 2026-11-04 approval, and to work already in progress only once that work records adopting 1.1. Other in-progress work keeps VER-005 1.0: P2 or lower findings are fixed or left with a recorded reason, and the 1.0 escalation condition applies.
- Before fixing a confirmed P2 or lower finding, apply the VER-005 1.1 fix test and record the result: fix it only when it breaks the work contract's purpose, approved requirements or acceptance criteria, is a regression this change introduced, or was observed in the target or has a confirmed reach path inside the approved input trust boundary. Otherwise leave it unfixed with that reason, as a follow-up candidate when useful; fixing it anyway widens the purpose, so ask BOSS first. P0 and P1 are not subject to this test.
- Count consecutive Codex rounds on the same work (one round is the cross and security run on one head; self-review rounds are counted separately by the self-review loop) in which at least one finding was to be fixed (P0, P1, or a P2 or lower that passed the fix test), whether the findings differ or came from earlier fixes. After the third such round, stop and report to BOSS with each round's target SHA, findings and handling, the open findings, and the options (stop and record, continue, split the scope); do not start a fourth round until BOSS answers. In a scheduled worker run, drop the affected items and report instead of waiting.
- A finding matches a prior adjudication only when it makes the same claim, `git diff <adjudicated_head>..<head> -- <file>` shows no change near the cited lines, and nothing the recorded reason relied on changed either (callers, routes, entry points or sources the reason names; check them with the same diff); record it as a repeat of that entry. A reason that relies on reachability or a source without naming them does not match. Otherwise, or when Codex says it is reopening an entry, assess it again. This matching test only decides whether to skip reassessment: for VER-005 any recurrence of the same claim counts, recorded as a repeat or reassessed, so its escalation to BOSS applies unchanged.
- Assess findings Codex lists as inherited or deferred risks like other findings; matching the expected-value source or a deferral does not by itself reject them. When a confirmed one can only be fixed by departing from the expected-value source or a deferral, treat it as a purpose challenge.
- Report purpose challenges separately. They question the purpose, expected-value source or a deferral, which only BOSS can change, so do not reject them yourself; pass them to BOSS with your view. An item Codex filed there that does not question the purpose, expected-value source or a deferral may be moved to the ordinary findings with the reason recorded. Until BOSS answers, do not enable auto-merge on that head; a worker run drops the affected item and reports the challenge.
- When the target changes, rerun on the new range. Do not reuse a result from an older head.

## Record

Put the review into the PR body's verification section, or the worker run report, as the block the helper renders. Do not type it by hand or edit its run fields:

```sh
python3 <skill-directory>/scripts/review_record.py render --record "$CROSS_RECORD" --record "$SECURITY_RECORD" \
  --adjudication "$ADJUDICATION" > "$EVIDENCE/review-block.md"
```

The adjudication file is the reviewer's assessment from the steps above, a JSON object keyed by `cross` and `security`:

```json
{"cross": {"run_id": "<run_id from the cross record>", "findings": [], "purpose_challenges": []},
 "security": {"run_id": "<run_id from the security record>",
              "findings": [{"location": "lib/a.ex:12", "severity": "P2", "claim": "...",
                            "assessment": "rejected", "handling": "..."}],
              "purpose_challenges": [{"claim": "...", "view": "...",
                                      "boss_decision": "...", "decided_on": "2026-11-04"}]}}
```

Each kind names the `run_id` of the run record it assesses, copied after reading that run's output; every run gets a new `run_id`, so an entry carried over from another run (an older head, a rerun of the same head) renders as UNKNOWN. `assessment` is `reproduced`, `plausible`, `rejected`, `needs-reproduction` or `repeat` (a match with a prior adjudication). Write `[]` only after reading the output and finding nothing in that list. Leave `boss_decision` out until BOSS answers; the block then says the decision is pending. For a documentation-only change pass `--not-applicable security=<reason>` instead of a security record. A review with no record renders as NOT_RUN; a run that did not complete renders its status and no findings; a version, exit code or time the run did not produce, and a kind missing from the adjudication, render as UNKNOWN. These stay as rendered. Run `scripts/check_pr_text.py` on the body after inserting the block, since claims quote Codex.

Agreement between Codex and another model is supporting analysis, not independent execution evidence. When Codex also implemented the change, state that this was not a cross-model review.
