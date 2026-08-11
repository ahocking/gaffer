# CLAUDE.md — for developing the `gaffer` plugin itself

> ⚠️ **This file does not propagate.** A plugin's root `CLAUDE.md` is **not**
> loaded as context in consumer repos. Nothing you write here
> reaches the agents when the plugin is installed elsewhere. Reusable operating
> instructions must live in the **agent** (`agents/*.md`) and **skill**
> (`skills/*/SKILL.md`) prompts instead. Treat this file as notes for a human
> (or Claude) working *inside this repo*.

## What this repo is

A portable Claude Code plugin — the reusable orchestration layer for AI-driven
engineering. It bundles subagents, skill chains, a task-packet
template, MCP stubs, and an approval guardrail hook. It is **domain-agnostic**:
the guardrail's built-in defaults cover risk common to any codebase (auth,
secrets, migrations, deps, deploys, git history); domain-specific risk (money,
PHI, …) is declared per-repo via `.agents/guard-extra-*`. First consumer: a
.NET/React/Postgres app.

## Structure rules (do not violate)

- Inside `.claude-plugin/` live **only** the two standard manifests:
  `plugin.json` (always) and, optionally, `marketplace.json` — the local
  single-plugin marketplace manifest that lets a consumer repo enable this
  plugin by name from a committed `.claude/settings.json` (see the consumer
  retrofit). No other files belong in `.claude-plugin/`.
- Every component directory (`agents/`, `skills/`, `hooks/`) and `.mcp.json`
  lives at the **repo root**, not inside `.claude-plugin/`.
- All component names are **kebab-case**.
- Hook commands reference scripts via `${CLAUDE_PLUGIN_ROOT}/...`, never a
  relative or absolute machine path.
- Hook scripts must be executable (`chmod +x`).
- **No hardcoded secrets** anywhere. Tokens come from env vars (`${VAR}`).
- **`gspec/` at the root is this repo's OWN backlog, not shipped content.** It is
  not a template and not part of the plugin — consumers never receive it, and
  nothing under `templates/` may reference it. This repo self-hosts (see below);
  `templates/spec-driven-base/` remains the only thing a consumer gets.

## This repo self-hosts its own backlog

`gaffer` drives its own development through its own adapter. The backlog is
**forward-only, plus one retro-spec** — the 25 shipped ADRs are deliberately not
retro-specced, because that is archaeology over decisions that already have
passing sweeps.

- **The one retro-spec is `run-metrics`** (ADR 0019, v1→v3.4), and it exists
  because that ADR is the clearest case in the repo of a **decision record being
  used as a status tracker**: 866 lines carrying five stacked `v3.x` revision
  sections, mirrored again in this file, with **no ADR in the repo having a
  status field at all**. That absence is what the backlog fixes. All its
  capabilities and tasks are checked, so it yields **zero** packets and reads as
  derived-done.
- **Known gaps of a shipped feature are a SEPARATE feature** (`metrics-coverage-gaps`,
  not an unchecked capability on `run-metrics`). Completion is derived from
  capability checkboxes, so folding a gap in would make a shipped collector read
  as incomplete and — via the dependency rule — block everything downstream of it
  forever. This is the modelling trap to avoid every time a shipped feature has
  a known hole.
- **A specced feature with no `gspec/tasks/<slug>.md` is the intended state for
  deferred work**, not an omission: the adapter reports `PLAN=none` plus the
  `/gspec-plan` hint. Decompose when the work comes up, so the decomposition
  reflects the repo as it is then rather than as it was when the ADR was written.
  Only `self-host-hardening` has a plan today.
- **Reflexivity is the risk self-hosting adds, and it has no analogue in a
  consumer repo** — there the plugin sits outside the working tree. Here the loop
  edits what it runs from, and the timing differs per surface: `scripts/*.sh` take
  effect **mid-run, in the run that made the edit** (`runstate.sh` is the loop's
  own single writer); a **hook body is spawned per event**, so it takes effect the
  same way — mid-run, on the next tool call, in the run that edited it — and only
  its registration (`hooks/hooks.json`, `.claude/settings.json`) crosses a session
  boundary; `agents/*.md` and `skills/*/SKILL.md` are read at dispatch.
  `hooks/guard.sh` is the sharpest case: it is the plugin's own safety floor, and
  here it is a first-class edit target at `full-autonomy` — a packet weakening the
  guard is live on the next matching tool call, in the same run, not caught by a
  loop still running an old copy. Closing this is
  `self-host-hardening`, and it is ordered first for that reason. Its T1/T2
  landed in `348f1cc`: `.agents/guard-extra-review` now routes that whole surface
  to the ASK tier, with 25 cases in `test-guard.sh`.
- **The ASK tier is OFF here — `bypass-ask-tier: true` in
  `.agents/project-overrides.yaml` (`2292c96`) — and that is a decision, not a
  regression of T1.** The surface `.agents/guard-extra-review` names IS this repo's
  entire backlog — nearly every packet edits a script or a prompt — so leaving the
  tier on meant a prompt on essentially every packet, which is not review, it is a
  click-through reflex that teaches you to stop reading. It was already close to
  inert: measured 2026-08-10, invoking `guard.sh` directly with this repo's cwd
  correctly returned `permissionDecision: "ask"` naming the matched rule, yet an
  `Edit` to `scripts/test-guard.sh` in that same session produced **no prompt** —
  while the hard-deny tier *did* stop an `rm -f`. Denies are enforced; asks were
  being auto-resolved. So the flip made explicit what was largely already true,
  rather than removing protection that was working. **Still enforcing, re-verified
  in-session:** the hard-deny floor (secrets/key material — an `Edit` to `.env`
  returned `rc=2`, `secret-path` — recursive deletes, history rewrite; a force-push
  still returned `risky-bash`), the git soft gates on `main`/`master`,
  `escalate_to_human_on` in `project-overrides.yaml` for the judgement calls the
  path patterns cannot express, and the reviewer plus the PR gate as the real
  review boundary. `.agents/guard-extra-review` is **kept, not deleted**: it costs
  nothing while the bypass is on, it documents what the reflexive surface is,
  `test-guard.sh` still pins its behaviour, and one line re-arms it. **What
  specifically stopped, and it is the sharpest part:** T2 added ask cases for the
  guard's own *configuration* on the rationale that a rule which can be silently
  deleted is not a rule. All four of those are now silent-allow here —
  `.agents/guard-extra-*`, `project-overrides.yaml` (which carries the bypass
  itself), `.agents/autonomy`, and `.claude/settings.json`. That is the control
  over the control, so the reviewer and the PR boundary are not a second line of
  defence for this surface; they are the only one.
- **Hard-denying `hooks/guard.sh` was proposed and rejected — and the flip above
  does not touch that.** This repo exists to develop the guard, so a hard floor
  over it makes the repo's central artifact unmaintainable. Same for
  `.agents/guard-extra-*` and `project-overrides.yaml`. Do not "harden" these to
  `.agents/guard-extra-paths` — it has been considered and it is wrong *for this
  repo*. A consumer repo is a different question and unaffected either way, since
  these patterns are repo-local. **And mind the load timing:**
  `project-overrides.yaml` and `.agents/guard-extra-*` are re-read by `guard.sh` on
  **every tool call**, so a change to them takes effect mid-session with no
  restart — only hook **registration** (`hooks.json`, `.claude/settings.json`)
  needs a session boundary. Conflating "changing the guard's config" with
  "changing what the harness loads" is the easy mistake.

## Conventions

- **Agents** (`agents/*.md`): YAML frontmatter with `name`, `description`,
  `tools`, `model`. Keep `tools` least-privilege (the reviewer has no
  Edit/Write on purpose). Each file carries a comment mapping it to the model
  routing intent: opus = reasoning/architecture/review/security, sonnet =
  implementation and research, haiku = the summarizer/doc agent (`doc-writer`).
- **Skills** (`skills/<name>/SKILL.md`): frontmatter with `name`, `description`,
  `argument-hint`. Reference shared files via `${CLAUDE_PLUGIN_ROOT}/...`.
- **INLINE IS THE DEFAULT; relay is for backlogs ≥ 40 packets** (`run-loop`,
  `resume` — ADR 0012, **crossover raised from 20 to 40 on 2026-08-10**).
  `--relay`/`--inline` override. The original 20 came from a *token extrapolation*
  (k≈21) with no production comparator. The first real one — 62 packets across two
  repos, `docs/metrics/2026-08-10-loop-cost-baseline.json` and the `argent`
  history — says **relay costs 1.84x inline per packet** (1,332,006 vs 722,989
  cacheCreation), and names the mechanism: the coordinator role carries a
  `cc_shape` max of **142k–240k with 9–55 turns over 50k in every relay run**,
  while no inline run has such a role. **The number is still not clean, and that is
  why relay was kept rather than deleted:** 65–96% of tool duration in those runs
  sits in the coordinator's own context, much of it **busy-wait polling** (33
  `until` loops = 51% of one run's wall clock), so each poll re-caches that
  standing context and inflates the very figure being compared. Fix the busy-wait,
  then re-measure as a two-arm A/B — that is `loop-cost-controls` P0, and deleting
  relay outright is the legitimate outcome if the gap survives. Note the regime the
  relay was built for has **never been reached**: inline compacts around packet
  ~28 and the largest run ever observed is **14**. If you change the brief or
  re-measure, update the ADR and both skills together.
- **Parallel mode is opt-in and worktree-isolated** (`run-loop`/`resume --parallel`
  — ADR 0016, amends ADR 0009). The default loop is single-checkout sequential and
  unchanged. `--parallel` runs the max number of **file-disjoint** packets at once,
  each in a `../<repo>-worktrees/<task-id>` lane, then serialize-merges green lanes
  back at `full-autonomy`. The safety rests on a **scheduling invariant**: concurrent
  lanes never share `allowed_files`, computed by `scripts/packet-graph.sh` (overlap ⇒
  mutual-exclusion edge) and materialized by `/gaffer:build-packet-dependency-tree`
  into `.agents/packet-graph.yaml`; a real merge conflict escalates, never
  auto-resolves. Deterministic cores live in scripts (`packet-graph.sh`,
  `worktree.sh`, `runstate.sh reconcile-parallel`) with matching test sweeps —
  judgment lives in the skill/agent prompts. run-state advances to **schema 3**
  (multi-lane) as a superset of the sequential schema; the driver is its single writer.
  The parallel-mode instructions (former `run-loop` §P) live in
  **`skills/run-loop/parallel.md`**, split out so the common sequential path does not
  load ~1.9k tokens it never runs (ADR 0019 v2 lever): `run-loop/SKILL.md`'s top section
  `Read`s it only when `$ARGUMENTS` contains `--parallel`; each dispatched lane still
  reads `SKILL.md` for §3. Keep §-references in `parallel.md` pointing at `SKILL.md`.
- **Graceful pause is a cooperative sentinel, not preemption** (`run-loop`/`resume`/
  `pause`, ADR 0017). A pause REQUEST is a write-once file — `.agents/pause` (whole
  run) or `.agents/pause.<task-id>` (one lane) — kept **separate from run-state** so
  a human/frontend setting it never contends with the driver's single-writer
  run-state; run-state records only the OUTCOME (`status: paused`). The sentinel is
  canonical in the **main checkout** and resolvable from any lane worktree via
  `git rev-parse --git-common-dir` (zero env dependency — the parallel requirement).
  The **guaranteed** stop is the prompt-poll (`runstate.sh pause-status`) that the
  loop/chief-engineer/implementer run at safe boundaries — landing on a green commit
  or rolling back, **never mid-edit**; `hooks/pause-check.sh` is **best-effort**
  reinforcement that injects a **context-only** advisory (no `permissionDecision`, so
  it can never weaken the guard). **Its delivery to subagents is VERIFIED but stays
  advisory, not enforcement (ADR 0017, probe 2026-07-19):** a probe in a session that
  loaded the hooks at startup confirmed PreToolUse `additionalContext` — the field this
  hook already uses — reaches a dispatched subagent's model (hook fired inside the
  subagent with `agent_id`/`agent_type` set; token quoted back). PostToolUse
  `additionalContext` delivers identically; PostToolUse `updatedToolOutput` fired but
  never surfaced. So the hook is NOT on the wrong event/field — the earlier "dead"
  reading was purely the mid-session-load confounder. **But a correct agent treats the
  injected advisory as untrusted data** (prompt-injection hygiene — the probe subagents
  read it and declined its embedded "stop"), so it cannot *force* a halt. The
  **prompt-poll remains the authoritative mechanism** (its result is a tool output the
  agent itself requested); correctness must never depend on the hook. Never describe
  pause as "automatic via the hook." Hard, agent-choice-proof enforcement would need a
  *coercive* PreToolUse `deny` gated on `agent_id` (subagent-only, sparing the
  orchestrator) — deferred until parallel runs show lanes overshooting poll checkpoints.
  On a parallel pause every lane's status is written back
  so all lanes stay resumable via the existing `reconcile-parallel`. There is no
  grace/kill timer — under synchronous dispatch there is nothing to time out; true
  mid-command preemption would need background-task dispatch, rejected in ADR 0017.
  Deterministic core in `runstate.sh` (`request-pause`/`clear-pause`/`pause-status`)
  with a matching `scripts/test-pause.sh`; judgment in the skill/agent prompts.
- **Rate-limit auto-pause is one more sentinel writer, not a new pause path** (ADR
  0018, amends 0017). Claude Code's rolling usage percentages (the **5-hour** AND
  **7-day** windows) are delivered to **exactly one place** — the `statusLine`
  command's stdin JSON (`rate_limits.five_hour`/`.seven_day`), only after the first
  API response, only on **Pro/Max**, refreshed once per API response, each field
  independently absent. No hook payload carries them and nothing persists them to
  disk, so the **status line is the sole sensor**. `scripts/statusline-pause-sensor.sh`
  reads both windows and, when *either* crosses its own threshold (defaults **90 /
  85** — weekly lower on purpose: exhausting it strands the account for *days*),
  writes the *existing* `.agents/pause` sentinel via `runstate.sh request-pause` —
  the same write, same format, same idempotent `! -f` guard. **Everything after the
  write is ADR 0017, byte-for-byte; the prompt-poll stays authoritative.** The sensor
  is **best-effort early-warning, never a hard stop** (both cutoffs are server-side —
  never describe it as guaranteeing a pause); if it's disabled/API-key/outrun, crash-
  reconcile `restart` is the floor. Three non-obvious constraints the sensor bakes in:
  it resolves `runstate.sh` and the main-checkout sentinel/config from its **own
  path + `git-common-dir`**, NOT `${CLAUDE_PLUGIN_ROOT}` (which does **not** expand
  in the `statusLine` context — the same reason `settings.json` needs a resolved
  absolute path a plugin can't write, so `/gaffer:rate-limit-pause on` writes
  it); it **parses `.agents/project-overrides.yaml` itself** (`rate_limit_pause:`
  block — env → YAML → default) because nothing exports `ORCH_RATE_PAUSE*` into a
  harness-invoked callback; and its `date` helper handles **both** BSD (`-r`) and GNU
  (`-d @`) epochs. The `rate-limit-pause` toggle skill mutates user config *outside*
  the plugin tree in both directions — never clobber a foreign `statusLine`, and
  `off --teardown` (global scope) is explicit and warned, distinct from plain `off`
  (per-repo). Regression cases live in `scripts/test-pause.sh` alongside the 0017 set.
- **Run-metrics is hook-collect + script-assemble + skill-analyze** (ADR 0019, Tier 1).
  Collection is a `PostToolUse` hook (`hooks/metrics-log.sh`, matcher **`.*` — ALL tools**,
  so `Task` dispatches and `Read`/`Grep` context-loading are counted, not just mutations) —
  the only mechanism that fires on *every* tool call and carries `agent_id`/`agent_type`
  **inside** dispatched subagents/lanes (verified from a real `git worktree` lane in
  `test-metrics.sh`) — appending **metadata + low-sensitivity labels** (ts, session,
  agent id/type, tool, and — ADR 0019 **v2** — `duration_ms`, `tool_use_id`, the running
  `skill`, dispatched `subagent_type`, and a Bash command **head only** as `cmd_class`:
  argv0[+subcommand], with env prefixes / args / paths / secrets STRIPPED, so the packet
  is still safe to hand to Claude and **no full command text or path is ever logged**)
  JSONL to `.agents/metrics/events/<session>.jsonl`. The loop skills (`run-loop`/`pause`/`resume`)
  call `metrics.sh collect || true` at checkpoints (best-effort, non-critical) to pin the
  perishable transcript-token data. It is advisory-safe exactly like
  `pause-check.sh`: prints **nothing** (no `permissionDecision`, cannot weaken the guard),
  fails silent, always exits 0. Assembly is the deterministic core `scripts/metrics.sh
  collect`, which joins the event spine ⟕ **packet boundaries derived from the `[orch
  packet:<id>]` commit trailers** (a deliberate ADR-0019 refinement: run-state's nested
  `packets[]` is **left untouched** — no schema migration, no single-writer contention;
  the trailer already ties every green commit to its packet) ⟕ the `packet-graph.yaml`
  wave map ⟕ **best-effort transcript tokens** (the default source; **version-fragile**, so
  it **fails soft** to structural-only and STAMPS `token_source` — never let an analysis
  read a partial run as complete) into one portable `.agents/metrics/<run-id>/run-metrics.json`.
  The trailer scan matches **only a trailer on its own line** (prose that merely mentions
  the format does not count) **and is bounded to the run window, not `git log --all`**
  (scoping revision 2026-07-21): the window is the **selected session's** span (default the
  **newest** events log by mtime; `--session`/`--all-sessions`/`--since`/`--until` override),
  and only trailers with commit time **≥ the window's lower bound** are kept — `--all` stays
  for lane-branch *ref coverage*, the time filter supplies the *run scope*, and the upper
  bound is open unless `--until` is given (the run's last packet commits just **after** its
  last tool event). Without events it falls back to `<integration_branch>..HEAD`. This killed
  the "156 phantom packets over 17 days vs. one 3-hour session" bug in the first production capture
  (now an honest 0). The `adhoc` run-id is disambiguated to **`adhoc-<session8>`** so two
  sessions never overwrite one `run-metrics.json`. Judgment lives in the `/gaffer:metrics <collect|show|
  status|analyze>` skill — `analyze` hands the compact rollup to Claude/the architect for
  ranked optimization advice. Tier 0 (OTEL) is **optional/deferred**, not built. **v2
  (2026-07-22, live-certified in a real session) adds**, all from the same PostToolUse
  payload: per-packet tokens (bucketed by transcript-turn timestamp, fail-soft null),
  active/idle wall split, an unattributed-tool-calls bucket, model-per-agent
  (`by_model`), per-tool `duration_ms`, and the skill/process + command-class dimensions
  (`by_skill` / `by_command_class` — the latter is the "where an output filter like rtk
  helps most" map). Field names were payload-**probed** first (not taken from docs):
  `duration_ms`/`tool_use_id` are native PostToolUse fields; the dispatch tool is named
  **`Agent`** (not `Task`). **Routing is ONE decision made ONCE (2026-07-23 revision):
  `tier` (a REQUIRED task-packet field, set at scope time) → **agent** (who you dispatch)
  → **model** (that agent's `model:` frontmatter). Never pass `model` at dispatch: an
  omitted `model` resolves to the target agent's frontmatter, and every orchestration
  agent declares one — the frontmatter IS the routing policy. The old
  `dispatches_without_named_model` counter inverted this and **manufactured false
  positives** (the first production capture read 8 clean architect/reviewer dispatches as 8
  violations); it is replaced by `dispatches_with_model_override`, which counts the
  thing that actually signals a deviation. Ground truth for what a role really ran on is
  `by_agent_role.<role>.models`, never the dispatch arg. Unlabelled packets now flag as
  `unlabelled:` rather than reading as clean — but **only in a mixed run**; a run where
  *no* packet carries a trailer is legacy, so the per-packet flags are suppressed and a
  run-level note carries the caveat. Remaining gaps in `notes[]`: guard ASK-tier frequency
  still uncaptured (PostToolUse sees allowed calls only, and `Notification` does NOT fire
  on a denied call — probed); failed/uncommitted packets absent. `.agents/metrics/` is
  gitignored bookkeeping (ADR 0009), in the plugin's
  own `.gitignore` **and** `templates/spec-driven-base/.gitignore`. Regression sweep:
  `scripts/test-metrics.sh` (synthetic git repo + event log + fake transcripts; no live agent).
  **v3 (2026-08-02) fixes three defects the first cross-repo `analyze` exposed** — read
  ADR 0019 §"v3 revision" before touching the collector. (a) The **trailer scan is now
  bounded at BOTH ends**, always: `[win_start, last-event + ORCH_METRICS_TRAILER_GRACE]`
  (default 3600s), `--until` verbatim. The old open upper end assumed collection happens
  at end-of-run; under *retrospective* collection every run absorbed every later run's
  packets (an 11-minute session reported **45**; 12 of 19 runs inflated 2x–45x). The grace
  is not slop — a run's last packet commits just *after* its last tool event. Corrected,
  the largest real run is **9 packets**, so ADR 0012's 20-packet relay crossover has never
  fired in production. (b) **`by_skill` was dark, not empty**: slash commands emit no
  `Skill` tool event (3 in ~6k calls), so `hooks/metrics-skill.sh` (UserPromptSubmit)
  now records the invoked name to a per-session state file that `metrics-log.sh` stamps
  onto every event. It is **sticky** (set, never cleared) ⇒ an *upper bound* on a skill's
  spend; that direction is deliberate, since clearing on each plain prompt would drop a
  whole `/run-loop` the moment a human nudged it. Like every hook here it prints
  **nothing** — UserPromptSubmit stdout is injected into context. (c) **`by_tool` added**
  (run + per-packet): `by_command_class` classifies Bash only, so tool *selection* was
  invisible — which hid **zero `Grep`/`Glob` calls against 1,568 shell `grep`s** across
  both repos. Still NOT captured, and stated in `notes[]`: `outcome` is hardcoded
  `"green"` (no trailer ⇒ no packet, so failed/rolled-back work cannot be seen — "42 of
  42 green" is survivorship, not quality), and no file paths are logged, so main-vs-
  implementer edit *overlap* inside a packet cannot separate correction from division of
  labor. Both are prerequisites for a rework rate by editor role.
  **v3.1 (2026-08-07) — the collector was blind on Windows, and said so misleadingly.**
  The native Windows jq build opens stdout in TEXT mode, so **every** jq line ends `\r\n`,
  on pipes too, and `read` strips only the `\n`. The distinct-session-id list is the one
  jq-written **line list** a `while read` loop consumes, and its values build **globs**:
  `$sid` came out 37 chars, so `<uuid>\r.jsonl` matched nothing and `token_source` never
  left its `none` initialiser — on every Windows run, via the legitimate fail-soft path,
  with every structural number still correct. **RULE: any `jq -r … > file` consumed by a
  `read` loop must be piped through `tr -d '\r'`** (a no-op on POSIX). **And do NOT
  conclude that `$(jq …)` captures are therefore safe** — that reading is what the bug
  report and the first cut of this fix both assumed. MSYS bash strips a trailing `\r\n`
  from command substitution; **plain bash does not** (measured: 11 bytes under MSYS bash
  5.2.37, **12 under Linux bash 5.2.21**), so all seven scalar captures were correct on
  Windows purely by accident of which bash Git Bash ships. They now go through
  `jqr() { jq -r "$@" | tr -d '\r'; }` — `pipefail` keeps jq's exit status so the
  `|| echo <default>` fallbacks still fire. **CI caught this, not the author's machine**:
  the regression test asserts the CRLF-shimmed packet is BYTE-IDENTICAL to a clean run,
  which on Linux exercises the exact shell/jq pairing Windows masks (it failed with
  `"implementer\r"` role keys and every per-packet `tokens` nulled). That assertion was
  written as redundant belt-and-braces and was the only thing separating *fixed* from
  *fixed on this machine* — keep it. The shim is written in `awk`, NOT `sed 's/$/\r/'`,
  because BSD/macOS sed inserts a literal `r` and the test would be silently vacuous
  exactly where it matters. Second half of the fix: `token_source: none`
  conflated four failures and its note claimed "no transcript found" while 29 transcripts
  sat on disk. Packets now carry `token_diagnostics` (counts only, no paths) separating
  *nothing on disk* / *lookup failure* / *format drift* / *window miss*, the note names
  which, and `show` prints it whenever `token_source != transcript`. The enum is
  unchanged.
  **v3.2 (2026-08-07) closes the overlap v3.1 left open, and adds the effort dimension.**
  All three changes are **retroactive** — they re-read stored events/git/transcripts, so old
  runs just re-collect. (a) Trailer times are **author dates** (`%ad`), not committer dates,
  which rebase/cherry-pick/squash-merge rewrite. This one is **defensive, not a fix for an
  observed failure**: the analysis that motivated it claimed six absorbed packets, but those
  commits have *identical* author and committer dates — claim withdrawn. Divergence is real
  but rare (**1 of 395** trailer commits in one repo, **8 of 107** in the other), so it
  matters mainly where branches are rebased before merging. That first repo's real
  attribution gap is not a date bug: only **395 of 899 commits carry a trailer at all**.
  (b) The trailer grace is **capped at the earliest event of any other session after
  `win_end`** — a flat grace is only safe when nothing else is running, and this is a bug
  fix, not the semantics decision v3.1 feared. It reproduces, exactly and automatically, the
  **7 phantom rows across 5 sessions** a consumer-repo analysis had removed by hand with
  explicit `--until` — while correctly keeping `wbr-t14`, the one packet that legitimately
  spans two sessions, in **both**. (c) `totals.by_effort` + `totals.context_invalidations`:
  reasoning effort is a per-turn request parameter (transcript-only — **no hook payload
  carries it**), and changing effort **or** model mid-context invalidates the cached prefix.
  Measured flips cost 372,588 / 380,005 / 115,509 cacheC against medians of 1,380 / 856 /
  ~1,700, and it fires in **both** directions — which is what makes it invalidation, not
  "higher effort costs more". Building it answered an open question: **effort propagates to
  subagents** — one flip produced **9 invalidations across 6 agent contexts totalling 1.53M
  cacheC**, ~one relayed-coordinator dispatch for one keystroke. The scan is per
  `(role, agent_id)`, NOT per role, so two dispatches of one role on different models read as
  normal tier routing rather than a switch; ts-less turns are excluded (degrade to 0), and an
  empty `by_effort` means *unmeasured*, never *constant*.
  **v3.3 (2026-08-07) — every token number before it was inflated ~2.6x.** A transcript
  records the SAME assistant message more than once (observed **3x** for one id, at +2ms and
  +26s), each row carrying the full `usage` block, and the collector summed rows. **ADR 0012's
  own measurement deduplicated by `message.id`; the collector never did.** Measured inflation
  over four real sessions: cacheCreation **2.3x–3.2x**, output **3.3x–6.3x** — *different
  rates, differing per session*, so it does **NOT** cancel in a ratio: `CC:out` read 6.4 raw
  vs **9.0** deduped on one session and 14.9 vs **33.8** on another. Directionally the
  conclusions held (ordering unchanged, best-vs-worst gap *widens* 2.3x → 3.8x) but that was
  luck. Dedup keeps the **earliest** row per id (duplicates carry identical usage, so the pick
  is cosmetic for totals but must be deterministic for the `context_invalidations` ts scan);
  rows with **no** `message.id` are kept verbatim, because `.uuid` is per-**ROW** and keying on
  it would dedupe nothing while looking like it worked — under-dedupe is the safe direction.
  `token_diagnostics.duplicate_turns_dropped` makes the rate visible: a drift toward 0 means
  either the transcript stopped repeating messages **or** stopped carrying `message.id`, and
  the second silently re-inflates ~2.6x while still stamping `token_source: transcript`.
  v3.3 also fixed `show` rendering **`null` as `0`** for `dispatches_with_model_override` and
  `failed_tool_calls` — the collector emits null for pre-instrumentation runs *on purpose*
  (its own comment calls reporting 0 "a lie") and `show` told that lie via `// 0`, so a legacy
  run read as fully-audited-and-clean. The audit block also moved **above** the per-packet
  table: at 14 packets it was off-screen, which is how a real signal goes unread with nothing
  actually hidden. **Neither was missing instrumentation** — do not reach for a new counter
  when the existing one is being rendered or placed wrongly.
  **v3.4 (2026-08-07) measures the PAYLOAD, not the aggregate, and stops assuming green.**
  (a) **`by_agent_role.<role>.cc_shape`** (median/p90/max/turns_over_50k/cc_over_50k) exists
  because cacheCreation-per-packet **cannot** detect a context diet: it spans **1.76x across
  four untouched same-regime sessions** (9x overall), so a ~150k trim (20–30%) sits inside the
  noise. The aggregate conflates two things — a turn is either a small warm-cache delta or a
  **full re-cache of everything the role holds**. Split out, the **median is flat everywhere**
  (1,408–4,683) while `max` separates by an order of magnitude with no overlap: **24,190 and
  0/300 turns >50k** on the cheap session vs **198,397 and 32/524** on the costly one. So
  `p90`/`max` read the standing-context SIZE and move when you scope reads — measurable in ONE
  run. **A flat median with a large max is not an expensive agent; it is a large payload being
  re-cached.** (b) **`outcome` is now attested or `null`, never assumed `"green"`** — a packet
  exists here only via its green-commit trailer, so failed/rolled-back work leaves NO row and
  "42 of 42 green" was survivorship that looked *better* the more work was discarded. The loop
  calls `runstate.sh record-outcome <pkt> <green|failed|rolled-back|blocked|abandoned>` at
  **every** boundary; append-only to `.agents/metrics/outcomes/`, deliberately NOT run-state
  (single-writer contention, same reason boundaries stayed on trailers), last-wins. (c)
  **`packets[].edits`** turns per-role edit counts into a rework signal: "implementer 34, main
  3" is either correction or division of labour, and only **same-file overlap**
  (`contended_files`) tells them apart. The hook stamps a 12-char **hash, never the path** —
  the packet must stay safe to paste into an issue, and a hash answers "same file?" and
  nothing else; digest probing is by **execution** (shasum/sha1sum/md5sum → POSIX `cksum`),
  the guard.sh rule. (d) **`runstate.sh trim-note`** enforces the ONE-line contract
  `templates/run-state.yaml` already documented but nothing checked — unbounded it hit
  **164,678 chars, 87% of the run-state, ~41k tokens, 15 stacked histories**, re-read on every
  relay dispatch to recover two facts. It archives to `run-state-note-archive.md` and trims on
  **whole lines** so the YAML stays parseable. All four degrade to `null`/absent on legacy
  runs — **`null` means unmeasured, never clean**.
- **Search-tool selection is a PREFERENCE; only the write surface is a real control**
  (ADR 0019 v3.3 — **v3's cost claim is RETRACTED**). All seven `agents/*.md` carry a
  "structured tools, not the shell" section: `Grep`/`Glob`/`Read` to search and read,
  `Edit`/`Write` to change, `Bash` for builds, tests, git, and running the project.
  v3 asserted this was "a measured cost, not a style preference" and the read-only
  agents were told shell search was "most of your context budget." **Both were wrong,
  and the error is instructive:** the finding v3 actually had was **0** `Grep`/`Glob`
  against 1,568 shell `grep`s — a measurement of tool *selection*, which was then
  reported as a measurement of tool *cost* without anyone measuring cost. Measured
  properly (join `tool_use`→`tool_result` in the transcripts and total the result
  bytes): shell search across 30 sessions is **~187k tokens against 105M deduped lifetime
  cacheCreation — ~0.18%**, mean 1,164 chars per call. (Result-byte figures needed no
  dedup correction: the v3.3 duplication is confined to assistant `usage` records, while
  `tool_use`/`tool_result` blocks measure **1.0x** unique. Only the denominator was
  wrong.) Eliminating it entirely saves a
  rounding error. `Read` is **7.6x** all shell search combined, with the top decile of
  calls carrying half the volume — so the real read-cost lever is scoping what agents
  read, not how they search. What survives is the WRITE half, and it survives on its
  own merits: `sed -i`/`cat >` bypass diff review and the guard's path tiers, which is
  exactly why `guard.sh` must pattern-match them as a write surface. **The general
  lesson: a frequency count is not a cost measurement.** Keep the (now smaller) block
  when editing an agent; do not re-add a cost claim to it without a cost measurement.
- **All seven agents carry a "do not re-read what you already have" block — the RULE only,
  never the evidence.** Measured across one production week: of **5,243 `Read` calls, 1,366
  (26%) re-read a file already read in that same context** (~2.4M tokens). That is not a
  2.4M problem — content in context is re-read on every later turn, so a token read twice is
  paid for twice on every subsequent turn for the rest of the session. At the measured ~16
  effective tokens per source token, it is ~**11% of that repo's weekly spend**. Part of the
  mechanism is confirmed: **63 occurrences of `Read` immediately after `Edit`/`Write` of the
  SAME file in just 25 subagent contexts** — verify-after-edit, which is unnecessary because
  those tools error on failure, so a successful result already IS the confirmation. It has to
  target the **implementer** above all: it is **47.9% of all turns** at 128k average context
  and does nearly all the reading, whereas the coordinator — which the run-state and
  read-list work reached — is only **9.5% of turns**. **Keep the evidence HERE, not in the
  prompts.** The first cut shipped a three-line "Measured:" paragraph into all seven agents
  — **61 tokens each, 427 total**, re-read on every dispatch to justify a rule the agent
  follows without it. Small, but it was bloat added by the very block telling agents not to
  waste context. Rule in the prompt, evidence in this file: this file does not propagate,
  so it is free here and recurring there.
- **Findings live in `.agents/findings/<id>.md`; run-state keeps ONLY a one-line index**
  (ADR 0022). Everything in run-state is read by every packet — a dispatched coordinator
  reads it at dispatch start, so it sits in the standing context and is re-written to cache
  on **every** large turn (measured: **32 cache writes >50k in ONE dispatch**, the
  coordinator the only role with any). A finding useful to one packet was being paid for by
  all of them. Evidence this is a **design gap, not sloppiness**: the two fields that
  ballooned were `note` (164,678 chars — documented as *one line*) and
  **`resolved_questions` (21,664 chars), which is not in the template or `runstate.sh` at
  all** — the agent invented it because the schema offered nowhere else. The shape is
  **index hot, body cold**, NOT "links instead of content": moving content out with no
  index flips the failure from *expensive* to *never read*, and a gotcha exists precisely
  to prevent the rework that not reading it causes. The summary's one job is to let an
  agent decide whether it needs the body **without opening it**. Routing is the ADR 0020
  seam and getting it wrong builds a **shadow backlog competing with gspec**: *"this should
  be built/fixed"* → **gspec task/feature** (+ `.agents/roadmap.yaml`), never a finding;
  *gotcha / constraint / decision + rationale / resolved question* → **a finding**;
  one sentence of "where we stopped" → `note:`. Mechanism is `runstate.sh add-finding`
  (appends the entry, creates the body stub) and `findings` (prints the index and nothing
  else) — appending to a YAML list by hand is how agents corrupt the loop's only durable
  state. Entries insert **immediately after the `findings:` key** (newest-first) because
  that is the only placement that cannot land in `note:`/`pending_questions:`; ids are
  `[a-zA-Z0-9._-]` (an id becomes a filename); summary newlines are **collapsed, not
  rejected** (a raw newline injects a sibling YAML key, and the caller is an agent
  mid-loop). `trim-note` survives as a **backstop**, not the intended path. The discipline
  is prompt-enforced and therefore the fragile part — **`cc_shape.max` is the detector: if
  it does not fall on the next run, the rule is not being followed.**
  **Treat every agent-supplied value written into run-state as hostile input** — it is
  the only state that survives a session and a parse failure is unrecoverable. The
  first cut wrote `summary` as a **plain** YAML scalar, so the single likeliest thing in
  a finding about code (`": "`) corrupted the file the function existed to protect.
  Summaries are now **single-quoted with `'` doubled**: single- and not double-quoted
  because a single-quoted scalar does **no** escape processing (`'' → '` is the whole
  rule, a backslash is already literal), and because one `sed` keeps `jq` out of it —
  `add-finding` must keep working on stock Git Bash, the same constraint `guard.sh` is
  built around. Interpolate via **`awk ENVIRON`, never `awk -v`**: `-v` expands `\n` in
  the *value*, which re-opened the newline injection one line after the `tr` collapse
  closed it. The duplicate-id check is scoped to the findings **block** and matched
  **literally** — a whole-file regex scan collided with schema-3 `packets:` ids (same
  `  - id: <x>` shape, and naming a finding after its packet is natural) and `.` is
  both a legal id char and a metachar, so `f.001` matched `f-001`. Same rule made
  `trim-note` re-emit the note as a **literal block scalar**: the cut is a byte cut, and
  only a block scalar is truncatable at any byte — cutting `note: "…"` severed the
  closing quote. **`test-runstate.sh` now asserts a real YAML *parse* after each mutating
  subcommand; grep is what let all of this through.**
  Bodies are **gitignored** (both `.gitignore`s), with run-state. Not just for symmetry:
  untracked ≠ ignored here — `git stash --include-untracked` (the pause path) sweeps an
  untracked finding and `reconcile` reads it in `git status --porcelain` as scratch on
  the green checkpoint and discards it, so the ADR's headline use case destroyed its own
  output. Cost: same-machine, like run-state. And because `runstate.sh write` **replaces**
  while `add-finding` **appends**, every whole-file write must carry `findings:` through
  and findings are recorded **after** it — a dropped index line does not delete a finding,
  it unlinks a body still on disk. **A parallel lane never calls `add-finding`** (no
  run-state in its worktree; it is not the writer): it returns `Findings:` lines in its
  check-in and the scheduler records them, lane-task-id-prefixed. That is the same rule
  `record-outcome` obeys from the other side — it is lane-callable *because* it writes
  append-only outside run-state.
- **A finding discovered after a plan is complete routes by scope in two arms tried in
  order, and the completed record is never edited** (ADR 0026). **Arm 1** applies when
  **some feature in the backlog** is **incomplete**, has a plan file with ≥1 **unchecked**
  task line, and an **unchecked capability in its PRD covers the finding** — both tests
  separate; no plan file means no anchor, regardless of scope match. Append a new unchecked
  task line to `gspec/tasks/<slug>.md` as an `Edit` anchored on an unchecked line, carrying
  truthful `covers:` naming that capability. **Arm 2** (everything else, including fully checked
  parent plans) becomes a **new feature**: a PRD via `/gspec-feature`, a `.agents/roadmap.yaml`
  entry (`depends_on:` the parent, `order` after it), and **no plan file** until the work
  comes up. Loop contexts lack `Skill`, so arm 2 splits: hand off on the `normal`-severity
  question block in `templates/check-in.md`, and main-context runs `/gspec-feature`.
  **The recorded diagnosis was WRONG, and that is the part to keep**: the immutability
  hook asks only that every checked task's **block** (its line through the next task
  line) survives byte-identically, so additive appends already pass mechanically;
  policy forbids it because a derived-done feature must not carry unshipped work
  (ADR 0020 D2) — the appended task would emit no packet node and never be scheduled.
  A hook rejection is a **signal** the edit disturbed a checked block or arm 1 was
  wrong, never a cue to bypass with shell or patch the vendored hook (it is re-stamped
  at install). `/gspec-plan` regeneration is unreachable from a dispatched context and
  would require reopening the feature. Arm 1 widens the plugin's write into `gspec/`
  past ADR 0025's `[ ]` → `[x]` flip, bounded to: append only,
  never modify existing lines, never touch capability checkboxes, always carry truthful
  `covers:`. The arm-1 scope test is prompt-enforced — nothing mechanically checks fit; the
  detector is a task whose `covers:` does not match, and the boundary is the packet's PR
  review. `-gaps` does not stack; arm-1-first keeps feature count aligned with scope.
- **There are THREE report files, and the split is by reader and by need** (ADR 0023).
  `templates/check-in.md` is the **wire** format — a lane or a dispatched Chief
  Engineer returns it and the scheduler *parses* it, so its keys are stable and it
  stays machine-shaped. `templates/report-conventions.md` holds the **conventions**
  every human-facing report owes (glyph vocabulary, indentation contract, decision
  block, header tally, the four rules). `templates/report-templates.md` holds only the
  loop's three **shapes** and assumes the conventions file. Skills with no shape of
  their own (`review-change`, `metrics`, `migrate`, `new-project`) read the
  conventions and **not** the shapes — that split is the whole point of splitting.
  `templates/report-conventions-card.md` is a fourth thing and not a fourth contract:
  a ~2.9k-char distillation that is the always-on layer, and the ONE source both L2
  (consumer `CLAUDE.md`) and L3 (the hook) copy from.
  **The contract must be DELIVERED, not referenced** — this is the fix ADR 0023
  exists for, and it is the failure mode to watch for anywhere else in this plugin.
  Every skill named `report-templates.md` **by path** and none said `Read`, so an agent
  rendered from the one-line paraphrase in the SKILL.md and had never seen the
  contract; free prose in consumer repos was the rules never arriving, not an agent
  ignoring them. Naming a path is not delivering a file. Scope the `Read` two ways or
  it gets expensive: **by role** (only whoever writes to the *human* — a relay-
  dispatched Chief Engineer or a lane returns the wire format, and reading the shapes
  would cost ~5k/packet for something it never emits) and **by need** (conventions vs
  shapes). The three delivery layers are deliberately redundant and **L2 suppresses
  L3** via the `gaffer:report-conventions` marker, so a session never pays twice:
  L1 the skills' `Read`; L2 `migrate.sh apply` stamping the card into the consumer's
  `CLAUDE.md` byte-verbatim (strongest — a repo's own `CLAUDE.md` is the *human's
  standing instruction*, obeyed as such); L3 `hooks/report-conventions.sh` injecting
  it at SessionStart (weakest — injected context is untrusted *data*, ADR 0017's
  probe had subagents read an injected "stop" and decline it — but it is the only
  layer that upgrades with the plugin). Never describe L3 as enforcing the format.
  A `Stop`-hook validator was **rejected, not overlooked**: most turns are not
  reports, and "is this a report?" is exactly the judgment a regex cannot make.
  It is a **separate `hooks.json` SessionStart entry** from `session-start.sh` because
  the matchers must differ — the card re-fires on `clear|compact` (context is lost
  there), while `session-start.sh` must not, since it reads `status: running` as "the
  previous session died" and would announce a crash that never happened mid-run.
  Regression sweep: `scripts/test-report-conventions.sh` (JSON validity of the
  hand-escaped envelope — the card is full of quotes, backticks, `→` and emoji, and a
  malformed envelope is dropped *silently*; L2-suppresses-L3; fail-open in four
  directions; and a byte-comparison against the overlay copy, since three copies of
  one contract is this design's standing risk). `scripts/test-migrate.sh` covers the
  stamp. **Scope is REPORTS, not responses** — a glyph tally on a two-line answer is
  decoration, and decoration is what teaches a reader to stop trusting the glyphs.
  What the human reads:
  one shared **decision block** plus three shapes — **C** kickoff (before the first
  packet, and on resume), **A** check-in (a packet or wave came back), **B** stop
  report (the loop stopped, for any reason). The main-context agent renders them from
  the wire text and the already-resolved backlog, **and nothing else** — ADR 0012 step
  3 was amended from "relay verbatim" to "render" for exactly this, because the rule
  it was protecting is *don't go back to disk*, not *don't reword*. A bounded text
  transform costs a few hundred tokens once per packet and does not grow with the
  backlog; re-opening the repo to enrich a check-in is what refills a relay's context.
  Two conventions are the whole point and the first thing to drift: **no bare ids**
  (`wbr-t14` and "ADR 0017" mean nothing to a reader who is not holding the numbering
  — every id gets a plain-English title on first appearance), and **every ask goes
  through the decision block** (two real options, what *follows from* each — the
  consequence, not the argument — plus a lean and the default if the human says
  nothing). Empty sections are omitted, never written as "none".
  **Two formatting contracts carry the scannability, and both are fixed.** The **glyph
  vocabulary** — ✅ landed · ⛔ failed · ⚠️ blocked/alert/risk · 🔀 a decision for you ·
  ⬚ queued · 🔁 retried · ⏸️ paused · ▶ next — is one glyph, one meaning, never two on
  a line. ⚠️ and 🔀 are **not** interchangeable and the split is load-bearing: waiting
  on another packet is ⚠️, waiting on the *human* is 🔀, which is why a tally can
  honestly read `⚠️ 2 blocked · 🔀 3 decisions`. **Section headings reuse the tally's
  glyphs in the tally's order**, so the header line works as a table of contents — add
  a decorative section marker (📦, 🎯) and that correspondence silently breaks. The
  **indentation contract** exists because markdown here renders proportional and
  **plain leading spaces indent nothing** (≤3 stripped, 4+ becomes a code block): so
  sections sit flush left, facts go inside a `>` quote bar (which also draws the
  section's vertical rule — hence no horizontal rules anywhere), bullets appear
  **only** for choices, and consequences hang unbulleted under their choice. Never pad
  into columns; alignment survives only inside a fence, and a fence costs every bold in
  it. The header **tally replaced a progress bar** on purpose: a bar collapses "waiting
  on you" and "not started" into one grey tail, which are precisely the two states the
  human needs to tell apart. Tables are banned outright — they read worst on a phone,
  which is where these land.
  **Conventions are not the same as shapes, and reports without a shape still owe
  them**: `review-change`'s verdict, `build-packet-dependency-tree`'s plan (which *is*
  a kickoff — use shape C), `metrics show`/`analyze`, `new-project`, and `migrate` all
  carry the vocabulary, the indentation, and the decision block. But do **not** bolt a
  header tally onto a report with nothing to count — on a metrics summary it is
  decoration, and decoration is what teaches a reader to stop trusting the glyphs.
  **The decision block is a shared primitive, not stop-report furniture** — it is
  also the Chief Engineer's intake "2–3 approaches with trade-offs", `review-change`'s
  Risks section, and an inline ask under a blocked lane in a check-in whose run is
  still going. That is why it is factored out: four near-identical shapes would drift
  apart, and the un-actionable form ("things a human should weigh") is exactly what
  they drift *into*. **The kickoff is the cheapest correction point in a run** — a
  wrong assumption costs a sentence there and several packets at the stop report,
  which is why shape C carries an explicit `Assuming:` line and why `run-loop` emits
  it *after* preflight and backlog resolution, when it states facts rather than
  intentions. Deliberately NOT built, so they do not get invented later: a
  welcome-back shape (identical content to B — reuse it), a metrics shape (numbers-
  dense and pulled on demand, not pushed), anything for guard ASK-tier prompts (Claude
  Code renders those natively and a template cannot reach them), and a mid-packet
  progress heartbeat (a subagent returns nothing until it finishes — ADR 0012; that
  is a transport limit, and a shape that implied liveness would be lying).
- **Two harness facts that are easy to break by accident** (ADR 0012, findings
  2–4): a dispatched agent has **no `Skill` tool**, so a brief must give the
  SKILL.md **path** to `Read` — naming the slash command silently yields an
  improvised loop; and `Task` in agent frontmatter is what **grants** delegation
  (it maps to a tool named `Agent`) — **do not rename it**, or the Chief Engineer
  silently loses the ability to spawn anyone. Agents that do not declare `Task`
  genuinely cannot delegate: the `reviewer` holds only `Read`+`Bash`, which is why
  read-only means read-only.
- **Guardrail** (`hooks/guard.sh`): all default policy lives in the clearly-labeled
  pattern arrays at the top. A `Bash` command is judged in three tiers (ADR 0008):
  a **read-only fast-path** (`READ_ONLY_CMDS`/`READ_ONLY_GIT`) allows unambiguous
  searches/inspection immediately, so grepping *for* a risky string isn't mistaken
  for running it; **`ASK_BASH_PATTERNS`** (deps, migrations, deploys) returns a
  PreToolUse `permissionDecision:"ask"` for a one-click native prompt; and
  **`DENY_BASH_PATTERNS`** + `BASH_WRITE_PATTERNS` hard-deny (exit 2, matched rule
  on stderr) the irreversible bash surface at every autonomy level. Extend coverage
  in those arrays; the code below them is mechanism. **It fails CLOSED when it
  cannot READ its input (ADR 0021)** — the hook only ever runs for the five
  mutating tools, and every one of those calls carries a command or a path, so an
  empty extraction is a parse failure, never a legitimate absence; the one
  remaining allow-on-ignorance is an entirely empty stdin. That inverts the old
  `[ -z "$CMD" ] && exit 0` behavior, under which any parsing failure silently
  disabled **every** path rule while the guard still blocked simple ASCII bash and
  so looked healthy. Four things keep it readable, and each is load-bearing:
  parsers are probed by **execution, not `command -v`** (Windows `python3` is
  usually the Microsoft Store alias — on PATH, exits 49); the regex fallback
  **decodes JSON escapes** or refuses (an *encoded* `C:\\Users\\…` cannot match a
  pattern written for one separator — and hand-built single-backslash payloads are
  invalid JSON that the broken fallback matched *correctly*, so manual probing
  said "healthy"; build probe payloads with `jq -n`); path matching is
  **separator-normalized** (`(^|/)\.env(\.|$)` had no `/` to bite on in
  `C:\repo\.env`, so the top SECRET rule was inert on Windows *with* a working
  `jq`); and no helper returns non-zero for an absent value, since under
  `set -euo pipefail` that exits 1, which Claude Code reads as a non-blocking
  error — the same fail-open by another road. `hooks/guard.sh --selftest` answers
  "is this guard actually enforcing?" without a live tool call. `jq` is strongly
  recommended but NOT required: stock Git Bash ships neither it nor a real
  `python3`, so a decoding fallback beats bricking the plugin there.
  **Path writes are their own two tiers (ADR 0014):** `SECRET_PATH_PATTERNS`
  (`.env`, key material, secret/credential stores) **hard-deny** — exposure is
  irreversible; `REVIEW_PATH_PATTERNS` (auth *code*, CI/deploy/infra config,
  appsettings) **ask** — reversible and PR-reviewed, so they get a one-click prompt,
  not a dead-end. The auth *directory* rule is constrained to source-code extensions
  so docs under an `auth/` folder don't trip it. Both tiers are enforced for
  `Edit`/`Write` and for shell writes (`cat >`, `sed -i`, `cp`, `tee`, …). A consumer
  repo adds per-project regexes without editing the plugin: `.agents/guard-extra-bash`
  → hard-deny bash tier; `.agents/guard-extra-paths` → **SECRET** hard floor (this is
  how money/PHI risk declared in `.agents/domain-rules.md` becomes an enforced
  hard-deny); `.agents/guard-extra-review` → **REVIEW** ask tier. All are loaded at
  runtime from the discovered config roots. **`bypass-ask-tier: true` in
  `.agents/project-overrides.yaml` (ADR 0015)** makes the guard skip the ASK tier
  entirely — both `ASK_BASH_PATTERNS` and REVIEW-path writes run without a prompt —
  while every hard-deny floor and the git soft gates still enforce. Default false;
  resolved restrictively (every discovered config root must opt in, mirroring the
  autonomy vote), so a nested/foreign `.agents/` can only keep the prompts on.

- **gspec is a pinned, optional dependency behind ONE adapter** (ADR 0020). The seam:
  **gspec owns *what to build and in what order*; this plugin owns *how a unit of work
  is safely executed*** — guardrail, autonomy, checkpointing, isolation, measurement.
  Every gspec read goes through `scripts/gspec-backlog.sh`; **never parse `gspec/`
  anywhere else**, or a format change breaks seven files again (it did — gspec 2.x
  moved `features/<slug>.plan.md` to `tasks/<slug>.md` and nothing checked). The
  consumed contract is exactly: `gspec/tasks/<slug>.md` (task lines + `deps:`),
  `gspec/features/<slug>.md` (capability checkboxes), `.agents/roadmap.yaml`, and —
  fail-soft, outside the pinned contract — `.gspec/build/status.json` for the
  two-drivers interlock. The pin has **two axes** because gspec does not stamp its
  version into a project: the TOOL pin (`GSPEC_PINNED_VERSION`, currently **2.7.0**)
  and the ARTIFACT pin (`spec-version`, asserted by `gspec-backlog.sh check`, which
  fails LOUD). Raising either is deliberate: bump, extend the supported set, re-run
  the sweeps, amend ADR 0020. **gspec is optional** — four and a half of the five
  pillars have no spec dependency, so a backlog may equally come from run-state or an
  explicit argument.
- **Two things are DERIVED and must never be stored** (ADR 0020 D2). Feature
  completion comes from the PRD's capability checkboxes; concurrency comes from
  `packet-graph.sh`. `.agents/roadmap.yaml` carries planning preference only —
  `slug`/`order`/`why` (+ an interim `depends_on` until upstream `U5` lands). It
  lives in `.agents/`, **not** `gspec/`, because gspec's `spec-integrity` floor
  governs every `.md` under `gspec/` and would flag a file gspec does not own.
  gspec's `[P]` marker is **advisory**: it is a model's guess with no isolation
  behind it, so the graph computes file-disjointness itself.
- **File scope comes from `.agents/task-files.yaml`, and every entry is
  fingerprint-guarded** (ADR 0020 `U1-local`). gspec task lines carry no file scope,
  so this sidecar is where `allowed_files` comes from; precedence is plan-authored
  `files:` > fingerprint-matched sidecar > empty. The guard is not ceremony: gspec
  preserves task IDs on regenerate but **re-decomposes unchecked work**, so `T5` can
  keep its id while its text becomes different work — and a stale entry would hand
  two genuinely colliding lanes a *narrow* scope. Mismatched or unfingerprinted
  entries are IGNORED (packet serializes) and reported by `gspec-backlog.sh
  files-status`. Wrong-wide costs parallelism; wrong-narrow costs correctness.
- **The driver claim is a HEARTBEAT, not a pid** (ADR 0020 D5). `status: running`
  alone cannot tell a crashed session from a second session driving right now.
  gspec's pid check does not transfer — its driver is one long-lived node process;
  ours is a Claude session issuing discrete tool calls, so `runstate.sh`'s own `$$`
  is dead the moment the command returns. The loop `claim-driver`s at start and
  `heartbeat`s at each packet boundary; a claim staler than
  `ORCH_DRIVER_STALE_SECS` (900) reads as crashed. `foreign` (another host) is
  never guessed dead. `runstate.sh outcome` is the separate terminal-state answer
  (0 complete · 1 blocked · 2 paused · 3 crashed · 4 running).
- **This plugin ships no general engineering-method skills** (ADR 0020 D7). TDD,
  systematic debugging, and verification-before-completion were removed: testing
  method belongs to the project (`gspec/practices.md`), and the rest is not
  orchestration mechanism. The evidence-before-claims rule survives inline in
  `run-loop` §3.3 and `implementer` — keep it there.

- **Migration reads REAL legacy shapes, and never rewrites them** (`/gaffer:migrate`,
  `scripts/migrate.sh`). Pre-2.0 consumer repos carry plan files this plugin's own
  architect authored, not `/gspec-plan` output, and they use non-canonical task and
  capability lines — `**T000 Description.**`, `**ser-t1** **P0** …`, `**P0 — Text**`.
  The adapter recognizes all of them, because that is what makes migration a safe
  **move**: rewriting task lines would edit **checked** tasks, which gspec's
  immutability floor blocks and which destroys the record of what was built.
  Regeneration via `/gspec-plan` is the supported path, feature by feature, when the
  work next comes up. **A migration is not done when the files have moved — it is
  done when packets come out the other end**, which is why `migrate.sh apply` always
  ends in `verify` and reports a packet count. Measured: a pure rename yielded 0
  packets from 31 real plan files, and an unrecognized *capability* line is worse
  still — the feature can never read as done, so everything depending on it stays
  blocked forever and the backlog quietly reports nothing to do.

## How to test the plugin

```bash
# 1. Validate manifest + structure
claude plugin validate .

# 2. Load locally and reload after edits
claude --plugin-dir .
#   ...then inside the session:  /reload-plugins

# 3. Run the script regression sweeps (exit 0 = all passed; CI runs them on push).
scripts/test-guard.sh          # guardrail allow/deny, closed bypasses, guard-extra
scripts/test-runstate.sh       # pause/resume + crash reconcile (seq + parallel lanes)
scripts/test-packet-graph.sh   # ADR 0016 dependency-graph math (edges, waves, ready)
scripts/test-worktree.sh       # ADR 0016 worktree lane lifecycle + safety gates
scripts/test-pause.sh          # ADR 0017 pause sentinel + hook (from a lane worktree) + ADR 0018 rate-limit sensor
scripts/test-parallel-pause-e2e.sh  # ADR 0017 parallel-pause choreography (real worktree.sh + runstate.sh)
scripts/test-metrics.sh        # ADR 0019 run-metrics: event log -> trailer/wave/token join -> packet, fail-soft
scripts/test-gspec-backlog.sh  # ADR 0020 gspec adapter: version pin, derived completion, nodes, interlock
scripts/test-migrate.sh        # v2.0.0 consumer-repo retrofit: moves, conversion, the packet-count check, and the CLAUDE.md conventions stamp
scripts/test-report-conventions.sh  # ADR 0023 report-format delivery: hook envelope validity, L2-suppresses-L3, fail-open, no drift between the three copies
```

When adding a new risky pattern to `guard.sh`, add a matching allow/deny pair to
`scripts/test-guard.sh` so regressions are caught. Same rule for the other eight
scripts: a behavior worth having is a behavior worth a test in its sweep.

## Ground rules for changes here

- Do not `git commit`/`push` on the user's behalf — they review diffs and commit
  manually. (The guardrail also blocks this.)
- Keep the plugin generic and reusable across any application domain. The
  guardrail's default patterns must stay generic (auth, secrets, migrations,
  deps, deploys, git history) — do NOT add domain-specific patterns (money,
  Plaid, PHI, …) to `hooks/guard.sh`. Those belong in the consumer repo's
  `.agents/guard-extra-bash` / `.agents/guard-extra-paths`.

<!-- gspec:preamble -->
## gspec — Living Specification Sync

This project uses **gspec** for living product specifications stored in `gspec/`.

These specs define what the product is, how it should look, what technology it uses, and what features it supports. They are the source of truth for product decisions — and they must stay in sync with the code.

### Prefer gspec commands over ad-hoc work

Because `gspec/` exists in this project, **route the user's request through the matching `gspec-*` command** instead of producing the equivalent output ad hoc. This applies even when the user's phrasing is casual (e.g. "just build it", "let's code this", "write a quick spec"). Each command runs the right specialist (architect, product, designer, engineer, QA reviewer) with a built-in **quality-review gate** — a separate checker validates the result before it's done (skip with `--no-qa`) — plus the phased execution, checkpointing, and checkbox updates that freeform responses skip.

The `gspec-*` names below are your harness's slash commands / skills, **not shell programs** — never try to execute `gspec-implement` (or any other `gspec-*` name) in the shell; it does not exist as a binary. The only shell CLI is `gspec` itself (`npx gspec`).

Use this mapping whenever the user's intent matches:

- **Building, implementing, coding, scaffolding, shipping, or "making it real"** — invoke `gspec-implement`. This is the most commonly-missed command. If the user asks you to write code for anything the specs describe (or a new capability that should be specced), route through `gspec-implement` rather than editing files directly. Generic prompts like "build it", "go", "keep going", "continue", or "do the next phase" should also invoke it when recent conversation has been about specs or planning. **Exception:** if `.gspec/build/run.json` exists, an autonomous build run is in progress or paused and owns the flow — those same generic prompts mean *resume it* (`gspec build --resume` in the shell), not `gspec-implement`.
- **Building an entire product from an idea, end-to-end and mostly unattended** — run `gspec-build` (`gspec build "<idea>"`), which drives profile → stack → practices → style → features → architecture → plan → implementation, gating each spec through QA and pausing once before implementation for a human spec review (skip with `--no-review`). Best for greenfield "build me X" requests; it generates only the specs that are missing.
- **Defining the product, users, or vision** — invoke `gspec-profile`.
- **Planning or writing a new feature / PRD** — invoke `gspec-feature`.
- **Producing an ordered plan from a feature PRD (with explicit dependencies and parallel-execution markers)** — invoke `gspec-plan`. Run before `gspec-implement` for non-trivial features; when a plan file exists, `gspec-implement` skips its own plan-mode step.
- **Choosing or revising the tech stack** — invoke `gspec-stack`.
- **Defining visual design, tokens, or theme** — invoke `gspec-style`.
- **Setting coding standards, testing, or workflow conventions** — invoke `gspec-practices`.
- **Designing project structure, data model, or API shape** — invoke `gspec-architect`.
- **Researching competitors or finding feature gaps** — invoke `gspec-research`.
- **Finding contradictions between specs** — invoke `gspec-analyze`.
- **Checking specs against the actual codebase (drift audit)** — invoke `gspec-audit`.
- **Checking a spec's quality against its bar** — invoke `gspec-qa` (one spec, or all of them). Every spec-writing command already runs this as a gate when it produces a spec (skip with `--no-qa`); use `gspec-qa` to re-check on demand.
- **Upgrading outdated spec files** — invoke `gspec-migrate`.

If the user explicitly asks you to skip the command and just do the work, honor that — but by default, prefer the command.

### Asking the user multiple questions

When a skill needs feedback on more than one question, first preview all of them as a numbered list so the user knows the full scope, then ask them **one at a time** in the conversation. Never present multiple questions as a single numbered list expecting one combined reply — that forces the user to retype each question number alongside their answer. One question per turn keeps replies short and natural.

### When you make code changes, follow these rules:

> **Apply the project's practices and style as you code.** `gspec/practices.md` (engineering standards, testing philosophy, definition of done) and `gspec/style.md` / `gspec/style.html` (design tokens, component styling) are this project's **coding rules** — follow them on *every* code change, in any flow, not only when running `gspec-implement`. `gspec/stack.md`'s "Technology-Specific Practices" section governs framework idioms. These specs define *how* code is written here; treat them as always-on conventions.

1. **Read the specs first** — Before making non-trivial changes, read the relevant gspec documents to understand existing decisions and constraints. At minimum, scan `gspec/profile.md` and any feature PRDs in `gspec/features/` related to your work.

2. **Spec before you build** — If the user asks for a feature or capability that isn't covered by an existing feature PRD in `gspec/features/`, run the `gspec-feature` command to create a new feature PRD before implementing it. Every feature should be specified before it's built — don't skip straight to code.

3. **Update feature checkboxes** — When you implement a capability defined in a feature PRD (`gspec/features/*.md`), change its checkbox from `- [ ]` to `- [x]`. **If a plan file exists** at `gspec/features/<feature>.plan.md`, also flip the checkbox of each completed task in that file. Only flip the PRD capability checkbox once every task whose `covers:` references it is checked.

4. **Update specs that your changes contradict** — If your code change makes a spec statement incorrect (e.g., you changed the data model, switched a dependency, altered a UI pattern, or added a new API endpoint), update the spec to reflect reality. Common candidates:
   - `gspec/architecture.md` — project structure, data model, API routes, component hierarchy
   - `gspec/stack.md` — dependencies, frameworks, infrastructure
   - `gspec/style.md` **or** `gspec/style.html` — design tokens, component styling, visual conventions (the style guide may be in either format; update whichever exists)
   - `gspec/practices.md` — coding standards, testing conventions, workflows
   - `gspec/profile.md` — product scope, target users, value proposition (rarely changes)

   **The `gspec/design/` folder is read-only to you** — it contains visual mockups (HTML, SVG, PNG, JPG) from external design tools. Do not edit or generate mockups; treat them as authoritative visual guidance to reason through during implementation. Before building or modifying UI for a screen, check whether a matching mockup exists in `gspec/design/` and honor its layout within the style guide's token constraints.

5. **Be surgical** — Change only what is necessary. Preserve the existing voice, structure, and formatting of each spec document. Do not rewrite sections that are still accurate.

6. **Announce spec updates** — When you update a spec, briefly mention what changed and why in your response. Never silently modify specs.

7. **Preserve version metadata** — Markdown gspec files use YAML frontmatter with a `spec-version` field. `gspec/style.html` uses a first-line HTML comment in the form `<!-- spec-version: v1 -->` before the `<!DOCTYPE html>`. Preserve either format when editing. If a file lacks the version marker, leave it as-is.

8. **Don't create new foundation specs** — Only update existing spec files. If you believe a new spec document is needed, suggest it to the user rather than creating it yourself.

<!-- gspec:preamble -->

## Scope override for the gspec preamble above

The block between the `<!-- gspec:preamble -->` markers is **written by the gspec
installer, not by this repo**, and it is re-stamped on every `npx gspec@<pin>
--target claude`. Never edit inside it — corrections go here, outside the markers,
or they are silently lost on the next install.

It is correct about specs and **wrong about execution in this repo**, because it
is written for a generic consumer that does not have this plugin. ADR 0020 draws
the seam: **gspec owns _what to build and in what order_; this plugin owns _how a
unit of work is safely executed_** — guardrail, autonomy levels, checkpointing,
worktree isolation, measurement. The preamble's routing advice claims that second
half for gspec. In this repo:

- **`gspec-implement` and `gspec-build` are NOT the execution path.** Execution is
  `/gaffer:run-loop` (and `/gaffer:resume`), which runs packets through the guard,
  the autonomy gates, and run-state checkpointing. `gspec-build` in particular
  drives profile → … → implementation unattended, which would bypass every one of
  those. The adapter's `interlock` subcommand exists precisely because two drivers
  must not run at once.
- **`gspec-plan` and `gspec-feature` ARE the right tools**, and are how the four
  deferred features get decomposed when their time comes.
- **`gspec-plan` must not be run against `gspec/tasks/run-metrics.md`.** It is a
  retro-spec of shipped work with every task checked; regeneration re-decomposes
  unchecked work and would destroy the record it exists to hold.
- **Ignore the preamble's "read the specs first" list where it names files this
  repo does not have.** `gspec/profile.md`, `stack.md`, `practices.md` and
  `style.md` are not present — this repo's equivalents are this file, the ADRs,
  and the regression sweeps. Do not generate them to satisfy the preamble.

The gspec hooks now installed under `.claude/hooks/` (spec-integrity, task-
immutability, practices-enforce, …) are registered in `.claude/settings.json` and
compose with — they do not replace — the plugin's own `hooks/guard.sh`. Both fire;
the guard's hard-deny floor is unaffected. Note that `task-immutability` will
refuse edits to the checked tasks in `gspec/tasks/run-metrics.md`, which is the
behaviour we want.
