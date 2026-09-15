---
spec-version: v2
feature: retire-unused-loop-modes
---

# Plan: retire-unused-loop-modes

Five tasks grouped **by file surface**, not by capability, so they run as
file-disjoint lanes. Three capabilities span several surfaces (the run-state
footprint, the shipped machinery, the prompts, the docs), so most tasks carry more
than one `covers:` quote and two capabilities are finished only by the last task.

**Deletion order is machinery → prompts → docs, and run-state goes first.** T1 owns
`scripts/runstate.sh` outright, including the per-lane pause sentinel, because the
sweep cases that prove those deletions live in `test-runstate.sh` and `test-pause.sh`
and must not be split from the code. That is also why T2 is **not** `[P]`: it shares
`scripts/test-pause.sh` with T1 and must land after it.

**The run-state format does not change.** `schema: 3` stays, there is no migration,
and no file on disk is rewritten. A run-state still carrying `mode: parallel`,
`lanes:` or per-packet `lane:` fields still parses after T1; the lane fields are
simply never written again, the read-only `lanes` listing survives because T4's
`resume` stop reads it to name branches and worktrees, and nothing else in the loop
reads them.

**`runstate.sh` must keep working on stock Git Bash — no `jq`, no real `python3`.**
Every deletion in T1 is a removal from an existing `awk`/`sed` path, never a
rewrite that introduces a new dependency.

**Registration crosses a session boundary and is called out where it applies.**
`hooks/hooks.json` is unchanged — no rate-limit hook was ever registered there, and
the plugin's own `.claude/settings.json` carries no `statusLine`. The only
registration this feature touches is a **user-level** `statusLine` pointing at the
deleted sensor, removed by T5 with the operator's confirmation. T5 cannot verify
that removal in the run that makes it: the status line is re-read at session start,
so until the next session the old entry may still arm a pause. T5 reports that
rather than asserting it.

**`templates/report-conventions-card.md` is byte-compared across three copies** by
`scripts/test-report-conventions.sh`. T4 emits its kickoff notice with an existing
glyph and edits no template; T5 sweeps `templates/report-templates.md` and
`templates/check-in.md` only, leaves the card and its two copies untouched, and runs
that sweep.

## Plan

- [x] **T1** [P] **P0** Strip the parallel footprint from `scripts/runstate.sh` — the lane-writing paths, `reconcile-parallel`, the parallel-only packet queries, and the per-lane pause sentinel in `request-pause`/`clear-pause`/`pause-status` — while keeping `schema: 3`, adding no migration, and keeping the read-only `lanes` listing that T4's `resume` stop reads; delete the parallel block and its lane fields from `templates/run-state.yaml` and the lane resolution from `hooks/pause-check.sh`; with cases in `scripts/test-runstate.sh` proving a run-state carrying `mode: parallel` and `lanes:` still parses, is left byte-unchanged, and yields no lane behaviour, and cases removed from `scripts/test-pause.sh` for per-lane pause while every whole-run pause case stays green
  - deps: —
  - covers: Parallel mode is removed · Rate-limit auto-pause is removed
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, scripts/test-pause.sh, hooks/pause-check.sh, templates/run-state.yaml

- [x] **T2** **P0** Delete the shipped machinery of both retired modes in one pass — `scripts/packet-graph.sh`, `scripts/worktree.sh`, `scripts/statusline-pause-sensor.sh`, `skills/build-packet-dependency-tree/`, `skills/rate-limit-pause/`, `skills/run-loop/parallel.md`, and the sweeps that own them (`scripts/test-packet-graph.sh`, `scripts/test-worktree.sh`, `scripts/test-parallel-pause-e2e.sh`) together with their `.github/workflows/ci.yml` entries — remove the `rate_limit_pause:` block, its commented example and the `max_parallel_packets` key with their introducing comments from `.agents/project-overrides.yaml` and `templates/spec-driven-base/.agents/project-overrides.yaml`, remove the sensor cases from `scripts/test-pause.sh`, mark ADRs 0016 and 0018 superseded, and keep `gspec-backlog.sh nodes` and the `.agents/task-files.yaml` scopes working — updating only its packet-graph commentary — with a `scripts/test-gspec-backlog.sh` case asserting the `nodes` TSV and file-scope resolution are unchanged
  - deps: T1
  - covers: Parallel mode is removed · Rate-limit auto-pause is removed
  - arch: —
  - files: scripts/packet-graph.sh, scripts/worktree.sh, scripts/statusline-pause-sensor.sh, scripts/test-packet-graph.sh, scripts/test-worktree.sh, scripts/test-parallel-pause-e2e.sh, scripts/test-pause.sh, scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh, skills/build-packet-dependency-tree/SKILL.md, skills/rate-limit-pause/SKILL.md, skills/run-loop/parallel.md, .github/workflows/ci.yml, .agents/project-overrides.yaml, templates/spec-driven-base/.agents/project-overrides.yaml, docs/adr/0016-parallel-worktree-lanes.md, docs/adr/0018-rate-limit-aware-cooperative-pause.md

- [x] **T3** [P] **P1** Add to `scripts/metrics.sh collect` a run-level count of overlapping pairs of file-editing agents, derived only from the events the hook already writes — a subagent's span running from its first to its last recorded event, the main session pairing with a subagent only through its own edit events inside that span, a pair requiring at least one `file_hash` edited by both and counted once however many it shares — reported as `unmeasured` when the run has no events or any edit event lacks a hash and as `0` only when every edit event carries one and no pair overlaps, rendered by `show` and described in `skills/metrics/SKILL.md`, logging no file path; in the same pass drop the `packet-graph.yaml` wave-map join, the `wave` field and the per-lane aggregates, with `scripts/test-metrics.sh` cases for an overlapping pair, a main-session pair, a shared-file-less overlap, a hash-less run and an event-less run
  - deps: —
  - covers: Same-file concurrent edits are observable · Parallel mode is removed
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh, skills/metrics/SKILL.md

- [x] **T4** **P0** Rewrite the loop instructions in `skills/run-loop/SKILL.md`, `skills/resume/SKILL.md` and `agents/chief-engineer.md` so that:
  - §0 and the relay contract are gone, there is one sequential mode, backlog size never switches it, and no run dispatches a per-packet coordinator — the `chief-engineer` agent definition stays for its other callers;
  - `--relay`, `--inline` and `--parallel` start normally, run the single mode, and are named in the kickoff report as flags that no longer exist, using an existing glyph so no template changes;
  - `resume` on a run-state recorded as `mode: parallel` stops before running any packet, names each lane branch and worktree it reads from run-state and whether run-state records it as merged, states that it merged none of them, names what the operator must clear before the loop can run again, and leaves run-state and every branch untouched;
  - both loop instructions and the `chief-engineer` agent state that file-editing agents run one at a time unless their declared file scopes are disjoint, that read-only agents may fan out freely, that worktree isolation is recommended only for self-contained work starting from the default branch such as spikes, experiments and deliberate refactors and never for loop implementers on the loop's branch, and — next to the rule — why: an isolated worktree lacks earlier packets' commits and is never merged back automatically.

  Mark ADR 0012 superseded in the same pass
  - deps: T1, T2
  - covers: Relay mode is removed · Parallel mode is removed · Concurrent file editing is governed by guidance
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, agents/chief-engineer.md, docs/adr/0012-delegated-loop-driver.md

- [ ] **T5** **P1** Teach `scripts/migrate.sh apply` to clean a consumer repo up — removing the `rate_limit_pause:` block, the `max_parallel_packets` key, the commented `rate_limit_pause:` example and the comment lines introducing each, leaving the rest of the overrides file as it was; removing a user-level `statusLine` entry only when it points at the plugin's sensor and only after the operator confirms, reporting that a declined or not-yet-reloaded entry may still arm pauses until removed and never touching any other `statusLine`; deleting the gitignored per-lane pause files; removing the tracked packet-graph file and reporting it as a change to commit; listing extra git worktrees without deleting them; and reporting, never editing, each line of the repo's own `CLAUDE.md` that routes to a removed mode or command — with `scripts/test-migrate.sh` cases for each removal, the decline path, the worktree listing and a second run changing nothing; and in the same pass sweep every remaining reference to relay, parallel mode, worktree lanes, the packet-graph command and the rate-limit sensor out of `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `.claude-plugin/plugin.json`, `skills/migrate/SKILL.md`, `skills/new-project/SKILL.md`, `agents/*.md`, `templates/task-packet.yaml`, `templates/report-templates.md`, `templates/check-in.md`, `templates/spec-driven-base/CLAUDE.md` (including the row routing parallel backlog runs) and `templates/spec-driven-base/spec-setup.md`, leaving ADRs, dated measurements, completed feature specs and the changelog as the historical record, leaving `templates/report-conventions-card.md` and its two copies byte-identical, and running `scripts/test-report-conventions.sh` with every other sweep
  - deps: T1, T2, T3, T4
  - covers: Migration cleans up safely · Relay mode is removed · Parallel mode is removed · Rate-limit auto-pause is removed
  - arch: —
  - files: scripts/migrate.sh, scripts/test-migrate.sh, skills/migrate/SKILL.md, skills/new-project/SKILL.md, CLAUDE.md, README.md, CONTRIBUTING.md, .claude-plugin/plugin.json, agents/chief-engineer.md, agents/implementer.md, agents/reviewer.md, templates/task-packet.yaml, templates/report-templates.md, templates/check-in.md, templates/spec-driven-base/CLAUDE.md, templates/spec-driven-base/spec-setup.md
