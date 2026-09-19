---
spec-version: v2
depends_on: [stop-report-decision-liveness]
---

# Feature: answered-question-expiry

## Overview

`stop-report-decision-liveness` made `runstate.sh run-tally`'s 🔀 figure count
only still-awaiting questions. The stop report's body does not come from the
same place. `/gaffer:pause` renders its decision blocks from run-state's
`pending_questions`, and it persists each new question "carrying every existing
entry through". Nothing ever drops an entry the operator has answered. So a run
that resumes, answers a question and stops a second time can render a block for
the answered question while `run-tally` leaves it out. That is the header/body
mismatch the parent fixed, re-created from the body side, and
`scripts/report-lint.sh`'s decision-count rule then flags the report. A second
source of the same mismatch already exists: a `retry` routed past its attempt
limit becomes `stop` with a blocking question, the body renders that as a
decision block, and `run-tally` counts it as 0 🔀.

The correction makes the body's source and the header's figure the same set by
construction. The parent's liveness rule is applied, unchanged, in two places. A
deterministic core step prunes answered entries whenever the list is
re-persisted, and `run-tally` counts the retry-past-limit stop as a decision.

## Users & Use Cases

- **The operator reading a stop report after a second stop** reads 🔀 as
  "waiting on me". A block for a question they already answered makes them
  answer it twice or go looking for what changed.
- **The agent rendering shape B** renders blocks from `pending_questions` and
  the header from `run-tally`. Today those two sources disagree after a resume,
  and the lint flags the report even when the agent followed both instructions.
- **The maintainer reading a lint result** needs decision-count to fire only on
  a real mismatch, including on runs that stopped on an exhausted retry.

## Scope

**In**
- a `runstate.sh` subcommand that prunes answered entries from
  `pending_questions`, and the skill sites that re-persist the list naming it.
- counting a retry-past-limit stop in `run-tally`'s DECISIONS figure, and the
  template's 🔀 definition naming it.
- regression cases in the sweeps that own each changed file.

**Out**
- a new outcome state.
- any change to the digest's four line kinds, the glyph vocabulary, the three
  shapes, or `report-lint.sh`'s rules.
- any change to how findings expire (that is `stale-finding-expiry`'s).

**Deferred**
- None beyond the Deferred Decisions below.

## Capabilities

- [ ] **P0**: Each `pending_questions` entry records when it was asked
  - pause's persist step stamps each new entry with `asked_at`, the `ts` of the
    routing record that raised it (the latest record for that packet routed
    `stop`), written as a quoted field
  - `asked_at` is part of the entry shape in `templates/run-state.yaml`,
    alongside `id`, `severity`, `packet` and `question`
  - entries already in the list are carried through with their `asked_at`
    unchanged

- [x] **P0**: A core subcommand prunes answered entries from `pending_questions`
  - an entry is dropped when its `packet` has a start, continuation or
    `abandoned` record whose `_rs_ts_key` is strictly later than its
    `asked_at`. This is the parent's liveness rule, unchanged. A tie or a
    `blocked` record does not answer, and the entry is kept. When one packet
    stops twice, the answered first question is dropped and the live second
    one is kept
  - an entry with no `packet:` or no `asked_at` (legacy, crash-recovered or
    hand-supplied) is kept, which fails toward over-reporting
  - the file is written through the existing run-state writer. Every other key,
    including `findings:`, is carried through byte-identical. When nothing is
    dropped, the file is left unchanged

- [ ] **P0**: The prune runs wherever the list is re-persisted
  - pause's persist step and resume's entry each run the subcommand before the
    list is written or rendered
  - those two sites and run-loop's "carrying every existing entry through"
    sentence name the subcommand instead of restating the rule. The change at
    each site is prose only

- [x] **P0**: `run-tally` counts a retry-past-limit stop as a decision
  - a routing record whose `retry` token was routed `stop` counts as one 🔀
    decision while it is still awaiting, by the same liveness rule as an
    `ask-operator` line
  - `SHIPPED`, `FAILED` and `UNFINISHED`, and run-digest's four existing line
    kinds, are byte-identical to today's output for the same run
  - the 🔀 definition in `templates/report-templates.md` names the
    retry-past-limit stop as a counted decision

- [x] **P0**: The prune and the new count are pinned by core sweep cases
  - `scripts/test-runstate.sh` has one prune case per answering kind (start,
    continuation, `abandoned`), each dropping the entry. It also has cases
    keeping an unanswered entry, a tied entry, an entry with no `packet:` and
    an entry with no `asked_at`, a case where one packet stops twice (the
    answered first question is dropped, the live second one kept), and a case
    where `findings:` survives the prune byte-identical
  - a retry-past-limit stop yields `DECISIONS=1` when unanswered and
    `DECISIONS=0` when a later start answers it, and a `retry` routed
    `attempt` yields `DECISIONS=0`
  - the existing `run-tally` fixture figures are unchanged

- [ ] **P1**: A report after a second stop lints clean
  - a `scripts/test-report-conventions.sh` fixture has a run that resumes,
    answers a question and stops a second time. Its body is rendered from the
    pruned list and its header from `run-tally`, and it yields no
    decision-count finding
  - a control fixture that skips the prune yields a decision-count finding

## Dependencies

- `stop-report-decision-liveness`: the parent. It defined the liveness rule and
  `run-tally`'s still-awaiting figure that the body is brought into line with.
  Derived-done, and nothing here reopens it.
- `thin-loop-driver`: owns the routing records, the retry limit that routes a
  `retry` to `stop`, the outcomes log the rule reads, and the resume path.
- `report-render-conformance`: owns `run-tally`, `report-lint.sh` and the
  template's tally sentence.
- `stale-finding-expiry` is related but not a dependency. It expires a
  different list, run-state's findings, on a different answering signal.

## Assumptions & Risks

- Assumption: a `pending_questions` entry carries its `packet` and `asked_at`,
  as pause stamps them from `run-loop`'s `stop` action. An entry without either
  is kept, so the failure is a lint finding, never a silently dropped question.
- Risk: the pruning call is still placed by prompts. A future site that
  re-persists the list without naming the subcommand re-opens the gap. The
  decision-count rule is what detects it.
- Risk: a question the operator answers without any start, continuation or
  `abandoned` record keeps its block, the same over-reporting direction the
  parent accepted.

## Success Metrics

- For questions raised by `ask-operator` or a retry-past-limit stop, after any
  number of resume/stop cycles, the stop report's 🔀 header figure equals
  `run-tally`'s DECISIONS, and the body renders exactly that many blocks from
  the pruned list. A question a human supplies by hand is outside this metric:
  it renders a block that `run-tally` never counts.
- The fixture named in the sixth capability pins the lint half of that metric
  on every change.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Which helper computes the rule** — a new shared liveness helper, or the
  existing `_rs_tally_live_questions` called by both. Either satisfies the
  capabilities as long as there is one definition of the rule in code.
