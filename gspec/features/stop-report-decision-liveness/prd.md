---
spec-version: v2
depends_on: [report-render-conformance]
---

# Feature: stop-report-decision-liveness

## Overview

`runstate.sh run-tally` counts every `ask-operator` decision line for the whole
of a run, and a run's id survives a resume. `templates/report-templates.md`
says two different things about the same figure: its tally sentence claims the
core counts only **still-awaiting** decisions, a property the core does not
compute, and its body rule renders one block per still-awaiting question. So
once a resume answers a question, the header reads 🔀 1 and the honest body
renders 0 blocks. `scripts/report-lint.sh`'s decision-count rule then flags the
correct body, and the driver's one sanctioned correction (a single fix to the
lines a lint finding names, from `report-render-conformance`) points at the
tally figure it was told never to recount. The gap exists only across packets and
only across a resume, which is why the parent's per-packet review could not see
it; its whole-branch review did.

The correction keeps 🔀 meaning *a decision for you*. The ⚠️/🔀 split in
`templates/report-conventions.md` is load-bearing, so redefining the bucket as
*questions the run asked* was considered and rejected. "Still awaiting" gets
one mechanical definition, and the core's figure, the template's tally
sentence and its body rule all use it. The header and the body then come from
the same test and cannot diverge.

## Users & Use Cases

- **The operator reading a stop report after a resume** reads 🔀 as "waiting
  on me". A figure that counts a question they already answered makes them look
  for a decision that is not there.
- **The agent rendering shape B** is told to render the core's figure as
  printed and to render blocks only for still-awaiting questions. Today those
  two instructions conflict, and the lint punishes it for obeying the second.
- **The maintainer reading a lint result** needs decision-count to fire only on
  a real mismatch. A finding that is dismissed on every resumed run teaches the
  reader to skip the whole result.

## Scope

**In**
- the liveness rule for `ask-operator` decision lines in `run-tally`'s
  DECISIONS figure.
- the template's tally sentence and body rule, reworded to state exactly that
  rule.
- regression cases in the sweeps that own each changed file.

**Out**
- any change to the digest's four line kinds, the glyph vocabulary, the three
  shapes, the decision block, or `report-lint.sh`'s rules.
- a new outcome state.
- redefining 🔀 as questions asked, or rendering answered questions as
  resolved blocks.
- any change to how `handoff-feature` lines are counted, including the dedup
  against a same-id `hand-off-feature` decision line.

**Deferred**
- None beyond the Deferred Decisions below.

## Capabilities

- [ ] **P0**: The DECISIONS figure counts an operator question only while it is still awaiting an answer
  - an `ask-operator` decision line counts until the same packet has a record
    in the outcomes log that answers it: a start, a continuation, or an
    `abandoned` outcome (dropping a packet is an answer). An answer must have a
    strictly later **parsed** timestamp than the question. The fraction is
    stripped before parsing, as the collector already does, because `.` sorts
    before `Z` and breaks string comparison. A tie does not answer, which fails
    toward over-reporting. The `blocked` outcome that `/gaffer:pause` records
    for the stop itself does not answer the question, and the line keeps
    counting
  - `handoff-feature` lines and `decision` lines whose token is
    `hand-off-feature` are outside the liveness rule and are counted as today.
    The existing exclusion of a `decision` line whose id already has a
    `handoff-feature` line is unchanged
  - `SHIPPED`, `FAILED` and `UNFINISHED` are byte-identical to today's output
    for the same run, and so are run-digest's four existing line kinds

- [ ] **P0**: The template's tally sentence and body rule state the core's definition
  - the tally sentence in `templates/report-templates.md` says exactly what
    `run-tally` counts for 🔀, including the answering records named in the
    first capability. It no longer attributes to the core a property the core
    does not compute
  - the body rule refers to the tally sentence's definition of "still awaiting"
    rather than restating it, so the header figure and the block count come from
    one definition
  - `scripts/test-report-conventions.sh` keeps its case pinning the tally
    sentence's keys to `run-tally`'s output green in both directions

- [ ] **P0**: The liveness rule is pinned by core sweep cases
  - `scripts/test-runstate.sh` has cases where a question answered by a later
    start, by a continuation, and by an `abandoned` outcome each yield
    `DECISIONS=0`
  - it has a case where a question followed only by a `blocked` outcome yields
    `DECISIONS=1`
  - the existing hand-off dedup case still yields its current figure

- [ ] **P1**: An honest body on a resumed run lints clean
  - a `scripts/test-report-conventions.sh` fixture has a resumed run whose
    question was answered. Its report has 0 decision blocks and no 🔀 in the
    header, and it yields no decision-count finding against its digest
  - the fixture's digest carries the answered `decision` line. The report is
    clean because of the liveness rule, not because the line was left out of
    the digest

## Dependencies

- `report-render-conformance`: the parent. It shipped `run-tally`, the
  template's tally sentence and the lint whose decision-count rule this change
  brings back into agreement. Derived-done. Nothing here reopens one of its
  capabilities or edits one of its checked task lines.
- `thin-loop-driver`: owns the outcomes log, the start, continuation and
  terminal records the liveness rule reads, and the resume path that answers a
  question. Derived-done and unchanged.

## Assumptions & Risks

- Assumption: the answering records (start, continuation, `abandoned`) are the
  only ways a resume acts on an operator question. If a later path acts on one
  without writing any of them, the question keeps counting. That fails toward
  over-reporting and a lint finding, never toward a silently dropped decision.
- Risk: the body rule stays prompt-enforced. The core's figure becomes right,
  but a renderer can still draw a block for an answered question. The
  decision-count rule is what detects that, and this change is what makes the
  rule trustworthy enough to act on.
- Risk: the template's tally sentence restates the core's rule, and the key-set
  case pins only the figure's name, so a later edit to either can drift
  unnoticed.

## Success Metrics

- After any resume, the stop report's 🔀 header figure equals `run-tally`'s
  DECISIONS for the run it names, and `report-lint.sh`'s decision-count rule
  does not fire on an honest body.
- The sweep fixture named in the fourth capability pins the lint half of that
  metric on every change.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Where the liveness test is computed.** It can be computed once, for example
  exposed through run-digest, and consumed by both the tally and the renderer,
  or it can be computed inside `run-tally` alone. Either satisfies the
  capabilities as long as the four existing line kinds stay unchanged. The
  choice depends on how the renderer is best given the answer, which is an
  implementation call.
