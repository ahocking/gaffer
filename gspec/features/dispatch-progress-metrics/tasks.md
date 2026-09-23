---
spec-version: v2
feature: dispatch-progress-metrics
---

# Plan: dispatch-progress-metrics

**Pin first, join second, roll up third, render last.** T1 pins today's `collect` output for the synthetic fixture before any field is added, so every later task can prove it left `packets[].edits`, `dispatched[]`, `by_agent_role`, `outcome` and `audit.review_dispatches` alone by deleting its own new fields and comparing bytes. The per-dispatch row (T2) lands before anything that classifies it (T3–T5), the rows before the rollup that counts them (T6), and the rollup before the flags and rendering that read it (T7–T9). Every task but T9 and T11 edits `scripts/test-metrics.sh`, so they run in sequence; only T9 (the skill prompt) can run alongside them.

**This adds no hook and no log, and nothing new goes into the outcomes log.** The join reads three logs that already exist: the events log (keyed by `agent_id`), the outcomes log's start records, and the routing records in `.agents/loop/*/routing.jsonl` (`ts`, `packet`, `token`, `action`, `status`; the collector does not read this file today). `_rs_open_packets` treats any outcomes record carrying `kind` as a packet start, so a helper record written there would reopen packets. A field the join needs but the records lack is a finding for `implementer-continuation` or `thin-loop-driver`. Do not fake it in jq.

**Attribution keys on the `Agent` event and on whether `agent_id` is present. It never uses `agent_type`.** A `claude --agent` main thread carries `agent_type` with no `agent_id` (ADR 0028). Every new jq read that a `read` loop consumes goes through `tr -d '\r'`, and every scalar capture goes through `jqr` (v3.1).

**`null` means unmeasured, never clean.** A legacy run, a run whose routing log has been pruned, a swept or sibling row, a dispatch with no resolved `agent_id`, or a missing transcript turn yields `null` with a `notes[]` reason. It never yields `0`, and it never yields a guessed `initial`.

## Plan

- [x] **T1** **P0** Add a pin to `test-metrics.sh` that captures the current fixture's `collect` output with `generated_at` removed, then asserts that later output with every `dispatch-progress-metrics` field deleted (an explicit jq `del` list, initially empty) is byte-identical to it; add three mutation cases proving the pin goes red when `packets[].edits`, `dispatched[]` or `audit.review_dispatches` is altered
  - deps: —
  - covers: Existing outputs keep their meaning and the sweep pins the new fields
  - arch: —
  - files: scripts/test-metrics.sh
- [x] **T2** **P0** Make `collect` emit `packets[].dispatches[]`, one row per implementer-role `Agent` event in the packet window. Each row is resolved to the `agent_id` with the earliest first event inside the dispatch's back-dated span — the `Agent` event's timestamp minus its `duration_ms`, to the timestamp, each bound widened by 1 s and inclusive (a row resolved to no `agent_id`, or whose `Agent` event has no `duration_ms`, still appears), and carries `tool_calls`, `duration_ms` and `edits` (the packet audit's four write tools), all null when unresolved. Swept and sibling rows get `dispatches: null` in their existing null-field shape. Add the new fields to T1's `del` list; cases cover two sequential dispatches with fixture events in real PostToolUse order (the `Agent` event after the subagent's own events), an unresolved dispatch, an `Agent` event with no `duration_ms`, two qualifying `agent_id`s, a main thread with `agent_type` and no `agent_id` never attributed, and swept and sibling rows reading null
  - deps: T1
  - covers: Every implementer dispatch in a packet is one row with a kind · Each dispatch carries its own cost and its own progress
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T3** **P0** Set each dispatch row's `kind` from the latest start or routing record for the packet before its `Agent` event, joining the outcomes log's start records and every `.agents/loop/*/routing.jsonl` record for the packet. A start with or without `--continue` → `initial`, a `continue` routing record → `continuation`, `fix`/`retry` → that verdict, and a routing record wins over a start at the same boundary. No such record → `null`; a run whose window holds neither record type is legacy, with every `kind` null; and a window that holds at least one start record but no routing record for any of its packets in any `.agents/loop/*/routing.jsonl` is routing-unmeasured — its routing log is pruned or never reached a review, since every packet that is reviewed gets at least a `pass` record — and carries `kind: null` on every row with a `notes[]` reason, never the `initial` the start record alone would give. The test reads the records themselves, never a `run_id` from the current `.agents/run-state.yaml`, which names the current run rather than the collected one. Cases cover `initial`→`fix`, a resume `--continue` start reading `initial`, a `continue` routing record plus a start at one boundary reading `continuation` (fixture records in `route`'s shape), a dispatch with no prior record, a pruned-routing-log run (start records present, no routing record for any packet) whose `fix` dispatch reads null and not `initial`, and a legacy run re-collecting identically
  - deps: T2
  - covers: Every implementer dispatch in a packet is one row with a kind
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T4** **P0** Give each dispatch row `tokens`: the sum of its `subagents/agent-<agent_id>.jsonl` transcript turns, deduplicated by `message.id` with the earliest row kept and id-less rows kept verbatim, read under the run's single `token_source`. It is null (no partial figure) when the packet's `tokens` is null, the dispatch is unresolved, or no turn resolves to it. Cases cover a duplicated message id counted once, a missing transcript, and a null packet `tokens` nulling every row
  - deps: T3
  - covers: Each dispatch carries its own cost and its own progress
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T5** **P0** Give each dispatch row `progress`, tested in the PRD's order: `null` (unmeasured trailer window, legacy run, or unresolved dispatch); `landed` (the packet's trailer author time falls at or after this dispatch's back-dated start and before the next implementer dispatch's start, or within the same bounded trailer window the packet row uses); `advanced` (≥1 edit event and no such commit); `none` (zero edit events). Cases cover `initial`→`fix` where only the `fix` row reads `landed`, an earlier dispatch whose edits a later commit carried reading `advanced`, a zero-edit dispatch reading `none`, a legacy run reading `progress: null`, and at most one `landed` per trailer
  - deps: T4
  - covers: Each dispatch carries its own cost and its own progress
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T6** **P0** Add `totals.dispatch_waste` with `zero_progress` (count and token sum), `continuations`, `over_threshold` (count and share of all implementer-dispatch tokens) and `turn_threshold`, which stamps the value and its unit: `implementer_turn_budget` from `.agents/project-overrides.yaml` when it is a positive integer, read in tool calls, else 150. Each component is null under the PRD's rules, and a `notes[]` line names which component is unmeasured and why; cases cover a fully measured run, the override and the default, one null `progress` nulling only `zero_progress`, one null `kind` nulling only `continuations`, one null `tokens` nulling only the sums and share, and a legacy run and a run with no implementer dispatch reading all-null
  - deps: T5
  - covers: A run-level rollup names the waste
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T7** **P1** Add `waste:zero-progress-dispatch(<n>)` and `waste:over-budget-dispatch(<n>)` to per-packet `audit.flags`, using the rollup's `turn_threshold` and unit. Suppress both on a legacy run the way `unlabelled:` is suppressed, never emit either on a swept or sibling row, and never count a dispatch with a null `progress` or `tool_calls` toward either, so `totals.audit.flagged_packets` picks up flagged packets unchanged; extend T1's pin filter to strip the two `waste:*-dispatch` entries from `audit.flags` and re-derive `flagged_packets` without them, so the pin still compares existing meaning byte-for-byte. Cases cover each flag, a packet of all-null dispatches carrying no flag, and the legacy run carrying no `waste:` flag
  - deps: T6
  - covers: Per-packet flags surface zero-progress and over-threshold dispatches
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T8** **P1** Make `metrics.sh show` print `dispatch_waste` inside the audit block, above the per-packet table. A null component renders as unmeasured with its `notes[]` reason and a non-null zero renders as 0, never through a `// 0` fallback; cases on the rendered text cover a measured run, a partly null run and a legacy run
  - deps: T7
  - covers: `show` renders the rollup where it is read
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T9** [P] **P1** Add `dispatches[]` and `totals.dispatch_waste` to the rollup the `analyze` verb in `skills/metrics/SKILL.md` hands over, telling it that null is unmeasured, and add no ranking rules beyond that
  - deps: T6
  - covers: `show` renders the rollup where it is read
  - arch: —
  - files: skills/metrics/SKILL.md
- [x] **T10** **P0** Extend the CRLF-jq byte-identity assertion so the shimmed fixture carries start, `fix` and `continue` routing records, asserts that non-null `kind` and `progress` values are present before comparing (so the case cannot pass vacuously), and still requires byte identity with the clean run; add a case proving a `kind` value with a trailing `\r` fails it
  - deps: T6
  - covers: Existing outputs keep their meaning and the sweep pins the new fields
  - arch: —
  - files: scripts/test-metrics.sh
- [ ] **T11** **P1** In one change, record in `CLAUDE.md` and in a new ADR 0019 v3.6 section: the per-dispatch join and its three sources; attribution by `agent_id` and never `agent_type`; the `kind` precedence with routing winning at a shared boundary; the pruned-routing-log null rule; the `progress` order; the null rules; the threshold stamp; and that no outcomes-log record kind was added. This is repo-convention upkeep, not a PRD criterion
  - deps: T8, T9, T10
  - covers: —
  - arch: —
  - files: CLAUDE.md, docs/adr/0019-run-metrics-observability.md
- [ ] **T12** **P1** Make `runstate.sh summary` count a `pending_questions` entry as blocking by its decoded severity, through the shared run-state decode rule: the value after `severity:`, with surrounding whitespace and a trailing CR removed, counts when it decodes to exactly `blocking` whether single-quoted, double-quoted or bare, and a value that only starts with `blocking` does not count. Today's bare-value regex counts a quoted `blocking` as 0, so a stop or resume report under-reports the question the run is stopped on (found in this feature's own run, 2026-09-23). `test-runstate.sh` gains a counted and an uncounted case per form, checking the number, and the quoted counted cases fail against the current code; it all holds with `jq` and `python3` absent
  - deps: —
  - covers: —
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
