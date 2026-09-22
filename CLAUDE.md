# CLAUDE.md — for developing the `gaffer` plugin itself

> ⚠️ **This file does not propagate.** A plugin's root `CLAUDE.md` is **not**
> loaded as context in consumer repos. Nothing you write here
> reaches the agents when the plugin is installed elsewhere. Reusable operating
> instructions must live in the **agent** (`agents/*.md`) and **skill**
> (`skills/*/SKILL.md`) prompts instead. Treat this file as notes for a human
> (or Claude) working *inside this repo*.

This file holds **rules**; reasoning and evidence live in the ADRs (`docs/adr/`) and
PRDs each rule points to. Append new evidence there, not here.

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
**forward-only, plus one retro-spec**; shipped ADRs are deliberately not retro-specced.

- **The one retro-spec is `run-metrics`** (ADR 0019). All its capabilities and tasks
  are checked, so it yields zero packets and reads as derived-done. Never run
  `/gspec-plan` against it (see the scope override at the end).
- **Known gaps of a shipped feature are a SEPARATE feature** (e.g.
  `metrics-coverage-gaps`), never an unchecked capability on the shipped one —
  completion is derived from checkboxes, so a folded-in gap makes the shipped feature
  read incomplete and blocks everything downstream of it.
- **A specced feature with no `tasks.md` is the intended state for deferred work**
  (the adapter reports `PLAN=none` plus the `/gspec-plan` hint); decompose when the
  work comes up. Same for a folder with no `arch.md` or `design.html` — this repo
  ships no UI, so `design.html` is correct to be absent everywhere.
- **Reflexivity: the loop edits what it runs from.** `scripts/*.sh` and hook bodies
  take effect **mid-run, on the next call**; `agents/*.md` and `skills/*/SKILL.md` at
  the next dispatch. A packet weakening `hooks/guard.sh` is live on the next matching
  call. `.agents/guard-extra-review` names this surface for the ASK tier
  (`self-host-hardening`), pinned by `test-guard.sh`.
- **Do not move `hooks/guard.sh`, `.agents/guard-extra-*` or `project-overrides.yaml`
  into `.agents/guard-extra-paths`** — this repo develops them.
- **Load timing:** `guard.sh` re-reads `project-overrides.yaml` and
  `.agents/guard-extra-*` on **every tool call**; only hook *registration*
  (`hooks/hooks.json`, `.claude/settings.json`) needs a session boundary.

## Conventions

### Components

- **Agents** (`agents/*.md`): YAML frontmatter with `name`, `description`, `tools`,
  `model`. Keep `tools` least-privilege (the reviewer has no Edit/Write on purpose).
  Each file carries a comment mapping it to the model routing intent: opus =
  reasoning/architecture/review/security, sonnet = implementation and research, haiku
  = the summarizer/doc agent (`doc-writer`).
- **Skills** (`skills/<name>/SKILL.md`): frontmatter with `name`, `description`,
  `argument-hint`. Reference shared files via `${CLAUDE_PLUGIN_ROOT}/...`.
- **Two harness facts that are easy to break** (ADR 0012, findings 2–4): a dispatched
  agent has **no `Skill` tool**, so a brief gives the SKILL.md **path** to `Read`, never
  the slash command; and `Task` in agent frontmatter is what **grants** delegation (it
  maps to a tool named `Agent`) — **do not rename it**. Agents without `Task` cannot
  delegate; the `reviewer` holds only `Read`+`Bash`.
- **The "structured tools, not the shell" block is a preference**; only its write half
  (`sed -i`, `cat >`) is a real control. Add no cost claim without a cost measurement —
  a frequency count is not one (ADR 0019 v3.3 §2).
- **All seven agents carry a "do not re-read what you already have" block — the rule
  only, never the evidence** (evidence: ADR 0019, "Relocated from CLAUDE.md").
- **This plugin ships no general engineering-method skills** (ADR 0020 D7). The
  evidence-before-claims rule survives inline in `run-loop` §3.3 and `implementer` —
  keep it there.

### Retired features (one line each; the reasoning is in the ADRs)

- **Relay mode** — retired (ADR 0012, `retire-unused-loop-modes` T4, 2026-09-15);
  `--relay`/`--inline` still accepted as a no-op.
- **Parallel mode** — retired (ADR 0016, `retire-unused-loop-modes` T2, 2026-09-15);
  `--parallel` still accepted as a no-op. Still live: schema-3 `lanes:`/`mode:
  parallel` run-state is **read-only compatibility**: `resume` stops on it and reports
  its lanes via `runstate.sh lanes`, with no auto-migration; nothing may write it again. Concurrency is loop-driver guidance
  (`agents/chief-engineer.md` Concurrency); never use a worktree for a loop packet.
- **Rate-limit auto-pause** — retired (ADR 0018, `retire-unused-loop-modes` T2,
  2026-09-15). `/gaffer:migrate` cleans up a leftover `rate_limit_pause:` block or stale
  `statusLine` entry only with operator confirmation, never touching a foreign
  `statusLine`.
- **Autonomy levels** — retired (`retire-autonomy-levels`, 2026-09-20; ADR 0004/0006
  in part). One guard rule set; a stricter mode is specced fresh, never by restoring
  the ladder. `/gaffer:migrate` removes `.agents/autonomy`/`autonomy_ceiling` and only
  *reports* level mentions in a consumer's own files.

### Pause (ADR 0017)

- The request is the sentinel `.agents/pause` (main checkout, found via `git rev-parse
  --git-common-dir`), never run-state; run-state records only `status: paused`.
- The **prompt-poll (`pause-status`) is the only guaranteed stop**, at safe boundaries.
  `hooks/pause-check.sh` is best-effort advisory — **never describe pause as automatic
  via the hook**.

### Run-metrics (ADR 0019 — read its revision sections before touching the collector)

- Hooks (`metrics-log.sh`, `metrics-skill.sh`) **print nothing and always exit 0**;
  they cannot emit a `permissionDecision`.
- **No full command text or file path is ever logged** — Bash is reduced to a
  `cmd_class` head, files to a 12-char hash; the packet must stay safe to paste.
- **`jq -r` output consumed by `read` goes through `tr -d '\r'`**; scalar captures use
  `jqr` (only MSYS bash strips the CR). Keep the CRLF-shim byte-identical test, shim in
  `awk`, not `sed`.
- **Dedupe transcript tokens by `message.id`** (earliest row); keep rows without one.
- **`null` means unmeasured, never 0** — `show` must not render it as 0.
- Trailers: **own-line only**, **author date**, scan **bounded at both ends** (knob
  `ORCH_METRICS_TRAILER_GRACE`).
- **`outcome` is attested or `null`**, via `record-start`/`record-outcome`
  (append-only outcomes log, never run-state). **`interrupted` has one writer,
  `sweep-open`.**
- Dispatch passes `routing.sh resolve <agent>`'s output as `model` (empty = omit).
- Machine-wide spend lives in `scripts/spend.sh`. `.agents/metrics/` is gitignored in
  both `.gitignore`s.

### Run-state and findings (ADR 0022, 0024, 0025; `runstate-write-integrity*` PRDs)

- **Every agent-supplied value in run-state is hostile input**; mutate it only through
  `runstate.sh`, never by hand.
- **Quote every value written; no plain-scalar allowlist** (re-adding one is a
  regression). The reader strips symmetrically — `cmd_get`'s strip is load-bearing.
  **One decode rule** serves every read path (`_yaml_decode_value`, awk `rs_decode`,
  the deliberate copy in `hooks/pause-check.sh`); the shared fixture table in
  `test-runstate.sh` is the anti-drift mechanism. Everything works with `jq`/`python3`
  absent.
- **`write` validates structurally and keeps `.agents/run-state-prev.yaml`** (no
  shrinkage guard). **`set` refuses a key it cannot address at column 0** and writes
  nothing; absent keys append. Refusal, not YAML path addressing — keep it so.
- Summaries are **single-quoted with `'` doubled**; interpolate with **`awk ENVIRON`,
  never `awk -v`**; id checks are block-scoped and literal. `trim-note` (literal block
  scalar) is a backstop only. Parse assertions in `test-runstate.sh` must skip
  **loudly** without PyYAML.
- **Findings: index hot, body cold** (`.agents/findings/<id>.md` + one index line).
  "Should be built/fixed" → gspec, never a finding; gotcha/decision/resolved question →
  finding; "where we stopped" → `note:`. Every whole-file `write` carries `findings:`
  through. A Chief Engineer with no run-state of its own returns `Findings:` lines
  instead of calling `add-finding`.
- **Findings expire on positive evidence only** (`--packets` mandatory; checkbox or
  trailer, actually read); absence from `pending` blocks expiry. Capture precedes drop.
- **The gspec checkbox is the completion record** (`backlog.done` is gone; `pending`
  stays — it is a decision). `check-task` flips it inside the packet commit
  (`CHECKED=none` = skipped; exit 4 = drift, report, do not halt).
  `complete-capabilities` flips only fully-covered capabilities and never unflips.
- The tally's ✅ counts this session, except the stop report (§B: the whole run).
- **A probe that does not reproduce the phenomenon cannot eliminate a cause** (the
  `trim-note` SIGPIPE flake, `runstate-write-integrity` tasks).

### Post-completion findings (ADR 0026)

- **Arm 1:** an incomplete feature with an unchecked task and an unchecked capability
  covering the finding → append one unchecked task (truthful `covers:`); never modify
  existing lines or capability checkboxes.
- **Arm 2** (everything else) **always ends at a question for the operator; no agent
  ever files the feature.**
- A task-immutability rejection means the edit was wrong — never bypass it or patch
  the vendored hook. `-gaps` features do not stack.

### Driver mode (ADR 0028, ADR 0029)

- **Refusal rule:** `guard.sh` refuses main-thread edits and recognised shell writes
  when **all three** hold: the session has a mark (`.agents/driver-mode/<session-id>`,
  only via `runstate.sh driver-mode`), the payload has **no `agent_id`**, and the
  target is outside `.agents/`. **Never branch on `agent_type`** — a `claude --agent`
  main thread carries it (same trap in `metrics-log.sh`).
- Validate the session id before using it as a path. The check sits **after the secret
  floor, before the ask tier**, is a `deny()` (`bypass-ask-tier` does not skip it),
  **refuses unjudgeable targets**, and names driver mode and `/gaffer:pause`.
- **Both `.gitignore`s ignore** `.agents/loop/`, `.agents/driver-mode/`,
  `.agents/run-state-prev.yaml` and findings bodies — untracked is not enough.
- **Routing, driver-mode and decision records have their own logs, never the outcomes
  log** — `_rs_open_packets` reads any `packet`+`kind` record there as a boundary.
- `route` enforces the retry limit (`packet_attempts`), not the decider.
  **`write-result` is how read-only agents stay read-only** — never grant them
  `Edit`/`Write`.
- **`templates/handoff-required.md` is the one home of the verification contract**
  (appended by `runstate.sh handoff`); nothing else restates its lines.
- **`check-status` runs before any write**; the driver never substitutes a status line.
- **A packet-close `write` must carry** `schema`, `run_id`, `branch`, every `driver_*`
  key, `status`, `pending_questions` and `findings:` from the on-disk file (`run-loop`
  §3.6).
- **`end-of-run-review` is a fixed non-packet id**, recorded before `run-tally` is read;
  never record an outcome for it.
- The decider's authority is a closed list (`agents/chief-engineer.md` §Escalation
  decider, §Periodic review).
- **A plugin cannot supply `autoCompactWindow`**; add no `SOURCE` branch without a named
  provenance.
- A run that edits driver mode runs the old contract; the change lands next run.

### Reports (ADR 0023)

- Split by reader: `status-line.md` (loop agents), `check-in.md` (Chief Engineer
  outside a packet), `report-conventions.md` (every human report), `report-templates.md`
  (the loop's shapes), `report-conventions-card.md` (the source L2 and L3 copy).
- **Deliver the contract (`Read` it), never just name a path**; scope by role and need.
- **L2 suppresses L3**; **never describe L3 (the hook) as enforcing the format.**
- Driver-mode reports come from `run-digest` plus status lines already read.
- **Scope is reports, not responses.** Glyphs and ⚠️ (blocked) vs 🔀 (waiting on you)
  are fixed; no decorative section markers, no tables, no bare ids.

### gspec adapter and migration (ADR 0020)

- **Every gspec read goes through `scripts/gspec-backlog.sh`; never parse `gspec/`
  anywhere else.** `runstate.sh` never reads `gspec/`.
- Consumed contract: plan task lines + `deps:`; PRD capability checkboxes and their
  criteria sub-bullets (for `handoff` only); the `arch.md`/`design.html` sections a
  task's anchors name; `.agents/roadmap.yaml`; fail-soft `.gspec/build/status.json`.
- **Completion is derived from the checkbox alone**, never stored; `covers:` matches
  verbatim (unmatched → `UNMATCHED=`).
- Paths resolve in one place each (`_resolve_*_path`); all three layouts (3.x folder,
  2.x, pre-2.0) are read, newer shadows older. **Trap:** in 3.x the slug is the
  *directory* — `basename <path> .md` yields `prd`/`tasks` for every feature.
- **Two pin axes:** tool pin `GSPEC_PINNED_VERSION` (`gspec-backlog.sh pin`) and
  artifact pin `spec-version` (`check`, fails loud; accepts `v1` and `v2` — do not
  narrow). The pin catches unparseable formats; it is not a migration nudge.
- **Runbook: `docs/gspec-migration.md`** (agent path: `skills/migrate/SKILL.md` §2b);
  neither restates the pinned version, and `test-migrate.sh` asserts that.
- **The 3.x relocation is `/gspec-migrate`'s move, never `/gaffer:migrate`'s**; install
  the pinned gspec first.
- **Migration never rewrites legacy task/capability shapes**; it is done when packets
  come out (`apply` ends in `verify`). Zero packets from an all-checked plan is
  complete; the failure is zero *readable* task lines (counted as `_nodes_for` counts).
- `.agents/roadmap.yaml` (planning preference only) lives in `.agents/`, not `gspec/`.
  `[P]` is advisory.
- **File scope: `.agents/task-files.yaml`, fingerprint-guarded** (plan `files:` >
  matched sidecar > empty; mismatches ignored, reported by `files-status`).
- **The driver claim is a heartbeat, not a pid** (D5; knob `ORCH_DRIVER_STALE_SECS`);
  `foreign` is never guessed dead.

### Guardrail (`hooks/guard.sh`; ADR 0008, 0014, 0015, 0021)

- All default policy lives in the labelled pattern arrays at the top; extend coverage
  there. Bash tiers: read-only fast-path → `ASK_BASH_PATTERNS` (ask) →
  `DENY_BASH_PATTERNS` + `BASH_WRITE_PATTERNS` (hard deny, exit 2).
- **It fails closed on unreadable input** (ADR 0021): probe parsers by execution, not
  `command -v`; the fallback decodes JSON escapes or refuses; paths are
  separator-normalized; no helper returns non-zero for an absent value. Build probe
  payloads with `jq -n`; `guard.sh --selftest` answers "is it enforcing?".
- Path writes: `SECRET_PATH_PATTERNS` deny, `REVIEW_PATH_PATTERNS` ask (auth-directory
  rule limited to source extensions), for `Edit`/`Write` and shell writes alike.
  Per-repo: `.agents/guard-extra-bash` (deny), `-paths` (secret floor), `-review` (ask).
- **`bypass-ask-tier`** (ADR 0015) skips only the ask tier and resolves restrictively
  (every config root must opt in).
- **Git:** commit/merge/rebase/push allowed off `main`/`master`; touching
  `main`/`master`, `--amend`, forced/interactive rewrites and commits staging a secret
  path are denied. Releases and PRs are the human's by convention and branch protection.

## How to test the plugin

```bash
# 1. Validate manifest + structure
claude plugin validate .

# 2. Load locally and reload after edits
claude --plugin-dir .
#   ...then inside the session:  /reload-plugins

# 3. Run the script regression sweeps (exit 0 = all passed; CI runs them on push).
scripts/test-guard.sh          # guardrail allow/deny, closed bypasses, guard-extra
scripts/test-runstate.sh       # pause/resume + crash reconcile (sequential; a legacy
                                # mode: parallel run-state still parses read-only)
scripts/test-pause.sh          # ADR 0017 pause sentinel + hook (from a generic worktree)
scripts/test-metrics.sh        # ADR 0019 run-metrics: event log -> trailer/token join -> packet, fail-soft
scripts/test-spend.sh          # ADR 0019 v3.5 spend: machine-wide transcript dedup, pricing, timestamp handling
scripts/test-gspec-backlog.sh  # ADR 0020 gspec adapter: version pin, derived completion, nodes, interlock
scripts/test-migrate.sh        # consumer-repo retrofit: moves, conversion, retired-mode cleanup,
                                # the packet-count check, and the CLAUDE.md conventions stamp
scripts/test-report-conventions.sh  # ADR 0023 report-format delivery: hook envelope validity, L2-suppresses-L3, fail-open, no drift between the three copies
scripts/test-routing.sh        # per-agent-model-routing lookup: resolve/validate/table, every fallback and report reason, VALID_MODELS pin
```

When adding a new risky pattern to `guard.sh`, add a matching allow/deny pair to
`scripts/test-guard.sh` so regressions are caught. Same rule for the other
scripts: a behavior worth having is a behavior worth a test in its sweep.

## Ground rules for changes here

- **Commit, push, and merge onto `orch/*` and `develop` are ALLOWED** — that is the
  loop's own checkpoint mechanism (`run-loop` §3.4); a resume has nothing to adopt
  without per-packet green commits (ADR 0005). Every packet commit carries its
  `[orch packet:<id>]` trailer. **`main`/`master`, releases, PRs and deploys stay the
  human's hard gate** — `hooks/guard.sh` enforces that floor and `test-guard.sh` pins it.
  This file is read by the harness's auto-mode classifier, so a prohibition written
  here is obeyed as a standing instruction — word rules here accordingly.
- Keep the plugin generic and reusable across any application domain. The
  guardrail's default patterns must stay generic (auth, secrets, migrations,
  deps, deploys, git history) — do NOT add domain-specific patterns (money,
  Plaid, PHI, …) to `hooks/guard.sh`. Those belong in the consumer repo's
  `.agents/guard-extra-bash` / `.agents/guard-extra-paths`.
- **Config state lives only in its config file.** Name a setting's key, never its
  current value or a code default, anywhere in prose.

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

3. **Update feature checkboxes** — When you implement a capability defined in a feature PRD (`gspec/features/<slug>/prd.md`), change its checkbox from `- [ ]` to `- [x]`. **If a plan file exists** at `gspec/features/<slug>/tasks.md`, also flip the checkbox of each completed task in that file. Only flip the PRD capability checkbox once every task whose `covers:` references it is checked. A project that has not yet run `/gspec-migrate` keeps these one level up, as `gspec/features/<slug>.md` and `gspec/tasks/<slug>.md` — read whichever layout is on disk, and never create a second copy in the other one.

4. **Update specs that your changes contradict** — If your code change makes a spec statement incorrect (e.g., you changed the data model, switched a dependency, altered a UI pattern, or added a new API endpoint), update the spec to reflect reality. Common candidates:
   - `gspec/architecture.md` — project structure, data model, API routes, component hierarchy
   - `gspec/stack.md` — dependencies, frameworks, infrastructure
   - `gspec/style.md` **or** `gspec/style.html` — design tokens, component styling, visual conventions (the style guide may be in either format; update whichever exists)
   - `gspec/practices.md` — coding standards, testing conventions, workflows
   - `gspec/profile.md` — product scope, target users, value proposition (rarely changes)

   **The `gspec/design/` folder is read-only to you** — it contains visual mockups (HTML, SVG, PNG, JPG) from external design tools. Do not edit or generate mockups; treat them as authoritative visual guidance to reason through during implementation. Before building or modifying UI for a screen, check whether a matching mockup exists in `gspec/design/` and honor its layout within the style guide's token constraints.

5. **Be surgical** — Change only what is necessary. Preserve the existing voice, structure, and formatting of each spec document. Do not rewrite sections that are still accurate.

6. **Announce spec updates** — When you update a spec, briefly mention what changed and why in your response. Never silently modify specs.

7. **Preserve version metadata** — Markdown gspec files use YAML frontmatter with a `spec-version` field. `gspec/style.html` uses a first-line HTML comment in the form `<!-- spec-version: v2 -->` before the `<!DOCTYPE html>`. Preserve either format when editing. If a file lacks the version marker, leave it as-is.

8. **Don't create new foundation specs** — Only update existing spec files. If you believe a new spec document is needed, suggest it to the user rather than creating it yourself.

<!-- gspec:preamble -->

## Scope override for the gspec preamble above

The block between the `<!-- gspec:preamble -->` markers is **written by the gspec
installer, not by this repo**, and it is re-stamped on every `npx gspec@<pin>
--target claude`. Never edit inside it — corrections go here, outside the markers,
or they are silently lost on the next install.

It is correct about specs and **wrong about execution in this repo**: ADR 0020's seam
gives gspec *what to build and in what order*, and this plugin *how a unit of work is
safely executed*. In this repo:

- **`gspec-implement` and `gspec-build` are NOT the execution path.** Execution is
  `/gaffer:run-loop` (and `/gaffer:resume`), which runs packets through the guard,
  its fixed git gates, and run-state checkpointing. `gspec-build` would bypass all of
  those; the adapter's `interlock` exists because two drivers must not run at once.
- **`gspec-plan` and `gspec-feature` ARE the right tools** for decomposing and
  specifying features.
- **`gspec-plan` must not be run against `gspec/features/run-metrics/tasks.md`** — a
  retro-spec with every task checked; regeneration would destroy the record.
- **Ignore the preamble's "read the specs first" list where it names files this repo
  does not have** (`profile.md`, `stack.md`, `practices.md`, `style.md`). This repo's
  equivalents are this file, the ADRs, and the sweeps. Do not generate them.

The gspec hooks under `.claude/hooks/` (spec-integrity, task-immutability,
practices-enforce, …) are registered in `.claude/settings.json` and compose with —
not replace — `hooks/guard.sh`. `task-immutability` refusing edits to checked tasks
is the behaviour we want.

**Three path references under `gspec/` still name pre-3.x locations, and they are
correct as they stand** — each sits inside a CHECKED block (a checked task in
`self-host-hardening-gaps/tasks.md`, and acceptance criteria under checked capabilities
in `runstate-write-integrity` and `self-host-hardening-gaps`). They record where a file
*was* when the work happened; do not "tidy" them.
