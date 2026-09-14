---
spec-version: v2
depends_on: [run-metrics]
---

# Feature: retire-unused-loop-modes

## Overview

The loop carries three execution modes its operator does not use. Each adds bytes to its instructions and cases to its test sweeps, and each has to be maintained on every change. **Relay** (ADR 0012) only breaks even at ≥40 packets per run. The largest run ever observed is 14, and when relay did run it cost 1.84x inline per packet. **`--parallel`** (ADR 0016) was run in one repository from 2026-07-19 to 2026-08-04 and tried twice in another on 2026-08-01, and none of the 151 recorded metric runs contains a lane. It spends the same tokens sooner, but the operator is limited by a weekly token allowance, not by wall clock. **Rate-limit auto-pause** (ADR 0018) never worked reliably in the operator's own testing. This feature removes all three. It also replaces the one safety property they provided, file-disjoint editing, which is already missing outside parallel mode. In one consumer repo over 14 days, 158 of 732 subagent dispatches ran in the background, none of them worktree-isolated. 41 pairs of file-editing subagents overlapped in time, and 10 of those pairs edited at least one file in common. This is part 1 of a loop-cost redesign, and its later parts build on it.

This feature **supersedes `loop-cost-controls`**, whose PRD folder and roadmap entry are removed. Later redesign features will carry its polling, routing-leak and per-packet-overhead items; until those are specced, the items live in the retired PRD's git history. Relay is removed as a scope decision: the loop will not operate in the ≥40-packet single-context regime relay served. No measurement proved relay worthless. The feature also **closes `coercive-pause-enforcement` unbuilt**, removing its PRD folder and roadmap entry, because its build trigger was parallel lanes overshooting their pause checks, and that can no longer occur.

## Users & Use Cases

- **The operator** runs the loop across several projects at once under a weekly token allowance. They need one predictable mode, no flag that quietly changes what a run costs, and runs that stop at the allowance and resume cleanly after it resets.
- **The plugin maintainer** keeps the loop's instructions, scripts and regression sweeps. They need fewer modes to reason about on each change, a smaller instruction file in the main session, and a signal when the concurrent-editing rule is broken.
- **A consumer repository** that already has the plugin installed has to upgrade through `/gaffer:migrate` without a failed start, without losing unmerged work, and without leftover configuration that points at removed pieces.

## Scope

**In**
- the six capabilities below
- the superseded ADRs, which stay as the record of what was decided
- removing the retired modes from shipped docs, command descriptions and regression sweeps
- the plugin's own overrides template dropping the `max_parallel_packets` key, and its consumer `CLAUDE.md` template dropping the row that routes parallel backlog runs to `/gaffer:build-packet-dependency-tree` and `--parallel`

**Out**
- the thin loop driver, handoff files, implementer checkpoints and loop measurement, which are later redesign features
- merging isolated worktree results back

**Deferred**
- nothing beyond the Deferred Decisions below

## Capabilities

- [ ] **P0**: Relay mode is removed
  - the loop has exactly one sequential mode, backlog size never switches it to another, and ADR 0012 is marked superseded
  - when `run-loop` or `resume` is given `--relay` or `--inline`, it starts normally, runs the single mode, and says in the kickoff report that the flag no longer exists. It never fails to start and never ignores the flag silently
  - the loop instructions no longer carry the relay contract, and no run dispatches a per-packet coordinator subagent. The `chief-engineer` agent definition stays, because other commands and agents use it

- [ ] **P0**: Parallel mode is removed
  - the shipped plugin has no worktree lanes, lane scheduling, packet dependency graph or `/gaffer:build-packet-dependency-tree` command. `--parallel` is accepted, gets the same kickoff notice as the relay flags, and runs sequentially, and ADR 0016 is marked superseded
  - on a run-state recorded as `mode: parallel`, `resume` stops before running any packet; names each lane branch and worktree recorded in run-state and whether run-state records it as merged; states that resume merged none of them; names what the operator must clear before the loop can run again; and leaves run-state and every branch untouched
  - the run-state format does not change: no schema bump and no migration. Lane fields are simply no longer written
  - `gspec-backlog.sh nodes` and per-task file scopes from `.agents/task-files.yaml` keep working, because the sequential loop still uses them

- [ ] **P0**: Rate-limit auto-pause is removed
  - the status-line sensor, the `/gaffer:rate-limit-pause` toggle command and the `rate_limit_pause:` overrides block are gone from the shipped plugin, and ADR 0018 is marked superseded
  - the cooperative whole-run pause (`/gaffer:pause`, ADR 0017) is unchanged: a pause request still stops a running loop at a safe boundary, and `resume` continues from there
  - the pause regression sweep keeps every whole-run pause case and has no rate-limit sensor or per-lane pause cases left, and the parallel-pause end-to-end sweep is removed

- [ ] **P1**: Concurrent file editing is governed by guidance
  - the `run-loop` and `resume` loop instructions and the `chief-engineer` agent say that agents which edit files run one at a time unless their declared file scopes are disjoint, and that read-only agents may fan out freely
  - they recommend worktree isolation only for self-contained work that should start from the repository's default branch, such as spikes, experiments and deliberate refactors. They never recommend it for loop implementers working on the loop's branch
  - the reason is stated next to the rule: an isolated worktree starts from the default branch, so it lacks the commits of earlier packets, and it is never merged back automatically

- [ ] **P1**: Same-file concurrent edits are observable
  - run metrics count, per run, the overlapping pairs of file-editing agents, where the main session counts as an agent. Two subagents overlap when their active spans, from first to last recorded event in the run, overlap; the main session overlaps a subagent only through its own edits recorded inside that subagent's active span. A pair still requires at least one file edited by both, and for a main-session pair, one the main session edited inside that span; it counts once however many files it shares
  - the count comes only from the event records the metrics hook already writes (time and agent on every event, a file hash on edits). There is no new instrumentation, and no file path is logged
  - the metrics summary shows the count. A run whose edit events all carry a file hash and that has no overlapping pair reports 0, and a run with no event records, or with any edit event lacking a file hash, reports the count as unmeasured, never as 0

- [ ] **P1**: Migration cleans up safely
  - `/gaffer:migrate` removes the `rate_limit_pause:` block and the `max_parallel_packets` key from the repo's overrides file, along with the commented-out `rate_limit_pause:` example and the comment lines introducing that key and that block, and leaves the rest of that file as it was. It reports, never edits, each line in the repo's own `CLAUDE.md` that routes to a removed mode or command, because that file belongs to the human
  - it removes a user-level `statusLine` entry only when that entry points at the plugin's sensor, and only after the operator confirms. If the operator declines, the entry stays and the report says it may still arm pauses until removed. It never touches any other `statusLine`
  - it deletes the gitignored per-lane pause files if they exist. It removes the tracked packet graph file and reports that removal as a change for the operator to commit. It lists extra git worktrees but never deletes them, since they may hold unmerged work
  - its report names every change it made and everything it left in place, and a second run on the same repo changes nothing

## Dependencies

- `run-metrics` (shipped): the overlap count builds on its event records, so it does not block ordering.
- Boundary with `metrics-coverage-gaps`: this feature counts cross-agent overlapping pairs per run; that feature derives a per-packet rework signal from edit overlap within a packet.

## Assumptions & Risks

- This assumes no consumer repo is in the middle of a parallel run. Every run-state checked on the operator's primary machine is sequential, but other machines are unverified. The `resume` stop in the parallel-removal capability covers the exception.
- An operator who relied on `--parallel` for throughput now gets sequential runs. The kickoff notice keeps that from being a silent surprise.
- The concurrent-editing rule is guidance, not enforcement. The same-file overlap count is how a violation gets detected, but file writes made through the shell produce no edit event and are invisible to the count.
- Without a rate-limit early warning, a run that reaches the allowance stops mid-packet and is recovered by the existing crash reconcile after the reset.
- Worktree isolation starting from the default branch, with no automatic merge-back, is how the harness is documented to behave today, and that could change.

## Success Metrics

- No shipped skill, agent, script, template or documentation file mentions relay, parallel mode or rate-limit auto-pause other than the migrate and resume paths that retire them, historical records (ADRs, dated measurements, completed feature specs, the changelog) and the unchanged run-state format description; every regression sweep passes.
- The `run-loop` instruction file that the main session carries is smaller than today's 40,081 bytes.
- In the same consumer repo, same-file overlapping pairs in the 14 days after release are fewer than the baseline: the count for the 14 days before release, re-derived from existing records with this same definition. Each window sums measured runs only and states how many runs were unmeasured; the earlier 10-pair figure counted subagents only and is not the baseline.

## Implementation Context

> This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Whether subagents ever need a hard stop.** This waits until the redesigned loop shows agents overshooting their checks. If that happens, the stop gets specced fresh against that loop.
- **Whether concurrency returns in another form.** This waits until throughput becomes a goal. At that point a new feature designs it against the thin driver instead of restoring lanes.
