---
spec-version: v2
depends_on: [thin-loop-driver, loop-measurement, retire-unused-loop-modes, retire-autonomy-levels]
---

# Feature: escalation-decider

## Overview

This is part 4 of the 2026-09-14 loop-cost redesign. The thin loop driver (`thin-loop-driver`) routes every judgment call to the escalation decider instead of making it itself. The decider is short-lived: it reads one packet's files plus what its triggers test and returns one next step. A periodic review by the same agent keeps the findings index small and honest.

The decider is the existing `chief-engineer` agent, slimmed, and given this role. It routes new work by ADR 0026's two arms and handles findings by ADR 0022 and ADR 0024, amending ADR 0024's rule against judgment prunes of the index inside the loop so a review can merge duplicates. A dispatched agent cannot run `/gspec-feature`, so work needing a new feature waits for the operator without blocking the run, as ADR 0026 decides.

## Users & Use Cases

- **The operator** runs long loops unattended. They need judgment calls made without the run stalling overnight, every decision visible afterwards, and only what `ask-operator` or `hand-off-feature` requires brought to them.
- **The plugin maintainer** wants each decision made by an agent scoped to one packet and its triggers, not by a long-lived coordinator carrying the run in its context.
- **A consumer repository** gets a backlog and findings index that stay tidy across runs.

## Scope

**In**
- the four capabilities below
- slimming the `chief-engineer` agent to the escalation decider, keeping what every shipped agent, skill, template and regression sweep that names it uses today, and the concurrent-editing rule from `retire-unused-loop-modes`

**Out**
- routing a packet to the decider, and the handoff and result files themselves (`thin-loop-driver`)
- how outcomes are recorded (`loop-measurement`)
- removing the agent's relay and parallel sections (`retire-unused-loop-modes`) and its autonomy levels (`retire-autonomy-levels`)
- writing a PRD: the decider only hands off
- implementer checkpoints (a later redesign part)

**Deferred**
- nothing beyond the Deferred Decisions below

## Capabilities

- [ ] **P0**: Each escalation gets exactly one next step
  - when `thin-loop-driver` routes a packet here, the decider reads that packet's handoff file, its result files and the findings naming the packet, with their bodies. It also reads what its triggers test: `escalate_to_human_on` in `.agents/project-overrides.yaml` (empty unless the repo lists entries), the backlog's PRDs and plans, and `.agents/roadmap.yaml`. It reads no other packet's handoff or result files
  - each decision has a trigger that excludes the others. **`ask-operator`**: the packet's task or failure matches an `escalate_to_human_on` entry, the packet escalates again while a decision finding naming it is still in the index, or the decider cannot settle on one of the other four, including when none of them fits. **`hand-off-feature`**: the packet needs new work that fails `append-task`'s test (ADR 0026 arm 2). **`append-task`**: the packet needs new work that an unchecked capability of an unfinished feature covers, and that feature's plan still has an unchecked task (arm 1). **`reorder`**: the packet can proceed once other pending work lands. **`retry`**: a changed handoff file makes another fresh implementer attempt worthwhile and the packet has one left; a `retry` uses one of the attempts `thin-loop-driver` counts. `hand-off-feature` and `append-task` fit only when the backlog comes from gspec. When more than one decision fits, the first in this order wins: `ask-operator`, `hand-off-feature`, `append-task`, `reorder`, `retry`
  - it returns one status line naming the packet and exactly one decision, and writes the decision, the trigger that fired and its reasoning to its result file

- [ ] **P0**: The decider acts only within fixed authority
  - it carries out three decisions without asking, and records each as a finding naming the packet and in a decision record cleanup does not reach. `reorder` changes run-state's pending order, and also the `.agents/roadmap.yaml` order when the new order crosses features. `append-task` appends one unchecked task to that feature's plan, with a truthful `covers:` naming that capability, changes no existing line, and puts the new task ahead of the packet in run-state's pending order. `retry` rewrites that packet's handoff file with the change, its only write to a handoff file, names the change in its result file, and returns the packet for a fresh implementer attempt
  - `ask-operator` stops the loop on a blocking question naming the matched `escalate_to_human_on` entry, or the options the decider could not choose between. `hand-off-feature` does not stop the loop (ADR 0026): it takes the packet out of this run's pending order and records a question naming what `/gspec-feature` should be run with, which the stop report carries. The decider never edits a checked task or a capability checkbox, never records an outcome (outcomes follow `loop-measurement`), and never makes a packet abandoned
  - every decision from an escalation or a periodic review appears in the next report the driver renders, including a decision made while the operator was away. The report names a packet by id and plain-English title and a finding by id and summary; a review's routings count as decisions, and its merges and drops appear as counts
  - a decision exists only once its status line is returned. A result file left without one by a crash or an allowance stop is not a decision, and the packet's outcome is left to `loop-measurement`'s interrupted sweep; a change already on disk from that decider is recorded as a finding at that packet's next escalation and not repeated. A pause never splits a decision: the loop pauses either before the decider is dispatched or after its decision is carried out and recorded, and `resume` continues from that point

- [ ] **P1**: A periodic review keeps the findings index small and honest
  - between packets, never while one is open, the driver dispatches the decider for a periodic review. It does so once 2 non-green endings or 10 beginnings have been recorded since the last completed review, whichever comes first. A non-green ending is a failed, rolled-back, blocked, abandoned or interrupted outcome record, and a beginning is a start record (not a continuation), both as `loop-measurement` defines them. When no review has completed yet, counting starts at the repo's first start record. Both numbers are set in `.agents/project-overrides.yaml`, and a missing or invalid value falls back to its default
  - a review counts as completed only when it returns its status line, so a review cut short by a crash runs again at the next boundary. When the outcomes log cannot be read, the next report shows both counts as unmeasured, never 0, and the review runs
  - the review reads the outcomes log and the findings index. It merges duplicate findings into one entry that names every packet either finding named, and loses no text: both bodies' text and the removed entry's summary go into the surviving entry's body file. It routes each finding that says something should be built into gspec through `append-task` or `hand-off-feature`, under the triggers and authority above, leaving pending order unchanged and naming the routed finding's packets, then drops it (routing is ADR 0024's capture); it drops any other finding only on ADR 0024's positive evidence
  - it returns one status line and writes each merge, routing and drop to its result file, and records its completion and the index bytes before and after where `thin-loop-driver`'s cleanup does not reach

- [ ] **P1**: Finding summaries stay within 160 characters
  - `runstate.sh add-finding`, from any caller, writes a summary of 160 characters or fewer to the index unchanged. Length is counted after newlines are collapsed, which works as it does today
  - it shortens a longer summary in the index to 160 characters or fewer, including a mark showing it was shortened, without splitting a character. It writes the full text to the finding's body file, `.agents/findings/<id>.md`, creating that file even when `--body` was not passed, and the index entry points to that file the way a `--body` entry does
  - the call is never rejected for length and otherwise behaves as it does for a short summary

## Dependencies

- `thin-loop-driver`: routes escalations to the decider and writes the handoff and result files it reads.
- `retire-unused-loop-modes` and `retire-autonomy-levels`: both edit `chief-engineer` before it is slimmed; the latter fixes the decider's authority at what `full-autonomy` allows.
- `loop-measurement`: provides the outcomes log that the review triggers count and the review reads, and records the outcomes the decider does not record.

## Assumptions & Risks

- A wrong `reorder` or `append-task` lands without the operator. The finding and the report required by the authority capability make it visible, not silent.
- Two judgments have no mechanical check: whether a capability covers some work, and whether two findings are duplicates. A merge can join findings that only look alike. No text is lost, and review of the branch before it merges is still the boundary.
- Entries written before the cap keep their long summaries until they are dropped, so the index can stay over its warning size for a while after release.

## Success Metrics

All three are measured in the same consumer repo, chains-and-charms-v2.
- **Findings index size.** The findings index is measured in bytes, the same way `findings --stale` measures it against `ORCH_FINDINGS_INDEX_MAX_BYTES` (default 4,096), and read from each review's recorded sizes. At the end of the last periodic review in the 14 days after release, it is at or under 4,096 bytes. A review with no recorded size is unmeasured, and the number of such reviews is stated. Baseline: 34,368 bytes holding 43 entries on 2026-09-14.
- **Decisions recorded.** In runs during the 14 days after release, 100% of `reorder`, `append-task` and `retry` decisions had a finding naming their packet recorded when the decision's status line returned. A run whose decision records are missing is unmeasured, not a pass. No baseline: the decider does not exist before release.
- **Escalations settled without the operator.** Per run, this is the share of escalations whose returned decision is `reorder`, `append-task` or `retry`, out of all escalations that returned a status line, counted from the decision records kept out of cleanup's reach. Escalations that returned no status line are counted separately. Tracked, not targeted; unmeasured before release.

## Implementation Context

> This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **The 160-character cap and the review triggers (2 non-green endings, 10 beginnings).** These are starting values, and tuning them is deferred until measurements come in from each review's recorded index size.
- **Whether `hand-off-feature` could draft a PRD for the operator to approve.** This is deferred because a dispatched agent cannot run gspec commands today (see Overview).
