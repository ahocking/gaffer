---
name: review-change
description: Review changes before merge — either the uncommitted working tree, or a committed branch range (e.g. develop→main before opening/merging a PR). Collect the diff, run build and tests, have the reviewer and architect check it, and output a clear ready/issues/risks/next-step verdict. Use when the user asks to review, sanity-check, or pre-merge-check their working changes or a branch about to be promoted.
argument-hint: (optional base branch/range and/or focus, e.g. "main", "main...develop", "the auth flow")
---

# Review changes $ARGUMENTS

Read-only pre-merge review: do not fix, commit, or merge anything — produce a
verdict the human acts on. The scope is one of two modes; decide from $ARGUMENTS
in step 1.

## 1. Collect the diff (Chief Engineer)
Delegate to the **chief-engineer** agent to gather the change set and pull in the
relevant spec/acceptance criteria or task packet so the review has a contract to
check against. Pick the scope mode from $ARGUMENTS:

- **Branch-range mode** — when $ARGUMENTS names a base branch or an explicit range
  (a ref like `main`, or a range like `main...develop`). This is the **primary
  pre-merge case**, e.g. reviewing `develop` before it is promoted to `main`.
  Resolve it to a committed diff: a bare base ref `<base>` means `git diff
  <base>...HEAD` (the changes the current branch would bring into `<base>`); an
  explicit `A...B` (or `A..B`) is used as given. Run `git log --oneline <base>..HEAD`
  too so the review sees the commit series, not just the net diff. The working tree
  should be clean here; if `git status` shows uncommitted changes, note it — they
  are **not** part of a merge and are out of scope for this review.
- **Working-tree mode** — the default when no base/range is given: run `git status`
  and `git diff` (and `git diff --staged`) to gather all uncommitted changes.

If $ARGUMENTS also names a focus area (beyond a ref/range), prioritize it but still
scan the rest.

## 2. Build and test
Run the project's build and test commands and capture the real output. In
branch-range mode this runs against the head of the range (the branch being
promoted — e.g. `develop`); check it out first if you are not already on it. Report
failures verbatim. (If the commands aren't known, ask the human or infer them from
the repo, but do not run anything that mutates state beyond building/testing.)

## 3. Review (Reviewer)
Delegate to the **reviewer** agent (read-only): check the diff against
acceptance criteria, flag spec↔code drift, and inspect security and correctness —
with extra scrutiny on auth/authz, secrets/PII in code or logs, and the
domain-critical paths declared in `.agents/domain-rules.md` (for a financial
repo, money/balance/portfolio/Plaid logic — rounding, currency, idempotency,
reconciliation).

## 3b. Decay-risk lens (brooks-lint — optional, advisory)
If the **brooks-lint** plugin is installed (the `/brooks-review` skill is
available to you — a repo that opted in has a `.brooks-lint.yaml` at its root),
run `/brooks-review` scoped to the same diff as an additional maintainability
lens. It grades the change against engineering decay risks (cognitive overload,
change propagation, knowledge duplication, accidental complexity, dependency
disorder, domain-model distortion) with cited Symptom→Source→Consequence→Remedy
findings. Fold its findings into the verdict as **advisory** input: dedupe
against the reviewer's findings, keep the reviewer authoritative on security and
correctness, and do **not** auto-apply `/brooks-sweep` fixes — surface them for
the human. If brooks-lint is not installed, skip this step silently (do not treat
its absence as a failure).

## 4. Design check (Architect)
Delegate to the **architect** agent: confirm the change is consistent with the
existing architecture and boundaries, and flag any ADR that should be written or
updated.

## 5. Verdict (Chief Engineer)
The **chief-engineer** consolidates into one report:

- **Ready to merge** — or —
- **Issues** — each with severity, `file:line`, and the required change
  (described, not applied)
- **Risks** — things a human should weigh
- **Recommended next step** — the single best next action

Stop there. Any commit or merge is the human's call.
