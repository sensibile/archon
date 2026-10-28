# Review prompts

Start the prompt file with the target, then one focus below (cleanup necessity is combined with cross review), then the request summary, approved requirement IDs, plan version and any area the assigner named. Keep it to what the reviewer needs; do not paste secrets.

## Target

Use exactly one line, with the recorded SHAs:

```text
Review only the changes shown by `git diff <base_sha>...<head_sha>`.
Review only the changes introduced by commit <sha> (`git show <sha>`).
Review only the uncommitted changes: `git diff HEAD` and the untracked files listed by `git status --short`.
```

## Cross review

```text
Review this change as an independent reviewer of work done by another agent.
Report correctness defects, requirement mismatches, missing edge cases, broken
contracts with existing callers, and tests that do not check what they claim.
For each finding give the file and line, the concrete failing input or state,
and the expected versus actual behavior. Do not report style preferences.
Do not modify files.
```

## Security review

```text
Review this change for security defects only. Check injection (shell, SQL,
path), path traversal and symlink handling, authentication and authorization
gaps, secret or token exposure, unsafe deserialization, unsafe defaults,
excessive permissions in CI workflows (including pull_request_target and
token scopes), dependency and supply-chain changes, and trust of untrusted
input. For each finding give the file and line, the attacker capability
required, a concrete exploit scenario and the impact. Mark findings you could
not confirm from the code as uncertain. Do not modify files.
```

## Cleanup necessity

Use with the cross review focus for `/taeguk-daily-cleanup` runs.

```text
This change is a set of cleanup items, each listed below with its evidence.
For each item, answer whether it is needed now: needed, not needed, or not
enough evidence, with the reason. Mark any item that changes behavior, a
contract, a public interface, dependencies or CI workflows as not cleanup.
Do not suggest further cleanup beyond the listed items. Do not modify files.
```
