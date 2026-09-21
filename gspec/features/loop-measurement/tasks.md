---
spec-version: v2
feature: loop-measurement
---

# Plan: loop-measurement

Two halves that share no files: honest outcomes (`runstate.sh` → `metrics.sh` → the
loop prompts) and machine-wide spend (a new script). The record-writing subcommands
land before anything that consumes them, and each consumer lands with its sweep
cases.

**Record formats are defined once, by T1 and T3, and nothing downstream reshapes
them.** Start and continuation records go in the existing append-only
`.agents/metrics/outcomes/<session>.jsonl` log, not run-state. `record-outcome`
stayed out of run-state for the same reason: run-state has a single writer. If T4,
T7 or T8 needs a field the records lack, change T1/T3 and their cases. Do not work
around it in a prompt or in jq.

**`interrupted` has one writer, and the script enforces it.** `record-outcome`
already refuses `interrupted` and T3 pins that with a case, so "only the sweep
records interrupted" does not depend on an agent following a prompt. `abandoned`
needs positive evidence that the task is gone. `runstate.sh` never reads `gspec/`,
so the caller lists the open packets (`sweep-open --list`), resolves them through
the adapter (T2), and passes the gone set back. An id the adapter reads as `unknown` (non-gspec
backlog, no plan) is swept as `interrupted`. That is the safe direction.

**The collector bug most likely to ship is attributing by the wrong key.** An
`interrupted` record is written by a *later* session's sweep, so it sits in that
session's log with a timestamp outside the run it closes. The outcomes join today
is scoped by selected session and window, and it will silently miss the record. T4
attributes it by the closed start it names. A trailer never implies green:
`/gaffer:pause` commits unfinished work with a packet trailer, and that start stays
open.

**`null` means unmeasured, never clean.** A run with no start records (every run
before this feature) reports outcome coverage as unmeasured. It must never report
it as complete, and never as 0 open.

**Spend is machine-wide, so it is its own script and sweep** (`scripts/spend.sh`,
`scripts/test-spend.sh`), not a `metrics.sh` subcommand. `collect` resolves one
repo's main checkout, and `metrics.sh` is the file T4–T6 serialize on. The rules
carry over and are asserted rather than imported:
- dedup keeps the earliest row per `message.id` and keeps id-less rows verbatim (v3.3)
- every `jq -r` read goes through the `tr -d '\r'` rule (v3.1)
- effort, agent type, the 5-minute/1-hour cache-write split and any compaction marker are **probed from real transcripts**, not taken from docs; a field that cannot be read is named and its totals marked unmeasured

**Prompt edits avoid what `retire-unused-loop-modes` deletes next.** Relay §0 and the
relay contract in `run-loop`/`resume`, `resume`'s parallel section, and
`skills/run-loop/parallel.md` get no new instructions. T7 and T8 edit the sequential
§1–§4 only.

**T16 is not a sweep case.** It needs the preserved 2026-09-14 transcripts and the
second machine's saved totals, so it is human-attended and ordered last but one, so
that it blocks nothing.

## Plan

- [x] **T1** [P] **P0** Add `runstate.sh record-start <packet-id> [--continue] [session-id]`, which appends a start or continuation record (packet id, sub-second UTC time, session, kind) to the append-only outcomes log `record-outcome` writes, moving `record-outcome` to the same sub-second stamp, resolving the main checkout the same way and refusing the same id charset, with `test-runstate.sh` cases asserting append-only valid JSON and that `record-outcome` accepts neither kind as an outcome
  - deps: —
  - covers: Every packet the loop begins records a start and a terminal outcome
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T2** [P] **P0** Give `gspec-backlog.sh task-status` a distinct `gone` state for an id whose feature plan exists but no longer names the task, kept out of `FINISHED=` and distinct from `unknown`, with `test-gspec-backlog.sh` cases including one proving the `FINISHED=` line is unchanged for existing callers
  - deps: —
  - covers: A packet left without an outcome is recorded as interrupted
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
- [x] **T3** **P0** Add `runstate.sh sweep-open [--list] [--paused-cursor <id>] [--gone <id,...>]`, which, across every outcomes log in the repo, appends `interrupted` (or `abandoned` for a gone id) for each packet whose latest start or continuation has no terminal outcome at or after it (comparing parsed times, not strings, so whole-second records written before this feature still order correctly), except the paused cursor; `--list` prints one `OPEN=<id>` line per such packet and appends nothing, so the caller can resolve the gone set before sweeping; each appended record names the session and time of the start it closes, the command prints one `SWEPT=` line per packet, and `record-outcome` keeps refusing `interrupted`, pinned by a case; cases cover `--list` writing nothing, the paused-cursor exemption, the gone set, an outcome earlier in the same second as a later start not closing it, an already-ended packet left untouched, and a second sweep appending nothing
  - deps: T1
  - covers: A packet left without an outcome is recorded as interrupted
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T4** **P0** Make `metrics.sh collect` build packet rows from start, continuation and outcome records as well as commit trailers, counting a packet as started in a run when that run's window holds a start, continuation or trailer for it or an outcome record attributed to that run; its outcome is the last record attributed to that run after its latest start or continuation, and an `interrupted` record belongs to the run of the start it names; `test-metrics.sh` cases cover a never-committed failed packet, a pause commit whose trailer does not read green, and an interruption swept by a later session
  - deps: T1, T3
  - covers: Run metrics never read a missing outcome as success · Every packet the loop begins records a start and a terminal outcome · A packet left without an outcome is recorded as interrupted
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T5** **P0** Add three things to the run packet: a count per outcome with each started packet counted once (interrupted included), a separate count of started packets with no terminal outcome, and an outcome-coverage field that is `unmeasured` when the run holds no start records; replace the `notes[]` line saying failed and uncommitted packets do not appear, with cases for a pre-feature run and a run with an open start
  - deps: T4
  - covers: Run metrics never read a missing outcome as success
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T6** **P0** Make `metrics.sh show` label a run with any started packet lacking an outcome as incomplete, and a run with no start records as outcome coverage unmeasured, never as all green; correct `skills/metrics/SKILL.md`'s show and analyze wording that says failed work is structurally absent, with cases on the rendered labels
  - deps: T5
  - covers: Run metrics never read a missing outcome as success
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh, skills/metrics/SKILL.md
- [x] **T7** [P] **P0** Rewrite `run-loop` §3 so that:
  - the driver alone runs `record-start` when it begins a packet, and again when it begins one after any recorded outcome;
  - it records a continuation when it continues a paused packet, and never a start for a subagent dispatch or a retry;
  - the §3.4 "whichever actually happened" line becomes the five exclusive triggers with their precedence (blocked over rolled-back and failed, failed over rolled-back);
  - a pause is stated as not an ending.

  Also state in `skills/pause/SKILL.md` that a pause committing unfinished work records no outcome and leaves the start open
  - deps: T1
  - covers: Every packet the loop begins records a start and a terminal outcome
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/pause/SKILL.md
- [x] **T8** **P0** Run `sweep-open` in `run-loop` and `resume` immediately before every start or continuation record:
  - pass `--paused-cursor` only for the cursor packet, and only when run-state's status read `paused` in `resume` §1, before §2 overwrites it with `running`;
  - resolve `--gone` by running `sweep-open --list`, then `task-status` on the listed ids, and passing its `gone` ids — skipping `task-status` and `--gone` when `--list` prints no `OPEN=` line, since `task-status` refuses an empty id list;
  - make `resume` §2 record green on `adopt` and nothing on `discard`;
  - make `resume` §4 `Read` `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` §3 for its start and outcome steps, recording the cursor packet with `record-start --continue` when the same paused-on-entry reading holds;
  - add to shapes A and B of `templates/report-templates.md` (a sweep always runs after the kickoff, so the next report is a check-in or a stop report) one line naming each swept packet by plain-English title and id, using an existing glyph so the conventions card is untouched
  - deps: T2, T3, T7
  - covers: A packet left without an outcome is recorded as interrupted · Every packet the loop begins records a start and a terminal outcome
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, templates/report-templates.md
- [x] **T9** [P] **P0** Add `scripts/spend.sh`, with a `scripts/test-spend.sh` sweep registered in CI, that does the following:
  - over a window (default the last 7 days), read every main and subagent transcript under the projects dir and count the assistant messages timestamped in it, deduplicated by message id, with id-less messages counted as they are and their count shown;
  - exclude and count messages lacking usage or a timestamp;
  - break tokens down by project folder name, model, agent role, effort and cost part (input, 5-minute cache write, 1-hour cache write, cache read, output), grouping a missing effort or agent type as unrecorded;
  - name any field it cannot read and mark the affected totals unmeasured;
  - emit no message content, prompt text or path
  - deps: —
  - covers: `/gaffer:metrics spend` reports API-equivalent spend over a time window
  - arch: —
  - files: scripts/spend.sh, scripts/test-spend.sh, .github/workflows/ci.yml
- [x] **T10** **P0** Add a price table stamped with its last-checked date, overridable by an alternate table file, and price every breakdown in dollars labelled API-equivalent; a model missing from the table shows its tokens as "unpriced", and totals state the unpriced token count instead of counting it as $0, with cases for a priced, an unpriced and a mixed window
  - deps: T9
  - covers: `/gaffer:metrics spend` reports API-equivalent spend over a time window
  - arch: —
  - files: scripts/spend.sh, scripts/spend-prices.json, scripts/test-spend.sh
- [x] **T11** **P0** Add the `spend` verb to `skills/metrics/SKILL.md` (description, argument-hint, intent resolution, window argument), rendered under the report conventions with the price-table date and API-equivalent label shown, unmeasured fields named in words, and unpriced tokens never summed as dollars
  - deps: T6, T10
  - covers: `/gaffer:metrics spend` reports API-equivalent spend over a time window
  - arch: —
  - files: skills/metrics/SKILL.md
- [x] **T12** **P1** Add to the spend report, per agent role, the per-turn cache-read shape (median, 90th percentile, maximum) and the count of turns above a size the report states, with cases
  - deps: T10
  - covers: The spend report shows where context cost comes from
  - arch: —
  - files: scripts/spend.sh, scripts/test-spend.sh
- [x] **T13** **P1** Group cache writes above a size the report states by cause, with count and dollars per cause, scanning per agent context as the collector's `context_invalidations` does:
  - the possible causes are: idle gap past the cache lifetime, model changed, effort changed, new session or subagent, compaction or prefix change, and new content;
  - each write counts once, under the first cause that fits, trying causes in an order the report states;
  - a write whose cause the transcript cannot show is counted as "unknown cause";
  - cases cover each cause, the unknown bucket, and a write fitting two causes
  - deps: T12
  - covers: The spend report shows where context cost comes from
  - arch: —
  - files: scripts/spend.sh, scripts/test-spend.sh
- [ ] **T14** **P1** Add `spend --save`, which writes a window's totals to a file holding only counts, tokens, dollars, the breakdown labels, the window, the price-table date, the save time, a machine label and project folder names with the home-directory prefix stripped (so a committed file carries no user name, and two machines with the same layout combine by key), with a case asserting no other field is present and no home-directory segment survives
  - deps: T10
  - covers: Saved spend totals combine across machines
  - arch: —
  - files: scripts/spend.sh, scripts/test-spend.sh
- [ ] **T15** **P1** Add `spend --combine <file>...`, which produces one report with the project, model, agent-role, effort and cost-part breakdowns and names each machine included; it warns by name on a window or price-table-date mismatch and counts only the later-saved of two files sharing a machine label and window, with cases, and document save and combine in `skills/metrics/SKILL.md`
  - deps: T11, T14
  - covers: Saved spend totals combine across machines
  - arch: —
  - files: scripts/spend.sh, scripts/test-spend.sh, skills/metrics/SKILL.md
- [ ] **T16** **P1** Run `spend` against the preserved transcripts for the 7-day window ending 2026-09-14 20:07 UTC, using a price table dated no later than 2026-09-14, and confirm:
  - the primary machine is within 5% of $2,078, with cache reads at 66–70%;
  - combined with the second machine's saved totals, the total is within 5% of $2,666.

  Commit both saved files under `docs/metrics/` as the redesign's before-measurement. On a miss, stop and report it; never adjust the price table to fit
  - deps: T15
  - covers: Saved spend totals combine across machines
  - arch: —
  - files: docs/metrics/
- [x] **T17** **P1** Record in `CLAUDE.md` and an ADR 0019 v3.5 section, as one deliberate change to the repo's most contended file:
  - packet rows now come from start records as well as trailers;
  - `interrupted` has one writer;
  - spend is machine-wide in its own script;
  - `test-spend.sh` is added to the sweep list.

  Repo-convention upkeep, not a PRD criterion
  - deps: T6, T8, T15
  - covers: Saved spend totals combine across machines
  - arch: —
  - files: CLAUDE.md, docs/adr/0019-run-metrics-observability.md
