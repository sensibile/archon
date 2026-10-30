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

Use a read-only sandbox, no saved session, and keep both the prompt file and the final message as evidence outside the reviewed tree:

```sh
codex exec review -c 'model="gpt-6-sol"' -c 'model_reasoning_effort="high"' -c 'sandbox_mode="read-only"' --ephemeral -o "$OUT" - < "$PROMPT"
```

On 2026-10-29 BOSS set cross and security reviews to `gpt-6-sol` with `high` effort for cost, replacing the 2026-10-28 `gpt-6-astra`/`medium` pin. The pin lives in this command, not in the role TOML, so roles keep inheriting the session model. Record the model and effort with the result; a run without them does not follow this procedure.

In codex-cli 0.164.0 the target flags `--base`, `--commit` and `--uncommitted` cannot be combined with a custom prompt (exit 2, observed 2026-10-28). So state the target inside the prompt file as the exact `git diff` command for the SHAs above, followed by the purpose context, the focus and, on a rerun, the prior adjudications, in the order given in [review prompts](references/review-prompts.md). Run it in the foreground or as a tracked background command and keep its exit code.

## After running

- Confirm HEAD, `git status --short` and the content fingerprint are unchanged. A change made during the review is a FAIL of the review run; report it and do not keep the edits silently. A change from another writer means the result belongs to an older version; rerun on the new one.
- Record command, CLI version, target SHAs, exit code, prompt path and its `shasum -a 256`, output path, start and end time, and put the prompt hash in the PR body or worker run report. Without the prompt it cannot be checked later what purpose Codex was given.
- Exit 0 with no findings means "Codex reported no findings for this target". It is not PASS for correctness or security. A non-zero exit, timeout or empty output is NOT_RUN or UNKNOWN.
- Report each finding with location, Codex's claim, severity and your assessment: reproduced, plausible, rejected with reason, or needs reproduction. Send claims needing execution to `taeguk_tool_verifier`.
- A finding matches a prior adjudication only when it makes the same claim, `git diff <adjudicated_head>..<head> -- <file>` shows no change near the cited lines, and nothing the recorded reason relied on changed either (callers, routes, entry points or sources the reason names; check them with the same diff); record it as a repeat of that entry. A reason that relies on reachability or a source without naming them does not match. Otherwise, or when Codex says it is reopening an entry, assess it again. This matching test only decides whether to skip reassessment: for VER-005 any recurrence of the same claim counts, recorded as a repeat or reassessed, so its escalation to BOSS applies unchanged.
- Assess findings Codex lists as inherited or deferred risks like other findings; matching the expected-value source or a deferral does not by itself reject them. When a confirmed one can only be fixed by departing from the expected-value source or a deferral, treat it as a purpose challenge.
- Report purpose challenges separately. They question the purpose, expected-value source or a deferral, which only BOSS can change, so do not reject them yourself; pass them to BOSS with your view. An item Codex filed there that does not question the purpose, expected-value source or a deferral may be moved to the ordinary findings with the reason recorded. Until BOSS answers, do not enable auto-merge on that head; a worker run drops the affected item and reports the challenge.
- When the target changes, rerun on the new range. Do not reuse a result from an older head.

Agreement between Codex and another model is supporting analysis, not independent execution evidence. When Codex also implemented the change, state that this was not a cross-model review.
