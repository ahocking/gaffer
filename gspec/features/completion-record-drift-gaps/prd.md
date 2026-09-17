---
spec-version: v2
depends_on: [completion-record-drift]
---

# Feature: completion-record-drift-gaps

## Overview

Four defects the whole-branch review of `completion-record-drift` found in that
feature's own output. One can invert the detector's central test and report drift
where there is none — the exact direction the parent's unjudgeable-never-drift
rule forbids. One puts a permanently unactionable figure in front of the operator
on every future run. Two are smaller: a reporting site that names the section but
not whether the line it carries takes a glyph, and a latent mismatch between two
patterns that reads one malformed capability line as several unjudgeable rows.

Split out rather than appended, on the `metrics-coverage-gaps` precedent: the
parent is derived-done — all five capabilities checked, all five task lines
checked — so an unchecked capability added to it would make shipped work read as
incomplete forever and block everything behind it through the dependency rule.
The parent shipped; this is new scope against it.

## Users & Use Cases

- **The operator reading a kickoff** — decides what needs their attention from
  it. A drift line naming a capability that is not drifted costs a trip into two
  files to disprove; a fixed figure that no edit can move teaches them to skip
  the whole clause, including the run where it changes.
- **The run whose scan is asked the question** — gets one answer per capability
  and has no second source to check it against. A wrong answer here is obeyed as
  the finding, not noticed as a bug.
- **A later reader of the detector's own source** — meets two patterns for the
  same thing that disagree about where a capability line may begin, and needs to
  know whether the divergence is a decision or an oversight.
- **The reviewer of the two reporting sites** — is the only gate on prose the
  loop reads at dispatch, so a vocabulary claim there has to be checkable by
  reading it against the conventions it cites.

## Scope

**In**
- the all-covering-tasks-checked test, and the construct whose failure mode can
  be read as its own negation.
- which features the scan visits — judged by the completion derivation the
  adapter already applies — and what a feature that reads as complete under it
  can contribute.
- the line form the termination site gives the drift lines it carries into the
  stop report.
- the anchoring divergence between the capability-line pattern completion
  derivation reads and the one the verbatim quote matcher applies.
- a regression case for every change a sweep can reach.

**Out**
- flipping a capability checkbox, or any widening of the adapter's write surface.
- blocking, halting or failing a run on drift, at either reporting site.
- changing how completion is derived, the three unjudgeable classes and their
  names, or the verbatim quote *comparison* (exact text, never a nearest guess) —
  the capability-line pattern that comparison reads is the fourth capability's
  business.
- a new report shape, glyph, tally figure or outcome state.
- reconciling the record of any feature whose plan carries shorthand `covers:`
  labels — those task blocks are checked and their record stands.
- re-opening, re-wording or re-checking any of the parent's capabilities.

**Deferred**
- Reporting the unjudgeable figure anywhere other than the kickoff, once the
  completion skip has removed the standing noise from it.
- Collapsing a feature whose plan resolves no `covers:` at all to one line rather
  than one per capability — the parent's own deferred decision, still open and
  still satisfied either way.

## Capabilities

- [ ] **P0**: The drift test cannot invert into a report of drift it did not find
  - a capability with at least one **unchecked** covering task emits no `DRIFT=`
    line, on every run, however the shell schedules the processes evaluating that
    test — the test is no longer expressed as a pipeline whose reader may close
    the pipe before its writer finishes (`scripts/gspec-backlog.sh`, the negated
    `printf | grep -qx` test, evaluated under the `pipefail` setting earlier in
    the same file, where a writer's resulting signal exit is reported in place of
    the reader's success and the leading negation turns it into a finding), and
    the construct is removed rather than probed for
  - this correction alters nothing else: for every input the test judges
    correctly today it yields the same three unjudgeable classes, the same
    per-capability drift lines, the same counted summary fields
  - `scripts/test-gspec-backlog.sh` gains a case over a capability covered by
    both checked and unchecked tasks, asserting that capability absent by name
    from every `DRIFT=` line **and** a genuinely drifted capability present in
    the same run, so it cannot pass by the detector reporting nothing

- [ ] **P1**: A feature that reads as complete contributes nothing to the scan
  - a feature that **reads as complete under the same derivation the adapter
    already applies** — at least one recognized capability line, and every one of
    them checked — emits no `DRIFT=` line and no `UNJUDGEABLE=` line of any class.
    No drift finding is lost to the skip, since the drift condition is reachable
    only from an unchecked capability. The justification is that property alone —
    the scan's question, *should this box be checked*, is answered for every
    capability there — and **never the number of rows this happens to remove in
    any one repository**
  - every other feature is still scanned, its unmatched-quote rows
    included: one with an unchecked capability, and equally one whose PRD offers
    no recognized capability line at all, which the derivation reads as **not**
    complete and where those rows are the only signal left. So the skip cannot be
    read as *skip features whose plan carries shorthand `covers:` labels* — the
    offending plans are skipped for reading as complete, and would be scanned
    again the moment one of their capabilities were unchecked
  - `scripts/test-gspec-backlog.sh` gains a case in both layouts the sweep already
    builds: a fully-checked feature whose plan carries an unmatchable `covers:`
    quote yields no line and does not raise the summary's `unjudgeable` count,
    while the same fixture yields that row again both with one capability
    unchecked and with its capability lines in a form the derivation does not
    recognize

- [ ] **P1**: The termination reporting site states a line form that does not collide
  - the site that carries each drift line into the stop report states the form
    those lines take there: an unglyphed line under `▶ Next`, the section the
    header tally does not count. It does not reuse ⚠️ — the report conventions
    reserve that glyph for a tally-counted section carrying one line per packet,
    and a drift finding is not a packet — and it introduces no new glyph. Checkable
    by reading the two sites against `templates/report-conventions.md`
    (`skills/run-loop/SKILL.md` §4)
  - the preflight site's ⚠️ is unchanged: in the kickoff that glyph is already an
    uncounted line, so the two sites differ by explicit statement rather than by
    one of them saying nothing
  - nothing else at either site changes: no tally figure, packet count or recorded
    outcome moves, and no template gains a slot, glyph or shape for the finding

- [ ] **P2**: The two capability-line patterns' anchoring divergence is resolved or recorded
  - the divergence is either removed, or — where it stands — recorded at **both**
    pattern sites by a comment naming the other pattern, the indented-line
    behaviour and the safe direction: an indented but otherwise canonical
    capability line is enumerated by the pattern completion derivation reads and
    declined by the verbatim quote matcher, so one such line yields
    `uncovered-capability` plus one `unmatched-quote` per covering task, never
    drift
  - whichever close is taken, that safe direction is preserved: an indented
    capability line never produces a `DRIFT=` line except where its covering
    tasks are all checked and its own box is not — the condition every other
    capability is judged by
  - an alignment is made by widening the stricter pattern, never by narrowing the
    one completion derivation reads: changing which lines count as capabilities
    would change which features read as done, which is out of scope here. The
    stricter pattern is also read by the hand-off path, so a widening is judged
    against both callers
  - a close that changes either pattern carries a case in
    `scripts/test-gspec-backlog.sh` over an indented capability line, asserting it
    resolved by both patterns and emitting no `DRIFT=` line except where its
    covering tasks are all checked and its own box is not

## Dependencies

- `completion-record-drift` — supplies every surface corrected here: the
  detector, its three unjudgeable classes, its counted summary, and the two
  reporting sites. Derived-done; nothing here re-opens a capability or edits a
  checked task line of it.
- `run-state-cleanup` — owns the preflight drift scan the corrected site sits
  beside and the report-never-flip-never-block rule inherited at both sites.
  Derived-done; unchanged by this feature.
- `thin-loop-driver` — owns the report shapes and conventions the third
  capability holds the termination site to, and the hand-off path that shares the
  quote matcher the fourth capability names. Derived-done; no new shape is added.
- `gspec-adapter-consistency` — **not blocking, but file-overlapping**: it
  refactors this adapter's shared pattern blocks and adds cases to this same
  sweep. No logical dependency in either direction; the two should not be in
  flight against the same files at once.

## Assumptions & Risks

- Assumption: the inverting test is the only place in the detector where a
  reader may close a pipe before its writer finishes. If a second exists, it has
  the same failure direction and is in scope for the same correction.
- Accepted consequence: the skip makes the scan silent about features that read
  as complete. That is the intent — an unjudgeable row about a reconciled record
  is uninformative by construction — and the cost is that a plan defect inside
  one is no longer surfaced by this command.
- Risk: the first capability's defect is rare by construction, so a green sweep
  is weak evidence either way. The detector for the change is a reading of the
  construct, not an observed failure before or after.
- Risk: two of these four land partly or wholly on prose and pattern-reading
  surfaces the sweep cannot reach; the reviewer is the only gate there, named as
  such rather than covered by a case asserting a string is present.
- Risk: the fourth capability admits a close that changes no behaviour. Stated
  plainly so it is not later read as work silently dropped.

## Success Metrics

- No `DRIFT=` line names a capability that still has an unchecked covering task —
  checkable per report against the plan it names, on every run after release.
- Every `UNJUDGEABLE=` row the scan emits belongs to a feature that does not read
  as complete under the adapter's own derivation — countable directly from the
  command's output, against the PRDs it names.
- No reporting site places a non-packet line under a tally-counted glyph,
  checkable by reading the two sites against the conventions file.
- The adapter's write surface is unchanged — one task-checkbox flip — and every
  change here adds none: pinned by the parent's existing checksum case, which
  stays green.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Whether the anchoring divergence is closed by code or by documentation.**
  Both satisfy the fourth capability; the choice needs a reading of the quote
  matcher's other caller, which is a decomposition call rather than a scope one.
- **Whether the un-piped drift test is expressed as a here-string, a pattern test
  over the joined values, or an accumulator carried through the enumeration.**
  All three remove the construct; the choice is an implementation call.
