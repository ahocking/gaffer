---
name: metrics
description: Assemble, show, or analyze a run-metrics packet (ADR 0019 Tier 1). `collect` joins the event log + `[orch packet:<id>]` commit trailers + best-effort transcript tokens into a self-contained `.agents/metrics/<run-id>/run-metrics.json`; `show` prints a compact summary; `status` reports whether metrics is on and which sources are present; `analyze` hands the packet to Claude for ranked, concrete optimization advice; `spend` reports machine-wide API-equivalent token spend over a time window, priced from the published API rate card (not a bill), and can `--save` a window's totals to a file and `--combine` saved files from several machines into one report. Use when the user asks where a run's compute went, how to make the loop cheaper/faster, to collect/see metrics for a run, or how much a window of usage cost across the machine (or across several machines).
argument-hint: collect | show | status | analyze | spend [--days N | --since ISO --until ISO] [--save FILE --machine LABEL] | spend --combine FILE... (omit to show the latest packet)
---

# Metrics → $ARGUMENTS

Measure a guided-autonomy run and turn the numbers into optimization decisions.
Deterministic collection is automatic (the `PostToolUse` hook logs tool events as
the run goes, with zero tokens); this skill is the human/Claude-facing interface
over `${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh`. See
[ADR 0019](../../docs/adr/0019-run-metrics-observability.md).

The **Chief Engineer** runs this. All four verbs are read-only analysis over local
bookkeeping — none crosses a gate.

**Before you print anything, `Read`
`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md`** — the glyph vocabulary, the
indentation contract, and the decision block that every human-facing report in this
plugin owes. This skill has **no shape of its own**, so those conventions *are* its
format; naming the path is not reading it, and unread they produce free prose. You do
**not** need `report-templates.md`: it holds the guided loop's shapes, which this never
emits (and see step 3 — this report takes no header tally).

## 1. Resolve intent from `$ARGUMENTS` (trim/lowercase)

- **empty / `show`** → print the latest packet (step 3).
- **`collect`** → assemble a fresh packet (step 2), then show it (step 3).
- **`status`** → report enabled-state + source availability (step 4).
- **`analyze`** → collect if needed, then reason over the packet (step 5).
- **`spend [--days N] [--since ISO] [--until ISO] …`** → machine-wide API-equivalent
  spend report over a window (step 6); pass any window, `--save`/`--machine` or
  `--combine` flags through verbatim.
- **anything else** → say the valid verbs are `collect | show | status | analyze | spend`.

## 2. `collect` — assemble the run packet

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect
```

It resolves the canonical `.agents/` from `git rev-parse --git-common-dir` (so it
works from a lane worktree too), joins:

- the **event spine** (`.agents/metrics/events/*.jsonl`, written by the hook) —
  scoped by default to the **newest** session log (the run you just finished),
- **packet boundaries** derived from the `[orch packet:<id>]` commit trailers AND
  `runstate.sh record-start`/`record-outcome`/`sweep-open` attestations
  (loop-measurement T4) — a packet the loop started now appears even if it never
  committed (failed, rolled-back) or was interrupted mid-run, and a pause commit's
  trailer never implies green — all **bounded to that session's run window** so a
  prior run's committed packets are not folded in (zero-migration; run-state is left
  untouched — ADR 0019 revision), and
- **token/cost** from the Claude Code transcripts (default source; **version-fragile**,
  so it **fails soft** to structural-only and stamps `token_source`),

and writes `.agents/metrics/<run-id>/run-metrics.json` — a compact, portable rollup
(`<run-id>` is the run's `orch/<task-id>`, else `adhoc-<session8>`). It prints the
packet path. `jq` is required; if absent it says so and the event log is unaffected.

**Multi-session runs** (a run that was paused and resumed spans more than one
session): the default newest-session scope captures only the latest slice. To roll
up the whole run, pass the session ids (`--session <id> --session <id> …`) or a lower
time bound (`--since <ISO>`); `--all-sessions` folds in every session log on disk.

## 3. `show` — compact summary

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh show          # newest packet
${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh show <path>   # a specific packet
```

Relay the run/window/tokens/cache-ratio, the per-role token split, and the
per-packet table to the user.

**Outcome coverage is a label, never a green count** (loop-measurement T6). The
printed `outcome coverage: …` line reads one of three ways, and none of them may be
softened to "all green" or hidden: `unmeasured` — this run holds no
`record-start` boundary at all (a pre-instrumentation run, or one where the loop
never called it) — say so and do not infer completeness from the packet count;
`incomplete` — at least one started packet has no terminal outcome yet (an open
pause, or a crash the next session's sweep has not reconciled) — name the count and
the packet(s); `complete` — every started packet has a terminal outcome, which is
**not** the same as "every packet is green" (an `interrupted`/`failed`/`rolled-back`
outcome is just as complete as `green` — read `totals.outcome_counts` for the real
split, and relay it, not a pass/fail summary). Relay whichever applies verbatim
rather than paraphrasing it into "the run succeeded" or "the run is clean".

**Main-session context is the "Long runs compact" success metric** (thin-loop-driver
T21). `totals.driver_mode_context` reports the largest context of one main-thread
turn — its input, cache-write and cache-read tokens, output deliberately excluded,
each message counted once by id — recorded while a selected session was in driver
mode, beside `threshold`, the compaction threshold that run's kickoff (its earliest
driver-mode `enter` record in scope) stated. The two fields are `null`
**independently, not together**: both are `null` when there is no driver-mode
window in scope, or the kickoff record's threshold is missing or `"unknown"`;
`threshold` is stated with `max_context: null` when no main-thread turn
carrying usage data falls inside any window; both numbers are present only
when the comparison is real. A real `max_context` is never paired against an
invented threshold. This fixed, run-KICKOFF baseline is deliberately different
from `run-digest`'s reading of the same driver-mode logs, which reports the
MOST RECENT `enter` across every session instead — `run-digest` answers what
setting is in effect *now* for a run that can span sessions, while this
measurement judges the run against the number the operator was shown at
kickoff, so the two are expected to disagree. A later re-entry is ASSUMED, not
verified, to carry the same repo/operator setting as the kickoff record it is
compared against. `totals.driver_mode_context_diagnostics`
(`windows`, `turns_in_window`) says what was actually seen even when the headline
reads unmeasured. `show` renders one line: the two numbers and whether the max turn
came in **under** or **⚠ OVER** the threshold, or the specific reason it is
unmeasured — relay it verbatim, the same rule as every other null in this packet.
That includes the no-threshold line's remedy clause (the part naming the settings
key `autoCompactWindow` as what supplies one): relay it unparaphrased with the rest
of the line, and never rewrite it into an instruction to set that key or a
recommended value for it — whether and what to set is the operator's call, not
this report's to open.

This is numbers-dense by nature, so it takes **no header tally and no glyph gutter** —
the tally means "this is a run and here is its state", and there is nothing to count
here. The rest of the conventions in
`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md` still apply: plain-English titles
before packet ids, one line per finding, empty sections omitted, and no restating of
the raw JSON. Where a number is *unmeasured* rather than zero (`null` on a legacy
run), say so in words — a `0` the human reads as "clean" is the exact failure v3.3
already had to fix once in this skill's own output.

## 4. `status` — is it on, and what can it see?

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh status
```

Reports `metrics: on|off` (env `ORCH_METRICS` → `.agents/project-overrides.yaml`
`metrics.enabled` → default on), whether `jq` and a transcript dir are present, and
how many event logs exist. Use this to explain a `token_source: none` packet.

## 5. `analyze` — turn the packet into optimization advice

This is the end goal (ADR 0019). First ensure a fresh packet exists (run step 2),
then **read the whole `run-metrics.json`** — it is deliberately small enough to drop
into context — and answer, grounded in its numbers:

> **Where is this run's compute going, and what specifically would reduce it?**

Look for, and cite the figures behind, at least:

- **Cache efficiency** — `totals.cache_hit_ratio` and the cacheCreation-vs-cacheRead
  split (run-level and per role). A low ratio / high cacheCreation means agents are
  re-loading context instead of reusing it — the loop's biggest suspected hidden cost.
- **Where spend concentrates** — the `by_agent_role` token split and the per-packet
  `tool_calls` table: which role or packet dominates.
- **Same-file overlap, via `totals.same_file_overlaps`** (retire-unused-loop-modes
  T3) — a run-level count of (main session, subagent) pairs that edited the SAME
  file: a subagent's span is its first-to-last recorded event, the main session
  pairs with it only through the main session's own edit events falling inside that
  span, and a pair counts once no matter how many files it shares. It replaces
  parallel mode's mechanical file-disjointness guarantee with observability now that
  the guarantee is gone — this is what tells the operator whether concurrent editing
  guidance is actually holding. `null` means **unmeasured** (no events in the run, or
  at least one Edit/Write/MultiEdit/NotebookEdit event with no `file_hash`), never a
  clean `0` — say so in words, the same rule as every other `null` in this packet.
  `totals.same_file_overlap_diagnostics` names the edit-event counts behind an
  unmeasured stamp. It logs no path, only opaque per-file hashes.
- **The relay-vs-inline crossover** — whether this run's shape supports or contradicts
  ADR 0012's 40-packet crossover (raised from 20 in its v2 revision). A run below the
  crossover cannot unseat it in either direction; say so rather than reading one arm as
  a verdict.
- **Standing-context size, via `by_agent_role.<role>.cc_shape`** — prefer this over
  cacheCreation totals, which are too noisy to steer by (measured: 1.76x spread across
  untouched same-regime runs, 9x overall). `median` is the cost of one more turn;
  `p90`/`max` are what it costs to rebuild that role's context once. **A flat median
  with a large max is not an expensive agent — it is a large payload being re-cached**,
  and it is fixed by scoping what the role reads, not by dispatching it less.
- **`totals.context_invalidations`** — effort or model changed mid-context, which
  re-caches the whole prefix. Measured at 16 events / 3.35M cacheC in one repo, ~3.2%
  of its lifetime cacheCreation, firing in **both** directions and propagating into
  dispatched subagents. If any appear, say so and note that the fix is behavioural:
  change effort/model at a **packet boundary**, where the context is smallest.
- **`packets[].outcome` and `packets[].edits`** — both are `null` on runs that predate
  the attestation, and `null` means **unmeasured, not clean**. Before loop-measurement
  T4 a packet existed here only because it produced a green commit, so failed and
  rolled-back work was structurally absent — that is **no longer true** once the run
  carries `record-start`/`record-outcome`/`sweep-open` attestations: read
  `totals.outcome_coverage` first (`unmeasured` = this run predates the instrumentation,
  never infer a rate from packet rows; `incomplete` = a started packet is still open,
  name it; `complete` = every started packet has a terminal outcome, which is **not**
  "every packet is green" — `totals.outcome_counts` has the real split, `interrupted`
  included). Where `edits` is present, `contended_files` (one file touched by more than
  one role) is the rework signal — it separates correction from division of labour,
  which per-role edit counts cannot.
- **`self_host`** — a boolean indicating whether this run measured the plugin's own
  repository (dogfooding) rather than a consumer application. Self-host and consumer
  runs must NOT be averaged together, since this repo's loop feeds the measurement
  corpus that benchmarks the plugin, and the populations are incomparable. Absent
  `self_host` key means unmeasured; treat unknown distinctly from measured consumer
  runs.

**Honesty about the token source is mandatory:** if `token_source` is `none` or
`transcript`, say so and scope the token-based claims accordingly (structural claims —
timing, tool counts — are unaffected). Then produce a **ranked, concrete** list
of changes (e.g. "same-file overlaps: 3 — the implementer and the main session edited
the same 2 files while both were active; tighten the declared file scopes so edits stay
disjoint", or "reviewer spends 2× the implementer in cacheCreation — hold its
context across packets"), most-impactful first, each tied to the metric that motivates it.

**A recommendation that is really a trade-off is a decision block**
(`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md`), not a bullet. "Widen
file-disjointness" costs review confidence; "hold the reviewer's context" costs
freshness. Where you are recommending something the human gives up something for, give
them the two options, what follows from each, your lean, and the default — the same
form every other ask in this plugin takes. A bullet that hides a cost reads as free.

For a single small packet, reasoning inline is fine. For a deep or multi-run analysis,
delegate to the **architect** (the optimization/architecture authority) via `Task`,
handing it the packet path to `Read` — a dispatched agent has no `Skill` tool, so give
it the file path, not this command (ADR 0012). Run `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve architect` immediately
before the dispatch (non-empty → pass it as `model`; empty → omit `model`).

## 6. `spend` — machine-wide API-equivalent spend report

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/spend.sh [--days N] [--since ISO] [--until ISO] \
  [--projects-dir DIR] [--price-table FILE]
```

Unlike `collect`/`show` (one repo's run), this reads **every** Claude Code transcript on
the machine — main sessions and subagents, every project — over a window: default the
last **7 days** (`--days N`); `--since`/`--until` (ISO, e.g. `2026-09-08T00:00:00Z`)
override it. Tokens are priced from `scripts/spend-prices.json` (or `--price-table
FILE`). Pass `$ARGUMENTS`' window flags straight through; an unrecognized flag is a
usage error (exit 1), not a silent no-op.

It prints one JSON report to stdout; relay it, not the raw JSON, following the report
conventions. Like `show`/`analyze` this is numbers-dense and takes **no header tally**;
titles-over-ids and one line per finding still apply.

- **Lead with the price table, not the total**: `price_table.date` and the report's own
  `label` ("API-equivalent spend estimate from published per-token API prices — not a
  bill."). Every dollar figure is priced as of that date and is an estimate, not a
  bill — say so once, up front.
- **`totals.dollars`** is the headline figure, broken down by `by_project` / `by_model`
  / `by_role` / `by_effort` (each carrying `tokens`, `dollars`, `unpriced_tokens`,
  `cache_write_unmeasured_tokens`). **Never fold `totals.unpriced_tokens` into a dollar
  figure** — a model missing from the price table prices at 0 but is NOT free; state its
  token count on its own line, never as "$0" or silence.
- **Name every `unmeasured[]` entry in words**, not a silent zero — each already says
  which field and how many tokens/messages it covers (an unavailable cache-write 5m/1h
  split, an unrecorded agent role, an unrecorded model id, no effort recorded anywhere
  in the window).
- **Report the dedup and exclusion counts, not just the total**: `counts.messages_deduped_dropped`
  (repeated message ids collapsed to the earliest row — scan-scoped, not window-scoped,
  per the report's own `notes[]`), `counts.messages_excluded_no_usage_or_ts` and
  `counts.messages_excluded_synthetic` (rows dropped for missing usage/timestamp, or a
  synthetic no-cost turn), and `counts.messages_no_id` (kept, not deduped, per
  `notes[]`). If `projects_dir.status` is `absent`, say the scan directory itself was
  not found rather than reporting zero spend.

### Saving a window's totals, and combining machines

`spend` reads only the machine it runs on. To total spend across machines, save each
machine's window, then combine the saved files on any one of them:

```bash
# on each machine, over the SAME window
${CLAUDE_PLUGIN_ROOT}/scripts/spend.sh --since ISO --until ISO \
  --save FILE --machine LABEL
# anywhere, once every file is in hand
${CLAUDE_PLUGIN_ROOT}/scripts/spend.sh --combine FILE [FILE...]
```

- **`--save FILE --machine LABEL`** prints the normal report **and** writes the window's
  totals to `FILE`: counts, tokens, dollars, the model / agent-role / effort / cost-part
  labels, the window, the price-table date, the save time, the machine label and project
  folder names with the home-directory prefix stripped (so the file carries no user name
  and two machines with the same layout share keys) — nothing else. `--machine` is
  required and is never defaulted from the hostname. It refuses, writing nothing, with
  `--project`, when the transcript directory does not exist, or when a home-directory
  segment would survive into the file.
- **`--combine FILE...`** reads no transcripts and consults no price table — each file's
  dollars were priced when it was saved. It prints one JSON report summing `counts`,
  `totals`, `by_project`, `by_model`, `by_role` and `by_effort` by key (each with its five
  cost-part token counts), with `machines[]` naming every machine counted. It cannot be
  mixed with any scan option, and a file that is not a `--save` file is refused, naming it.

Render the combined report like the single-machine one (price-table date and label first,
unpriced tokens never as dollars, every `unmeasured[]` entry in words), plus:

- **Name every machine in `machines[]`**, with its window and price-table date.
- **Relay every `warnings[]` entry**, as a ⚠️ line above the totals — they are also
  printed to stderr as `WARNING:` lines. A **window mismatch** or **price-table date
  mismatch** means the files were combined anyway: the totals span different periods,
  or sum dollars priced from different tables, and the top-level `window` /
  `price_table_date` is then `null` — say "differs by machine", never one machine's
  value.
- **Of two files with the same machine label and window, only the later-saved one is
  counted**; the other is in `superseded[]`. Name it and say it was not counted (on a tie
  in save time, the file given later on the command line is counted, and the warning
  says so). A machine counted from two files with *different* windows is not superseded
  — both are counted, and the warning says their overlap is counted twice.
- A combined report carries **no** per-role cache-read shape and **no** cache-write
  causes (saved files do not hold them); its `unmeasured[]` says so — report them as not
  measured, never as zero.

## Config

Enable/disable and retention live in `.agents/project-overrides.yaml`:

```yaml
metrics:
  enabled: true      # default; the zero-token Tier-1 event+timing spine
  otel: false        # Tier 0 (OTEL) is optional/deferred — not required for Tier 1
  retain_runs: 20    # cap on retained .agents/metrics/<run-id>/ dirs
```

`ORCH_METRICS=off` (env) disables the spine for a session. `.agents/metrics/` is
gitignored bookkeeping (ADR 0009) — archive a run by **copying its `run-metrics.json`
out**, not by committing the live directory.
