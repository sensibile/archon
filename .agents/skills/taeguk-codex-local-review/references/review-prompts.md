# Review prompts

Build the prompt file in this order: the target line, the purpose context, one focus below (cleanup necessity and test adequacy are combined with cross review), the prior adjudications when this is a rerun, then any area the assigner named. Keep it to what the reviewer needs; do not paste secrets.

## Target

Use exactly one line, with the recorded SHAs:

```text
Review only the changes shown by `git diff <base_sha>...<head_sha>`.
Review only the changes introduced by commit <sha> (`git show <sha>`).
Review only the uncommitted changes: `git diff HEAD` and the untracked files listed by `git status --short`.
```

## Purpose context

Required for every focus. Codex sees the diff and the read-only repository, not the request, so without this it judges the change against generic practice instead of what the change is for. Fill purpose, requirements, expected-value source and out-of-scope items from the work contract, the approved requirements and the decision records, never from the implementation itself; fill reachability from observed callers and entry points with their paths. Write "none" when a field does not apply. Point to files by repository path so Codex can read them.

```text
Purpose context (from the assigner; challenge it if you think it is wrong):
- Purpose: <the purpose hypothesis this change serves, one or two sentences>
- Requirements: <approved requirement IDs with their text or file path, plan version>
- Expected-value source: <what defines correct behavior, for example an
  upstream implementation and its tests, a spec, or a contract; with paths>
- Out of scope here: <behavior deliberately left to later work, each with the
  decision record that defers it, for example an ADR and phase>
- Reachability and trust: <entry points that can reach the changed code now,
  who controls its inputs, and what is not wired yet; observed by the
  assigner, so verify it>

Judge the change against this context. Do not report a difference from generic
practice as a defect when the expected-value source requires that behavior, or
a missing feature that is listed as out of scope here; report it only when the
change contradicts the context or harms something the context does not cover.
List any security defect, or any defect you would rate P0 or P1, even when the
expected-value source or a deferral explains it, under "Inherited or deferred
risks" with the source or decision it matches.
If you think the purpose, expected-value source or a deferral is itself wrong,
report that separately under "Purpose challenges" with your reasoning.
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
required, a concrete exploit scenario and the impact. Base the attacker
capability on the reachability and trust in the purpose context; when a path
is not reachable yet, say what wiring would expose it. Mark findings you could
not confirm from the code as uncertain. Do not modify files.
```

## Cleanup necessity

Use with the cross review focus for `$taeguk-daily-cleanup` runs.

```text
This change is a set of cleanup items, each listed below with its evidence.
For each item, answer whether it is needed now: needed, not needed, or not
enough evidence, with the reason. Mark any item that changes behavior, a
contract, a public interface, dependencies or CI workflows as not cleanup.
Do not suggest further cleanup beyond the listed items. Do not modify files.
```

## Test adequacy

Use with the cross review focus for `$taeguk-test-gap` reinforce runs.

```text
This change adds tests, each listed below with the gap it closes, the
requirement or contract it cites as the expected value, and the fault that
makes it fail. For each test, answer whether it is needed now: needed, not
needed, or not enough evidence, with the reason. Mark a test as not needed
when its expected value comes from the current implementation rather than the
cited source, when it would still pass with the cited behavior broken, or when
it changes product code. Do not suggest further tests beyond the listed ones.
Do not modify files.
```

## Prior adjudications

Add on a rerun for the same PR or worker run, listing every earlier Codex finding that was not fixed, with the reviewed head SHA, its status and the reason. Name in the reason the callers, entry points or sources it relies on. Fixed findings need no entry; the new diff shows them. Worker items removed after Codex judged them unneeded are not findings and need no entry.

```text
Earlier rounds on this change produced these findings, already assessed:
- <head_sha> <file:line> <claim, one line> -> <status>: <reason>
  (status: rejected, deferred, pending reproduction, or pending BOSS)
Entries marked rejected or deferred are settled: do not report them again
unless you have evidence the reason does not hold (new code, a counterexample,
or a source the reason missed); then say which entry you are reopening and why.
Entries marked pending are still open; report any new evidence on them.
```
