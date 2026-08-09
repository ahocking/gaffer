# gaffer

A reusable **Claude Code plugin** that installs a small orchestration layer into
any application repo: a coordinated subagent team, workflow chains, a
task-packet template, a **single-checkout feature-branch workflow** (a `develop`
integration branch with `orch/*` packet branches), a **graduated autonomy dial**
with a pausable/resumable guided loop, an MCP config, and an
**approval guardrail hook** that gates the risks common to *any* codebase (auth,
secrets, DB schema/migrations, dependency installs, deploys, and git history).
Domain-specific risk (money movement, PHI, grading, …) is not baked in — each
repo declares its own in `.agents/guard-extra-paths` / `.agents/guard-extra-bash`.

It is a portable "global orchestration layer":
you act as technical lead and the agents handle research, architecture,
implementation, testing, and review — with a human approval gate on anything
risky, and (when you opt in) unattended commits of routine green work on a
feature branch. Built generic and reusable for any kind of application; the
first consumer repo is a .NET / React / Postgres app.

## Spec-driven development with gspec

**[gspec](https://github.com/gballer77/gspec)** (MIT, © Baller Software) is the
spec-driven development tool this plugin targets. `/gaffer:new-project` installs it
(`npx gspec@2.7.0 --target claude`), `/gaffer:migrate` retrofits older repos onto its
current layout, and the guided loop's default backlog is the gspec one:
`gspec/tasks/<slug>.md` task lines (with `deps:`) plus `gspec/features/<slug>.md`
capability checkboxes.

The seam is deliberate ([ADR 0020](docs/adr/0020-gspec-boundary-and-version-pin.md)):
**gspec owns *what to build and in what order*; gaffer owns *how a unit of work is
safely executed*** — guardrail, autonomy, branch isolation, checkpointing, and
measurement. Every gspec read goes through the single adapter
`scripts/gspec-backlog.sh`; nothing else in the plugin parses `gspec/`, so an upstream
format change lands in one file. Because gspec does not stamp its version into a
project, the pin has two axes: the **tool** pin (`GSPEC_PINNED_VERSION`, currently
**2.7.0**) and the **artifact** pin (`spec-version`, asserted by
`gspec-backlog.sh check`, which fails loudly rather than guessing).

**gspec is optional.** Four and a half of the five pillars — the guardrail, the
autonomy dial, the pause/resume checkpointing, worktree-isolated parallelism, and
run-metrics — have no spec dependency at all. A backlog may equally come from
`.agents/run-state.yaml` or from an explicit argument to `/gaffer:run-loop`, and a repo
with no `gspec/` directory loses only the spec-derived backlog, not the execution
layer.

## Components

| Path | What it is |
| --- | --- |
| `.claude-plugin/plugin.json` | Plugin manifest (name, version, author). |
| `agents/chief-engineer.md` | **opus** orchestrator: interprets intent, routes work, delegates, gates risk, owns routine commits above `interactive`. |
| `agents/architect.md` | **opus** read-mostly design authority and spec author; writes design/spec prose under `docs/**`, `adr/**`, and any doc/spec paths the repo declares in `.agents/project-overrides.yaml` (`allowed_paths.docs`/`.specs`, e.g. `gspec/**`) — never code; flags security/auth/financial concerns. |
| `agents/ux-designer.md` | **opus** visual/UX design specialist; iterates against the rendered UI via a **context-adaptive** preview loop — a web DOM preview or a live Unity Editor (via the Unity MCP), selected by `ux.preview_mode` in `.agents/project-overrides.yaml` (auto-detected, **web** default; ADR 0010) — and researches comparable products; writes presentation only under `allowed_paths.frontend` + `.agents/ux-references.md` + `.claude/launch.json` (web). Opt-in for repos with a user-facing surface. |
| `agents/reviewer.md` | **opus** read-only reviewer: diff vs acceptance criteria, spec↔code drift, security. |
| `agents/implementer.md` | **sonnet** scoped code writer; escalates on auth/schema/secrets and any domain risk the repo declares in `.agents/domain-rules.md`. |
| `agents/researcher.md` | **sonnet** read-only investigator; researches libraries/APIs, compares options, sweeps in-repo context, and returns a compact cited brief — offloads retrieval so the opus reasoners' context stays clean. Never edits. |
| `agents/doc-writer.md` | **haiku** documentation/summarization agent; writes README/setup/usage docs and changelog-style summaries from established fact under `allowed_paths.docs`. Never touches code, tests, ADRs, or design decisions. |
| `skills/new-project/SKILL.md` | Chain: bootstrap a spec-driven repo — generic overlay + **version-pinned** gspec + a seeded `.agents/roadmap.yaml` — stops before the initial commit. |
| `skills/review-change/SKILL.md` | Chain: review uncommitted changes → ready/issues/risks/next-step. |
| `skills/run-loop/SKILL.md` | The guided loop: drive a backlog of packets — isolate, implement→test→review, commit on branch if green, check in, repeat (ADR 0004). Runs **inline** on a small backlog, or **relays** one dispatch per packet on a big one (≥ 20 packets — ADR 0012). |
| `skills/pause/SKILL.md` | Pause the loop at a safe checkpoint: roll to the last green commit, persist run-state, emit a check-in, stop. |
| `skills/resume/SKILL.md` | Resume a run from `.agents/run-state.yaml` in a fresh session; picks relay vs inline from what **remains** (ADR 0012). |
| `skills/set-autonomy/SKILL.md` | Show or set the autonomy level in-session by writing `.agents/autonomy` — the Desktop-native equivalent of `ORCH_AUTONOMY=… claude` (ADR 0004). |
| `skills/rate-limit-pause/SKILL.md` | Show or set rate-limit auto-pause (ADR 0018): `on` wires the status-line sensor into `settings.json` + enables it here; `off` disables per-repo; `off --teardown` removes the global sensor; `status` reports state. |
| `skills/build-packet-dependency-tree/SKILL.md` | Build `.agents/packet-graph.yaml` — packet nodes from the gspec backlog, ordering edges from task deps, mutual-exclusion edges from computed `allowed_files` overlap, grouped into waves. Prerequisite for `--parallel` (ADR 0016). |
| `skills/migrate/SKILL.md` | Retrofit a consumer repo from an older plugin layout to the current one: move plans to `gspec/tasks/`, convert `gspec/roadmap.md` → `.agents/roadmap.yaml`, stamp missing spec frontmatter, then **verify the backlog actually parses**. |
| `skills/metrics/SKILL.md` | Assemble / show / analyze a run-metrics packet (ADR 0019): where a run's compute went, per packet, agent, model, tool, and skill. |
| `scripts/migrate.sh` | Deterministic half of `/gaffer:migrate`: detect / plan / apply / verify. Refuses a dirty tree, never deletes, never overwrites, and ends by counting packets. |
| `scripts/gspec-backlog.sh` | **The one place this plugin reads gspec** (ADR 0020): version-pin assertion, derived feature completion, next-feature selection, packet nodes, the two-drivers interlock, and the fingerprint-guarded file-scope sidecar. Nothing else may parse `gspec/`. |
| `templates/task-packet.yaml` | Fillable contract handed to a specialist agent (includes the packet `autonomy` level). |
| `templates/run-state.yaml` | Schema for the durable `.agents/run-state.yaml` checkpoint file. |
| `templates/check-in.md` | The two check-in shapes the loop emits: status update, severity-tagged blocking question. |
| `templates/spec-driven-base/` | The stack-agnostic overlay `new-project` copies into a fresh repo. |
| `hooks/hooks.json` + `hooks/guard.sh` | PreToolUse guardrail: hard-denies high-risk actions; autonomy-aware soft gates for `git commit` (≥ supervised) and `git merge`/`rebase`/`push` onto non-`main` (full-autonomy). |
| `hooks/session-start.sh` | SessionStart hook: on reopen, surfaces an in-flight guided run (crash-safe resume, ADR 0005). |
| `hooks/report-conventions.sh` | SessionStart hook: injects the report-format card so reports follow the house format without being asked each session — silent when the repo's own `CLAUDE.md` already carries it (ADR 0023). Advisory, never enforcement. |
| `scripts/runstate.sh` | Durable run-state I/O (atomic writes) + the crash-recovery `reconcile` decision. |
| `scripts/statusline-pause-sensor.sh` | A `statusLine` command that reads the 5-hour + 7-day usage percentages and arms the ADR 0017 pause sentinel when either crosses its threshold (ADR 0018). Opt-in, Pro/Max only. |
| `.mcp.json` | Stubbed git / github / filesystem MCP servers (tokens via env vars only). |

### Model routing intent

- **opus** — reasoning, architecture, security, review (`chief-engineer`, `architect`, `ux-designer`, `reviewer`).
- **sonnet** — narrow implementation (`implementer`) and retrieval-heavy research (`researcher`).
- **haiku** — summarization / documentation (`doc-writer`).

### The guardrail

`hooks/guard.sh` runs before every `Bash`/`Edit`/`Write` call and judges it in
**three tiers** (ADR 0008): a read-only fast-path allows, an *ask* tier prompts,
and a hard-deny tier blocks.

**Read-only fast-path — allowed immediately (exit 0):** a `Bash` command whose every
pipeline segment leads with a whitelisted read-only tool (`grep`/`rg`/`ls`/`cat`/
`find` without `-delete`, read-only `git` subcommands, …) and that contains no
redirection/command-substitution/statement-separator is allowed before any denylist
runs — so `rg "npm install"`, `git log --grep="rm -rf"`, and `gcloud … --format`
are searches, not denials. Purely additive: anything not clearly read-only is judged
as before.

**Ask tier — routine-but-notable (`permissionDecision:"ask"`):** dependency
installs/upgrades, DB migrations (EF/flyway/alembic/prisma), and deploys (docker/
kubectl/terraform/fly/vercel/cloud CLIs) surface Claude Code's native one-click
approval instead of a dead end. An *ask* is never auto-approved by autonomy — an
unattended loop still stops at the prompt.

**Hard gates — denied at every autonomy level (exit 2, matched rule on stderr):**

- **Irreversible Bash:** git history destruction — `force`-push/`reset --hard`/
  `clean -f`/`--amend`/interactive rebase (including `git -C … ` and `git -c … `
  forms) — plus destructive fs ops (`rm -rf`, `find -delete`, raw-device writes).
  **Commit/merge/push to `main`/`master`** stays here too.
- **Sensitive-path writes:** auth/authz, secrets, `.env`, credentials, and
  CI/deploy config — blocked both via the `Edit`/`Write` tools **and** via shell
  writes (`cat >`, `sed -i`, `cp`, `mv`, `tee`) that target those paths. These are
  the generic defaults; a repo adds its own domain paths (e.g. money/banking for a
  financial app) via `.agents/guard-extra-paths` (appended to the hard-deny tier)
  without editing the plugin.

**Soft gates — autonomy-aware git (ADR 0004 / 0006).** `git commit` is allowed when
**all** hold: the resolved level is ≥ `supervised`, the branch is not `main`/`master`,
and the staged diff touches no sensitive path. **At `full-autonomy` only,
`git merge` / `rebase` / `push` are likewise allowed** — but only onto a **non-`main`**
target, never forced, and a merge carrying a sensitive path re-escalates. Anything
else denies with an explanation and fails **closed** on any error (not a repo,
detached HEAD, unreadable diff). At the default `interactive` level every commit
still requires the human — the conservative posture is opt-out, not opt-in.

Everything else is allowed (exit 0). The built-in patterns live in labeled arrays
(`DENY_BASH_PATTERNS`, `ASK_BASH_PATTERNS`, `BASH_WRITE_PATTERNS`,
`SENSITIVE_PATH_PATTERNS`) at the top of `guard.sh` — **edit there to extend
coverage.** (It gates *writes* to sensitive paths, not *reads*.)

**It fails closed when it cannot read its input (ADR 0021).** The hook runs only
for the five mutating tools, and each of those calls carries a command or a path
— so if the payload cannot be parsed, the call is **denied** (`payload-unreadable`)
rather than allowed. Previously a parsing failure silently disabled every path
rule while the guard kept blocking simple ASCII bash, so it still looked healthy.
`jq` is **strongly recommended** — install it and this never comes up. It is not
required (stock Git Bash ships neither `jq` nor a real `python3`, so there is a
decoding regex fallback), but note that on Windows `python3` is usually the
Microsoft Store alias: on `PATH`, not a parser. To check a guard's health at any
time, without a live tool call:

```bash
"$CLAUDE_PLUGIN_ROOT/hooks/guard.sh" --selftest
```

It reports the parser in use and proves a JSON-escaped Windows path still matches
the rules. Exit 0 = enforcing; exit 1 = it would deny everything until a parser is
on `PATH`.

**Per-project rules without editing the plugin.** A consumer repo can add its own
regexes in `.agents/guard-extra-bash` and `.agents/guard-extra-paths` (one
`grep -E` regex per line, `#` comments allowed). The hook loads them from the
repo at runtime and appends them to its arrays, so risk **declared** in
`.agents/domain-rules.md` becomes risk **enforced** by the hook. The template
ships commented example files.

## Autonomy & the guided loop

The autonomy level decides how much the Chief Engineer may do without you
(ADR 0004 / 0006). Resolution order: env **`ORCH_AUTONOMY`** → **`.agents/autonomy`**
→ default **`interactive`** — then clamped down to `autonomy_ceiling:` in
`.agents/project-overrides.yaml` if the repo sets one.

*Which* `.agents/` is consulted is not simply "the repo you are in" (ADR 0011). The
guard walks up from both `CLAUDE_PROJECT_DIR` and the shell's cwd, collecting every
ancestor that declares an `.agents/` directory — so a command run from a
subdirectory, a submodule, or a package cache still finds the project's rules. When
that walk finds more than one root, they are merged **restrictively**: the
**lowest** autonomy any root declares wins, the lowest `autonomy_ceiling` clamps,
and `guard-extra-*` patterns are **unioned**. Adding a root can only tighten the
guard, never loosen it — so ambiguity fails closed by construction.

| Level | What it means |
| --- | --- |
| `interactive` (default) | Human approves every mutation gate — the original block-everything posture. |
| `supervised` | The Chief Engineer commits routine green work on a feature branch itself; checks in between packets. |
| `autonomous` | Same, and it drives across the whole backlog without stopping between green landings. |
| `full-autonomy` | Same, **plus** merge/rebase/push onto **non-`main`** branches — the loop integrates feature branches into the integration branch and pushes them for CI on its own. |

Hard gates (commit/merge/push to **`main`**, migrations, secrets, deploys,
dependency installs, sensitive paths, history rewrite) require the human at
**every** level, including `full-autonomy`. Below `full-autonomy` the loop stops at
"branch ready for review"; at `full-autonomy` it integrates onto a non-`main` branch
and stops at "ready for the human to release." **Merging to `main`, releasing, and
opening a PR are never automated.**

A semi-attended run looks like:

```bash
cd ~/workspace/your-app
ORCH_AUTONOMY=supervised claude
#   ...then inside the session:
#   /gaffer:run-loop        # drive the backlog (gspec/tasks/<slug>.md or run-state)
#   /gaffer:pause           # stop at a safe green checkpoint, any time
#   /gaffer:resume          # pick the run back up in a later session
```

### How the loop runs: inline or relayed (ADR 0012)

`run-loop` and `resume` count the backlog first and pick how to execute it. You do
not have to choose, and the mode is announced in one line before the run starts.

| Backlog | Mode | Why |
| --- | --- | --- |
| **< 20 packets** | **inline** — the session runs the loop itself | Relaying costs ~29% more tokens and ~40% more wall clock at this size and prevents nothing. |
| **≥ 20 packets** | **relay** — a fresh Chief Engineer is dispatched per packet; the session only relays each check-in | Past the measured crossover the relay is *both* cheaper (~27% at 33 packets, ~50% at 52) **and** the only mode that finishes: an inline coordinator grows ~6.7k tokens/packet and hits a forced, lossy compaction near packet ~28. |

Override either way with **`--relay`** or **`--inline`**:

```bash
/gaffer:run-loop --relay     # flat context cost, even on a short backlog
/gaffer:run-loop --inline    # cheapest per packet; also for debugging the loop
```

`resume` counts what **remains**, not the run's original size — a 40-packet run with
4 left is a small backlog now and finishes inline.

**20 is a measured crossover, not a preference**, and it was measured on small
packets — heavier packets grow the coordinator faster and move the real crossover
down. See [ADR 0012](docs/adr/0012-delegated-loop-driver.md) for the method, the
numbers, and what would change them.

**Setting autonomy on Claude Desktop (no terminal).** The `ORCH_AUTONOMY=… claude`
form above is terminal-only — the Desktop app launches from Finder/Dock and
cannot take an inline env var. Two Desktop-native ways to set the level instead:

- **In-session:** run **`/gaffer:set-autonomy supervised`** (or
  `interactive` / `autonomous`, or no argument to just show the current level). It
  writes the repo's `.agents/autonomy` and reports the effective level after any
  `autonomy_ceiling` clamp. This is the direct equivalent of the env-var launch.
- **Persistently, per project:** add `"env": { "ORCH_AUTONOMY": "supervised" }` to
  the repo's `.claude/settings.json`. Claude Code injects it into the session
  environment, and the guard already reads `ORCH_AUTONOMY` first — so this works
  with no plugin change, and env still wins over the file.

Note this only affects the *soft* commit gate: a commit to **main**/master is a
hard gate and always requires you to run it yourself, at every autonomy level —
raising autonomy does not change that.

Each packet runs on its own feature branch (`orch/<task-id>`) in the single local
checkout ([ADR 0009](docs/adr/0009-single-directory-feature-branch-workflow.md) —
no worktrees), cut from the integration branch (`.agents/project-overrides.yaml`
→ `integration_branch`, default `develop`). It lands as a green commit tagged
`[orch packet:<cursor>]` and advances the durable checkpoint in
`.agents/run-state.yaml` (gitignored local bookkeeping, written atomically via
`scripts/runstate.sh`). Closing the laptop is safe: a clean pause persists state
and sets any scratch aside with `git stash`, and even a crash mid-loop is
recovered — the SessionStart hook surfaces the in-flight run when you reopen
Claude, and `runstate.sh reconcile` adopts or discards whatever the crash left
behind (ADR 0005). Check-ins are **produced** by the plugin and **delivered** by
the frontend (Claude Desktop / Dispatch) — there is no notification transport
here (ADR 0003).

### Auto-pause before a usage limit (ADR 0018)

A long unattended run — especially a wide `--parallel` one — can exhaust the
account's **rolling usage limits** (a fast **5-hour** window and a slower, costlier
**7-day/weekly** one) mid-flight. When either trips, Claude Code stops serving
responses **server-side**, and a lane blocked on that cutoff is stranded on a
mid-edit tree — exactly the loss the cooperative pause exists to avoid. This feature
**sees the limit coming and drains to a green checkpoint first.**

The catch is *sensing* it: the usage percentages are delivered to **exactly one
place** — the `statusLine` command's stdin JSON (`rate_limits.five_hour` /
`.seven_day`), only after the first API response and only on **Pro/Max**. No hook
payload carries them and nothing persists them to disk. So the plugin ships a
`statusLine` **sensor** (`scripts/statusline-pause-sensor.sh`): it renders the
percentages *and*, when either window crosses its threshold, writes the **same
`.agents/pause` sentinel** a human would — after which it is the ordinary ADR 0017
cooperative pause, byte-for-byte (the prompt-poll is still the authoritative stop).

Turn it on with the toggle skill — it resolves the installed sensor path and wires
`settings.json` for you (a plugin cannot, and `${CLAUDE_PLUGIN_ROOT}` does **not**
expand in the `statusLine` context, so the entry needs a resolved absolute path):

```bash
/gaffer:rate-limit-pause on      # wire settings.json + enable here
/gaffer:rate-limit-pause status  # what's wired + effective thresholds
/gaffer:rate-limit-pause off     # per-repo disable (status line stays)
/gaffer:rate-limit-pause off --teardown   # also remove the GLOBAL sensor
```

Thresholds default to **5-hour 90% / 7-day 85%** (the weekly one lower on purpose —
exhausting the 7-day window strands the account for *days*, not the couple of hours a
5-hour reset costs). Configure per repo in `.agents/project-overrides.yaml` under
`rate_limit_pause:`, with an `ORCH_RATE_PAUSE` / `ORCH_RATE_PAUSE_PCT` /
`ORCH_RATE_PAUSE_7D_PCT` env fast-path. It is **best-effort early-warning, not a hard
stop**: both cutoffs are server-side; if one outruns the drain, crash-reconcile
`restart` is still the floor (which is why packets are commit-sized). Under API-key
auth there is no `rate_limits` payload and the sensor is inert. See
[ADR 0018](docs/adr/0018-rate-limit-aware-cooperative-pause.md).

### Measuring runs (ADR 0019)

To find where a run — especially a wide `--parallel` one — spends its compute, the
plugin captures a **run-metrics packet**: one self-contained
`.agents/metrics/<run-id>/run-metrics.json` per run, built to be read by a human or
**handed to Claude for optimization advice**. Collection is automatic and costs zero
tokens: a `PostToolUse` hook logs tool events (metadata + low-sensitivity labels —
per-tool `duration_ms`, the running skill, the dispatched `subagent_type`, and a Bash
command **head** only; never full command text, arguments, or paths) as the run goes,
and `scripts/metrics.sh collect` joins that event spine with
packet boundaries derived from the `[orch packet:<id>]` commit trailers, the
`packet-graph.yaml` wave map, and best-effort token/cost from the session transcripts:

```bash
/gaffer:metrics collect   # assemble the packet for the current run
/gaffer:metrics show      # per-role tokens, cache-hit ratio, per-packet table
/gaffer:metrics status    # is metrics on? which sources are present?
/gaffer:metrics analyze   # hand the packet to Claude for ranked optimization advice
```

The packet surfaces the loop's real levers — **cache-hit ratio** (cacheRead vs
cacheCreation, the biggest hidden cost when subagents re-load context), **per-role,
per-packet, per-skill, and per-command-class spend** (which skill/process costs most,
and which commands dump the most output — the "where an output filter like RTK helps"
map), **model-per-agent** (so opus/sonnet/haiku tokens are cost-comparable), per-tool
**duration**, an **active/idle wall split**, and **per-wave parallel efficiency**. Tokens come from the
transcripts by default (a **version-fragile** source, so the collector **fails soft** to
structural-only and stamps `token_source` — a partial run is never misread as complete);
**Tier 0 OpenTelemetry** is an optional, deferred richer source, not required. Enable/
disable and retention live in `.agents/project-overrides.yaml` under `metrics:` (env
fast-path `ORCH_METRICS=off`). `.agents/metrics/` is gitignored bookkeeping — archive a
run by copying its `run-metrics.json` out. See
[ADR 0019](docs/adr/0019-run-metrics-observability.md).

**Tests.** `scripts/test-guard.sh` is the guardrail regression sweep (allow/deny
pairs for every category, the closed cross-tree bypasses, the autonomy×branch×diff
commit matrix, and the `guard-extra` loading); run it after any change to
`guard.sh`. `scripts/test-runstate.sh` is the pause/resume + crash-recovery sweep
(the reconcile decision table, atomic writes, the SessionStart hook; ADR
0004/0005/0009); `scripts/test-pause.sh` covers the cooperative-pause sentinel/hook
(ADR 0017) **and the rate-limit sensor's threshold/reason/idempotency/YAML-config
behavior** (ADR 0018) — run it after any change to `runstate.sh`, `pause-check.sh`,
`statusline-pause-sensor.sh`, or the loop skills. `scripts/test-metrics.sh` covers
the run-metrics core (ADR 0019) — the event-log → trailer/wave/token join, fail-soft
to structural-only, the skill/command-class/duration enrichment and its head-only
command classifier (leak-tested), and the logger hook's no-`permissionDecision`
contract — against a synthetic git repo and fake transcripts (no live agent). CI runs
them on every push.

## Develop it (working on the plugin itself)

```bash
git clone https://github.com/ahocking/gaffer.git
cd gaffer

# Start Claude Code with this directory loaded as a plugin
claude --plugin-dir .

# Inside the session, after editing plugin files:
/reload-plugins

# Validate the manifest & structure
claude plugin validate .
```

Try it out inside the session:

- Skills are **namespaced by plugin**: `/gaffer:new-project`,
  `/gaffer:review-change`, `/gaffer:run-loop`,
  `/gaffer:pause`, `/gaffer:resume`, `/gaffer:set-autonomy`,
  `/gaffer:rate-limit-pause`, `/gaffer:metrics`,
  `/gaffer:build-packet-dependency-tree`.
- Agents appear as `chief-engineer`, `architect`, `ux-designer`, `reviewer`,
  `implementer` (delegate to them via the Task tool or let a skill drive them).
- To sanity-check the guardrail directly:

  ```bash
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push"}}' \
    | hooks/guard.sh; echo "exit=$?"   # expect exit=2 + a GUARDRAIL message
  ```

## Install it

**A. Marketplace (recommended).** Add this repo as a plugin marketplace source,
then install by name. Installs at user scope by default, so it is available in
every repo:

```bash
claude plugin marketplace add ahocking/gaffer
claude plugin install gaffer@gaffer-marketplace
```

Restart Claude Code afterwards — plugins and hooks bind at session start. Pull
updates later with `claude plugin update gaffer@gaffer-marketplace`.

**B. Direct dir load (quick, per-session, no install).** Clone it anywhere and
point a session at it:

```bash
git clone https://github.com/ahocking/gaffer.git
claude --plugin-dir /path/to/gaffer
```

**C. From a local clone as a marketplace.** Useful if you are modifying the
plugin — `marketplace add` accepts a path as well as a GitHub repo:

```bash
claude plugin marketplace add /path/to/gaffer
claude plugin install gaffer@gaffer-marketplace
```

Either way, the consumer repo keeps its own specs, ADRs, source, and tests; this
plugin supplies the reusable agents, chains, template, and guardrail on top. The
guardrail's generic defaults (auth, secrets, `appsettings`, CI/deploy) already
match a typical app; a financial app's money/banking-specific paths are declared
per-repo in `.agents/guard-extra-paths` (see `.agents/domain-rules.md`), not in the
plugin.

> **Note:** a plugin's own `README.md` and root `CLAUDE.md` are **not** loaded as
> context in a consumer repo. All reusable operating instructions therefore live
> in the agent and skill prompts, not here. This README and `CLAUDE.md` are for
> humans developing the plugin.

## Attribution

**[gspec](https://github.com/gballer77/gspec)** — MIT, © Baller Software — is the
spec-driven development tool this plugin targets. It is an independent upstream
project: gaffer neither vendors nor forks any of its code or text, and installs it
(`npx gspec@<pinned> --target claude`) as a normal dependency of `/gaffer:new-project`.
The credit is offered because gaffer's backlog model — features, PRD capability
checkboxes, task lines with `deps:` — is gspec's design, and this plugin's job of
*executing* a backlog only makes sense on top of someone else's answer to *what to
build and in what order*. See
[Spec-driven development with gspec](#spec-driven-development-with-gspec) and
[ADR 0020](docs/adr/0020-gspec-boundary-and-version-pin.md).

## License

This project is licensed under the [MIT License](LICENSE) (© 2026 Arron Hocking).
Third-party tools it integrates with are noted under [Attribution](#attribution) and
carry their own licenses.

## Secrets

Nothing in this plugin requires your Anthropic API key — the agents run inside
Claude Code under your Claude Max subscription. The only credential referenced
is an optional **GitHub** PAT for the `github` MCP server, read from
`GITHUB_PERSONAL_ACCESS_TOKEN`. Never hardcode tokens; `.env` is gitignored.
