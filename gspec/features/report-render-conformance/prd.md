---
spec-version: v2
depends_on: [thin-loop-driver]
---

# Feature: report-render-conformance

## Overview

The report contract runs to 659 lines across three files — the conventions
(236), the shapes (370) and the distilled card (53) — and its sweep checks only
that the contract is **delivered**: that the session-start hook's envelope is
valid JSON, that it exits 0 in four fail-open directions, that the standing
instruction suppresses the injected copy, and that the three copies of the card
are byte-identical. Nothing checks whether a report that was rendered obeys any
of it. The cost is visible in this repository's own backlog: 12 features
exist because the system observed or reported its own state wrongly, and 6 of
those are second-order corrections of the first-order correction — four filed
inside three days.

The narrow opening is that the loop's three shapes are rendered from one
machine-produced source with a known grammar: `runstate.sh run-digest`, whose
`packet` / `decision` / `handoff-feature` / `enter` lines are tab-separated and
enumerable. So the mechanical properties of a report can be checked against the
digest that produced it, without ever asking whether an arbitrary piece of text
is a report. Two halves follow, and the first is the stronger: the header
tally is pure arithmetic over digest lines, so it moves out of the agent's head
into the deterministic core and stops being wrong; the second half lints the
remaining mechanical rules of a rendered report against that same digest. **The
boundary that makes this feasible is that neither half classifies anything**: a
`Stop`-hook format validator was rejected, because *is
this a report?* is the judgement a regex cannot make — and that
rejection stands, is not reopened here, and is why every check below is given a
report together with the digest behind it rather than asked to find one.

## Users & Use Cases

- **The operator scanning a stop report** — reads the header tally as a table of
  contents and as the run's state. A figure the agent computed by hand is a
  number with no second source; when it disagrees with the sections beneath it,
  the tally stops being an index and becomes a count sitting next to one.
- **The agent rendering shape B or C** — holds a digest and a contract and is
  asked to do arithmetic, apply a dedup rule, and obey a fixed section order, all
  in prose. Every one of those is a place to be quietly wrong, and nothing today
  tells it that it was.
- **The reviewer of a rendered report** — is the only gate on the report contract
  today, mechanical rules included. Rules a machine can settle are the ones worth
  taking off that desk, so the judgement calls get the attention.
- **A maintainer reading a clean check result** — needs to know what the check
  did not look at, or a passing lint is read as *this report is good* rather than
  *no mechanical rule was broken*.

## Scope

**In**
- the tally's four digest-derived figures, computed by the deterministic core
  from the digest's own lines, including the decision dedup rule.
- the rendering sites that today instruct an agent to compute those figures,
  reworded to consume them.
- a lint over a rendered report's mechanical rules, given the report text and the
  digest it was rendered from.
- the statement, at the site the lint's result is read, of the classes it cannot
  judge.
- regression cases for every change a sweep can reach, in the sweep that owns
  each file.

**Out**
- a `Stop`-hook validator, or any attempt to classify arbitrary turns as reports.
- changing the glyph vocabulary, the indentation contract, the three shapes, the
  decision block, or the fixed tally order.
- reports with no digest behind them — the change review, the metrics summaries,
  the migration and bootstrap summaries. They owe the conventions and have no
  machine source to check against.
- any new report shape, glyph, tally bucket or outcome state, and any change to
  the digest's four existing line kinds.
- prose quality of any kind: whether a clause states a consequence, whether an
  assumption is the right one, whether a title is a good title.

**Deferred**
- Extending the lint to reports with no digest behind them, which needs a source
  of truth those reports do not have.
- Retaining rendered reports so the lint can run retrospectively across a run's
  history rather than at the moment of rendering.

## Capabilities

- [x] **P0**: The tally's four digest-derived figures are computed by the deterministic core
  - the deterministic core emits the four digest-derived tally figures for the
    run it is given — ✅ one per `packet` line reading `green`; ⚠️ aggregating
    `blocked`, `interrupted`, `abandoned`, `open` and `paused`; ⛔ `failed` and
    `rolled-back`; 🔀 one per `handoff-feature` line plus one per `decision` line
    whose token is `ask-operator` or `hand-off-feature`, except one whose id
    already carries a `handoff-feature` line
  - ⬚ queued is untouched and stays outside the digest: it is the pending count
    the run-state summary already reports, and the shape still omits the bucket
    when it was not read rather than guessing it
  - the four existing line kinds are byte-identical to what they emit today —
    same fields, same tab separation, same absence of a header, same unordered
    output — so the loop's own read at its termination step and the resume entry
    point are undisturbed
  - `scripts/test-runstate.sh` gains cases over a fixture carrying every outcome
    the digest can emit, a handed-off packet and an operator question in one run
    (asserting the dedup yields two, not three), and a byte comparison of the
    four existing line kinds against their pre-change output

- [ ] **P0**: The stop report consumes the digest-derived figures rather than deriving them
  - the stop report shape states that each digest-derived figure is
    read from the core's counted output, and the arithmetic they currently spell
    out as an instruction to the renderer is stated instead as what the core
    does, so a reader can check a number without recomputing it
  - nothing else at that site moves: the fixed order, the shape-B wording of
    the ⚠️ bucket, the section headings that mirror it, and the queued bucket's
    existing source are unchanged, and no shape, glyph or bucket is added
  - `scripts/test-report-conventions.sh` gains a case pinning the shapes' tally
    sentence to the counted output on both sides, so a figure named in one file
    and not emitted by the other fails rather than drifting

- [ ] **P0**: A rendered report is checked against the digest it was rendered from
  - every rule is evaluated against the shape the report was rendered as, and a
    construct that shape itself defines is conformant rather than a finding — the
    tally's own multi-glyph line, the kickoff's phase lines and its `▶` session
    and autonomy headings, a bare branch or sha in the state line, and `▶ Next`
    as the one section the tally does not count. Given a report's text and that
    digest, the check then reports a finding for each of: a glyph outside the
    fixed vocabulary; two glyphs on one line; section headings that do not reuse
    the tally's glyphs in the tally's order; a header 🔀 figure unequal to the
    body's decision blocks plus any "N more" deferral; an id appearing with no
    plain-English title on its first appearance; a section written as "none"
    rather than omitted, excepting the kickoff's `Will need you`, where
    "nothing expected" is real information
  - it classifies nothing: it is invoked with a report and its digest — by the
    step that just rendered that report, on the digest it rendered it from — and
    never inspects a turn, a transcript or any text it was not handed, so no judgement
    of the form *is this a report* exists anywhere in it
  - the section order it checks is derived from the conventions' own fixed-tally
    line rather than a frozen copy, so a future reordering of the authority is
    what the check re-derives from
  - `scripts/test-report-conventions.sh` gains, per rule, a conforming fixture
    yielding no finding and a violating fixture yielding that finding by name, so
    no rule can pass by the check reporting nothing at all

- [ ] **P1**: A finding changes nothing about the run
  - a report with every rule violated leaves the run's records exactly as a clean
    one does: no outcome recorded, no packet blocked or rolled back, no checkbox
    flipped, no non-zero status reaching the caller that renders reports
  - the check fails soft in every direction it can fail — no digest, an
    unreadable report, an empty one — reporting that it could not judge rather
    than reporting conformance or an error
  - `scripts/test-report-conventions.sh` asserts both: the all-violations fixture
    against unchanged records, and each fail-soft direction distinguishable in
    the output from a clean result

- [ ] **P1**: What the check cannot see is stated where its result is read
  - the site reporting the check's result names the classes it does not judge —
    whether a consequence clause states a consequence rather than an argument,
    whether the assumption a kickoff names is the one most likely to be wrong,
    whether a title is a good plain-English title rather than merely present, and
    prose quality generally — and names the reviewer as the gate for all of them
  - a clean result is worded as *no mechanical rule was broken*, never as the
    report conforming to the contract. Checkable by reading the site against
    `templates/report-conventions.md`
  - nothing else at that site changes: no new glyph, no tally figure, and no
    report shape gains a slot for the result — prose only — no sweep case

## Dependencies

- `thin-loop-driver` — owns the digest, the three shapes, and the rule that a
  report is assembled from files rather than from memory. Every surface here is
  one it landed. Derived-done; nothing here re-opens a capability or edits a
  checked task line of it.
- `loop-prose-consistency` — landed the derived section-order case this feature's
  lint re-uses the technique of, and the shape-B order it checks against.
  Derived-done; the authority is untouched.
- `next-state-reporting-integrity` — **not blocking, but file-overlapping**: it
  changes the deterministic core and adds cases to the same core sweep. No
  logical dependency in either direction; the two should not be in flight against
  the same files at once.
- `escalation-decider` — produces the `decision` and `handoff-feature` records the
  🔀 figure counts and the dedup rule exists for. Not built; the interim stand-in
  writes the same records, and nothing here blocks it.

## Assumptions & Risks

- Assumption: this checks a rendering an agent produced against the machine
  source it was rendered from, so it detects a **violated rule**, never a missing
  insight. A report that breaks nothing mechanical can still be uninformative,
  and that is the reviewer's finding, not this one's.
- Risk: the bare-id and the "none" rules are textual, so they can fire on
  legitimate prose — a commit sha, a branch name, a sentence that contains the
  word. A noisy check teaches its reader to skip the whole result, which is worse
  than not running it; the quiet direction is the safe one, and the detector for
  getting it wrong is a finding an operator dismisses twice.
- Risk: moving the arithmetic into the core makes the figures right; it does not
  make the rendering use them. The 🔀-equals-blocks rule is the only tie between
  the header and the body, and everything else about that rendering stays
  prompt-enforced.
- Risk: nothing forces a rendered report through the lint. An agent that does not
  invoke it produces the same unchecked report as today, so the lint bounds
  accidental drift rather than a skipped step.
- Accepted consequence: reports with no digest behind them stay entirely
  unchecked, and the gap between checked and unchecked reports is now uneven in a
  way it was not when nothing was checked.

## Success Metrics

- Every digest-derived figure in a rendered stop report equals the core's counted
  output for the same digest — checkable per report by re-running the count
  against the run it names.
- No rendered report carries a glyph outside the fixed vocabulary, two glyphs on
  one line, a section order diverging from the tally, or a 🔀 figure unequal to
  its decision-block count — countable from the lint's result on each report as it
  is rendered.
- The digest's four existing line kinds are unchanged and a finding changes no
  run record — both pinned by the sweep cases their capabilities name.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Whether the counted figures are a new digest line kind, which also amends
  the digest's documented "no summary counts" statement, or a separate
  subcommand of the deterministic core.** Both satisfy the first capability and
  both leave the four existing line kinds untouched; the choice needs a reading
  of every current caller, which is a decomposition call rather than a scope one.
- **Whether the lint is its own script or a subcommand of an existing one.**
  Either satisfies the third capability.
- **Whether the loop invokes the lint at every report it renders or only at the
  stop report.** Both are advisory either way; the choice trades coverage against
  the driver's own context cost and is an implementation call.
