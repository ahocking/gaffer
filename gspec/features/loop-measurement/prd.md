---
spec-version: v2
depends_on: [run-metrics]
---

# Feature: loop-measurement

## Overview

This is part 2 of the 2026-09-14 loop-cost redesign. Part 1 is `retire-unused-loop-modes`, but this part is built first so the redesign has a true before. It makes the loop's quality and cost measurable, so each later part can be judged by numbers taken before and after it. A packet exists in run metrics only through its green-commit trailer, so failed or uncommitted work leaves no row. `runstate.sh record-outcome` accepts five outcomes, but the `run-loop` instructions give a command only for green and blocked, and name failed, rolled-back and abandoned only as alternatives with no trigger. As of the 2026-09-14 analysis, one consumer repo's outcome log held 174 green, 7 blocked and nothing else. Cost cannot be measured repeatably either. The 2026-09-14 ad hoc analysis of 7 days' spend kept no scripts, so no later change can be compared against it.

This feature **takes over `metrics-coverage-gaps`' P1 capability "Failed and uncommitted packets appear in the run packet"**.

## Users & Use Cases

- **The operator** runs the loop across several projects on two machines under a weekly token allowance. They need to know where the tokens went and whether a change to the loop helped.
- **The plugin maintainer** judges each redesign change by before-and-after numbers. They need honest outcomes so quality is judged alongside cost, and so a change that saves tokens by discarding more work never reads as an improvement.
- **A consumer repository** gets honest run outcomes with no extra steps.

## Scope

**In**
- the six capabilities below

**Out**
- guard approval-prompt capture and the rework rate (`metrics-coverage-gaps`)
- parallel lanes (retired by `retire-unused-loop-modes`)
- same-file concurrent-edit counting (`retire-unused-loop-modes`)
- budgets, checkpoints or caps (later redesign parts)
- dashboards or charts
- fetching usage from Anthropic over the network

**Deferred**
- nothing beyond the Deferred Decisions below

## Capabilities

- [x] **P0**: Every packet the loop begins records a start and a terminal outcome
  - each time the `run-loop` or `resume` loop begins a packet, inline or through subagents, it records a start holding the packet id, the time and the session. Subagent dispatches inside a packet are not starts; continuing a paused packet records a continuation the same way, and beginning a packet again after any recorded outcome records a new start
  - it records each outcome when its ending happens, on triggers that exclude each other: **blocked**, the loop stops on a blocking question (to the human, or waiting on another packet), whatever then happens to the packet's work; **rolled-back**, the loop discards the packet's work to the last green checkpoint without asking; **failed**, verification still fails and the loop moves past the packet without a blocking question; **abandoned**, the operator's answer drops the packet, or the sweep finds a started packet whose task no longer exists, which it records instead of interrupted; **green**, the packet's work lands complete as a green commit. When a stop fits more than one, blocked wins over rolled-back and failed, and failed over rolled-back; a retry within the packet is neither a start nor an ending
  - a pause, or `resume` discarding a crashed session's leftovers, is not an ending; `resume` adopting a crashed session's green commit records green: a pause that commits unfinished work does not record green, and a paused packet keeps its open start until it is continued and ends
  - outcome records stay append-only; within a run, a packet's outcome is the last one attributed to that run after its latest start or continuation

- [x] **P0**: A packet left without an outcome is recorded as interrupted
  - before beginning or continuing any packet, including the first after `resume`, the loop records interrupted (or abandoned) for every packet in this repo whose latest start or continuation has no terminal outcome recorded after it, except the packet at run-state's cursor when its status was paused on entry to `run-loop` or `resume`, so pausing is never read as an interruption. It names each by id and plain-English title in the next report it renders, and continues. This covers a crash and an allowance stop mid-packet
  - only this sweep records interrupted: no agent ends a packet it is working on that way, and the sweep never changes an outcome already recorded
  - when an interrupted packet is begun again and ends, its latest outcome is the packet's outcome, and the interruption counts in the run of the latest start or continuation it closed, which the interrupted record names, not in the run whose sweep recorded it

- [x] **P0**: Run metrics never read a missing outcome as success
  - `metrics.sh collect` builds packet rows from start records as well as green-commit trailers, so a packet that never committed still appears with its outcome. A packet has started in a run when that run's window holds a start or continuation record or a commit trailer for it, or an outcome record attributed to that run
  - a run's metrics count each started packet once, under its outcome in that run, interrupted included, and separately count started packets with no terminal outcome
  - `metrics.sh show` and `/gaffer:metrics show` label a run with any started packet lacking an outcome as incomplete, never as all green. A run with no start records, such as one from before this feature, reports outcome coverage as unmeasured, never as complete

- [x] **P0**: `/gaffer:metrics spend` reports API-equivalent spend over a time window
  - over a window the operator names (default: the last 7 days), it counts every assistant message whose timestamp falls in the window, across every Claude Code session transcript on the machine: main sessions and subagents, every project. A message the transcript repeats is counted once, by its message id, and messages without an id are counted as they are, with their count shown
  - it breaks spend down by project, model, agent role (main session or subagent type), effort level and cost part (input, cache write by 5-minute or 1-hour lifetime, cache read, output), each in tokens and dollars. A message whose transcript does not carry its effort or agent type is grouped as unrecorded, never guessed
  - dollars come from a price table stamped with the date it was last checked, shown in the report and labelled API-equivalent, not a bill. A model missing from the table shows its tokens with cost "unpriced", and totals state how many tokens were unpriced instead of counting them as $0
  - messages lacking usage data or a timestamp are excluded and their count is shown. No message content, prompt text or file path appears, and projects appear by folder name

- [ ] **P1**: The spend report shows where context cost comes from
  - per agent role, it shows the context re-read per turn, measured as the turn's cache-read tokens (median, 90th percentile, maximum), and the number of turns above a size the report states
  - it groups cache writes above a size the report states by cause, each with count and dollars: cache lifetime expired during an idle gap, model changed, effort changed, new session or subagent started, context compacted or its prefix changed, or new content added
  - each large write is counted once, under the first cause that fits, trying causes in an order the report states. A write whose cause the transcript cannot show is counted as "unknown cause", never given a guessed one

- [ ] **P1**: Saved spend totals combine across machines
  - `/gaffer:metrics spend` can save a window's totals to a file holding only counts, tokens, dollars, the model, agent-role, effort and cost-part labels the combined breakdowns need, the window, the price-table date, the time it was saved, a machine label and project folder names
  - given saved files from several machines, it produces one combined report with the project, model, agent-role, effort and cost-part breakdowns, naming each machine included
  - files whose windows or price-table dates differ are combined only with a warning naming the mismatch, and of two files with the same machine label and window, only the later-saved one is counted

## Dependencies

- `run-metrics` (shipped): the outcome records, event log, commit trailers and message de-duplication this feature builds on.
- `retire-unused-loop-modes`: not a dependency (see Overview).
- `metrics-coverage-gaps`: its rework rate will depend on this feature's outcome rows.

## Assumptions & Risks

- Transcript format is not a stable contract. When a field the report needs cannot be read, the report names that field and marks the affected totals unmeasured.
- Assumption: the transcripts for the 7-day window ending 2026-09-14 on both machines are preserved, copied aside or kept by raising Claude Code's retention setting, until this feature can read them. If that window is deleted, the reproduction metric cannot be measured.
- Saved totals are the durable record of a window.
- API-equivalent dollars are a proxy for subscription usage. How the weekly allowance weighs models or cache reads is not published.
- The interrupted sweep catches forgotten outcomes but cannot tell a forgotten green from a crash.
- This assumes one loop drives a repo at a time. A packet still open in a second session driving the same repo would be swept as interrupted.

## Success Metrics

- **Outcome coverage.** In the same consumer repo, in runs after release, every started packet (as run metrics define it), except one the stop report leaves paused, has a terminal outcome by the time the next packet in that repo starts or the run renders its stop report, reported together with the share of packets recorded interrupted. An interrupted packet in a run that rendered its stop report counts as a miss. Baseline: 27 of 98 packets with no recorded outcome in the week ending 2026-09-14, counted over trailer-derived packets because start records did not exist yet.
- **Failures visible.** Every failed, rolled-back or abandoned ending named in the loop's own check-in or stop report appears with that outcome in that run's metrics.
- **Reproduces the 2026-09-14 analysis.** For the 7-day window ending 2026-09-14 20:07 UTC on the primary machine, total API-equivalent spend is within 5% of $2,078 and cache reads are 66–70% of it. Adding the second machine's saved totals for the same window gives a combined total within 5% of $2,666. Both use a price table dated no later than 2026-09-14.

## Implementation Context

> This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **How the price table is kept current**, whether edited at each release or fetched. The date stamp keeps staleness visible.
- **Whether the report ever shows weekly-allowance percentages.** This waits until a reliable source for the allowance exists.
