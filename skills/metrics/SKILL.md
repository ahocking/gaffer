---
name: metrics
description: Assemble, show, or analyze a run-metrics packet (ADR 0019 Tier 1). `collect` joins the event log + `[orch packet:<id>]` commit trailers + best-effort transcript tokens into a self-contained `.agents/metrics/<run-id>/run-metrics.json`; `show` prints a compact summary; `status` reports whether metrics is on and which sources are present; `analyze` hands the packet to Claude for ranked, concrete optimization advice. Use when the user asks where a run's compute went, how to make the loop cheaper/faster, or to collect/see metrics for a run.
argument-hint: collect | show | status | analyze (omit to show the latest packet)
---

# Metrics → $ARGUMENTS

Measure a guided-autonomy run and turn the numbers into optimization decisions.
Deterministic collection is automatic (the `PostToolUse` hook logs tool events as
the run goes, with zero tokens); this skill is the human/Claude-facing interface
over `${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh`. See
[ADR 0019](../../docs/adr/0019-run-metrics-observability.md).

The **Chief Engineer** runs this. All four verbs are read-only analysis over local
bookkeeping — none crosses a gate.

## 1. Resolve intent from `$ARGUMENTS` (trim/lowercase)

- **empty / `show`** → print the latest packet (step 3).
- **`collect`** → assemble a fresh packet (step 2), then show it (step 3).
- **`status`** → report enabled-state + source availability (step 4).
- **`analyze`** → collect if needed, then reason over the packet (step 5).
- **anything else** → say the valid verbs are `collect | show | status | analyze`.

## 2. `collect` — assemble the run packet

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect
```

It resolves the canonical `.agents/` from `git rev-parse --git-common-dir` (so it
works from a lane worktree too), joins:

- the **event spine** (`.agents/metrics/events/*.jsonl`, written by the hook) —
  scoped by default to the **newest** session log (the run you just finished),
- **packet boundaries** derived from the `[orch packet:<id>]` commit trailers,
  **bounded to that session's run window** so a prior run's committed packets are
  not folded in (zero-migration; run-state is left untouched — ADR 0019 revision), and
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

This is numbers-dense by nature, so it takes **no header tally and no glyph gutter** —
the tally means "this is a run and here is its state", and there is nothing to count
here. The rest of the conventions in
`${CLAUDE_PLUGIN_ROOT}/templates/human-report.md` still apply: plain-English titles
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
  `tool_calls` / wave table: which role, packet, or wave dominates.
- **Parallel efficiency** (parallel runs) — packets per wave and their wall-times;
  flag waves that serialized when the graph allowed concurrency.
- **The relay-vs-inline crossover** — whether this run's shape supports or contradicts
  the ADR 0012 "20-packet" assumption.
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
  the attestation, and `null` means **unmeasured, not clean**. Never infer a success
  rate from packet rows alone: a packet exists only because it produced a green commit,
  so failed and rolled-back work is structurally absent. Where `edits` is present,
  `contended_files` (one file touched by more than one role) is the rework signal —
  it separates correction from division of labour, which per-role edit counts cannot.

**Honesty about the token source is mandatory:** if `token_source` is `none` or
`transcript`, say so and scope the token-based claims accordingly (structural claims —
timing, waves, tool counts — are unaffected). Then produce a **ranked, concrete** list
of changes (e.g. "wave 3 lanes re-load ~40k each; widen file-disjointness so N more run
concurrently", or "reviewer spends 2× the implementer in cacheCreation — hold its
context across packets"), most-impactful first, each tied to the metric that motivates it.

**A recommendation that is really a trade-off is a decision block**
(`${CLAUDE_PLUGIN_ROOT}/templates/human-report.md`), not a bullet. "Widen
file-disjointness" costs review confidence; "hold the reviewer's context" costs
freshness. Where you are recommending something the human gives up something for, give
them the two options, what follows from each, your lean, and the default — the same
form every other ask in this plugin takes. A bullet that hides a cost reads as free.

For a single small packet, reasoning inline is fine. For a deep or multi-run analysis,
delegate to the **architect** (the optimization/architecture authority) via `Task`,
handing it the packet path to `Read` — a dispatched agent has no `Skill` tool, so give
it the file path, not this command (ADR 0012).

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
