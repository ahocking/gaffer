---
spec-version: v2
depends_on: [loop-prose-consistency]
---

# Feature: loop-prose-consistency-gaps

## Overview

The parent feature's own run left four defects behind. **A stale source branch:**
two loop entry-point skills and the report shapes document each still instruct a
reader to branch on a compaction-source value that reader can no longer emit —
the enumeration directly above names the repository, the operator and unknown as
the values in effect, while the branch keys on the tool's own default, whose
reader-side case was removed (`skills/run-loop/SKILL.md`:101 vs :112,
`skills/resume/SKILL.md`:81 vs :92, `templates/report-templates.md`:317). **A
sweep case defending it:** `scripts/test-report-conventions.sh`:255–262 asserts
that removed value present exactly once per file, so it now names the correction
as the error. **A pin that misses the copied half:** a second case pins the stop
report shape's section order but extracts its range from an anchor the shape's
own worked example sits outside (`:441`), so reverting only the example leaves
the sweep green. **A trigger that states no condition:** the run entry point's
continuation trigger defers to a second site that restates it as a tautology
(`:200`, `:255`), so neither states the situation. All were found by the
whole-run review of the parent feature's own run, 2026-09-17.

Split out rather than appended, on the `metrics-coverage-gaps` precedent: the
parent is derived-done — five of five capabilities and five of five tasks checked
— so an unchecked capability added to it would make shipped work read as
incomplete forever and block everything downstream through the dependency rule.
This is new scope against a feature that shipped.

## Users & Use Cases

- **A driver reading an entry point's source-branching rule** — takes the
  enumerated values as the set it must handle. A branch keyed to a value the
  reader cannot emit is dead code in prose, and sitting one paragraph under a
  corrected enumeration it teaches that neither statement is reliable.
- **An agent copying a shape's worked example** — reproduces the example, not the
  shape it illustrates. A property pinned on the shape alone is pinned on the
  half less often obeyed.
- **A driver choosing between a fresh start and a continuation** — needs a
  condition it can evaluate against state it already holds. Two sites deferring
  to each other leave it with no condition, so it guesses and the guess is
  invisible.
- **A future editor correcting the stale clauses** — runs the sweep and is told
  by a red bar that the correct edit is the regression.

## Scope

**In**
- the three source-branching clauses naming the removed value: both loop
  entry-point skills and the report shapes document.
- the sweep case asserting that value's per-file occurrence count, retired in the
  same change as the clauses.
- the sweep's section-order assertion, extended to reach the stop report shape's
  worked example.
- the run entry point's continuation trigger, on the sweep call and on the start
  attestation.

**Out**
- the output-block enumerations themselves, and the two sweep cases pinning them.
- the resume entry point's continuation trigger: its else branch already states
  the condition (a fresh start is one whose prior attempt already closed with a
  recorded outcome), so it is unedited.
- the fixed tally order in the conventions document: still the single authority.
- the compaction-threshold reader's behaviour — no branch added or removed, no
  enumerated value changed. The prose moves to the code, never the reverse.
- the parent feature's checked task lines and capability blocks, which record what
  was asked for at a time when the exclusion was correct.

**Deferred**
- Regression coverage for the corrected continuation trigger's agreement with the
  resume entry point's. The parent deferred the same pin for the same reason, and
  nothing here changes that reason.
- the check-in shape's worked hand-off failure clause — a cosmetic, pre-existing
  mismatch with the template slot it fills, folded in only if the shapes document
  is already open for an item above, and deliberately not a capability.

## Capabilities

- [ ] **P0**: The source-branching clauses name only values the reader can emit, and the sweep case defending them is retired in the same change
  - each clause telling a reader what to do when the compaction-threshold reader
    names no value in effect enumerates only the value that reader can emit for
    that case; the value whose branch was removed appears in no instruction, in
    either entry-point skill or in the report shapes
  - each enumeration directly above such a clause is already correct and is not
    edited — the clause is corrected to the enumeration, or where there is none to
    the values its reader emits, never the reverse — and the two sweep cases
    pinning those enumerations stay as they are
  - the occurrence-count case asserting the removed value present exactly once per
    file is retired **in the same change**. It asserts the stale statement, so it
    would name the correction as the failure: a change that fixes the prose and
    leaves the case is a red sweep, and a change that retires the case and leaves
    the prose is the same defect with its evidence removed

- [ ] **P1**: The stop report shape's worked example is pinned to the order its shape is pinned to
  - the section-order assertion covers the worked example's rendered body as well
    as the shape's own, so the half an agent copies is pinned by the same case as
    the half it copies from
  - each extracted region is asserted non-empty before it is scanned, as the
    existing extraction already does for its single anchor: a range matching
    nothing yields an empty order that compares equal to nothing and passes
  - the conventions document's fixed tally order stays the single authority for
    both regions — the example is compared to the authority, never to the shape —
    so a shape and an example that drift together still fail
  - reverting only the worked example's two sections turns the sweep red, which is
    the mutation that leaves it green today

- [ ] **P1**: The run entry point states its continuation trigger as a situation a reader can act on
  - the trigger is stated concretely enough to be evaluated where it is read,
    without following a pointer to a second site; today the first site defers to
    the second and the second restates it as a tautology, so neither carries a
    discriminating statement
  - the corrected trigger names no status list: it is worded as the situation,
    which is what the parent capability required
  - the condition it states is the one the resume entry point's else branch
    already carries — a fresh start is one whose prior attempt already closed
    with a recorded outcome, a continuation is one whose start is still open —
    so after the correction both entry points read as one rule
  - exactly one of the two sites carries the statement and the other may refer to
    it: one statement with a reference is in scope, two references and no
    statement is the defect

- [ ] **P0**: Every case this change touches in the sweep that owns this surface can fail
  - no case is left asserting a statement the system contradicts: a case pinning
    prose expires when the reason for that prose does
  - every case added or changed here is verified by reverting the content it pins
    and observing the sweep go red
  - no case is added whose only assertion is that a just-removed string is absent:
    the parent declined exactly that pin, because from the moment the removal
    lands it passes forever while checking nothing
  - the sweep's existing cases over the enumerations and over the shape's own
    section order keep passing unchanged, so this coverage is additive and nothing
    already pinned is loosened

## Dependencies

- `loop-prose-consistency` — the parent. Owns all four corrected sites and the
  section-order case being extended; its capability 1 is what scoped the three
  stale clauses out. Derived-done; nothing here re-opens a capability or edits a
  checked task line.
- `thin-loop-driver-gaps` — landed both the packet that deliberately kept the
  removed value named and the packet that removed its branch. The second is what
  expired the first. Derived-done.
- `thin-loop-driver` — owns the report shapes and the entry-point skills every
  correction lands in. Derived-done.
- `loop-measurement` — owns the sweep-before-start rule whose continuation trigger
  is at issue. **Not blocking:** the shipped half is what is depended on, and no
  file is shared with its deferred tail.

## Assumptions & Risks

- Assumption: line references were taken at one commit and this repository's prose
  moves. Every site is located by content, never by line number.
- Risk: capability 1's two halves each fail on their own and are one change; the
  only detector for the second failure is the reviewer.
- Risk: the worked example is comment-prefixed precisely so it does not render as
  a shape, so it has no unique unprefixed anchor of its own. Extending the
  assertion means a second extraction as anchor-fragile as the first; the
  non-empty check is what keeps that fragility loud rather than green.
- Risk: correcting a trigger toward concreteness is one step from the status list
  the parent removed. The two constraints pull against each other and only the
  reviewer sits between them.
- Assumption: the section order is still stated in exactly one file. The distilled
  card, the consumer standing-instruction stamp and the session-start hook carry
  the glyph vocabulary and no section order, so this repository's
  three-copies-of-one-contract risk does not open here.

## Success Metrics

- No instruction in the loop's documents branches on a value the reader it names
  cannot emit — checkable by reading each clause against the enumeration above it,
  or the values its reader emits where there is none, with zero mismatches across
  the three documents.
- No case in the sweep asserts the presence of a statement the code contradicts,
  and reverting any content this feature pins turns the sweep red.
- The stop report shape and its worked example render the same section order, each
  asserted against the conventions document rather than against each other.
- Both entry points' continuation triggers can be evaluated where they are read:
  no site defers to another for the condition.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- Which of the two continuation-trigger sites carries the concrete statement, and
  which refers to it. Deferred because either arrangement satisfies the
  capability.
