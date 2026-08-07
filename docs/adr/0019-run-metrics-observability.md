# ADR 0019 — Run-metrics observability (the per-run metrics packet)

- Status: Accepted
- Date: 2026-07-21
- Deciders: user (tech lead), orchestration plugin
- Revision (2026-07-21): **Tier 0 (OTEL) demoted from accepted to optional/deferred.**
  Tier 1 ships standalone with **transcript-parse as the default token source** (OTEL
  becomes a later optional upgrade). Added an explicit end-goal: the run metrics packet is
  designed to be **handed to Claude for optimization analysis** — so the packet is a
  compact, self-describing rollup, and `/gaffer:metrics` gains an `analyze`
  subcommand. See Decisions 1, 2, 4 and Open question 1.
- Revision (2026-07-21, at implementation): **Per-packet timing is NOT threaded into
  run-state's `packets[]`.** Implementation showed that forces a schema migration and
  contends with the driver's single-writer/atomic contract (and would disrupt an in-flight
  run). Instead, `metrics.sh collect` derives packet boundaries from the **`[orch
  packet:<id>]` commit trailers that already exist** (zero-migration; run-state untouched),
  matching only a trailer on its own line **within the run window** (see the 2026-07-21
  scoping revision under Decision 2 — the scan is bounded to the selected session's window,
  not `git log --all`). Consequence: failed/uncommitted packets do not
  appear in v1, and per-packet token split is deferred (run + per-role tokens only). These
  gaps are self-documented in each packet's `notes[]`. See Decision 2 and Open question 2.
  Status: **Accepted & implemented (Tier 1)** — `hooks/metrics-log.sh`, `scripts/metrics.sh`,
  `scripts/test-metrics.sh`, `skills/metrics/SKILL.md`, gitignore + docs.
- Revision (2026-07-21, follow-up): two items originally noted as deferred are now done.
  (a) **The `PostToolUse` matcher is `.*` (ALL tools), not just the mutating set** — so
  `Task` dispatches (the fan-out being measured) and `Read`/`Grep` (context-loading, the
  cache-cost story) are counted; `totals.tool_calls` is now all activity. (b) **Auto-collect
  is wired into the loop skills** — `run-loop` (§4 done; `parallel.md` P3 DAG-done / P3 pause), `pause`
  (§3b), and `resume` (§2, to capture a crashed prior segment) each call `metrics.sh collect
  || true`, best-effort and non-critical, to pin perishable transcript-token data at each
  checkpoint. **Verified for parallel** by `test-metrics.sh` (39 checks): a hook firing from
  inside a real `git worktree` lane resolves to the MAIN checkout's `.agents/metrics/`, and
  concurrent same-session-file appends stay intact (O_APPEND atomicity).
- Revision (2026-07-22): **v2 — enriched collection, live-certified.** The metrics layer
  gained the dimensions the repo-optimization objective actually needs (rank which
  skills / agents / processes / command-classes cost the most compute), all derived from
  the **same PostToolUse payload** — no new hooks. Additions:
  - `metrics.sh` (schema **1 → 2**): **per-packet token split** (transcript turns bucketed
    by their own timestamp into packet windows; fail-soft `null` when a turn lacks a
    timestamp — closes the v1 "per-packet token split deferred" gap); **active/idle wall
    split** (`window.active_seconds`/`idle_seconds` + per-packet `active_seconds`, from
    inter-event gaps vs an `idle_gap_seconds` threshold — wall-time had overstated effort
    ~7× on a paused run); **unattributed-tool-calls bucket** (`totals.unattributed_*` —
    events outside any packet window, the wasted/between-packet compute that was silently
    dropped); **model-per-agent** (`by_agent_role.<role>.models` + `totals.by_model` — raw
    token counts are not cost-comparable across opus/sonnet/haiku); per-tool **`duration_ms`**
    rollups; and the **skill/process + command-class dimensions** (`by_skill`,
    `by_command_class`) — the last is the "where an output filter like RTK helps most" map
    the deferred Tier 2 needs.
  - `metrics-log.sh` enrichment: the event line now also carries `duration_ms`,
    `tool_use_id`, the running `skill` (from the `Skill` tool input), the dispatched
    `subagent_type` (from the **`Agent`** tool input), and a Bash **`cmd_class`** — the
    command **head only** (argv0[+subcommand] for known multiplexers), with env prefixes,
    args, and paths STRIPPED. **This supersedes the v1 "metadata-only, never command text
    or paths" property**: the log now carries low-sensitivity labels and a program-name
    classifier, but still **no full command text, arguments, paths, or tool output** — so
    the assembled packet stays safe to hand to Claude. Full-fidelity forensics remain in the
    (deferred) transcript snapshot (P4), not here.
  - **Field names were payload-PROBED, not taken from docs** (a throwaway `PreToolUse`/
    `PostToolUse`/… dump hook, run live). Findings that changed the build: **`duration_ms`
    is a native `PostToolUse` field** (so per-tool duration needs no Pre/Post pairing — a
    guide-agent claim to the contrary was wrong); `tool_use_id` (per-call) + `prompt_id`
    (per-turn) both present; **`agent_id`/`agent_type` do arrive inside a dispatched
    subagent** (attribution confirmed live — the subagent's own tool events stamp its
    identity); the **dispatch tool is named `Agent`, not `Task`** (matcher must key on
    `Agent`); Skill input is `{skill,args}`, Agent input carries `subagent_type`. **Negative
    results:** there is **no `tool_output_token_estimate`** field; **`Notification` does NOT
    fire on a denied tool call** (so guard ASK/DENY-frequency friction cannot key on it —
    P3-I deferred); `PreCompact` did not fire in a short session (unconfirmed).
  - **The `cmd_class` classifier was hardened against REAL payloads** (replaying the probe's
    captured events through the source hook), which caught three bugs synthetic tests missed:
    `cd DIR && cmd` and `cd DIR`⏎`cmd` wrappers must classify as `cmd` not `cd` (agents run
    this constantly), and non-program tokens (`[`, `-flag`, `$(...)`) must be filtered. All
    leak-tested (env prefixes / tokens / paths never reach the log).
  - **Live-certified 2026-07-22** end-to-end in a fresh session with the bumped plugin: the
    enriched hook fires (incl. inside a dispatched subagent), no secret leaks, and
    `metrics.sh collect`/`show` populate `by_command_class` (real programs, not `cd`),
    `by_skill` (with duration), per-role duration, and the model split. Regression sweep:
    `scripts/test-metrics.sh` (89 checks). **Deferred (unchanged):** P3 friction
    (`blocked_attempts` needs a `PreToolUse` collector), P3-H/P3-I (compaction/stall — events
    unconfirmed/negative), P4 transcript snapshot, P5-M lane attribution, and the static
    prompt-size audit. See Decision 2 and Open questions 1–2.
- Revision (2026-07-23, from the first real analysis): **the routing audit measured the
  wrong thing, and the tier label was collected too late to be reliable.** Both surfaced
  when the first production capture (`adhoc-<session8>`, 6 packets) was analyzed:
  - **`dispatches_without_named_model` was a false-positive generator — removed.** It rested
    on the premise that an omitted `model` at dispatch inherits the *session* model and so
    defeats tiering. That premise is wrong: the `Agent` tool resolves an omitted `model` to
    the **target agent's own `model:` frontmatter**, and every orchestration agent declares
    one (`implementer`=sonnet, `doc-writer`=haiku, `architect`/`reviewer`/`chief-engineer`=
    opus); only an agent with no declared model falls through to the parent. That run
    therefore scored **8/8 "violations" on 8 dispatches that had all resolved correctly to
    opus**. Replaced by **`dispatches_with_model_override`** (+ `by_dispatch_model_override`),
    which counts explicit `model` args — a *deliberate deviation* from a declared tier, and
    the only thing the dispatch payload can actually tell us. Ground truth for what a role
    ran on is `by_agent_role.<role>.models` (transcript-derived), never the dispatch arg.
    The corresponding run-loop §3.3 instruction ("name the model explicitly at every
    dispatch") is deleted — it was the source of the bad premise.
  - **`tier` is now a REQUIRED task-packet field set at scope time (run-loop §3.2), not a
    decision recreated at commit time.** In that run 4 of 6 packets committed with
    `tier: null`, which silently no-op'd every tier-conditioned audit check — an unlabelled
    packet read as a *clean* one. Routing is now one decision that propagates:
    **`tier` → agent → model (frontmatter)**, replacing the packet template's vestigial
    `model_policy` field (a second vocabulary for the same choice that nothing consumed).
    `docs` joins `mechanical`/`integration`/`design-heavy` as a tier so doc work routes to
    the haiku `doc-writer`. The collector gains `packets_total` / `packets_missing_tier` /
    `packets_missing_impl` / `unlabelled_packet_ids`, per-packet `unlabelled:` flags, and
    `waste:` flags for `integration`- and `docs`-tier packets edited inline on opus.
    **Unlabelled flags fire only in a MIXED run**: a run where no packet carries a trailer
    is legacy/convention-off, so per-packet flags are suppressed and a run-level note
    carries the caveat instead — otherwise every pre-convention run reads as a wall of
    violations. Regression sweep: `scripts/test-metrics.sh` (155 checks).
- Relates to: [ADR 0004](0004-graduated-autonomy-and-pausable-loop.md) (run-state / pausable loop),
  [ADR 0005](0005-crash-safe-resume.md) (durable checkpoint, `[orch packet:<id>]` trailer),
  [ADR 0009](0009-single-directory-feature-branch-workflow.md) (git-derivable state, gitignored bookkeeping),
  [ADR 0012](0012-delegated-loop-driver.md) (relay-vs-inline crossover — the "20 is a **measured** crossover" claim this ADR lets us keep honest),
  [ADR 0016](0016-parallel-worktree-lanes.md) (parallel worktree lanes — the scenario this ADR most needs to see inside),
  [ADR 0017](0017-graceful-cooperative-pause.md) / [ADR 0018](0018-rate-limit-aware-cooperative-pause.md) (the hook + status-line callback families this instrumentation joins, and the runs it must survive).

## Context

The plugin has **no usage instrumentation today**. It routes models by role
(opus/sonnet/haiku), offloads determinism into scripts, and — in `--parallel` mode —
burns several file-disjoint lanes at once, each a dispatched subagent in a worktree.
Every one of those choices spends compute, and **none of it is measured.** We tune the
loop by argument and intuition (the ADR 0012 crossover, the ADR 0016 wave width) without
a number to check the intuition against. The immediate ask: **be able to collect, for a
single run — especially a wide parallel run — one self-contained artifact that holds the
whole run's metrics, to analyze offline for optimization.** Call it the **run metrics
packet**.

For an orchestration loop the useful decomposition of spend is not the video-tier
`tokens × model` but:

> **cost ≈ Σ packets × (agents per packet × context each agent re-loads × turns) × model tier**

Two of those terms are already tuned (model tier via routing; determinism via scripts).
The two we cannot currently *see* are **context re-loaded per agent** (cache efficiency —
our relay mode re-dispatches fresh chief-engineers that re-read the same files) and
**which term dominates for a given backlog**. Those are the frontier, and they are
invisible without measurement.

### The three sources of truth (and what each can and cannot tell us)

Verified against current Claude Code docs (`monitoring-usage`, `hooks`, `sessions`,
`agent-sdk/cost-tracking`). Facts are split into **documented** (stable to build on) and
**version-fragile** (must be re-verified by the implementing packet, and nothing
load-bearing may depend on them):

1. **OpenTelemetry export — the aggregate compute-budget truth. (Documented.)**
   `CLAUDE_CODE_ENABLE_TELEMETRY=1` plus standard `OTEL_*` vars (exporters: `otlp`,
   `prometheus`, `console`). Emits `claude_code.token.usage` **broken down by `model` and
   token type (`input` / `output` / `cacheRead` / `cacheCreation`)**, `claude_code.cost.usage`
   (USD), `claude_code.session.count`, `claude_code.code_edit_tool.decision`,
   `claude_code.active_time.total`, `lines_of_code.count`. Metrics carry `session.id`,
   `user.id`, `model`, `account_uuid`, and attribution labels `agent.name` / `skill.name` /
   `plugin.name`. **Subagent spend rolls up into the parent `session.id`, tagged by
   `agent.name`** — there is *no* separate subagent session id. A separate **events/logs**
   stream (`OTEL_LOGS_EXPORTER`) emits `user_prompt` / `tool_result` / `tool_decision` /
   `api_request` events, all correlatable by a `prompt.id`. Custom run tagging is possible
   via `OTEL_RESOURCE_ATTRIBUTES="key=value,..."` — **but only at Claude Code launch time**
   (the loop runs *inside* the session and cannot set its own parent's OTEL env).

2. **Session transcript JSONL — per-turn/per-agent token detail. (Partly version-fragile.)**
   Files at `~/.claude/projects/<slug>/<session-id>.jsonl`, one per session; **subagent
   turns live in *separate* files** (reported pattern `…/<session-id>/subagents/agent-<agent-id>.jsonl`).
   Assistant lines carry a `usage` object (input/output/cache-creation/cache-read) with
   `model` and `timestamp` — **but the docs declare the on-disk format internal and subject
   to change between versions.** So the transcript is a *best-effort, version-guarded*
   source for the fine detail OTEL rolls up, never a contract.

3. **Hooks — the plugin-owned event spine. (Documented behavior; one fragile field.)**
   A `PostToolUse` hook receives `session_id`, `tool_name`, `tool_input`, `tool_output`,
   and (confirmed by the ADR 0017 probe) **`agent_id` / `agent_type` when it fires inside a
   dispatched subagent** — i.e. we can attribute every tool call to the lane/role that
   issued it. **No hook payload carries per-model token totals or rate-limit data** (ADR
   0018 established the status line is the sole rate-limit sensor; the transcript/OTEL are
   the sole token sources). A per-tool `token_counts` field *may* be present in the
   payload, but that is **version-fragile and MUST NOT be depended on** — treat it as a
   bonus if present, and get token/cost truth from OTEL (source #1).

The design consequence writes itself: **OTEL is the aggregate cost/token truth; the
hook is the plugin-owned, always-available event+timing spine; run-state is the packet
spine; a deterministic collector joins the three into the run metrics packet.** No new
daemon, no dependence on any fragile field.

### The correlation keys (how "one run" is reconstructed)

A run is not one session — it can span sessions across pause/resume (ADR 0017), and its
parallel lanes are subagents that **share the driver's `session_id`** and differ by
`agent_id` / `agent_type`. So the join graph is:

- **`session_id`(s)** — the run. Recorded in run-state as the list of sessions that
  participated (survives pause/resume). The filter that isolates a run in OTEL and the
  transcripts.
- **`agent_id` / `agent_type`** — the **lane / role** within the run (parallel lanes and
  the chief-engineer/implementer/reviewer split both fall out of this).
- **`prompt_id`** — a single dispatch, for end-to-end event correlation.
- **packet id** — from run-state per-packet lifecycle timing (this ADR adds it) and the
  existing `[orch packet:<id>]` commit trailer.
- **The one join that has no shared key — `agent_id` ↔ packet** — is bridged
  **temporally**: run-state brackets each packet with start/end timestamps, and the lane's
  tool-event timestamps (and its commit's trailer + commit time) fall inside that bracket.
  Deterministic post-hoc, no new runtime coupling (see Open question #2).

## Decision

**Ship a two-tier metrics layer whose deliverable is a single self-contained
`.agents/metrics/<run-id>/run-metrics.json` per run. Tier 0 is OTEL-as-baseline (config
only). Tier 1 is a plugin-owned, zero-token event+timing spine (a `PostToolUse` logger
hook + per-packet lifecycle stamps in `runstate.sh`) joined by a deterministic
`scripts/metrics.sh` core into the run metrics packet. Tier 2 (input compression, e.g.
RTK) is explicitly DEFERRED, to be evaluated against Tier 1's before/after numbers.**

1. **Tier 0 — OTEL as an OPTIONAL, DEFERRED richer source. Not required for Tier 1.**
   *(Revised 2026-07-21: demoted from "accepted baseline" to optional.)* Turning on
   `CLAUDE_CODE_ENABLE_TELEMETRY=1` + an exporter (Prometheus-pull is Docker-free; OTLP for
   a collector) yields `claude_code.token.usage` (by model + token type) and
   `claude_code.cost.usage` (with `agent.name` attribution) — the docs-stable ground truth
   for compute-budget-used. We **document and support** it, but Tier 1 does **not** depend
   on it, and we do **not** stand it up first. The reason: OTEL requires external infra and
   a collect-time read-back inside `metrics.sh` (Open question 3), whereas Tier 1's default
   token source (transcript-parse, Decision 2) lives entirely inside the script and keeps
   the packet a self-contained artifact. **Transcript-parse is the chosen default token
   source; OTEL is a later optional upgrade** to reach for if the version-fragile parse ever
   breaks or if repeated-run dashboards are wanted. When a collector *is* configured, the
   run can be tagged at launch with `OTEL_RESOURCE_ATTRIBUTES="orch.run_id=<id>"` and
   `metrics.sh` prefers OTEL over the transcript; when it is not, nothing degrades — the
   packet assembles from transcript-parse (or, if that too is unavailable/blocked,
   structural-only), and records which source it used.

2. **Tier 1 — the plugin-owned spine + the run metrics packet. This is the build.**
   - **A `PostToolUse` event-logger hook** (`hooks/metrics-log.sh`, wired in `hooks.json`
     alongside the existing guard + pause-check) appends one JSONL line per tool call to
     `.agents/metrics/<run-id>/events.jsonl` — recording only **definitely-present** fields
     (`session_id`, `agent_id`, `agent_type`, `tool_name`, a monotonic timestamp, and
     tool-outcome facts such as a Bash exit code / edited path). It is **advisory-safe like
     the pause hook**: it never returns a `permissionDecision`, cannot weaken the guard, and
     fails silently (a metrics hook must never break a run). If a `token_counts` field turns
     out to be present, it is logged as a bonus, never relied on.
   - **Per-packet boundaries derived from the `[orch packet:<id>]` commit trailers**
     (*revised at implementation — see the header note; supersedes the original "additive
     fields in `runstate.sh`" plan*). `metrics.sh collect` scans `git log` for trailers on
     their own line, takes each packet's commit time as its green boundary, and forms
     contiguous per-packet windows to attribute events. This is **zero-migration** and leaves
     run-state's single-writer `packets[]` **untouched** — the trailer already ties every
     green commit to its packet (ADR 0005). Trade-off: failed/uncommitted packets and a
     per-packet token split are out of v1 scope (noted in the packet). A richer append-only
     packet-timeline log (for attempts/review-passes/wave beyond the graph) remains a clean
     future add that still avoids run-state contention.
   - **The trailer scan is bounded to the run window, not `git log --all`** (*revised
     2026-07-21 after the first real production capture*). The original scan was unbounded across
     every branch and all history, which folded **every packet ever committed** into one
     "run" — the first production capture reported **156 packets spanning 17 days** against a single
     3-hour session's tokens, with inverted per-packet windows (a packet `end` preceding its
     `start`). `collect` now defines the run window from its **selected session events**
     (default: the **newest** session log by mtime; `--all-sessions`/`--session`/`--since`/
     `--until` override) and keeps only trailers whose commit time is **≥ the window's lower
     bound**. `--all` is retained for *ref coverage* (unmerged lane branches must still be
     seen) but the time filter supplies the *run scope*; the upper bound stays open unless
     `--until` is given, because a run's last packet commits just **after** its last tool
     event. With no events it falls back to an `<integration_branch>..HEAD` range (mirroring
     `runstate.sh reconstruct`). Post-fix, that session correctly reports **0 committed
     packets** (it was the paused/analysis session) instead of 156 phantoms. The `adhoc`
     run-id fallback is likewise disambiguated to `adhoc-<session8>` so two different sessions
     no longer overwrite one `run-metrics.json`. Regression coverage in `test-metrics.sh`
     (out-of-window exclusion, newest-session default, adhoc path).
   - **A deterministic `scripts/metrics.sh` core** — the judgment-free join, in the plugin's
     established "deterministic core in a script, unit-testable without a live agent" style
     (`packet-graph.sh`, `runstate.sh`). Subcommands roughly: `record` (helpers the
     driver/hook call), and **`collect <run-state> → run-metrics.json`**, which joins the
     packet spine (run-state timing) ⟕ the event spine (`events.jsonl`, by `agent_id`/time)
     ⟕ token/cost (**transcript-parse by default**; OTEL only if a collector is configured;
     structural-only if neither is available) into the packet.
   - **The run metrics packet** (`.agents/metrics/<run-id>/run-metrics.json`) is the headline
     deliverable — one file, self-contained, gitignored like run-state (ADR 0009), and
     **designed to be handed to Claude for optimization analysis** (the end goal — see
     Decision 4). That intent constrains its shape: it is a **compact, self-describing
     rollup**, not the raw `events.jsonl` (which would blow an analysis context and carries
     no rollup meaning). Every figure is labeled and unit-carrying, the token `source`
     (`otel`/`transcript`/`none`) is stamped so a partial run is never misread as complete,
     and it stays small enough to drop whole into a prompt. It carries: run identity
     (id, session_ids, start/end, autonomy level,
     sequential-vs-parallel, relay-vs-inline); **per-packet** rows (wall-time, model, tokens
     by type when available, attempts, review passes, lane, wave, outcome); **per-wave**
     rollups (achieved concurrency vs. the `packet-graph.sh` theoretical max, lane-idle time
     waiting on the serialize-merge, real merge-conflict/escalation rate); **per-agent-role**
     rollups (spend by chief-engineer/implementer/reviewer/etc.); and run-level signals —
     **cache-hit ratio** (cacheRead vs cacheCreation, the biggest suspected hidden cost),
     **guard ASK-tier prompt frequency** (a friction metric), and the inputs to
     **empirically re-checking the ADR 0012 relay-vs-inline crossover** instead of trusting
     the one-time "20."

3. **Tier 2 — DEFERRED, gated on Tier 1 results.** Input compression (RTK-style
   pre-compression of verbose Bash/test/diff output before it enters agent context) is a
   plausible next lever *because* the loop is Bash-heavy, but it is **not adopted now.** It
   sits in the same `PreToolUse` pipeline as `guard.sh` (hook-ordering risk) and is
   third-party code in the tool path. It is revisited **only** once Tier 1 can measure its
   before/after in tokens — otherwise we would compress blind. This ADR records the deferral;
   a future ADR decides adoption.

4. **On-demand report + Claude-driven analysis is a thin skill; collection is automatic.**
   Collection needs no human in the loop (the hook logs continuously; `run-loop`/`resume`/`pause`
   call `metrics.sh collect` at run end / checkpoint, and a crash still leaves a
   reconstructable packet from run-state + `events.jsonl`). A `/gaffer:metrics
   <collect|show|status|analyze>` skill — mirroring the `set-autonomy` "show or set" idiom —
   lets a human assemble/print the latest packet or hand it to Claude:
   - **`analyze`** is the end goal made concrete. It reads `run-metrics.json`, drops the
     whole compact rollup into context, and asks an agent to answer **"where is this run's
     compute going, and what specifically would reduce it?"** — surfacing the expensive
     packets/waves/roles, the cache-creation-vs-read ratio, lane-idle and merge-conflict
     cost, and the ADR 0012 crossover reality, then proposing ranked, concrete changes
     (e.g. "wave 3 lanes re-load ~40k each; widen file-disjointness / switch to inline
     below N"). This is a **pure judgment step over a deterministic artifact** — exactly the
     "scripts for the repeatable, AI for judgment" split: `metrics.sh` produces the numbers;
     the analysis prompt reasons about them. Because the packet is self-contained, `analyze`
     also works offline on any past run's packet, and the same JSON can be handed to an
     external Claude session (or a future scheduled routine) with no plugin runtime attached.
     The **architect** is the natural analyst (it already owns optimization/architecture
     judgment), though the skill may keep the reasoning inline for a single small packet.
   The deterministic join stays in the script; what the numbers *mean* and what to change
   stays in the skill/agent prompt.

5. **Config in the established style; default off-ish and cheap.** A new optional
   `metrics:` block in `.agents/project-overrides.yaml`, resolved env-first like every other
   knob (`ORCH_METRICS`):
   ```yaml
   metrics:
     enabled: true          # Tier-1 event+timing spine (zero-token). Default true; cheap.
     otel: false            # Tier-0 hint only — the plugin cannot set launch-time OTEL env
                            # for you; this records intent + drives the /metrics status report.
     retain_runs: 20        # prune .agents/metrics/<run-id>/ beyond the N most recent.
   ```
   Resolution order matches the others: `ORCH_METRICS=off` env → `metrics.enabled: false` →
   default on. The Tier-1 spine is zero-token and safe-by-default; Tier-0 OTEL stays opt-in
   because it needs external infra the plugin cannot provision.

6. **Stays domain-agnostic (CLAUDE.md ground rule).** Metrics are generic
   orchestration/usage signals (tokens, timing, waves, cache, guard prompts). **No
   domain-specific dimensions** (money, PHI, …) enter `metrics.sh` or the packet schema — a
   consumer repo that wants domain tags adds them the same way it adds guard rules, not by
   editing the plugin.

7. **A behavior worth having is a behavior worth a test.** `scripts/test-metrics.sh` joins
   the existing six sweeps: feed synthetic run-state + `events.jsonl` fixtures and assert
   the collector emits the expected per-packet/per-wave/per-agent rollups, that a missing
   OTEL/transcript source degrades gracefully (packet still assembles from timing+events),
   and that the hook never emits a `permissionDecision` and never fails a run.

## Implementation sketch

New components, all at repo root per the structure rules (nothing under `.claude-plugin/`,
all kebab-case, hooks referenced via `${CLAUDE_PLUGIN_ROOT}`, scripts `chmod +x`):

- `hooks/metrics-log.sh` — `PostToolUse` logger; append-only JSONL; advisory-safe
  (no `permissionDecision`), fail-silent. Added to the existing `PostToolUse` matcher in
  `hooks/hooks.json` (a new event array — today only `PreToolUse` + `SessionStart` exist).
- `scripts/metrics.sh` — deterministic core (`collect` / `record` / helpers). Resolves the
  main-checkout `.agents/` via `git rev-parse --git-common-dir` (the ADR 0017/0018 pattern),
  so a lane worktree writes to the canonical run dir. Handles OTEL-present and OTEL-absent.
- `scripts/test-metrics.sh` — the regression sweep (added to CI's push run and to CLAUDE.md's
  test list).
- `runstate.sh` — additive per-packet timing fields + the session-id list on the run header;
  driver stays single writer; schema note bumped (superset of 3).
- `.agents/metrics/<run-id>/` — `events.jsonl` (hook) + `run-metrics.json` (assembled).
  **Gitignore the whole `.agents/metrics/` directory** — both the raw log and the rollup —
  in **two** places, matching the existing `.agents/run-state.yaml` / `.agents/pause*`
  entries and citing ADR 0009: the plugin's own `.gitignore` (dogfooding) and
  `templates/spec-driven-base/.gitignore` (the consumer seed `/gaffer:new-project`
  lays down). This is **required, not tidiness**: the loop's `git add -A` (full-autonomy)
  would otherwise sweep metrics into packet commits, `git stash -u` discard would destroy a
  run's data mid-loop, and stray files would dirty the tree `runstate.sh reconcile` inspects.
  The rollup is a portable single file, so "retain a run's metrics" = copy that JSON out to
  an archive, not commit the live directory.
- `.agents/project-overrides.yaml` — the `metrics:` block (parsed by `metrics.sh` directly,
  copying the `autonomy_ceiling`/`integration_branch` YAML-read pattern already in the repo).
- `skills/metrics/SKILL.md` — optional `/gaffer:metrics <collect|show|status>`.
- Docs: a README "Measuring runs" section (how to wire Tier-0 OTEL at launch; what the
  packet contains; that Tier-2/RTK is deferred).

The loop skills (`run-loop`, `resume`, `pause`) gain one line each: call `metrics.sh collect`
at run end / at the pause checkpoint, so a packet exists without a human asking.

## Open implementation questions

Left to the implementing packet; each is real and named:

1. **Token/cost binding is the fragile seam — and transcript-parse is now the DEFAULT, so
   harden it.** Per the 2026-07-21 revision the default token source is **transcript parse**
   (source #2), with OTEL (source #1) an optional override when a collector is configured.
   Transcript parse is documented as **version-fragile** (internal on-disk format,
   subagent turns in separate `agent-<agent-id>.jsonl` files), so the implementing packet
   must: pin/probe the expected shape, **fail soft to structural-only** (never crash the
   collector) when the format is unrecognized, and **stamp the `source`** (`otel` /
   `transcript` / `none`) on every packet so a partial run is never misread as complete —
   which matters doubly now that Claude *analyzes* the packet (Decision 4): the analysis must
   be told when token data is absent or best-effort, not silently reason over gaps. Do
   **not** build on the per-tool `token_counts` hook field — verify whether it exists in the
   installed version and treat it as bonus-only.
2. **The `agent_id` ↔ packet join is temporal — decide how tight it must be.** Primary bridge:
   run-state's per-packet `started_at`/`ended_at` bracket the lane's event timestamps, and
   the `[orch packet:<id>]` commit's time + trailer confirm it. Decide whether that temporal
   join is sufficient or whether the driver should additionally write an explicit
   `agent_id → packet` marker at dispatch (tighter, but adds runtime coupling the temporal
   join avoids). Recommend temporal-first, marker only if fixtures show ambiguity.
3. **OTEL query mechanism when a collector *is* present.** `metrics.sh collect` needs to pull
   the run's aggregates back out — decide between a Prometheus query, an OTLP/file exporter
   the script reads, or simply pairing with `console`/file export and parsing. Keep it
   optional and pluggable; the packet must assemble with zero OTEL configured.
4. **Run-id definition across pause/resume.** A run spans sessions (ADR 0017). Decide the
   run-id (first session id? a minted id persisted in run-state?) and how `resume` appends
   the new `session_id` so the packet covers the whole run, not just the final session.
5. **`hooks.json` gains a `PostToolUse` array for the first time** — confirm ordering/interaction
   with the existing `PreToolUse` guard + pause-check is clean, and that a fail-silent metrics
   hook cannot perturb tool execution.

## v3 revision (2026-08-02) — corrections found by using the packets

The first cross-repo `analyze` (21 sessions across two consumer repos, ~2.6B tokens of
traffic) exposed three defects in the collector itself. All three are fixed, with
regression cases in `scripts/test-metrics.sh`.

**1. The trailer-scan upper bound was open, so retrospective collection invented packets.**
v2 bounded the `[orch packet:<id>]` scan below (`win_start`) but applied the upper bound
only when `--until` was passed, reasoning that "collection happens at end-of-run, so
nothing legit is after". That assumption holds for live collection and fails for the
retrospective collection this very skill invites. Every run absorbed every packet
committed after it: an 11-minute session reported **45 packets**, a 19-tool-call session
reported 22, and **12 of 19 captured runs were inflated 2x–45x**, with each packet list
running to the repo's newest commit days later. The bound is now **always** enforced, at
`last-event + ORCH_METRICS_TRAILER_GRACE` (default 3600s); `--until` still wins verbatim.
The grace preserves the real case the open end was protecting — a run's last packet
commits just *after* its last tool event, since the commit itself emits no tool event.

This mattered beyond tidiness: `totals.packets` is the input to the ADR 0012 relay-vs-inline
crossover. Corrected, the largest run in either repo is **9 real packets**, so the 20-packet
threshold has never once been reached in production and the relay path has never fired.

**2. `by_skill` was structurally dark, not merely empty.** The hook stamped `skill` only
when the tool call *was* the `Skill` tool, and the assembler carried that forward. Both
halves were correct and fed almost nothing: the orchestration skills are invoked as **slash
commands**, which the harness expands into a prompt without ever calling the `Skill` tool.
Measured: **3 `Skill` events in ~6,000 tool calls**, so 18 of 22 runs reported
`by_skill: {"none": everything}` — a dead dimension that read as an empty one. New
`hooks/metrics-skill.sh` (UserPromptSubmit) records a leading `/<name>` or `/<plugin>:<name>`
to a per-session state file; `metrics-log.sh` stamps it onto every subsequent event.
Attribution is **sticky** — set on invocation, never cleared — so `by_skill` is an *upper
bound* on a skill's spend. That is the deliberate failure direction: clearing on every plain
prompt would silently drop a whole `/run-loop` the moment a human nudged it mid-run. The
packet's `notes[]` states this. Being a UserPromptSubmit hook, it prints **nothing** —
that stdout is injected into the model's context, which would be both a token cost and a
prompt-injection surface in a collector that must not influence what it measures.

**3. `by_tool` did not exist.** Events always carried `.tool`, but the rollup exposed only
`by_command_class`, which classifies Bash and nothing else — so the packet had no view of
tool *selection*. That blind spot hid a live finding: across ~6,000 tool calls in two repos
there were **zero `Grep`/`Glob` calls and 1,568 shell `grep`s**, plus 258 `find` and 496
`sed`. In `by_command_class` this looks like healthy search volume; in `by_tool` it is
obviously context waste, since shell search dumps unbounded output into context while the
`Grep` tool bounds it. Fixed by rolling up `by_tool` at both run and packet level. The
behavioral half of that fix lives where it must (CLAUDE.md's "does not propagate" rule) —
in the **agent prompts**, all seven of which now carry a tool-selection section.

Two gaps this revision does **not** close, recorded so they are not mistaken for clean:
`outcome` is still hardcoded `"green"` (a packet exists only if it has a commit trailer, so
failed and rolled-back work is invisible — 42 of 42 green is survivorship, not quality), and
the event log deliberately carries no file paths, so main-vs-implementer edit *overlap*
within a packet — correction versus division of labor — cannot be distinguished. Both are
prerequisites for measuring rework rate by editor role.

## v3.1 revision (2026-08-07) — the collector was blind on Windows

`collect` stamped `token_source: none` on **every** run on Windows — empty `by_role`,
empty `by_model`, `-` in every per-packet `out-tok` — while transcripts sat on disk,
correctly named, full of valid `usage` blocks. Across 7 sessions on the affected machine
all 7 were blank; one of them alone held 211 usage turns and 28.4M tokens. Everything
structural (wall/active/idle, `by_tool`, `by_skill`, `by_command_class`, packet
boundaries, the routing audit) was correct and unaffected, which is exactly what made the
packet look healthy. `/gaffer:metrics analyze` — the stated end goal of this ADR — could
only ever produce structural advice on that platform.

**1. Root cause: the native Windows jq build writes CRLF, and one line list is read with
`read`.** That build opens stdout in text mode, so *every* jq line ends `\r\n`, on pipes
as well as consoles (`jq -rn '"abc"' | od -c` ⇒ `a b c \r \n`), and `read` strips only
the `\n`. The distinct-session-id list is the one
jq-written line list consumed by a `while read` loop, and its values build **globs**:
`$sid` came out 37 characters instead of 36, `…/<uuid>\r.jsonl` matched nothing,
`[ -e "$mf" ] || continue` skipped every file, and `turns.ndjson` stayed empty — so
`token_source` never moved off its `none` initialiser. The failure routed through the
legitimate fail-soft path, which is why it was silent.

Fixed at the source (`… | tr -d '\r' > sids.txt`, a no-op on POSIX where jq emits `\n`)
and again at the consumer. The rule is now stated in the script header: **any `jq -r …
> file` consumed by a `read` loop must be `tr -d '\r'`-piped.** The same one-line defect
existed in `test-metrics.sh` itself (a jq list joined with `paste`), fixed the same way.

**1b. The bug had one site by accident, not by design — and the regression test caught
it.** The obvious reading, the one the originating bug report reached and this ADR first
recorded, is that the collector's seven `$(jq -r …)` scalar captures are safe because
command substitution strips the trailing `\r\n`. **That is an MSYS quirk, not bash
behavior.** Verified directly: capturing `printf 'implementer\r\n'` yields **11 bytes
under MSYS bash 5.2.37 and 12 bytes under Linux bash 5.2.21** — the CR survives. Those
captures were correct on Windows purely by accident of which bash Git Bash ships, and a
CRLF jq under any other shell would corrupt all seven.

CI caught this within minutes, because the new regression test asserts the CRLF-shimmed
packet is **byte-identical** to a clean run — strictly harsher than the production
failure, and on Linux it exercises precisely the shell/jq combination Windows masks. It
failed with `by_agent_role` keys of `"implementer\r"`, `\r`-suffixed window and packet
timestamps, every per-packet `tokens` nulled (`turns_have_ts` no longer equalled
`"true"`), and the turn counts tripping their numeric guard and resetting to 0. All raw
reads now go through `jqr()` (`jq -r "$@" | tr -d '\r'`; `pipefail` preserves jq's exit
status so callers' `|| echo <default>` fallbacks still fire), so correctness no longer
depends on the host shell.

Two things are worth keeping from this. The byte-identity assertion was written as a
belt-and-braces "strongest form" check and expected to be redundant; it was the only
thing separating *fixed* from *fixed on this machine*. And the shim deliberately uses
`awk`, not `sed 's/$/\r/'` — BSD/macOS sed does not interpret `\r` in the replacement and
would insert a literal `r`, making the test silently vacuous on the platform least able
to verify it. When the check did fail it reported only `expected [same] got [differs]`,
naming nothing; it now prints the differing fields.

**2. `token_source: none` was undiagnosable, and its note actively lied.** A single
`none` covered four unrelated failures, and the emitted note asserted "no transcript
found" in all of them — false while 29 transcripts sat on disk, and the direct cause of a
half-hour bisect. Every packet now carries `token_diagnostics` (counts only, no paths, so
it stays safe to hand to Claude): `transcript_dir`, `transcript_files_present`,
`transcript_files_matched`, `usage_turns`, `usage_turns_in_window`. Those separate
*nothing on disk* from *lookup failure* (files present, none matched — the exact CRLF
signature) from *format drift* (matched, none parsed — the version-fragility this ADR
already anticipated) from *window miss* (parsed, none in range). The note names which one,
and `show` prints the line whenever `token_source != transcript`. The enum itself is
unchanged, so consumers comparing against `none`/`transcript`/`transcript-degraded` are
unaffected.

Still open from the report and **not** addressed here: per-session collection double-counts
packets when two sessions overlap in wall-clock, since `--session` bounds the trailer scan
to that session's event window plus the 1h grace. Tool counts and timings stay correct;
only `packets[]` rows go non-disjoint. This is inherent to deriving boundaries from commit
trailers rather than run-state, and closing it means either narrowing the grace or
intersecting overlapping windows — a semantics decision, not a bug fix.

## v3.2 revision (2026-08-07) — the overlap left open by v3.1, plus effort

Two cross-repo analyses of 42 real sessions closed the overlap question above and found one
dimension the packet could not see at all. All three changes are **retroactive** — they
re-read stored events, git history and transcripts, so existing runs can simply be
re-collected.

**(a) Trailer times are AUTHOR dates, not committer dates.** Committer date is rewritten by
rebase, cherry-pick, amend and squash-merge, so a packet's recorded time drifts to whenever
the branch was last replayed. `%cd` → `%ad`; traversal moves to `--author-date-order` for
coherence only (the per-packet reduction re-sorts on the emitted column, so correctness never
depended on traversal).

Honest scope: this is **defensive, not a fix for an observed production failure**. The
analysis that motivated it claimed six packets had been absorbed into a run that did not
author them; checked against git, those commits have *identical* author and committer dates
and were genuinely in-window — the claim does not hold and is withdrawn. Divergence is real
but rare: **5 of 899 commits in one repo (1 of 395 carrying a trailer), 12 of 329 in the
other (8 of 107 with a trailer)**. So the change matters mainly for repos that rebase before
merging, where up to ~7.5% of trailer commits carry a rewritten date. What actually drives
that first repo's unattributed spend is much simpler and is *not* a date bug: only **395 of
899 commits carry an `[orch packet:]` trailer at all**.

**(b) The grace is capped at the next session's first event.** This is the overlap question
v3.1 left open, and it resolves as a bug fix rather than the feared semantics decision. A
flat grace is only safe when nothing else is running; with overlapping or back-to-back
sessions it reaches straight into the next run and claims its commits. The cap is the
earliest event belonging to any *other* session after `win_end`, which handles both shapes:
a back-to-back session cuts the grace short, and a concurrent one already has events just
past `win_end`, so the bound collapses to ~`win_end`. When nothing else ran, the full grace
still applies — which is the case it exists for. `--until` still wins verbatim.

Validated against ground truth derived independently by hand: one consumer repo's analysis
had removed **7 phantom rows across 5 sessions** by re-collecting each with an explicit
`--until`. The cap reproduces that list **exactly and automatically** — and correctly keeps
`wbr-t14`, the one packet that legitimately spans two sessions (checkpointed in one, verified
and merged in the next), in **both**. The fix is not "drop everything near a boundary".

**(c) `by_effort` and `context_invalidations`.** Reasoning effort is a per-turn request
parameter the user can change mid-session, recorded in the transcript as a top-level `effort`
field. Nothing in the packet read it, so a run spanning two effort levels was
indistinguishable from one that did not. Both are now emitted from the same transcript
records already parsed for tokens.

The second counter is the more useful one: changing `effort` **or** the model mid-context
invalidates the cached prefix, so the whole context is re-written to cache. Three flips
measured by hand cost **372,588 / 380,005 / 115,509** cache-creation against session medians
of 1,380 / 856 / ~1,700 — 270x, 444x and 68x. It fires in **both** directions
(`high→xhigh` *and* `xhigh→high`), which is what identifies it as invalidation rather than
"higher effort costs more"; the size tracks how deep into the context the flip happens, not
which way it went.

Implementing it answered a question the manual analysis had left open: **effort propagates to
dispatched subagents.** A single flip in one session registered **9 invalidations across 6
agent contexts** (main, chief-engineer ×3, implementer ×3, reviewer, ux-designer) totalling
**1,531,777** cache-creation — roughly one full relayed-coordinator dispatch for one keystroke,
and ~4x what measuring the main context alone suggested.

The scan is per `(role, agent_id)` — one agent context — not per role: two dispatches of the
same role are separate contexts, so an implementer that ran opus once and sonnet once is
normal tier routing, not a mid-context switch. Turns without a timestamp cannot be ordered
and are excluded, so this degrades to 0 rather than guessing on older transcripts. An empty
`by_effort` means the transcripts predate the field (unmeasured), never that effort was
constant.

Per-turn effort is **not** available to the hooks — no hook payload carries it — so the
transcript remains the sole sensor, and these two fields inherit `token_source`'s
version-fragility exactly like the token figures do.

Regression cases live in `scripts/test-metrics.sh` under the three `v3.2` headings, including
the non-regressions that matter: legacy transcripts leave `by_effort` absent rather than
zeroed, and separate dispatches of one role never register as an invalidation.

## v3.3 revision (2026-08-07) — every token number was inflated ~2.6x, and v3's cost claim was never measured

Two corrections. The first invalidates every absolute token figure this collector has ever
emitted; the second retracts a claim this ADR itself made and propagated into seven agent
prompts. Both were found the same way — by trying to *calibrate* a recommendation rather
than act on it.

### 1. Deduplicate transcript turns by `message.id`

A transcript records the **same assistant message more than once**. Observed: message id
`msg_011CdnkJ7EP1uDWn2Wbn` appearing three times, at +2ms and +26s, each carrying the full
`usage` block. Summing rows therefore counts the same tokens repeatedly. `metrics.sh` had no
dedup; **ADR 0012's own measurement deduplicated by message id** ("totals come from each
agent's transcript, deduplicated by message id"), so the technique was known in this repo and
simply never reached the collector.

Measured inflation across four real sessions:

| Session | cacheCreation | output | CC:out raw | CC:out deduped |
|---|---|---|---|---|
| `89cecaec` | 3.16x | 4.38x | 5.6 | **7.8** |
| `58215cfa` | 2.32x | 3.28x | 6.4 | **9.0** |
| `0195876b` | 2.60x | 3.67x | 11.8 | **16.6** |
| `970115da` | 2.64x | 4.33x | 12.6 | **20.6** |
| `af043d81` | 3.03x | 4.09x | 19.4 | **26.2** |
| `e383a0d8` | 2.76x | 6.25x | 14.9 | **33.8** |

**The two rates differ, and differ per session, so this does NOT cancel in a ratio.** That is
what makes it more than a scaling error: CC:out — the metric every optimization decision here
was ranked by — was wrong by 1.4x-2.3x, non-uniformly. Directionally the conclusions survived
(the ordering is unchanged and the best-vs-worst gap *widens* from 2.3x to 3.8x), but that was
luck, not method.

The fix keeps the **earliest** row per id. Duplicates carry identical usage so the choice is
cosmetic for totals, but it must be deterministic for the `context_invalidations` scan, which
reads per-turn `ts`. Rows with **no** `message.id` are kept verbatim rather than keyed on
`.uuid`: `.uuid` is per-ROW, not per-message, so keying on it would silently dedupe nothing
while appearing to work. Under-deduping is the safe direction. `token_diagnostics` gains
`duplicate_turns_dropped` so the rate is visible — a sudden move toward 0 means either the
transcript stopped repeating messages **or** stopped carrying `message.id`, and the second
would silently re-inflate the packet ~2.6x while still stamping `token_source: transcript`.

### 2. RETRACTED: "search tool selection is a measured cost"

v3 added a "structured tools, not the shell" section to all seven `agents/*.md`, asserting it
was "a measured cost, not a style preference," and telling the three read-only agents that
shell search was "most of your context budget."

**No cost was ever measured.** The v3 finding was **0** `Grep`/`Glob` calls against 1,568
shell `grep`s — a measurement of tool *selection*. It was reported as a measurement of tool
*cost*, and the inference went unchallenged because the number was striking.

Measured properly — joining `tool_use`→`tool_result` in the transcripts and totalling result
bytes across 30 sessions:

| | calls | output | mean |
|---|---|---|---|
| shell search (`grep`/`find`/`rg`) | 643 | **749,069 ch ≈ 187k tok** | 1,164 ch |
| `Grep`/`Glob` | 10 | 1,680 ch | — |
| `Read` | 1,192 | **5,668,991 ch ≈ 1,417k tok** | 4,755 ch |

187k tokens against 279M lifetime cacheCreation is **0.07%**. The greps are well-targeted, not
unbounded dumps. Eliminating shell search entirely saves a rounding error, and the
planned guard-hook enforcement was dropped on this evidence.

The same measurement points somewhere real: **`Read` is 7.6x all shell search combined**, and
the **top 10% of `Read` calls carry 50% of the volume** (top 25% carry 73%; median read is
only 2,189 chars). A few very large document reads dominate — which is the coordinator
read-list problem, and the opposite of a search-tool problem.

What survives is the **write** half, on its own merits and independent of tokens: `sed -i` and
`cat >` bypass diff review and the guard's path tiers, which is why `guard.sh` pattern-matches
them as a write surface. The agent blocks now say only that, and are shorter for it — which
matters directly, since they are re-read on every dispatch.

**The general lesson, recorded because this ADR made the mistake twice in two revisions
(v3 here, and the phantom-packet framing in v3.2): a frequency count is not a cost
measurement.** Do not add a cost claim to an agent prompt without measuring cost.

### 3. `show` reported unmeasured counters as clean zeros

This started from a wrong premise too, and the correction is the useful part. The plan was
"surface the routing audit, because nothing prints it" — after a real deviation (16 of 83
dispatches overriding a declared model, 13 onto opus) went unnoticed for weeks. **`show`
was already printing it.** The counters were never dark.

Two things were actually wrong:

- **`null` rendered as `0`.** The collector deliberately emits `dispatches_with_model_override`
  and `failed_tool_calls` as `null` for runs predating the instrumentation, with an explicit
  comment that reporting them as `0` would be "a lie" — and then `show` applied `// 0` and
  told exactly that lie. A legacy run read as "83 dispatches, 0 overrides, 0 failures": fully
  audited and perfectly clean. Both now print `unmeasured — pre-instrumentation run`.
- **Placement.** The audit sat *below* the per-packet table. At 14 packets it is off the
  bottom of a screen, which is how a real signal goes unread without anything being hidden.
  It now prints above the table.

Worth stating plainly, because it recurs: the failure was **not** missing instrumentation.
It was a true value rendered indistinguishably from a false one, and a real signal placed
where nobody looks. Adding a new counter would have fixed neither.

## Consequences

- **First real visibility into the loop, at zero token cost for the always-on part.** The
  Tier-1 spine is deterministic bash + append-only JSONL — it spends no model tokens, matching
  the plugin's "scripts for the repeatable, AI for judgment" philosophy. OTEL (Tier-0) is
  opt-in infra for the richer cost/cache breakdown.
- **One analyzable artifact per run — and Claude is a first-class consumer of it.** The
  stated end goal (hand a run's metrics to Claude and get ranked, concrete optimization
  advice) is met by `/gaffer:metrics analyze` over the self-contained
  `.agents/metrics/<run-id>/run-metrics.json` (reconstructable even after a crash from
  run-state + `events.jsonl`). **Foregoing Tier 0 does not weaken this** — if anything it
  helps: the packet stays a single portable file the analysis reads whole, rather than data
  split into a Prometheus/Grafana store an analyst would have to export first. The one caveat
  is honesty, not capability: without OTEL the token figures come from the version-fragile
  transcript parse, and the packet's stamped `source` tells the analysis when to trust them.
- **Lets us keep ADR 0012 honest.** The "20 is a **measured** crossover" claim becomes
  re-measurable from real runs instead of frozen; likewise ADR 0016 wave width and lane-idle
  cost become observable.
- **Cache efficiency — the biggest suspected hidden cost — finally has a number** (cacheRead
  vs cacheCreation), which is what will tell us whether relay's fresh-chief-engineer
  re-dispatch is as expensive as feared.
- **No new daemon, no new pause path, no guard weakening.** The metrics hook is advisory-safe
  and fail-silent by construction; correctness of the loop never depends on it, exactly like
  the ADR 0017 advisory hook.
- **Domain-agnostic and reversible.** Generic signals only; `ORCH_METRICS=off` (or
  `metrics.enabled: false`) turns the spine off per-repo; no collector means graceful
  degradation, not failure.
- **Tier 2 stays a decision, not a default.** RTK/input-compression is deferred with an
  explicit gate (Tier-1 before/after numbers) and its own future ADR — recorded here so the
  deferral is intentional, not forgotten.

## Alternatives considered

- **A standalone monitoring daemon polling usage.** Rejected, same reasoning as ADR 0018:
  the user does not want a second process, and there is little to poll — token truth lives in
  OTEL/transcripts, not a pollable file. The hook + run-state spine needs no daemon.
- **Depend on the per-tool `token_counts` hook field for attribution.** Rejected as
  load-bearing: version-fragile and undocumented as a contract. Used only as a bonus if
  present; OTEL is the real token source.
- **Parse only the transcript JSONL (skip OTEL entirely).** Rejected as the *primary* path:
  the on-disk format is explicitly internal/unstable, and subagent turns are in separate
  files — fine as a best-effort fallback, wrong as the contract. OTEL is the documented,
  stable aggregate.
- **Build Tier 2 (RTK) now.** Rejected/deferred: compressing before we can measure is
  optimizing blind, and RTK is third-party code sharing the guard's `PreToolUse` pipeline.
  Gate it on Tier-1 numbers.
- **Emit metrics as a domain-extensible schema from day one.** Rejected: violates the
  domain-agnostic ground rule and over-builds. Consumers extend via their own config, as with
  guard rules.
