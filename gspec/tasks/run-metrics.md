---
spec-version: v1
feature: run-metrics
---

# Plan: run-metrics

RETRO-SPEC of work already in the tree (ADR 0019). Every task is checked, so this
plan contributes no backlog nodes — it exists as the implementation record that
was previously spread across five `v3.x` revision sections with no status field.

Tasks are grouped by the shipped increment that introduced them. `covers:` names
the capability in `gspec/features/run-metrics.md`; `deps:` records the real build
order. Do not regenerate this file with `/gspec-plan` — regeneration re-decomposes
work, and every task here is checked and immutable.

## Plan

- [x] **T1** **P0** Add the `PostToolUse` collection hook writing per-session JSONL, matcher `.*`, metadata and low-sensitivity labels only
  - deps: —
  - covers: P0 event log, P0 advisory-safe
- [x] **T2** **P0** Derive packet boundaries from `[orch packet:<id>]` commit trailers, leaving run-state's `packets[]` untouched
  - deps: T1
  - covers: P0 trailer boundaries
- [x] **T3** **P0** Add `metrics.sh collect` assembling the portable single-file run packet from the event spine, wave map and trailers
  - deps: T1, T2
  - covers: P0 portable run packet
- [x] **T4** **P1** Add best-effort transcript token attribution that fails soft to structural-only and stamps `token_source`
  - deps: T3
  - covers: P1 token attribution
- [x] **T5** **P1** Add the `/gaffer:metrics` skill with collect, show, status and analyze
  - deps: T3
  - covers: P1 metrics skill
- [x] **T6** **P1** v2 — add per-packet tokens, active/idle wall split, `by_model`, per-tool `duration_ms`, `by_skill` and `by_command_class`
  - deps: T4
  - covers: P1 cost dimensions
- [x] **T7** **P1** v2 — replace `dispatches_without_named_model` with `dispatches_with_model_override`
  - deps: T6
  - covers: P1 routing deviation
- [x] **T8** **P0** v3 — bound the trailer scan to the run window, killing the 156-phantom-packet inflation
  - deps: T2
  - covers: P0 bounded trailer scan
- [x] **T9** **P1** v3 — feed `by_skill` from a `UserPromptSubmit` hook state file, since slash commands emit no `Skill` tool event
  - deps: T6
  - covers: P1 cost dimensions
- [x] **T10** **P1** v3 — add `by_tool` at run and packet level, exposing tool selection that `by_command_class` could not see
  - deps: T6
  - covers: P1 cost dimensions
- [x] **T11** **P0** v3.1 — route every jq line list through `tr -d '\r'` and add the `jqr()` scalar helper for Windows correctness
  - deps: T3
  - covers: P0 Windows correctness
- [x] **T12** **P1** v3.1 — replace the conflated `token_source: none` with `token_diagnostics` separating four distinct failures
  - deps: T4
  - covers: P1 token attribution
- [x] **T13** **P1** v3.2 — read trailer times as author dates rather than committer dates
  - deps: T8
  - covers: P0 bounded trailer scan
- [x] **T14** **P0** v3.2 — cap the trailer grace at the earliest event of any later session, removing 7 cross-session phantom rows
  - deps: T8
  - covers: P0 bounded trailer scan
- [x] **T15** **P1** v3.2 — add `totals.by_effort` and `totals.context_invalidations`, scanned per `(role, agent_id)`
  - deps: T4
  - covers: P1 effort and invalidation
- [x] **T16** **P0** v3.3 — deduplicate transcript turns by `message.id`, correcting a ~2.6x inflation in every token number
  - deps: T4
  - covers: P0 transcript dedup
- [x] **T17** **P1** v3.3 — stop rendering null as 0 in `show`, and move the audit block above the per-packet table
  - deps: T5
  - covers: P1 metrics skill
- [x] **T18** **P1** v3.4 — add `by_agent_role.<role>.cc_shape` to measure standing-context size rather than the aggregate
  - deps: T16
  - covers: P1 cc_shape
- [x] **T19** **P0** v3.4 — add `runstate.sh record-outcome` and stop assuming every packet is green
  - deps: T2
  - covers: P0 attested outcome
- [x] **T20** **P1** v3.4 — add `packets[].edits` with `contended_files`, identifying files by hash and never by path
  - deps: T1
  - covers: P1 rework signal
- [x] **T21** **P1** v3.4 — add `runstate.sh trim-note` enforcing the documented one-line `note:` contract
  - deps: —
  - covers: P1 note growth
- [x] **T22** **P0** Cover every capability above in `scripts/test-metrics.sh`, including the byte-identical CRLF assertion
  - deps: T11, T14, T16, T19
  - covers: P0 Windows correctness
</content>
