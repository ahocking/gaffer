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

## Conventions

- **Agents** (`agents/*.md`): YAML frontmatter with `name`, `description`,
  `tools`, `model`. Keep `tools` least-privilege (the reviewer has no
  Edit/Write on purpose). Each file carries a comment mapping it to the model
  routing intent: opus = reasoning/architecture/review/security, sonnet =
  implementation and research, haiku = the summarizer/doc agent (`doc-writer`).
- **Skills** (`skills/<name>/SKILL.md`): frontmatter with `name`, `description`,
  `argument-hint`. Reference shared files via `${CLAUDE_PLUGIN_ROOT}/...`.
- **The loop skills choose relay vs inline by backlog size** (`run-loop`, `resume`
  — ADR 0012): **≥ 20 packets** → dispatch a fresh `chief-engineer` per packet and
  relay its check-in verbatim (context stays flat; ~27–50% cheaper on the 33- and
  52-packet backlogs real repos actually carry); **< 20** → run it inline (the
  relay costs ~29% more there and prevents nothing). `--relay`/`--inline` override.
  **20 is a measured crossover, not a taste** — if you change the brief or
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
- **Search/edit tool selection is a measured cost, and it lives in the agent prompts**
  (ADR 0019 v3). All seven `agents/*.md` carry a "structured tools, not the shell"
  section: `Grep`/`Glob`/`Read` to search and read, `Edit`/`Write` to change, `Bash` only
  for builds, tests, git, and running the project. This is not style — two production
  repos logged **0** `Grep`/`Glob` calls against 1,568 shell `grep`s, 258 `find`s and 496
  `sed`s in ~6k tool calls. Shell search dumps unbounded output into context where `Grep`
  bounds it (`output_mode`/`head_limit`), and `sed -i`/`cat >` edits bypass diff review
  and the guard's path tiers — which is exactly why `guard.sh` must pattern-match them as
  a write surface. It has to live in the **agent** prompts: this file does not propagate,
  and every one of these agents is granted `Grep, Glob` already — the grant was never the
  problem. Keep the block when editing an agent, and add it to any new one.
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
scripts/test-migrate.sh        # v2.0.0 consumer-repo retrofit: moves, conversion, and the packet-count check
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
