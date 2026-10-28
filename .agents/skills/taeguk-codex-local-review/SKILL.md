---
name: taeguk-codex-local-review
description: "Run a local Codex CLI review of an exact change range for cross review or security review, and record the output as LLM judgment with its limits; use when a codex reviewer role is assigned."
---

# taeguk-codex-local-review

Run `codex exec review` from the local Codex CLI against one exact target and record what it reported. The output is a model judgment, not tool evidence or approval.

## Authority

Running the CLI sends the diff and repository context to OpenAI. On 2026-10-28 BOSS approved this transmission as standing authority for work in the Taeguk repository (`sensibile/taeguk`), and on 2026-10-29 extended it to the archon repository (`sensibile/archon`). Any other repository, including the other pilot projects, needs explicit BOSS authorization for that task; without it, record the review as NOT_RUN with that reason. This skill grants no other external effect.

## Before running

1. Fix the target as exact SHAs: a range `<base_sha>...<head_sha>` (diff from their merge-base), one commit, or the working tree against HEAD including untracked files. Record the base SHA, head SHA, `git status --short` and a content fingerprint of the working tree, since status and HEAD stay the same when an already modified or untracked file changes again:

   ```sh
   { git diff HEAD --binary; git ls-files -o --exclude-standard -z | xargs -0 shasum -a 256 --; } | shasum -a 256
   ```
2. Read the diff that will be sent. If it contains secrets, credentials, tokens or personal data, do not run; report NOT_RUN and the location without repeating the value.
3. Check `codex --version`. A missing CLI or failed login is NOT_RUN, not a product failure.

## Run

Use a read-only sandbox, no saved session, and save the final message as evidence outside the reviewed tree:

```sh
codex exec review -c 'model="gpt-6-astra"' -c 'model_reasoning_effort="medium"' -c 'sandbox_mode="read-only"' --ephemeral -o "$OUT" - < "$PROMPT"
```

On 2026-10-28 BOSS set cross and security reviews to `gpt-6-astra` with `medium` effort. The pin lives in this command, not in the role TOML, so roles keep inheriting the session model. Record the model and effort with the result; a run without them does not follow this procedure.

In codex-cli 0.164.0 the target flags `--base`, `--commit` and `--uncommitted` cannot be combined with a custom prompt (exit 2, observed 2026-10-28). So state the target inside the prompt file as the exact `git diff` command for the SHAs above, followed by the focus from [review prompts](references/review-prompts.md) and the request, approved requirements and plan version the reviewer needs. Run it in the foreground or as a tracked background command and keep its exit code.

## After running

- Confirm HEAD, `git status --short` and the content fingerprint are unchanged. A change made during the review is a FAIL of the review run; report it and do not keep the edits silently. A change from another writer means the result belongs to an older version; rerun on the new one.
- Record command, CLI version, target SHAs, exit code, output path, start and end time.
- Exit 0 with no findings means "Codex reported no findings for this target". It is not PASS for correctness or security. A non-zero exit, timeout or empty output is NOT_RUN or UNKNOWN.
- Report each finding with location, Codex's claim, severity and your assessment: reproduced, plausible, rejected with reason, or needs reproduction. Send claims needing execution to `taeguk_tool_verifier`.
- When the target changes, rerun on the new range. Do not reuse a result from an older head.

Agreement between Codex and another model is supporting analysis, not independent execution evidence. When Codex also implemented the change, state that this was not a cross-model review.
