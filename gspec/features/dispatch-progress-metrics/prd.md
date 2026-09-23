---
spec-version: v2
depends_on: [run-metrics, implementer-continuation]
---

# Feature: dispatch-progress-metrics

## Overview

The run collector sees a packet as one unit. `packets[]` carries `dispatched[]`
counts per subagent type and `audit.review_dispatches`, and a second
implementer dispatch is inferred to be a fix round, but no dispatch is
classified by kind, none carries its own tool-call count or token cost, and
nothing says whether a given dispatch advanced the packet or spent its whole
context and landed nothing. The operator's baseline (2026-09-14) is the reason
that matters: 60 of 242 implementer runs of 150 turns or more carried 74% of
implementer cost, and the 27 of 98 packets with no recorded outcome were
mostly the longest. An upstream tool that added per-run kind tagging and a
progress flag before saving anything found 4–5 of 12 runs checking zero tasks
and used that to target its turn cap and continuation brief (−54% implementer
input). The raw records for the same classification already exist here across
three logs — the events log by `agent_id`, the outcomes log's start records,
and `routing.jsonl`'s verdict records — and the collector does not join them
per dispatch.

This feature joins them. It is also the detector for `implementer-continuation`:
a cooperative turn budget is honoured only if continuations converge, and that
is countable only per dispatch. ADR 0026 arm 2, a new feature against the
derived-done `run-metrics`; no existing field changes meaning.

## Users & Use Cases

- **The operator reading `/gaffer:metrics show` or `analyze`** — wants "which
  dispatches spent tokens and landed nothing" and "are continuations
  converging" answered from the run packet, with unmeasured shown as
  unmeasured. The second question is how they judge whether a cooperative turn
  budget (`implementer-continuation`) is honoured, and it is countable only
  per dispatch.
- **The architect running `analyze`** — needs the kind and progress dimensions
  per dispatch to rank advice; a packet-level total hides a zero-progress
  dispatch behind the one that landed. When judging a loop-cost change by
  before-and-after numbers (`loop-measurement`), they re-collect old runs and
  compare, so every existing field keeps its meaning and only new fields
  appear.

## Scope

**In**
- `scripts/metrics.sh collect` emits, per packet, a `dispatches[]` array of
  implementer-role dispatches, each with `kind`, `tool_calls`, `duration_ms`,
  `tokens`, `edits` and `progress`, joined from the logs the Overview names.
- A run-level `totals.dispatch_waste` rollup.
- Two per-packet `audit.flags` entries in the existing flag vocabulary.
- `/gaffer:metrics show` renders the rollup in the audit block above the
  per-packet table.
- Cases in `scripts/test-metrics.sh` against the synthetic fixture, including
  the CRLF byte-identity assertion extended to the new fields.

**Out**
- Any new hook or new log. A new record kind in the outcomes log is forbidden
  — `_rs_open_packets` reads any record carrying `kind` as a packet start.
- Changing the meaning of any existing field: `packets[].edits`,
  `by_agent_role`, `dispatched[]`, `outcome`, `audit.review_dispatches`.
- Guard ASK-tier frequency and correction-versus-division edit overlap
  (`metrics-coverage-gaps`).
- The spend tail and cache-cause grouping (`loop-measurement`).
- The `analyze` prompt's ranking rules, beyond exposing the new fields to it.

**Deferred**
- Nothing beyond the Deferred Decisions below.

## Capabilities

- [x] **P0**: Every implementer dispatch in a packet is one row with a kind
  - one counted dispatch is one `Agent` event in the packet's window whose
    `subagent_type` names the implementer role. The `Agent` event is logged
    when the dispatch returns, so the dispatch's start is that event's
    timestamp minus its own `duration_ms`, and its span runs from that start
    to the event's timestamp, each bound widened by 1 s and inclusive. Its
    events are the events carrying the `agent_id` whose first event falls
    inside that span. When more than one `agent_id` qualifies, the one whose
    first event is earliest is the dispatch's; when none qualifies, or the
    `Agent` event carries no `duration_ms`, the dispatch is still a row,
    resolved to no `agent_id` (amended 2026-09-23, operator's call: the event
    is written after the subagent returns, so "first event after the `Agent`
    event" would credit the next agent). Attribution keys on `agent_id` presence
    and the `Agent` event, never on `agent_type`, since a main thread run as
    an agent carries `agent_type` with no `agent_id`
  - `kind` is set by the latest record for the packet preceding the dispatch's
    `Agent` event: `initial` after a `start` record, whether or not it was
    written with `--continue` — a resume's continuation record is a start for
    this purpose; `continuation` after the `continue` routing record
    `implementer-continuation` defines, and only that record; `fix` or `retry`
    after a routing record with that verdict. Each dispatch matches at most one
    record, the latest — except that when a routing record and a start record
    are both written at one boundary before the dispatch, as
    `implementer-continuation` does for a continuation, the routing record
    decides — and a dispatch with no such record before it has
    `kind: null`
  - a run whose window holds neither a start record nor a routing record is a
    legacy run: every dispatch row carries `kind: null` and `progress: null`,
    never a guessed `initial`; re-collecting an old run yields the same
  - a run whose start records survive but whose routing log does not — its
    `.agents/loop/<run_id>/` directory already pruned, since `begin-run` keeps
    only the current run and the newest other — carries `kind: null` on every
    dispatch row, never the `initial` the surviving start record alone would
    give a `fix` or `retry` dispatch; an unreadable routing log is unmeasured,
    not a run without verdicts (amended 2026-09-21, operator's call at plan time)
  - a swept or bundle-sibling packet, whose window the collector already
    declares unmeasured, has `dispatches: null`, in the same null-field shape
    those rows use today

- [x] **P0**: Each dispatch carries its own cost and its own progress
  - `tool_calls` is the count of the dispatch's events, `duration_ms` their
    `duration_ms` sum, `edits` the count among them with tool `Edit`, `Write`,
    `MultiEdit` or `NotebookEdit`, the same write surface the packet-level
    audit counts; all three are null, never 0, for a dispatch resolved to no
    `agent_id`. `tokens` is the sum over the dispatch's transcript turns
    deduplicated by `message.id`, read under the run's single `token_source`,
    and null with no partial figure when the packet's own `tokens` is null or
    when no transcript turn resolves to this dispatch
  - `progress` is tested in this order and exactly one value applies: `null`
    first, when the packet's trailer window is unmeasured, the run is legacy
    as the kind capability defines it, or the dispatch resolved to no
    `agent_id`; then `landed`, when the packet's commit trailer author time
    falls at or after this dispatch's start (as the kind capability defines
    it) and before the next implementer-role dispatch's start, or before the
    window's end for the last
    dispatch, using the same bounded trailer window as the packet row; then
    `advanced`, when the dispatch has at least one edit event and no such
    commit; then `none`, when it has zero edit events
  - a dispatch whose edits are carried by a later dispatch's commit reads
    `advanced`, not `landed`: `landed` is attributed only to the dispatch in
    whose interval the commit falls, and a packet has at most one `landed`
    dispatch per trailer

- [x] **P0**: A run-level rollup names the waste
  - `totals.dispatch_waste` carries: `zero_progress` (count and token sum of
    dispatches with `progress: none`), `continuations` (count of dispatches
    with `kind: continuation`), `over_threshold` (count of dispatches whose
    `tool_calls` exceeds a threshold, and the share of all implementer-dispatch
    tokens they hold), and `turn_threshold`, the threshold used
  - the threshold is the repository's `implementer_turn_budget` when one is
    set and its unit is tool calls, else 150, the baseline's own cutoff; the
    rollup stamps whichever applied in `turn_threshold` together with the unit
    it was read in
  - each component is `null`, never 0, when the run's records cannot support
    it: `zero_progress` and `continuations` when any dispatch row has a null
    `progress` or `kind` respectively, the token sum and share when any
    counted dispatch's `tokens` is null, and every component on a legacy run
    or a run with no implementer dispatch. A `notes[]` line names which
    component is unmeasured and why

- [x] **P1**: Per-packet flags surface zero-progress and over-threshold dispatches
  - `audit.flags` gains `waste:zero-progress-dispatch(<n>)` when a packet has
    n ≥ 1 dispatches with `progress: none`, and `waste:over-budget-dispatch(<n>)`
    when n ≥ 1 dispatches have `tool_calls` above the same `turn_threshold`
    the rollup stamps, read in the same unit, in the existing
    `<class>:<detail>(<count>)` vocabulary and alongside the existing `waste:`
    and `leak:` flags
  - both are suppressed on a legacy run the same way `unlabelled:` is
    suppressed when no packet carries a trailer, and neither is emitted for a
    swept or sibling row; a dispatch with a null `progress` or a null
    `tool_calls` counts toward neither flag and its own nulls carry the
    unmeasured state, so a packet of such dispatches gets no flag rather than
    a zero, and the sweep's legacy-run case asserts no
    waste flag is emitted
  - `totals.audit.flagged_packets` lists a packet carrying either flag exactly
    as it lists one carrying any other

- [ ] **P1**: `show` renders the rollup where it is read
  - `/gaffer:metrics show` prints `dispatch_waste` inside the audit block,
    above the per-packet table, on the rule that an audit signal off-screen
    goes unread
  - a `null` component renders as unmeasured with the reason from `notes[]`,
    never as 0 or as absent; a non-null zero renders as 0
  - `analyze` receives `dispatches[]` and `dispatch_waste` in the rollup it is
    handed, so it can name the top zero-progress dispatches by tokens

- [ ] **P0**: Existing outputs keep their meaning and the sweep pins the new fields
  - for the current synthetic fixture, `collect` output with every new field
    deleted is byte-identical to the output before this feature, apart from
    `generated_at`; `scripts/test-metrics.sh` asserts it, and the assertion
    fails under a mutation that alters `packets[].edits`, `dispatched[]` or
    `audit.review_dispatches`
  - the sweep gains a packet with `initial` → `fix` → `landed`, a packet with
    a zero-progress dispatch, a packet with a continuation, and a legacy run
    with neither start nor routing records asserting null kinds, null
    progress and a null rollup
  - the CRLF-jq byte-identity assertion covers the new fields, so a `kind` or
    `progress` value with a trailing carriage return turns the sweep red

## Dependencies

- `run-metrics` — the parent: the collector, the trailer window, `message.id`
  deduplication and `token_source`. Derived-done; nothing here re-opens a
  capability or edits a checked task.
- `implementer-continuation` — defines the `continue` status and its routing
  record. The dependency is for `kind: continuation` to be producible, not for
  the code to run: built first, this feature never produces that value and
  every other kind is unaffected.
- `loop-measurement` — **not blocking, but same files**: it edits
  `scripts/metrics.sh` and `scripts/test-metrics.sh`, and its before/after
  comparison is why no existing field changes. The two should not be in flight
  against those files at once.
- `metrics-coverage-gaps` — sibling, non-overlapping by declared scope.

## Assumptions & Risks

- Assumption: an implementer dispatch's events are those of the earliest
  `agent_id` first seen inside its back-dated span (`Agent` event timestamp
  minus `duration_ms`, to the timestamp, ±1 s). Two implementer dispatches
  inside one packet whose contexts interleave would join deterministically but
  possibly to the wrong context; the loop runs file-editing agents one at a
  time, so the case is guidance-excluded, not impossible.
- Assumption: `tool_calls` stands in for the baseline's turns. The baseline
  counted transcript turns; event counts are the same order and the threshold
  is stamped, so a reader can re-derive.
- Risk: `progress` uses author dates, which rebase and cherry-pick preserve
  and squash-merge does not; a packet landed by squash after the run reads
  `advanced` for every dispatch. Same exposure as the packet row, not new.
- Risk: the classification is retroactive, and old runs re-collect with
  `kind: null` wherever routing records were never written. That is
  unmeasured, not clean, and the rollup says so.

## Success Metrics

Baseline (2026-09-14): 74% of implementer cost in runs of 150 turns or more;
the share of implementer tokens spent in dispatches that land nothing is
unmeasured today.

- On the next consumer run of ten or more packets, the share of implementer
  tokens spent in `progress: none` dispatches is reported as a figure, from
  `totals.dispatch_waste`, where the baseline has none.
- In that run, every implementer dispatch has a non-null `kind`, so the
  continuation count `implementer-continuation` needs is a number, not
  unmeasured.
- `analyze` on that run names the top three zero-progress dispatches by tokens
  — checkable in its output.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Whether `progress` also reads the checkbox flip inside the commit
  (task-level) rather than the packet trailer (packet-level).** A bundle can
  land members across dispatches, and the trailer credits the last; the
  task-level reading needs `gspec-backlog.sh`'s flip to be attributable to a
  dispatch, which it is not today.
- **Whether a reviewer dispatch gets a kind.** It is not an implementer, its
  cost is already `audit.review_dispatches`, and no analysis has yet needed
  it split.
