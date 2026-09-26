---
spec-version: v2
depends_on: [completion-record-drift-gaps]
---

# Feature: next-state-reporting-integrity

## Overview

The adapter's feature-selection path answers *what does the loop pick up next*,
and when it picks up nothing it must say which of three distinct nothing-to-do
states it found. Two of the three are decided by a pipeline used directly as a
condition under the file-wide `pipefail` setting (both
`printf … | awk … | grep -q .` inside `cmd_next` in `scripts/gspec-backlog.sh`):
the reader exits on its first match and closes the pipe while the writer is still
writing, the writer dies on the resulting signal, and `pipefail` reports that
signal in place of the reader's success — so a **true** condition reads as false
and the branch is skipped. This is reproduced, not theorised: against this
repository's real feature rows (18,756 bytes, 15 rows after the filter), 235 and
241 failures in 400 iterations across two runs, first failure at iteration 3.
Control then falls through to the last branch, which reports the
backlog as finished. The comment above the first site already says, in its own
words, that collapsing these states is how *the loop has stopped picking work
up* gets misread as *the backlog is finished*; a misfire produces exactly that,
and the loop driver reading the answer concludes the backlog is done, runs the
whole-branch review and records the run complete over work nobody built. In the
deferred case, a human decision reversible by editing one line is never
surfaced.

The second site shows zero failures in 400 iterations only because its payload
is 733 bytes and fits a single buffered write, so the reader blocks on an empty
pipe until that one write lands and the writer has already exited — there is no
window. That is a property of today's data, not of the code: one more deferred
feature, or one with a longer explanatory value, crosses the buffer threshold
and it behaves like the first. Both are therefore in scope together, along with
the remaining instances of the same construct in the loop's deterministic core.
This is a new feature rather than an appended task on
`gspec-adapter-consistency`, which touches the same file: that feature has no
plan file to anchor an append, its Scope Out opens with "Any change to what the
adapter reads, reports, or writes", and one of its unchecked capabilities is "No
observable behaviour of the adapter changes" — which this change is, so
appending it there would leave that feature unable to honestly read as done. The
slug names its own scope rather than stacking a second `-gaps` suffix.

## Users & Use Cases

- **The loop driver asking what to work on next** — reads one answer, has no
  second source to check it against, and treats *the backlog is finished* as a
  terminal fact. A wrong answer here is obeyed, not noticed.
- **The operator whose remaining work is deferred** — deferral is their decision
  and is reversed by editing one line, which only happens if they are told the
  backlog is deferred rather than done.
- **The operator whose remaining work is blocked** — needs the blocked features
  and their unfinished dependencies named, since a blocked backlog and a
  finished one demand opposite responses.
- **The run that terminates on the backlog-complete path** — reviews the whole
  branch and records the run complete on the strength of that answer, so a
  misfire is written into the durable record rather than lost with the session.
- **A maintainer auditing the same construct elsewhere** — needs each remaining
  instance to say whether it is safe by construction or merely safe against
  today's data.

## Scope

**In**
- Both nothing-to-do condition tests in the feature-selection path of
  `scripts/gspec-backlog.sh`, expressed without a reader that can close the pipe
  before its writer finishes.
- The remaining instances of the same construct in `scripts/runstate.sh`: closed
  where a wrong answer can reach a caller, recorded where it cannot.
- Sweep cases over a blocked backlog and a deferred backlog, shown to fail
  against the unfixed construct.
- A sweep-level guard against a new instance of the construct.

**Out**
- What the selection path reports when it is working correctly: the same
  `NEXT=` / `PLAN=` / `REASON=` / `HINT=` vocabulary, and no new state, field or
  output column.
- How completion, blocking or deferral is derived — the subject here is a test
  misreporting its own result, not what the right answer is.
- `scripts/metrics.sh`, and anything under `gspec/` itself.
- Any widening of the adapter's write surface.
- Re-opening, re-wording or re-checking any capability of
  `completion-record-drift-gaps`.

**Deferred**
- Surveying the same construct across the plugin's hook bodies and its remaining
  scripts. The two files named here are the ones with a reproduced or a
  size-dependent instance; a wider survey is its own scope.

## Capabilities

- [x] **P0**: Neither nothing-to-do branch can report a state it did not find
  - each of the two condition tests in the feature-selection path (both
    `printf … | awk … | grep -q .` inside `cmd_next`, evaluated under the
    `pipefail` setting earlier in the same file) is expressed with no pipe
    whose reader can exit before its writer finishes, so a backlog
    whose every incomplete feature is blocked reports the blocked `REASON=` plus
    one `BLOCKED=` line per feature, and a backlog whose every remaining feature
    is deferred reports the deferred `REASON=` plus one `DEFERRED=` line per
    feature and the `HINT=` line — on every run, at any size of input, however
    the shell schedules those processes
  - nothing else about the branch changes: the three nothing-to-do states stay
    distinct, each keeps its existing `REASON=` text, the `BLOCKED=`,
    `DEFERRED=` and `HINT=` line forms are byte-identical, and `all features
    complete` is reported exactly when neither of the other two conditions holds

- [x] **P0**: Each of the three nothing-to-do states has a case in `scripts/test-gspec-backlog.sh`, and the two new cases are shown to fail against the unfixed construct
  - one fixture whose every incomplete feature is blocked by an unfinished
    dependency and one whose every remaining feature is deferred each assert
    their own `REASON=` text **and** their per-feature `BLOCKED=` / `DEFERRED=`
    lines by feature name — an assertion that the output merely differs from
    `all features complete` passes on several wrong answers
  - each fixture carries enough feature rows that the unfixed construct
    reproduces its failure there, and each case is run against the pre-change
    code and observed to fail, with that observation recorded in the case's own
    comment. A probe that does not reproduce the phenomenon eliminates nothing,
    so a case sized below the buffer threshold would certify the fix while
    exercising nothing
  - a fixture in which every feature reads as complete still asserts `NEXT=none`
    with the `all features complete` reason, so the correction cannot be
    evidenced by a branch that has simply stopped being reached

- [x] **P1**: Every remaining instance of the construct in `scripts/runstate.sh` is closed or recorded
  - each `printf … | grep -q`-shaped test used directly as a condition under
    `pipefail` in `scripts/runstate.sh` — the set-membership helper and the two
    findings duplicate-id checks — is either expressed without the pipe or
    carries a comment stating the bound that makes it unable to misreport,
    expressed as a reading of the writer's maximum output size rather than as an
    observed pass. Their writers are small today and their exposure grows with
    the findings block, so the bound is the thing that must be removed or written
    down
  - the orphan-tag extraction in the same file, whose piped value still reaches
    standard output correctly and whose polluted exit status is already
    discarded by the trailing fallback, keeps its behaviour unchanged and gains
    a comment stating both facts, so a later reader auditing this shape does not
    convert a working value-producing pipeline into something else

- [x] **P1**: A new condition-shaped instance of the construct cannot be added to either file unnoticed
  - the sweep that owns each file — `scripts/test-gspec-backlog.sh` for the
    adapter, `scripts/test-runstate.sh` for the deterministic core — carries a
    case scanning that file for a pipeline whose final stage is an early-exiting
    reader used as a condition, failing on any instance outside a recorded set
    of reviewed exceptions
  - the recorded exception set names each instance and the reason it is safe, so
    adding one is a deliberate edit to that list rather than a silent pass
  - each guard is shown to fail when an instance is introduced anywhere in the
    file it scans, demonstrated at implementation time and recorded in the
    case's comment

## Dependencies

- `completion-record-drift-gaps` — its first capability removed this same
  construct from the drift test in this same file and named the mechanism;
  this feature extends that correction to the selection path and to the
  remaining instances. Derived-done; nothing here re-opens a capability or edits
  a checked task line of it.
- `completion-record-drift` — owns the drift detector that shares the file and
  the sweep. Derived-done; its judgements and reporting are unchanged.
- `thin-loop-driver` — owns the entry point that reads the selection path's
  answer and the stop report a misfire reaches. Derived-done; no shape, glyph or
  outcome state is added.
- `gspec-adapter-consistency` — **not blocking, but file-overlapping**: it
  refactors this adapter's shared pattern blocks and adds cases to this same
  sweep, and its own scope forbids the reporting change made here. No logical
  dependency in either direction; the two should not be in flight against the
  same files at once.

## Assumptions & Risks

- Assumption: the instances enumerated here are every condition-shaped instance
  in the two named files. If another is found during implementation it has the
  same failure direction and is in scope for the same correction.
- Risk: the second selection-path site and the three deterministic-core
  instances reproduce no failure at today's input sizes, so a green sweep is not
  evidence about them either way. The detector for those is a reading of the
  construct, not an observed failure before or after.
- Risk: a guard that scans source text can be satisfied by rewriting a construct
  into an unrecognised shape with the same hazard. It bounds accidental
  reintroduction, not a deliberate one, and the reviewer remains the gate there.
- Accepted consequence: the exception set makes the safe-by-comment instances a
  standing item a maintainer must re-judge when the data they are bounded by
  grows.

## Success Metrics

- A backlog in which every incomplete feature is blocked, and one in which every
  remaining feature is deferred, each report their own reason and per-feature
  lines on every invocation — checkable by repeated invocation against a fixture
  large enough to reproduce the failure.
- No run records itself complete on a backlog that still holds blocked or
  deferred features — checkable per run against the selection path's output.
- Every condition-shaped instance in the two named files is either absent or
  present in the recorded exception set with its reason, countable by reading
  the two files, and by the guard once it exists.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Whether each corrected condition becomes a captured value tested from a
  here-string, or an emptiness test folded into the writer so no pipe exists.**
  Both remove the construct; the choice is an implementation call.
- **Whether the three deterministic-core instances are closed or merely
  recorded.** Both satisfy the third capability; the choice needs a reading of
  how large each writer can become, which is a decomposition call rather than a
  scope one.
- **Whether the two guards share one implementation or are written per sweep.**
  Either satisfies the fourth capability.
