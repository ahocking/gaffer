---
spec-version: v2
depends_on: [runstate-write-integrity, runstate-write-integrity-gaps]
---

# Feature: runstate-summary-quoted-severity

## Overview

`scripts/runstate.sh summary` (`cmd_summary`) reports how many blocking
questions a run is stopped on, and it counts them with a line regex that matches
only a bare `severity: blocking`. The repo's run-state rule is that every value is
written quoted, so a `pending_questions` entry written `severity: 'blocking'` —
the form the rule produces — is counted as zero, and the one-line summary a resume
or stop report relays reads "0 blocking question(s)" for a run that is blocked on
one. Found 2026-09-23 during the `dispatch-progress-metrics` run, where the driver
wrote the entry unquoted as a workaround so the count came out right.

The same regex has a second, smaller defect of the same class: it is unanchored
after the word, so a bare value that merely *begins* with `blocking` is counted.
Both go away once the severity is read as a decoded value and compared whole. A
reader audit of `scripts/runstate.sh` found `cmd_summary` to be the only site that
reads a question's severity; every other `pending_questions` reader carries the
entry without interpreting that field.

## Users & Use Cases

- **The loop driver relaying a resume or stop report** — passes the summary line
  through as written, with no second source to check the count against.
- **The operator reading that report** — decides from the blocking count whether
  the run needs them now; a zero there tells them it does not.

## Scope

**In**
- How every reader of a `pending_questions` entry's severity in
  `scripts/runstate.sh` interprets that value.
- One case per severity form in `scripts/test-runstate.sh`.

**Out**
- How questions are written — the writers, their quoting, and the `pause` skill's
  shape for an entry.
- Readers of any key other than a question's severity, including `summary`'s
  pending count.
- The `run-metrics` retro-spec and every other script, hook and sweep.
- Run-state's schema and the severity vocabulary.

**Deferred**
- Whether the blocking count is also restricted to lines inside the
  `pending_questions` block, rather than any `severity:` line in the file.

## Capabilities

- [ ] **P0**: Every reader of a `pending_questions` entry's severity reads it through the shared run-state decode rule, so quoted and bare forms count identically
  - the value is taken after the `severity:` key with surrounding whitespace,
    including a trailing CR, removed before decoding; for an entry whose severity
    is `blocking` written single-quoted, double-quoted, bare, or followed by
    trailing whitespace, `summary` reports exactly the same blocking count — one
    per such entry — and a run-state holding one of each reports 4
  - a severity that decodes to anything other than exactly `blocking` — `high` or
    `normal` in any of the three forms, or a bare value that only begins with
    `blocking` — is not counted, so a run-state holding only such entries reports
    0
  - `scripts/test-runstate.sh` gains a case per form for both the counted and the
    uncounted side, each asserting the reported count by value rather than that a
    count was printed, and the sweep passes; each counted-side case for a quoted
    form fails against the pre-change `cmd_summary`
  - the counted and uncounted cases hold with `jq` and `python3` absent from
    `PATH`, the dependency tier `runstate.sh` already keeps

## Dependencies

- `runstate-write-integrity` — established that every run-state value is written
  quoted and that compatibility with bare values is the reader's job. Derived-done;
  nothing here re-opens it.
- `runstate-write-integrity-gaps` — supplies the single shared decode rule this
  feature routes the severity read through. Complete.

## Assumptions & Risks

- Assumption: the decode rule already accepts the single-quoted, double-quoted and
  bare shapes, so this feature adds a caller to it rather than changing it.
- Risk: if the count uses a second copy of the decode rule, that copy can drift
  from the shared decoder unless the sweep's shared fixture table exercises it.
- Assumption: a run-state written with the unquoted workaround still counts
  correctly, so no on-disk run-state needs migrating.

## Success Metrics

- An operator never sees "0 blocking question(s)" for a run blocked on one —
  checkable by running `summary` against a run-state carrying a quoted blocking
  entry, and pinned by the sweep's per-form cases.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- Whether the blocking count is scoped to the `pending_questions` block. Deferred
  because the brief bounds this feature to how severity is decoded; scoping changes
  which lines are counted, which is a separate behaviour change.
