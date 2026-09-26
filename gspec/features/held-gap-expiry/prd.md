---
spec-version: v2
depends_on: [completion-record-drift-gaps]
---

# Feature: held-gap-expiry

## Overview

Completing a feature is what files the next one. Six of this repository's 29
features are second-order corrections, each filed because a completed feature's
closing whole-branch review found something — two in late August, then four in
three days — while 16 of the 29 still have no plan at all. The routing already
stops short of filing autonomously. What is left is that a gap is put to the
operator as a proposal the moment it is found, whether or not it is still real
by the time they reach it, and every proposal that survives becomes a permanent
row in a backlog nowhere near draining.

This feature adds a step before the proposal. A gap that has not been accepted
as work is written to a **holding pen** instead. At each run's preflight every
held entry is re-tested: the ones that no longer reproduce are dropped with the
evidence recorded, and the ones that still reproduce are reported with their age
and reproduction status. A gap that later work incidentally fixed leaves without
anyone deciding anything. The shape has a precedent here already —
`.gspec/memory/pending/` holds agent-written memories awaiting a batch review:
capture cheaply on discovery, decide later, in bulk.

## Users & Use Cases

- **The operator reading a stop report** — is asked to accept or decline a
  proposal at the moment a review produced it, with the least information they
  will ever have about whether it matters. A candidate they can defer without
  losing it is the decision they actually want to make.
- **The operator reading a kickoff** — decides which held candidates now deserve
  a feature, and needs each one's age and re-test result rather than a list that
  looks the same every morning.
- **The agent routing a finding at the end of a run** — needs somewhere to put
  something real that no open capability covers, which is neither a permanent
  backlog row nor a findings entry the routing rules already refuse.
- **A later run re-testing an entry it did not write** — holds the entry and
  nothing else, so the re-test has to be runnable and self-judging.
- **The operator scanning the backlog for what to build next** — must never have
  to tell accepted work from a candidate nobody agreed to.

## Scope

**In**
- the severity gate on the second routing arm: which findings are held and which
  are proposed on the run that found them.
- what a held entry records, including its re-test and the condition that judges
  the re-test's result.
- the preflight re-test pass: what it drops, what it keeps, and what it reports.
- the treatment of a recorded re-test command as untrusted, bounded input.
- the boundary between the pen and the specification backlog.
- what a held entry must survive and the storage state it must never sit in.
- a regression case for every change a sweep can reach.

**Out**
- the first routing arm — appending an unchecked task line to an incomplete
  feature's plan. Unchanged, and still tried first.
- deriving completion, ordering, scheduling or packets from the pen.
- filing a feature from a held entry without the operator.
- re-testing anything other than a held entry; the run-state findings index
  keeps its own packet-scoped expiry.
- blocking, halting or failing a run because a re-test could not run, returned a
  bad verdict, or still reproduces.
- a new severity vocabulary; the gate reads the classes the whole-branch review
  already assigns.
- reconciling the features already filed by the path this replaces.

**Deferred**
- Re-testing held entries at termination as well as preflight, so a gap the run
  itself fixed leaves in that run rather than at the next preflight.
- Promoting an entry that has reproduced on many consecutive runs into a
  proposal without the operator asking for it.
- A bound on the pen's size, and what happens when it is reached.

## Capabilities

- [ ] **P0**: A critical gap is proposed on the run that found it; only an important one is held
  - the second routing arm gains one test, applied to the severity the
    whole-branch review already assigns: a **Critical** finding is reported as a
    feature proposal in the stop report exactly as it is today, an **Important**
    one is written to the pen and reported as held, and — because the labels are
    free text no schema enumerates — a finding carrying neither label is
    proposed, never held. No third class is introduced and no severity is
    re-judged by the gate — prose only — no sweep case
  - the gate is worked against the live Critical case named in Dependencies: a
    defect that makes the loop's own state reports untrustworthy is proposed on
    the run that finds it, because it cannot sit in a pen waiting to be
    re-tested by the very reporting it undermines

- [ ] **P0**: An entry is holdable only with a self-judging re-test; a gap without one is proposed and never held
  - an entry is holdable only with a re-test recorded at the moment it is held,
    in one of exactly two forms: a **command** that reproduces the gap, or —
    where the gap is a prose or cross-document inconsistency no command reaches
    — a **named concrete read**, giving both sites and the question the reader
    answers, in the form this repository's plan tasks already use
  - the re-test carries its own judging condition: what output, exit status or
    answer counts as *still reproduces* and what counts as *does not*, written so
    a later run can reach a verdict holding the entry and nothing else
  - a finding with neither form is routed to the existing proposal path on the
    run that found it and never enters the pen, because a gap that cannot be
    re-tested can never expire, and an entry that can never expire is precisely
    what the findings expiry rule was built to remove — prose only — no sweep
    case

- [ ] **P0**: An entry is dropped only on positive evidence that it no longer reproduces, and every drop leaves a record
  - an entry is dropped only when its re-test ran to a verdict and that verdict
    is *does not reproduce*. A re-test that could not run, was refused, errored,
    timed out, or returned an ambiguous result reads **unknown**, and unknown
    keeps the entry — as do "nobody has seen it lately" and "later work probably
    covered it", neither of which is a re-test result
  - a re-test that still reproduces keeps the entry and updates its last-tested
    record. Nothing expires on elapsed time, on run count, or on absence from any
    list
  - a drop writes the run that dropped it, the re-test that was run, and the
    verdict, outside the entry it removes and in storage that is tracked, or
    ignored by both ignore files, and never untracked-and-unignored — so a wrong
    drop is visible afterwards rather than silent. The write is asserted by the
    sweep case of the capability below

- [ ] **P0**: Preflight re-tests the whole pen under a bound, and nothing the pass does can halt a run
  - preflight re-tests every held entry and the kickoff reports each surviving
    entry with its age and whether it reproduced on this pass, plus the number
    dropped — reported outside the header tally and under no glyph the tally
    counts, so a held candidate never renders as queued work. An empty pen
    reports nothing
  - no result of the pass is a stop — not a re-test that fails or is refused, not
    an unreadable or absent pen, not an entry that still reproduces, not every
    entry reproducing at once. The pass reports and the run continues, the same
    standing rule the read-only scans beside it already obey
    (`skills/run-loop/SKILL.md` §1)
  - a recorded re-test command is treated as untrusted agent-written input: it
    passes the same guard tiers as every other command the run issues and is
    never itself an authorization to run something the run could not otherwise
    run, and it is **non-mutating and bounded** — it may read, search and run the
    repository's own sweeps; it never writes a tracked file, installs, deploys or
    contacts the network, and it runs under a time bound. A recorded command
    outside that bound is not holdable and is routed to the proposal path of the
    capability above; a command the guard refuses, and one that exceeds the time
    bound, each yield **unknown** rather than a bypass or a prompt-driven retry
  - a case in the sweep that owns the pen's commands — registered in the set the
    repository already runs — asserts all three outcomes on one fixture: an entry
    whose re-test reproduces survives, one whose re-test returns the
    non-reproducing verdict is dropped with its drop record written, one whose
    re-test cannot run survives as unknown, and the command's exit status is
    identical in all three

- [ ] **P0**: The pen holds candidates and never becomes a second backlog
  - nothing schedules from the pen, orders from it, derives completion from it,
    or yields a packet from it: the adapter that reads the specification backlog
    does not read the pen, and no held entry appears in any list the loop picks
    work from
  - no pen entry names work that exists in the specification backlog —
    checkable by reading the pen against `gspec/features/` — and the context
    that files the feature or appends the task line removes the entry in the
    same change
  - only the operator accepts. No run files a feature from a held entry, whether
    or not driver mode has exited, and what the loop emits about the pen is a
    report and a question, never a command it then runs itself — prose only — no
    sweep case

- [ ] **P0**: A held entry survives a fresh checkout and never sits in the state that destroys it
  - an entry written on one machine is readable after a fresh clone on another —
    unlike the run-state and its findings index, which are same-machine execution
    bookkeeping by design and are ignored for that reason
  - the pen is never left untracked-and-unignored: the pause path stashes
    untracked files and the checkpoint reconcile discards them as scratch, so an
    entry in that state is destroyed by the very run that held it. It is either
    tracked, or ignored by both this plugin's ignore file and the consumer
    template's — never neither, asserted by a sweep case reading both ignore
    files, the same class of assertion the retrofit and report-format sweeps
    already carry

## Dependencies

- `completion-record-drift-gaps` — corrects the two sites this feature extends:
  the preflight reporting of a read-only scan and the termination routing block.
  Ordered behind it so the two are not editing the same prose at once.
- `thin-loop-driver` — owns the termination routing block, the stop-report
  question carrier a proposal travels on, and the rule that the driving session
  does not file the feature itself. Derived-done; no capability re-opened.
- `run-state-cleanup` — owns the findings index, its packet scoping and its
  positive-evidence expiry rule, which this feature applies one level up to a
  different artifact with a different expiry event. Derived-done and unchanged.
- `stale-finding-expiry` — **not blocking**: same evidence principle, different
  artifact, and a different boundary in the same skill file, so the two should
  not be in flight at once.
- `next-state-reporting-integrity` — **not blocking**: it is the live Critical
  case the severity gate is worked against, and under that gate it is proposed
  rather than held.

## Assumptions & Risks

- Assumption: the whole-branch review's Critical/Important judgement is reliable
  enough to gate on. It already decides whether a finding is routed at all, so
  the gate attaches a consequence to a judgement already being made.
- Risk: severity is prompt-assigned, so an Important-labelled defect that is
  really Critical waits in the pen. The detector is the pen's own report — an
  entry that reproduces on consecutive runs and describes the loop misreading
  its own state was misclassified.
- Risk: the re-test is written by the run that found the gap, and one wrong in
  the *does not reproduce* direction expires a real gap quietly. Nothing verifies
  a re-test's fidelity — the same prompt-enforced discipline the existing
  capture-before-drop rule carries, with the drop record as its only trace.
- Risk: four of these six capabilities land wholly or partly on routing and
  reporting prose the sweep cannot reach; the reviewer is the only gate there,
  named as such rather than covered by a case asserting a string is present.
- Risk: re-testing the whole pen at every preflight costs time and context, and
  an unbounded pen makes preflight grow with it. The bound is deferred above
  rather than assumed unnecessary.
- Accepted consequence: a held candidate can be lost by the operator never
  reading the report that names it. That is the same exposure an unfiled proposal
  already carries, traded for candidates that disappear on their own when they
  stop being real.

## Success Metrics

- Candidates that stop reproducing leave without an operator turn: over any span
  of runs, the count of drops carrying a non-reproducing verdict is countable
  from the drop records, against the feature folders that would otherwise exist.
- Every entry in the pen carries a re-test and its judging condition — countable
  by reading the pen; an entry without either is a defect, not a rough edge.
- No entry is dropped without a recorded verdict of *does not reproduce* —
  checkable one drop record at a time.
- No run's stop reason, recorded outcome or exit changes because of the pen —
  checkable per run against its own report.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Where in the tree the pen lives, and an entry's file format.** The observable
  properties are decided above — survives a fresh checkout, never
  untracked-and-unignored, readable at preflight — and the path and format are a
  decomposition call, together with whether the pen's commands join the existing
  run-state tooling or take a script and a sweep of their own.
