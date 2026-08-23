---
spec-version: v2
---

# Feature: run-metrics

Observability for the guided autonomy loop: where a run's compute actually went,
at a granularity that supports ranked optimization advice rather than a total.

**Status: shipped (ADR 0019, v1 → v3.4).** This PRD is a RETRO-SPEC — it was
written after the fact to give the collector a completion record, because the
implementation history had accumulated in [ADR 0019](../../../docs/adr/0019-run-metrics-observability.md)
(866 lines) and `CLAUDE.md` as five stacked `v3.x` revision sections with no
status field anywhere. Every capability below is checked because it is in the
tree and covered by `scripts/test-metrics.sh`.

Known gaps are NOT recorded here — they are their own forward feature
(`metrics-coverage-gaps`), so that derived completion stays honest and does not
block everything downstream of a shipped collector.

## Capabilities

- [x] **P0**: A `PostToolUse` hook records every tool call to a per-session JSONL event log
  - matcher is `.*` — `Agent` dispatches and `Read`/`Grep` context loading are counted, not only mutations
  - carries `agent_id`/`agent_type` from inside dispatched subagents and parallel lanes
  - records metadata and low-sensitivity labels only: never full command text, never a file path
  - `cmd_class` is the Bash command head alone (argv0 + subcommand), env prefixes and args stripped
  - covered by `scripts/test-metrics.sh`

- [x] **P0**: The collection hook can never weaken the guardrail or break a run
  - prints nothing on stdout, emits no `permissionDecision`, fails silent, always exits 0
  - same advisory-safe contract as `hooks/pause-check.sh`

- [x] **P0**: `metrics.sh collect` assembles one portable, self-contained run packet
  - joins event spine, packet boundaries, wave map and tokens into `.agents/metrics/<run-id>/run-metrics.json`
  - `adhoc` run-ids are disambiguated to `adhoc-<session8>` so two sessions never overwrite one packet

- [x] **P0**: Packet boundaries are derived from `[orch packet:<id>]` commit trailers
  - run-state's nested `packets[]` is left untouched — no schema migration, no single-writer contention
  - only a trailer on its own line counts; prose mentioning the format does not
  - falls back to `<integration_branch>..HEAD` when no events are present

- [x] **P0**: The trailer scan is bounded at BOTH ends of the run window
  - lower bound is the selected session's span; upper is last-event + `ORCH_METRICS_TRAILER_GRACE`
  - the grace is capped at the earliest event of any other session after the window end
  - an open upper bound made retrospective collection absorb every later run's packets (12 of 19 runs inflated 2x–45x)

- [x] **P0**: Transcript turns are deduplicated by `message.id` before any token is summed
  - a transcript records the same assistant message up to 3x, each row carrying the full `usage` block
  - undeduped totals ran 2.3x–3.2x high on cacheCreation and 3.3x–6.3x on output, at rates that differ per session and so do not cancel in a ratio
  - the earliest row per id wins (deterministic, for the `context_invalidations` timestamp scan)
  - rows with no `message.id` are kept verbatim — under-dedupe is the safe direction

- [x] **P0**: `outcome` is attested or null, never assumed green
  - `runstate.sh record-outcome <packet> <green|failed|rolled-back|blocked|abandoned>` is called at every loop boundary
  - append-only under `.agents/metrics/outcomes/`, deliberately not run-state
  - a packet exists only via its green-commit trailer, so assuming green made discarded work look like quality

- [x] **P0**: The collector is correct on Windows / Git Bash
  - every `jq -r` line list consumed by a `read` loop is piped through `tr -d '\r'`
  - scalar captures go through a `jqr()` helper rather than relying on MSYS bash stripping CRLF from command substitution
  - the regression test asserts a CRLF-shimmed packet is byte-identical to a clean run

- [x] **P1**: Token attribution is best-effort and fails soft, never silently partial
  - stamps `token_source`; degrades to structural-only rather than reporting a partial run as complete
  - `token_diagnostics` separates nothing-on-disk / lookup-failure / format-drift / window-miss
  - `duplicate_turns_dropped` makes a drift toward zero visible, since that silently re-inflates totals

- [x] **P1**: Per-packet and per-role cost dimensions are captured
  - per-packet tokens bucketed by transcript-turn timestamp, plus an unattributed bucket
  - active/idle wall split; per-tool `duration_ms`; `by_model`, `by_tool`, `by_skill`, `by_command_class`
  - `by_skill` is fed by a `UserPromptSubmit` hook because slash commands emit no `Skill` tool event; it is sticky, and therefore an upper bound

- [x] **P1**: `by_agent_role.<role>.cc_shape` measures the payload, not the aggregate
  - median / p90 / max / turns_over_50k / cc_over_50k
  - cacheCreation-per-packet spans 1.76x across untouched same-regime sessions, so a 20–30% context trim hides inside it
  - median is flat while max separates by an order of magnitude — p90 and max read standing-context size and move in one run

- [x] **P1**: Reasoning-effort and context-invalidation cost is visible
  - `totals.by_effort` and `totals.context_invalidations`, scanned per `(role, agent_id)` rather than per role
  - effort is a per-turn request parameter carried only in the transcript — no hook payload has it
  - an empty `by_effort` means unmeasured, never constant

- [x] **P1**: Routing deviation is counted by what actually signals one
  - `dispatches_with_model_override`; ground truth for what a role ran on is `by_agent_role.<role>.models`
  - replaced `dispatches_without_named_model`, which inverted the routing rule and read 8 clean dispatches as 8 violations

- [x] **P1**: `packets[].edits` distinguishes rework from division of labour
  - per-role edit counts plus `contended_files` (same-file overlap)
  - files are identified by a 12-char hash, never a path, so a packet stays safe to paste into an issue

- [x] **P1**: `/gaffer:metrics <collect|show|status|analyze>` presents the packet
  - `show` surfaces the audit block above the per-packet table, and renders null as null rather than 0
  - `analyze` hands the compact rollup to Claude for ranked optimization advice

- [x] **P1**: Run-state note growth cannot crowd out the run packet
  - `runstate.sh trim-note` enforces the one-line `note:` contract the template documented but nothing checked
  - archives overflow to `run-state-note-archive.md`, trimming on whole lines so the YAML stays parseable
</content>
</invoke>
