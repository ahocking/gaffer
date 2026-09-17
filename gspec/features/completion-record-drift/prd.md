---
spec-version: v2
depends_on: [thin-loop-driver]
---

# Feature: completion-record-drift

## Overview

Nothing detects a feature whose work is done but whose completion record is not.
A capability's checkbox flips only once every task whose `covers:` references it
is checked, and nothing in the loop performs or checks that flip: the adapter's
one write flips a **task** checkbox and, by its own contract, nothing else, and
the post-completion routing rule that widened that write is bounded with "never
touch capability checkboxes". Because completion is **derived** from the
capability boxes and never stored, a feature with every task checked and no
capability checked reads as incomplete forever — the adapter keeps returning it
as the next feature, its plan yields zero packets because every task line is
already checked, and everything depending on it stays blocked.

It was missed silently in two consecutive runs — `thin-loop-driver-gaps` and
`loop-prose-consistency` — and caught both times only because a whole-run review
happened to look. Both features' capability boxes were flipped by hand in a
separate `spec:` commit after the run had finished: `4a33ae3` for the first,
`28c387e` for the second. **The central constraint is that this feature
DETECTS and never flips.** It is cheap because nothing new is parsed: the adapter already
reports each plan's task lines and how many are unchecked, already derives
completion from the PRD's capability boxes, and already resolves a `covers:`
quote against a capability verbatim. New here is the comparison between them and
the two places it is reported — no new write, no new parsing.

## Users & Use Cases

- **The run that finishes a feature's last task** — lands the work, checks the
  task, and has no reason to look at the PRD. It leaves a record that is
  half-written and stops without knowing.
- **The next run picking work up** — asks the adapter what is next, is handed a
  feature whose every task is checked, and produces zero packets. The state is
  indistinguishable from a decomposition that has not happened yet.
- **A feature waiting behind that one** — is blocked by a dependency that is
  finished in fact and unfinished on paper, with no bound on how long that
  lasts.
- **The operator reconciling the record** — is the only party allowed to flip a
  capability box, and needs to be told which box, in which feature, rather than
  that something somewhere is inconsistent.

## Scope

**In**
- A per-capability drift test, over every feature whose PRD and plan the adapter
  resolves.
- Classifying what the test cannot judge inside that set — an unmatched
  `covers:` quote, a capability no task covers, a capability shape the verbatim
  matcher does not recognize — as unjudgeable rather than as either answer.
- Reporting at the run entry point's preflight, beside the existing
  trailer-versus-task drift scan.
- Reporting at termination, on the backlog-complete path, before the stop report.
- A case in the sweep that owns the adapter for each detection and unjudgeable
  judgement above, none able to pass vacuously.

**Out**
- Flipping a capability checkbox, automatically, ever: today's failure is loud
  and safe — re-picked, zero packets, noticed — while an auto-flip's is silent
  and unblocks everything behind a feature wrongly marked done.
- Widening the adapter's write surface in any other direction: the task-checkbox
  flip and the architect's append of a new unchecked task line are unchanged.
- Blocking, halting or failing a run on drift.
- Changing how completion is derived, or the verbatim `covers:` match and its
  unmatched reporting.
- A new report shape, a new glyph, or a new outcome state — the finding is
  reported through the shapes and vocabulary that already exist.
- Reconciling the two features whose records already drifted; both are ticked.

**Deferred**
- The same scan at the resume entry point's own preflight. Resume re-enters at
  the loop body and states no such scan today; a resumed run still reaches the
  termination point, and a fresh run's preflight is the backstop.
- Reporting drift on the blocked path's stop report. A blocked run's drift is
  reported by the next run's preflight, which is the weaker but sufficient cover.

## Capabilities

- [x] **P0**: The drift test is per capability, across every feature with a resolvable PRD and plan
  - the reported condition is exactly a capability whose covering tasks are **all
    checked** while its own box is unchecked — the state a feature enters the
    moment its last covering task lands and nothing flips the capability
  - a capability with at least one unchecked covering task is **not** reported: a
    feature legitimately sits part-ticked mid-flight, and that partial drift is
    both the likelier shape and the one a per-feature test — no unchecked task
    lines and no checked capabilities — cannot see
  - the scan covers every feature whose PRD **and** plan the adapter resolves,
    not only the feature the run is working on, since the drift by definition
    lives in a feature the run has already finished with. A feature with no plan
    file — the intended state for work not yet decomposed — is **out of scope,
    not unjudgeable**; only a failure inside a resolved PRD/plan pair lands as
    unjudgeable
  - each report names the feature and the capability it belongs to, never a
    count alone, so the reader can flip the right box without re-deriving which
    one is short

- [x] **P0**: Anything the test cannot judge is reported as unjudgeable, never as drift
  - a `covers:` quote matching no capability in the PRD is reported as unmatched,
    and its task counts as evidence for no capability. The adapter already
    reports an unmatched quote rather than guessing at the nearest capability,
    and a detector reading unmatched as drift would turn that guess back on
  - a capability no task covers **in a plan the adapter resolved** is unjudgeable
    for the same reason and is never reported as drift: with no covering task
    there is no positive evidence of delivery, and absence of evidence is not completion — the rule completion
    derivation already applies to a PRD with zero capability checkboxes
  - a capability line in a shape the verbatim matcher does not recognize reads
    unjudgeable rather than resolving to either answer, since completion
    derivation accepts shapes that matcher deliberately declines
  - both counts are over the scanned set only, and the unjudgeable count is
    reported separately from the drift count, so a run can distinguish *nothing
    drifted* from *nothing could be judged* — a single clean-looking zero across
    both is the failure this whole feature is about

- [x] **P0**: Preflight reports drift on every run, and blocks none
  - the scan runs in the run entry point's preflight beside the existing
    trailer-versus-task drift scan, and reads only the record on disk, so it
    fires however the previous run ended — complete, blocked, paused or
    interrupted
  - it reports in the kickoff, flips nothing and halts nothing, on the same
    authority as the scan beside it: reconciling a drifted record is the human's
    call. The criterion holds wherever a run entry point states a preflight drift
    scan, not only at the one that states one today — prose only — no sweep case
  - a repo with no gspec directory is a silent no-op, never an error — gspec is
    optional, and the preflight it sits in is already a no-op there

- [x] **P1**: The run that drifts the record reports it before it stops
  - the same scan runs at termination on the backlog-complete path, before the
    stop report is rendered, so a capability whose last covering task landed in
    this run is named by this run rather than by the next one
  - it is the same computation as the preflight scan, from one implementation —
    two readings of one rule that could disagree would re-create, inside this
    feature, exactly the second-source-of-truth problem it exists to detect —
    prose only — no sweep case

- [x] **P0**: Every judgement has a case in `scripts/test-gspec-backlog.sh`, and none passes vacuously
  - one fixture feature carries two capabilities — one whose covering tasks are
    all checked, one with an unchecked covering task — and the case asserts the
    first is reported and the second is absent by name. A per-feature test
    reports neither there, because the feature still has an unchecked task line,
    so the case fails if the test is widened back to the feature; reverting the
    detector fails it too, since it asserts a named capability present rather
    than output non-empty
  - each of the three unjudgeable classes — an unmatched quote, a capability no
    task covers, and a capability line the matcher does not recognize — asserts
    an unjudgeable report *and* that feature absent from the drift set: both
    halves, since either alone passes for the wrong reason
  - running the detector over a drifted fixture leaves every plan and PRD
    byte-identical, asserted by checksum: the detect-never-flip constraint is
    pinned mechanically, because an auto-flip's failure is the silent kind that
    a reviewer reading for intent would not catch
  - the fixtures are built by the sweep's existing PRD and plan builders in both
    layouts it already exercises, so a layout-specific detector that reads only
    the current feature folder fails rather than passing on the newer one alone

## Dependencies

- `run-state-cleanup` — owns the preflight drift scan this one sits beside, the
  report-never-flip-never-block rule it inherits, and the adapter's single
  task-checkbox write that defines the boundary being held. Derived-done;
  nothing here re-opens a capability of it.
- `thin-loop-driver` — owns the run entry point's structure, driver mode, the
  report shapes both detection points report through, and (its capability 2,
  whose handoff carries a capability's acceptance criteria) the verbatim
  `covers:` match and its unmatched reporting this detector rests on.
  Derived-done; no new shape is added.
- `gspec-adapter-consistency` — **not blocking, but file-overlapping**: it
  refactors the adapter's shared task-line pattern blocks and adds cases to the
  same sweep. No logical dependency in either direction; the two should not be
  in flight against the same files at once.
- `escalation-decider` — owns the routing whose arm-1 task append is the other
  write into `gspec/`. Not built; its bounds are unchanged and unblocked.

## Assumptions & Risks

- Assumption: `covers:` is the only evidence linking a task to a capability. A
  plan whose task lines carry none — the legacy shapes the adapter reads but
  which predate the field — yields no judgement for that feature, which is why
  unjudgeable is reported rather than passed over in silence.
- Accepted consequence: the detector fires the moment the last covering task
  lands, including inside the run that landed it, and keeps firing every run
  until a human flips the box. That is the intent, not noise — a report that
  stops before the record is reconciled would restore the silence being closed.
- Risk: reported-never-blocking depends on the report being read; the existing
  preflight scan makes the same bet, and the underlying failure stays loud
  without it: the feature is re-picked and yields zero packets every run.
- Assumption: exactly one entry point states a preflight drift scan today; the
  resume entry point re-enters at the loop body and states none. The criterion is
  written over every entry point that states one so a second site cannot ship
  half-covered.
- Risk: both reporting sites are prose in files the loop reads at dispatch, so a
  wrong statement there is obeyed rather than noticed, and the adapter's sweep
  cannot reach them. The reviewer is the only gate for those two, named as such
  rather than covered by a case asserting a string is present.

## Success Metrics

- Every capability **in a feature whose PRD and plan the adapter resolves** whose
  covering tasks are all checked while its own box is not is named in a report
  within one run of reaching that state, or by the next fresh run's preflight
  where the run that created it ended blocked or paused. Both observed misses
  stood for a whole run and were found by a review that did not have to look.
- The adapter's write surface is unchanged — one task-checkbox flip — and the
  detector adds none: countable by inspection and pinned by the checksum case.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- Whether the detector is a new read-only adapter subcommand or an extension of
  an existing one. Deferred because both satisfy every capability here and the
  choice is a decomposition call, not a scope one.
- Whether a feature whose plan carries no resolvable `covers:` at all is reported
  once for the feature rather than once per capability. Deferred because it is a
  report-volume judgement that needs the first real scan's output to settle, and
  either shape satisfies the unjudgeable capability.
