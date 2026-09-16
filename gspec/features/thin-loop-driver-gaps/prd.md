---
spec-version: v2
depends_on: [thin-loop-driver]
---

# Feature: thin-loop-driver-gaps

## Overview

The defects the whole-branch review of `thin-loop-driver` found in that feature's
own output, together with four the operator hit while running the branch that
produced it. They sit on one surface: the digest → report pipeline driver mode
introduced, the two loop skills that drive it, the guard rule that enforces it,
and the documents that describe it. Two corrupt or contradict a report on
ordinary input, so they degrade every run until they are closed; the rest are
corrections to statements that are simply wrong.

Split out rather than appended, on the `metrics-coverage-gaps` precedent: the
parent is derived-done — all six capabilities checked, all twenty-four task
lines checked — so an unchecked capability added to it would make shipped work
read as incomplete forever and block everything downstream through the
dependency rule. The parent shipped; this is new scope against it.

## Users & Use Cases

- **The operator reading a stop report** — decides what needs their attention
  from the header tally and the one line per packet. A tally that disagrees with
  the sections beneath it, or one packet reported twice with contradictory
  glyphs, spends the trust the report exists to earn.
- **A driver session mid-run** — records a durable preference, resumes a run
  that stopped on a question, and reconciles a working tree that holds output it
  did not produce. Each of those is currently refused, mis-swept, or misjudged.
- **A later reader of the measurements** — reconciles two numbers derived from
  the same records, and must be able to tell a divergence by design from a
  defect, and an unmeasured value from a zero.
- **An agent reading the repository's standing instructions** — obeys them as
  standing instruction, so a superseded rule left there actively competes with
  the contract that superseded it.

## Scope

**In**
- the digest's one-line-per-item contract, and the title interpolation that
  breaks it.
- the two loop skills' open-packet sweep calls, and which runs exclude the
  cursor packet.
- the stop report's decision tally and the kickoff's session line.
- the value of the tool's own compaction default and whether it is ever stated.
- driver mode's write refusal where the target cannot reach any packet.
- the reconcile decision that classifies an untracked tree, and the instruction
  that acts on it.
- the standing-instruction file, the digest's header comment, and the
  null-semantics wording the measurement and its skill share.
- a regression case for every change a sweep can reach.

**Out**
- probing whether a plugin can supply a compaction default without overriding a
  repository's own value — that probe is what the current pure-reader design
  deliberately waits on.
- changing which enter record either consumer selects.
- new report shapes, new measurement fields, new outcome states.
- anything in the escalation decider's scope.
- re-opening, re-wording or re-checking any of the parent's capabilities.

**Deferred**
- Applying a compaction default supplied by the plugin, if a later probe shows it
  can be done without overriding a repository's own value.
- Giving the digest's enter record a source field, if the session line ever needs
  more than the reader call the skill already makes can supply.

## Capabilities

- [ ] **P0**: The digest emits one line per item, whatever a task title contains
  - a packet whose title carries a literal backslash sequence — `\n`, a Windows
    path — yields exactly one digest line for that packet with its leading type
    field intact (`_rs_digest_title` in `scripts/runstate.sh`), honouring the
    repository's standing rule against escape-processing interpolation
  - the packet id interpolated beside it is left as it is — charset-validated
    with no backslash — so the change is scoped to the one value carrying
    arbitrary task prose
  - `scripts/test-runstate.sh` gains a case with a backslash-bearing title
    asserting one output line for that packet and no fragment lacking a type
    field; the existing hand-off fixture does not cover this case, its
    backslashes sitting in the status field

- [ ] **P0**: A packet continued in the same run is reported once, with one outcome
  - the loop's open-packet sweep call states the rule as: the cursor packet is
    excluded exactly when this session is about to continue it (the call in
    `skills/run-loop/SKILL.md` omits the cursor argument that
    `skills/resume/SKILL.md` passes)
  - the report renders one line for that packet carrying its real outcome, never
    a swept-as-interrupted line and a landed line for the same id in the same
    report; one glyph, one meaning
  - no `interrupted` record for that packet enters the append-only outcomes log,
    where a false record is permanent
  - `scripts/test-runstate.sh` covers a continued cursor packet under the
    run-loop call shape, not only the resume one

- [ ] **P1**: A run that stopped on a blocking question resumes like a paused one
  - resume's sweep states the rule in the same words: the cursor packet is
    excluded exactly when this session is about to continue it — that situation,
    not one status value as today (`skills/resume/SKILL.md` passes the cursor only
    when the status reads paused, while a run stopped on a question reads blocked)
  - resuming such a run therefore writes no `interrupted` record for the packet
    it is about to continue, closing the same false-record path as the capability
    above from the other call site
  - everything the sweep closes today still closes, the exclusion reaching only
    the cursor packet: a crash, or a run whose work is gone, still writes
    `interrupted` for it, so the rule cannot be written as "never close the
    cursor"
  - `scripts/test-runstate.sh` covers a resume from a status the rule admits and
    one it excludes; the skill prose selecting between them is prose only — no
    sweep case

- [ ] **P1**: Reconcile separates the loop's own scratch from deliberate output it did not produce
  - the discard decision, and the instruction that acts on it, distinguish a
    packet's uncommitted work from untracked files the loop did not create; the
    second is escalated to the operator before anything is set aside, matching
    the instinct the pause path already carries (`skills/pause/SKILL.md`) and the
    reconcile path in `skills/resume/SKILL.md` does not
  - worked example that must come out right: thirteen untracked files under a
    reviewed-output directory — agent memories awaiting operator review —
    returned a discard decision from the reconcile classifier in
    `scripts/runstate.sh`, and following the instruction literally would have
    stashed unreviewed work
  - the ordinary case is unchanged: a packet's own uncommitted scratch sitting on
    the green checkpoint is still set aside non-destructively without asking, so
    the escalation cannot be written as "escalate on any dirt"
  - where the discrimination lands in the script, `scripts/test-runstate.sh`
    covers both tree shapes; where it lands in skill prose it is prose only — no
    sweep case

- [ ] **P1**: Driver mode refuses only writes that could reach a packet
  - a write whose target cannot enter any packet's commit — anything outside the
    repository the loop is driving — no longer draws driver mode's refusal; every
    other tier still judges it, the secret/key-material floor first. The permitted
    class is the criterion, not a list of paths
  - the refusal's stated remedy is reachable for every write it refuses: the
    current one in `hooks/guard.sh` ("write temp files under `.agents/`") does
    not apply to a target outside the repository at all
  - worked example: a driver-mode session could not write its own agent-memory
    file, which lives outside the repository entirely, so a durable preference
    could not be recorded until the run ended
  - `scripts/test-guard.sh` covers a permitted write outside the repository, an
    out-of-repository target the secret floor still hard-denies, an unchanged
    refusal for an in-repository target outside `.agents/`, and a
    repository-relative target that resolves outside, which stays refused for
    being unverifiable

- [ ] **P1**: The kickoff never states a compaction threshold that is not in effect
  - when the threshold reader in `scripts/runstate.sh` names no value in effect —
    which it does whenever neither repository nor operator set one, the default
    state, this repository included — neither consumer states a number: the
    kickoff and the resume session line carry no threshold line at all, and the
    driver-mode context measurement in `scripts/metrics.sh` reports null for both
    of its fields rather than flagging context over a threshold nothing enforces.
    The condition is the reader's `SOURCE`, never its `APPLIED` field, which reads
    `no` on every path — including one an operator set and the harness genuinely
    enforces, which must still be stated
  - the tool's own invented default in `scripts/runstate.sh` is removed rather
    than corrected, that branch reporting `unknown` with a source naming nothing
    in effect: ADR 0028 result 3 records `1m tokens` as the default *on Opus 5
    (1M)*, a model-conditional reading rather than a harness-wide one, and the
    ADR's own instruction to this reader is to report `unknown` rather than
    invent one. The two sweep cases pinning the old 200000 change with it
    (`scripts/test-runstate.sh`, `scripts/test-metrics.sh`)
  - the kickoff shape gains no source slot and the digest's enter record no fourth
    field
  - both loop skills carry the same instruction for that line, where one asks for
    a source today and the other omits the instruction entirely

- [ ] **P1**: The stop report's decision tally matches the sections it indexes
  - one handed-off packet contributes exactly one to the header's decision count,
    matching the single decision block the body renders for it
    (`templates/report-templates.md:146` counts both lines of the routing record;
    `:186` renders one block)
  - the routing record still emits two lines — deliberate, and pinned in
    `scripts/test-runstate.sh` — so the correction lands in the counting rule,
    never in the digest
  - the header tally reads as a table of contents: every glyph it counts has a
    section beneath it, and every section a glyph in the tally
  - prose only — no sweep case: a run with one handed-off packet and one operator
    question renders a header reading two decisions above a body holding two
    decision blocks

- [ ] **P1**: The standing instructions describe the loop that actually runs
  - the per-packet report shape is named correctly where the harness reads it as
    standing instruction: it covers every **ended** packet — failed, blocked and
    interrupted included — not only landed ones (`CLAUDE.md:760`, stale since the
    rename that the loop skill already carries)
  - the green-count rule carries the exception that supersedes it for the stop
    report, naming the template that is now the authority, and drops its
    reference to a per-packet report the loop no longer produces
    (`CLAUDE.md:576`, `:604`)
  - the end-of-run review's scope in `skills/run-loop/SKILL.md` expresses **this
    run's integrated work** rather than everything the integration branch has
    accumulated since its base; worked example, on the run that found these
    defects the branch-versus-base scope was 211 files and about 30,000
    insertions of already-reviewed earlier work, against 25 files for the run
    itself, and the corrected rule selects the 25. All three surfaces here are
    prose only — no sweep case

- [ ] **P1**: The digest's documented mechanism is the one it uses
  - the header comment and the template both describe the digest as reading the
    routed status recorded for a hand-off, not as reading result files, which it
    never opens (`scripts/runstate.sh`, the run-digest header;
    `templates/report-templates.md:24`)
  - the correction makes the routing call's status argument read as load-bearing:
    a routing call that omits it leaves the hand-off line with an empty status and
    the stop report silently loses the question text, with no result file to fall
    back on
  - the constraint the parent specified — the driver never opens a result file —
    is restated unchanged
  - the two descriptions and the code name one mechanism, checkable by reading
    the three together — prose only, no sweep case

- [ ] **P2**: The measurement's nulls read unambiguously
  - the sentence defining what the two context fields' nulls mean no longer
    contradicts the sentence after it: they are not **always** null together, and
    one is forced null when the other is. The contradiction survives only in
    `scripts/metrics.sh`, in two comment blocks — `skills/metrics/SKILL.md` has
    already been corrected to "independently, not together", so the wording is no
    longer shared and only the additions below are owed to that copy
  - the two consumers that select a different enter record — the digest takes the
    most recent across sessions, the measurement the earliest in scope — carry one
    sentence naming the divergence and why each is right for its own use
  - the assumption that a later re-entry carries the same setting is stated as an
    assumption rather than as fact

## Dependencies

- `thin-loop-driver` — supplies every surface corrected here: the digest, the
  report shapes, the two loop skills, the driver-mode write rule. Derived-done;
  nothing here re-opens a capability or edits a checked task.
- `loop-measurement` — owns the outcome records the continued-packet and resume
  capabilities keep honest, and the context measurement whose null semantics the
  last capability clarifies. **Not blocking:** the shipped outcomes half is what
  is depended on, and the deferred spend tail shares no files with this feature.
- `escalation-decider` — consumes the routing records whose documented mechanism
  is corrected here. Not built; nothing in this feature blocks it.
- `retire-autonomy-levels` — **not blocking.** The end-of-run review scope is
  stated at one autonomy level today; this feature corrects whatever branching
  exists when it is built.

## Assumptions & Risks

- Removing the invented compaction default retires an assumption this feature
  would otherwise have carried — that ADR 0028 result 3's `1m tokens` is a
  harness-wide default rather than a reading taken on one model. It is not, which
  is why the value is removed rather than corrected.
- Assumption: the two loop skills are the only callers of the open-packet sweep,
  so aligning them breaks nothing that works today.
- Risk: four of these ten capabilities land entirely on surfaces with no
  regression sweep, and part of two more — the report templates, the
  standing-instruction file, the digest's header comment, and skill prose. Their
  only detector is a careful read, which is the same detector that missed them.
- Risk: the tally and threshold corrections change what a report says. A reader
  who learned the old numbers will read the new ones as a regression unless the
  wording lands with them.
- Risk: widening what driver mode permits weakens a control by construction. The
  permitted class must be stated so it cannot be read as "anything the driver
  judges harmless".

## Success Metrics

- No stop report contains one packet reported twice, a line split into fragments,
  or a header count that disagrees with the sections beneath it — checkable per
  report, on every run after release.
- No `interrupted` record exists in the outcomes log for a packet that was
  continued rather than cut short — countable directly from the append-only log.
- No kickoff states a threshold the session is not using, and no context
  measurement flags a threshold nothing enforces; both read as unmeasured
  instead.
- A driver-mode session records a durable preference during the run rather than
  after it, and the number of refusals whose stated remedy does not apply to the
  refused target is zero.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Whether the end-of-run review's scope is computed or stated.** A recorded
  range of the packets this run landed, or a rule the driver applies when it
  builds the diff, both satisfy the criterion; the choice is a decomposition
  call, not a scope one.
- **Whether a compaction default is ever applied rather than only reported.**
  Deferred until someone probes whether a plugin can supply one without
  overriding a repository's own value — the probe that was deliberately left
  unrun.
- **Renaming `sweep-open`'s `--paused-cursor` flag.** Once the exclusion rule
  reads "about to continue it" rather than "paused", the flag name is
  misleading. Renaming it touches every caller and the sweep cases that pin it
  for no behaviour change, and widens a diff whose only defect-detector on the
  prose surfaces is a careful read — so it is left for a standalone tidy.
