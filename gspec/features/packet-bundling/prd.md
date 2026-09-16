---
spec-version: v2
depends_on: [thin-loop-driver]
---

# Feature: packet-bundling

## Overview

The loop runs one plan task per packet: a fresh implementer, a fresh review, a full verification run and a commit for each. Tasks that edit the same files cannot run at the same time anyway, so each one pays again to load the same large files. In the `thin-loop-driver` P0 run on 2026-09-15, the first single-task packet's implementer alone used about 188,000 tokens, most of it loading one script it then edited; grouping the run's tasks by shared files ran 14 P0 tasks as 4 dispatches. The operator's weekly token allowance was about 40% spent by Tuesday, which is what this feature answers.

This feature lets the loop group consecutive unchecked tasks that share file scope into one packet: one implementer dispatch, one review, one verification run, one commit. The grouping is the loop's own decision, made at execution time — gspec keeps owning what to build and in what order (ADR 0020's seam), and how a unit of work is executed is gaffer's half. Measurement stays per task, because a bundling change that made the loop's own cost numbers coarser would defeat the reason for making it.

## Users & Use Cases

- **The operator** wants the same backlog to cost fewer tokens per landed task, without deciding grouping per run or annotating the plan.
- **The plugin maintainer** needs per-task measurement to survive bundling, so a run of bundles and a run of single-task packets can still be compared task for task.
- **A consumer repository** gets the same loop, with grouping off until it opts in.

## Scope

**In**
- the five capabilities below

**Out**
- running unrelated bundles at the same time: it saves wall clock, not tokens, and the operator is limited by a weekly token allowance — the reason parallel mode was retired (`retire-unused-loop-modes`)
- changing how gspec decomposes a feature into tasks
- grouping tasks from more than one feature
- an operator-facing or plan-authored grouping marker

**Deferred**
- nothing beyond the Deferred Decisions below

## Capabilities

- [ ] **P0**: The loop groups consecutive same-scope tasks of one feature into a single packet
  - the loop forms each group when it selects the next packet, from the plan as it stands. A group holds unchecked tasks of exactly one feature, consecutive in plan order
  - a task joins the group being formed only when its declared file scope shares at least one file with the union of the scopes of the tasks already in it, and when every task it declares a dependency on is either earlier in the same group or already finished. A task whose declared scope is empty overlaps nothing, so it runs alone
  - a task in the design-heavy tier never joins a group and never starts one: it runs as its own packet
  - a group of one task is an ordinary packet and behaves exactly as it does today

- [ ] **P0**: Bundling is off until the repository raises the cap
  - the largest number of tasks a group may hold is set in `.agents/project-overrides.yaml`. The default is 1, and a missing, invalid or zero value reads as 1
  - the setting is documented with a recommended starting value of 4, and with the two costs of a larger value: a larger review diff and more discarded work on failure
  - a group stops growing at the cap even when the next task would otherwise join, and the next task begins the following group

- [ ] **P0**: A bundle is one unit of work for dispatch, review and routing
  - the bundle's handoff file is the per-task handoff files concatenated in plan order, so the implementer gets every task's text, file scope and acceptance criteria. The packet's file scope is the union of its tasks' scopes
  - one implementer dispatch, one review, one verification run and one commit cover the whole bundle. The reviewer's verdict applies to every task in it, a fix attempt re-does the whole bundle, and the attempt limit `thin-loop-driver` counts applies to the bundle, not to each task
  - when a bundle ends non-green — its attempts used, or the escalation decider discarding it — it ends as one packet: its tasks' work is discarded to the last green checkpoint together, and no part of a bundle lands on its own
  - the loop names a bundle in its reports by its packet id and the plain-English titles of its tasks

- [ ] **P0**: Every task in a bundle keeps its own record
  - a start is recorded for each task in the bundle when the packet begins, and a terminal outcome for each task when the packet ends, both exactly as `loop-measurement` defines them. Every task in a bundle that ends non-green gets the same outcome, chosen by applying `loop-measurement`'s triggers to the bundle as one packet
  - the bundle's commit flips the gspec checkbox of each task it lands
  - the bundle's commit carries one `[orch packet:<id>]` trailer per task it lands, each naming that task's own id, each on its own line

- [ ] **P0**: Run metrics emit one packet row per trailer on a commit
  - `scripts/metrics.sh collect` emits one packet row for every `[orch packet:]` trailer on a commit, not one row per commit. Each row of a multi-trailer commit carries that commit's tier and implementer labels and its packet boundary
  - a commit carrying one trailer produces exactly the row it produces today, so runs recorded before this feature read the same as they did
  - re-collecting an existing run whose commits carry several trailers — commit `8f236af`, which landed five tasks, is the case to verify against — yields one row per task where it previously yielded one
  - the run's totals count each of those rows once, so a bundled run's packet count matches the number of tasks it landed

## Dependencies

- `thin-loop-driver`: handoff files, the reviewer verdict routing, the fix-attempt limit and the design-heavy tier that this feature groups around. Blocking.
- `loop-measurement`: the start and outcome records each task in a bundle writes, and the packet rows run metrics build from starts and trailers. Its outcomes half has shipped; this feature does not wait on the rest.
- `gspec-adapter-consistency`: not blocking. Both touch how plan task lines are read, in different files.
- `escalation-decider`: unchanged by this feature — it receives a bundle as one escalating packet.

## Assumptions & Risks

- A larger diff per review may hide a defect that a per-task review would have caught. Every bundle in the 2026-09-15 P0 run had real bugs found by its review, so this is the risk the cap exists to bound: a bad grouping is only visible once the review returns, which is why the loop cannot correct it partway through.
- A bundle that ends non-green discards more work than a single task would, and the cost of that grows with the cap.
- Assumes declared file scope is a reasonable proxy for what a task will actually edit. A task that edits outside its declared scope can put unrelated work in one bundle.
- Assumes tasks adjacent in plan order that share files are safe to do in one pass; gspec orders tasks within a feature, and this feature does not reorder them.

## Success Metrics

- **Tokens per landed task.** On a bundled run, total tokens divided by tasks landed green is lower than the single-task baseline from the 2026-09-15 `thin-loop-driver` P0 run, measured the same way over the same repository. A run whose token data cannot be read reports unmeasured, never a pass.
- **Per-task rows survive bundling.** Every task landed by a bundled commit has its own packet row in that run's `run-metrics.json`, carrying that commit's tier and implementer labels.

## Implementation Context

> This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **What the default cap should become.** It ships at 1 (no bundling) so that adopting this feature is an explicit act. Whether the default should rise waits until bundled runs have been measured against the single-task baseline.
