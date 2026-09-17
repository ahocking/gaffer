---
spec-version: v2
depends_on: [thin-loop-driver-gaps]
---

# Feature: loop-prose-consistency

## Overview

Five shipped instructions that disagree with their own declared authority, or
with what the system measurably does. Two code-block comments reproduce an
output the script no longer emits; a worked example quotes a count taken
mid-run that was wrong by the time the run ended; a report shape orders its
sections against the order its own conventions document fixes, in the same
sentence that claims the table-of-contents property that order provides; a
worked hand-off carries an outcome no hand-off records, so it teaches the wrong
glyph for the commonest case in its shape; and one skill states a
continuation rule more narrowly than the rule that shipped. Every one lives in
a file the loop reads on every run, so a wrong statement is obeyed rather than
noticed. All five were found by the end-of-run whole-run review.

Split out rather than appended, on the established precedent: the parent is
derived-done — all eleven task lines checked — so an unchecked capability added
to it would make shipped work read as incomplete forever and block everything
downstream through the dependency rule. This is new scope against a feature that
shipped.

## Users & Use Cases

- **An agent rendering a report from a shape** — copies the shape's worked
  example, including its outcome and its section order. A factual error in an
  example is reproduced as output, not caught, because the example is the most
  trusted line in the file.
- **A driver reading a skill's output-contract comment** — treats the quoted
  output as the set of values it must branch on. A value that no longer exists
  buys a dead branch; a value the script now emits and the comment omits buys a
  case handled by accident.
- **The operator scanning a stop report** — uses the header tally as a table of
  contents and expects the sections beneath it in the tally's order. When they
  disagree, the tally stops being an index and becomes a second count sitting
  next to one.
- **A driver that stopped on a blocking question and re-entered through the
  other entry point** — reads a continuation rule worded for one of the two
  statuses the shipped rule admits, and so reads itself as outside it.

## Scope

**In**
- the two output-contract code-block comments in the loop skills that purport to
  reproduce the compaction-threshold reader's output.
- the worked example in the loop skill that states a count of a run's own
  integrated work.
- the stop report shape (B)'s section order, the sentence that states that
  order, and the ordered note that moves with the reordered section.
- the check-in shape (A)'s worked hand-off outcome and the glyph it therefore
  renders.
- the continuation wording on the run entry point's continuation call (the one
  selecting a continued start over a fresh one).
- two regression cases: one pinning the reordered shape's section order, one
  pinning where the removed source value may still appear.

**Out**
- the rule prose that names both the removed source value and the unknown one.
  Naming both is deliberate and is what made the suppression real across the
  interval between the two packets that landed it; a change there is a
  regression, not a tidy.
- the fixed tally order in the conventions document. It is the authority the
  shape is being corrected against, and it is untouched.
- the checked task and capability blocks of the parent feature that carry the
  superseded counts. They are the record of what was asked for; the immutability
  floor refuses edits there and is right to.
- any mechanism change: no script behaviour, no new field, no new report shape,
  no new outcome state.
- the sweep rule itself, which is already worded identically in both entry
  points.

**Deferred**
- Regression coverage for the hand-off example's outcome and for the two
  continuation triggers' agreement. Both are pinnable by techniques the sweep
  already applies to these files; deferred to hold this feature to the two cases
  in scope.

## Capabilities

- [ ] **P1**: The output-contract comments reproduce the output the script emits
  - each code block that presents itself as that reader's output names exactly
    the values the reader now emits — the repository, operator and unknown
    sources — and no value whose branch was removed
  - the rule prose that deliberately names both the removed value and the
    unknown one is left unchanged in each of its three locations: both loop
    skills and the report shapes
  - the regression sweep gains a case asserting the removed source value
    appears, across the two loop skills and the report shapes, in exactly the
    three rule-prose locations and in neither output block; an edit that tidies
    the prose must fail that case

- [ ] **P1**: The worked example states no count that rots
  - the example states the contrast it exists to make — a branch-versus-base
    scope against the run's own scope — with no count on the run side, because a
    count of a run's integrated work measured mid-run cannot still be right when
    the run ends
  - the branch-versus-base figure is kept: its sentence already attributes it to
    the moment it was measured, where the removed count claims what the run
    finally landed
  - the superseded counts inside the parent feature's checked task lines and
    checked capability blocks are not edited. A hook rejection here is the signal
    that the edit reached a completed record, never a cue to bypass it — prose
    only — no sweep case

- [ ] **P1**: The stop report's section order matches its declared authority
  - the shape renders its sections in the order its conventions document fixes —
    the decisions section above the queued section — in the shape itself and in
    both of its worked examples, so no example contradicts the shape it
    illustrates
  - the sentence stating the order inside the shape is corrected in the same
    place it claims the table-of-contents property, and the ordered note
    describing the queued section's collapse moves with the section it describes
  - the conventions document is untouched: the shape is reordered to the
    authority, never the authority to the shape
  - the regression sweep gains a case asserting the shape's section order
    against the conventions document's fixed tally order, where it checks only
    glyph presence today. A reordering that satisfies the shape and diverges
    from the authority must fail that case

- [ ] **P1**: The worked hand-off shows the outcome a hand-off records
  - the worked hand-off packet carries the outcome a handed-off packet actually
    records, and therefore renders the glyph the shape's own outcome-to-glyph
    table maps that outcome to
  - the check-in shape's worked example and the stop report's dedup example
    agree about the one scenario they both cover
  - the correction is to the example's outcome value and the glyph that follows
    from it; the outcome-to-glyph table, the two-lines-per-handed-off-packet
    rule, and the routing that produces the outcome are all unchanged — prose
    only — no sweep case

- [ ] **P2**: One continuation rule, worded the same in both entry points
  - the run entry point's narrowed continuation trigger — the one naming only a
    paused packet — is corrected to admit every status the shipped rule does, a
    run stopped on a blocking question included; the resume entry point already
    admits both, so one edit reaches the end state
  - the sweep rule itself is not reworded: it is already identical in both
    files, and only the continuation trigger's wording is in question
  - both entry points word the trigger as the situation — this session is about
    to continue the cursor packet — not as a status list, so a later status the
    rule admits does not re-open the divergence — prose only — no sweep case

## Dependencies

- `thin-loop-driver-gaps` — the parent. Its packets landed every statement
  corrected here: the compaction-threshold reader whose removed value the
  comments still quote, the promoted section-order rule, the second worked
  example, and the broadened continuation trigger. Derived-done; nothing here
  re-opens a capability or edits a checked task line.
- `thin-loop-driver` — owns the report shapes and the loop skills the
  corrections land in. Derived-done; no capability of it is re-opened.
- `loop-measurement` — owns the outcome records and the sweep whose continuation
  trigger is reworded. **Not blocking:** the shipped half is what is depended on
  and no file is shared with its deferred tail.
- `escalation-decider` — the routing whose hand-off outcome the corrected worked
  example reports. Not built; nothing here blocks it, and no routing behaviour
  changes.

## Assumptions & Risks

- Risk: three of the five capabilities ship with no sweep case. The only pin
  available for one of the three is asserting the single superseded string
  absent, and it is declined — it expires the moment the string is removed,
  leaving a case that passes forever while checking nothing. The
  other two are pinnable by techniques the sweep already applies to these files —
  a sed-anchored range plus a token assertion, and one clause asserted on both
  sides of a two-file contract — and those pins are declined to hold this feature
  to two cases. For all three the reviewer is the only gate — the same detector
  that missed them, now aimed deliberately.
- Accepted consequence of the reorder: the decisions section stops sitting
  immediately above the next-action section. The authority's fixed order is
  chosen over that adjacency, deliberately.
- Assumption: the section order is stated in exactly one file. The distilled
  card, the consumer standing-instruction stamp and the session-start hook carry
  the glyph *vocabulary* in the same order and state no section order, so this
  repository's standing three-copies-of-one-contract drift risk does not open
  here. A correction that adds a section order to any of those three opens it.
- Assumption: line references in the brief were taken at one commit and this
  repository's prose moves. Every site is located by content, never by line
  number.

## Success Metrics

- No code block presenting itself as a script's output names a value that script
  cannot emit, and the two entry points' continuation triggers read the same —
  checkable by reading each block against the emitting line, and by diffing the
  two trigger clauses.
- No worked example in the loop's documents states a count of a run's own
  integrated work; the branch-versus-base contrast survives without one.
- Every stop report renders its sections in the conventions document's fixed
  order, and the regression sweep fails if the shape and the authority diverge.
- Each worked example's outcome value maps, through the shape's own table, to the
  glyph the example renders — zero mismatches across both shapes.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.
