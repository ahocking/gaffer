---
spec-version: v2
depends_on: [thin-loop-driver]
---

# Feature: handoff-verification-contract

## Overview

Under `thin-loop-driver` the driver dispatches an implementer and a reviewer
with a handoff file path as their whole brief and never opens a result file,
so the reviewer is the only check on an agent's self-report, and the gate's
strength tracks the handoff's specificity. One 8-packet driver-mode run
(2026-09-16, recorded as the run-state finding
`handoff-needs-mutation-verification`) measured it: seven packets reached
review, five needed at least one retry, and every defect was in work whose own
status line said done. The packet that had failed three prior attempts closed
first-try once its handoff carried a REQUIRED mutation-verification line
demanding both observed counts. Two of the retries were the repository's known
defect class, an unmeasured state rendering as a measured one. Those lines
were written into handoffs one packet at a time and live only in the driver's
context: a compaction or a fresh session starts from the bare
`templates/task-packet.yaml`, which carries only the weaker ancestor of the
first (a sweep must be named as its own acceptance criterion), and the driver
appends at most two conditional REQUIRED lines per `skills/run-loop/SKILL.md`
§3.3. The defect rate returns with the next session.

The finding's literal proposal — the lines in `templates/task-packet.yaml` —
would not deliver them, since the agents read only the handoff (ADR 0023:
naming a path is not delivering a file), so the script that writes the handoff
appends the contract on every packet and each line is an acceptance criterion
the reviewer holds the result file to. ADR 0026 arm 2, a new feature against a derived-done
parent; the slug names its scope, with no `-gaps` suffix, because this is a
contract the parent never had rather than a defect in one it shipped.

## Users & Use Cases

- **The implementer reading a handoff** — its whole brief is that file. It
  needs the verification demands in the file it reads, stated so that a result
  file either satisfies them or visibly does not.
- **The reviewer holding a result file to the handoff** — the only check
  behind a self-report. It needs each demand to be a criterion it can fail a
  packet on, not advice it may weigh, and it needs to be the one judging which
  demands apply to this packet.
- **A driver session after compaction or a resume** — writes handoffs from
  the bare template with no memory of what earlier packets taught. It must not
  have to remember anything for the contract to reach the next packet.
- **The operator of a consumer repository** — has verification rules of their
  own (a domain invariant, a fixture that must be regenerated) and needs to add
  them once, per repository, without editing the plugin.

## Scope

**In**
- `scripts/runstate.sh handoff` appends a fixed REQUIRED block to every handoff
  it writes, read from a new `templates/handoff-required.md`, and refuses to
  write a handoff when it cannot.
- The six generic lines of that block, phrased for any repository (the
  template owns the exact text):
  - mutation-verification with both observed counts stated
  - unmeasured is null, never 0
  - verify against the real interface, not its documentation
  - reporting a limitation is a pass
  - read the current file, not your memory of it
  - a second run must find nothing
- A per-repository extension file, `.agents/handoff-extra`, appended after the
  six.
- `agents/reviewer.md` and `agents/implementer.md` state that each applicable
  block line is an acceptance criterion.
- A comment in `templates/task-packet.yaml` naming the block's source.
- Cases in `scripts/test-runstate.sh` pinning the append, the refusal and the
  extension file.

**Out**
- The reviewer's verdict vocabulary and the routing of its verdicts.
- The driver's two conditional lines (the sweep criterion and
  `session_boundary`), which stay where and as they are.
- A Stop-hook or regex validator of result files — ADR 0023 rejected the
  analogous report validator: "is this a report?" is judgment, and so is "does
  this result file satisfy this line".
- Any parsing of `gspec/`; every gspec read stays in `scripts/gspec-backlog.sh`.
- Two of the finding's eight lines, deliberately: "deduplicate by
  `message.id`" is specific to this repository's metrics collector and stays in
  `CLAUDE.md`; "hook bodies are live mid-run" is already the packet template's
  `session_boundary` field.

**Deferred**
- Measuring the contract's effect in consumer repositories; the success
  metrics below are for this one.

## Capabilities

- [ ] **P0**: Every handoff carries the verification block by construction
  - `scripts/runstate.sh handoff` appends the block from
    `templates/handoff-required.md` after the piped task text on every handoff
    it writes — gspec-sourced, run-state-sourced, or a bundle — with no option
    to omit it; the driver's two conditional lines pass through inside the task
    text exactly as today, neither moved nor repeated, and the `HANDOFF=refused`
    path is unchanged
  - the block sits under its own heading or marker, so an agent can tell the
    contract from the task text and from the driver's lines, and each of the
    six lines reads as a `REQUIRED` line in the same form the driver's two use
  - when the template is missing, unreadable or empty, no handoff file is
    written — not a handoff without the block — and the command exits non-zero
    naming the template it could not read
  - `scripts/test-runstate.sh` gains a case asserting that a written handoff
    holds each of the six lines and the task text before them, a case for the
    refusal, and a mutation check recorded in the case's comment: with the
    append removed, the sweep turns red

- [ ] **P0**: The reviewer treats each block line as an acceptance criterion
  - `agents/reviewer.md` states that a result file which does not satisfy an
    applicable block line is a `fix` verdict naming that line, with the same
    standing as any unmet acceptance criterion — in particular a
    mutation-verification that states one count, neither, or does not name the
    wrong implementation each case rules out is a `fix`, never a pass with a
    note
  - the reviewer judges applicability, not whether to check: the
    mutation-verification line applies when a test case was added or changed,
    the read-the-current-file line when a preceding packet changed a file this
    one depends on, and so on for each line; an inapplicable line is passed
    over, never waived
  - `agents/implementer.md` states the same contract from its side: the result
    file addresses each applicable line, and where a line says to report a
    limitation rather than approximate, reporting it is the pass
  - the verdict vocabulary (`pass` / `fix` / `escalate`) and the routing of
    each are unchanged; prose only — no sweep case

- [ ] **P1**: A repository extends the block with `.agents/handoff-extra`
  - each non-blank, non-`#` line of `.agents/handoff-extra` in every discovered
    config root is appended after the six as a further `REQUIRED` line, unioned
    across roots with the same discovery and restrictive union
    `hooks/guard.sh` applies to `.agents/guard-extra-*` — a nested or foreign
    root can add lines, never remove them
  - a repository with the file in no discovered root gets a handoff identical
    to one written with the mechanism absent: no empty section, no warning;
    a file that is present but unreadable is refused exactly as a missing
    template is — no handoff written, non-zero exit naming the file
  - `scripts/test-runstate.sh` covers a root with the file, one without, one
    holding only comments and blank lines, one whose file is present but
    unreadable, and two roots whose lines are both present in the written
    handoff

- [ ] **P1**: The block's text has one source
  - the six lines' text lives only in `templates/handoff-required.md`;
    `templates/task-packet.yaml` carries a short comment naming that file as
    the source of the block every handoff carries and restates none of the
    lines, and no agent prompt or skill restates them either — each refers to
    the block by name
  - the six lines are phrased by kind for any repository, naming no path,
    script, tool or field of this one, since the template is read in place from
    the plugin root by every consumer
  - `skills/run-loop/SKILL.md` §3.3 still instructs the driver to append only
    its two conditional lines and nothing from the block; a driver that forgets
    §3.3 entirely still produces a handoff carrying all six
  - checkable by search: the distinctive phrase of each line occurs in exactly
    one file under `templates/`, `agents/` and `skills/` — prose only, no sweep
    case

## Dependencies

- `thin-loop-driver` — the parent: supplies the handoff writer, the result
  files and the one-status-line dispatch that make the handoff the whole brief.
  Derived-done; nothing here re-opens a capability or edits a checked task.
- `packet-bundling` — shipped; a bundle's handoff is one of the three sources
  the block must reach. Not blocking.
- `thin-loop-driver-gaps` — **not blocking, but same files**: it edits
  `scripts/runstate.sh` and `scripts/test-runstate.sh`. The two should not be
  in flight against those files at once.
- `escalation-decider` — not built; a `fix` on an unmet block line routes as
  any other `fix`. Not blocking.

## Assumptions & Risks

- Assumption: the handoff file is the only thing the implementer and reviewer
  read as their brief, so a line in it is delivered and a line anywhere else is
  not. This is the parent's contract and the reason the finding's literal
  proposal is declined.
- Assumption: the six lines generalise. Learned on one repository, phrased by
  kind they are claims about any packet that adds a test, reports a
  measurement, or depends on a preceding packet's file.
- Risk: the contract is prompt-enforced at the reviewer. Nothing mechanical
  reads a result file, so the detector for a reviewer that stops checking is
  the retry rate in the next run, not a sweep.
- Risk: six unconditional lines on every packet cost context on packets where
  most do not apply. The applicability rule bounds the cost to a read.
- Risk: an extension line is repository prose appended verbatim; a line that
  reads as a heading or as task text can confuse the block's boundary. The
  comment and blank-line rules are the whole filter.

## Success Metrics

Baseline, from the 8-packet run of 2026-09-16: 5 of 7 reviewed packets needed
a retry, and 0 of the retried packets' first attempts stated both mutation
counts.

- The first-attempt review pass rate rises over the next driver-mode run of
  five or more reviewed packets — countable from that run's routing records.
- Every result file for a packet that added or changed a test case states both
  observed counts — checkable per result file against the packet's diff.
- Zero packets in that run are retried for the "unmeasured rendered as
  measured" class — countable from the review files.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Whether the block and the extension lines are appended before or after the
  driver's two conditional lines.** Both satisfy every criterion above; the
  order is decided at plan time with the heading that delimits the block.
- **Whether an extension line may carry an applicability hint of its own.** A
  consumer's line applies to every packet until someone needs otherwise; the
  need has not been seen, so no syntax is invented for it.
