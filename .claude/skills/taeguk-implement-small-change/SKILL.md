---
name: taeguk-implement-small-change
description: "Implement an agreed single-intent change with behavior preservation and executable evidence; use after scope and oracle are established."
---

# taeguk-implement-small-change

Apply the repository worktree instructions. Preserve unrelated changes. Compare the smallest adequate fix with keeping current behavior. Write the relevant regression check and patch. Run checks on the exact artifact, including affected integration and failure boundaries. Return a patch/evidence packet. Do not expand to a framework or silently adjust criteria.

For work using a verifier plan, record its exact version alongside the design and starting artifact. Implement against the plan's approved oracle and expected results; do not derive or relax criteria to fit the patch. If a planned check misstates the real boundary, return evidence, affected requirement/check IDs and impact for verifier correction. Record implementation checks and repairs by those IDs, then hand the exact final artifact version to tool and LLM reviewers. Your own checks do not replace their conclusions.

Read [evidence packet](references/evidence-packet.md) when exchanging results or resuming work. Apply within the user's existing scope and authority; this skill does not authorize external effects or criteria changes.

For a repair, hand off the diff and affected check IDs with new evidence instead of repeating the full design or plan. Record running command handles; coordinate shared test resources using the re-verification reference in /taeguk-plan-cross-verification.
