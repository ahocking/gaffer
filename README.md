# gaffer

A reusable **Claude Code plugin** that installs a small orchestration layer into
any application repo: a coordinated subagent team, workflow chains, a
task-packet template, a **single-checkout feature-branch workflow** (a `develop`
integration branch with `orch/*` packet branches), a **pausable/resumable guided
loop**, an MCP config, and an
**approval guardrail hook** that gates the risks common to *any* codebase (auth,
secrets, DB schema/migrations, dependency installs, deploys, and git history).
Domain-specific risk (money movement, PHI, grading, …) is not baked in — each
repo declares its own in `.agents/guard-extra-paths` / `.agents/guard-extra-bash`.

It is a portable "global orchestration layer":
you act as technical lead and the agents handle research, architecture,
implementation, testing, and review — with a human approval gate on anything
risky, and unattended commits of routine green work on a feature branch. Built generic and reusable for any kind of application; the
first consumer repo is a .NET / React / Postgres app.

## Spec-driven development with gspec

**[gspec](https://github.com/gballer77/gspec)** (MIT, © Baller Software) is the
spec-driven development tool this plugin targets. `/gaffer:new-project` installs it
(`npx gspec@3.1.1 --target claude`), `/gaffer:migrate` retrofits older repos onto its
current layout, and the guided loop's default backlog is the gspec one: a feature's
`tasks.md` task lines (with `deps:`) plus its `prd.md` capability checkboxes.

gspec 3.x keeps everything about a feature in one folder —
`gspec/features/<slug>/` holding `prd.md`, `tasks.md`, and (written by
`/gspec-architect`, not by migration) `arch.md` and `design.html`. The adapter also
reads the two older layouts, because a consumer repo migrates on its own schedule
and an adapter that knew only the current path would report an **empty backlog**
rather than an error.

The seam is deliberate ([ADR 0020](docs/adr/0020-gspec-boundary-and-version-pin.md)):
**gspec owns *what to build and in what order*; gaffer owns *how a unit of work is
safely executed*** — guardrail, branch isolation, checkpointing, and
measurement. Every gspec read goes through the single adapter
`scripts/gspec-backlog.sh`; nothing else in the plugin parses `gspec/`, so an upstream
format change lands in one file. Because gspec does not stamp its version into a
project, the pin has two axes: the **tool** pin (`GSPEC_PINNED_VERSION`, currently
**3.1.1**) and the **artifact** pin (`spec-version`, asserted by
`gspec-backlog.sh check`, which fails loudly rather than guessing). The artifact
pin accepts **`v1` and `v2`** on purpose — narrowing it to the current version
would stop the loop on a repo whose backlog the adapter reads perfectly well. The
pin exists to catch a format the code *cannot parse*, not to nag a repo into
migrating.

**gspec is optional.** The guardrail, the pause/resume checkpointing, and
run-metrics have no spec dependency at all. A backlog may
equally come from `.agents/run-state.yaml` or from an explicit argument to
`/gaffer:run-loop`, and a repo with no `gspec/` directory loses only the
spec-derived backlog, not the execution layer. (A fifth pillar,
worktree-isolated parallelism under `--parallel`, existed here too — ADR 0016 —
but is retired; see `retire-unused-loop-modes`.)

## Components

| Path | What it is |
| --- | --- |
| `.claude-plugin/plugin.json` | Plugin manifest (name, version, author). |
| `agents/loop-driver.md` | **inherit** — the role the session *driving* the loop takes (ADR 0028). Passes paths, reads one status line per agent, never opens a result file, routes every verdict through `runstate.sh route`. Declares no `tools:` restriction, so `claude --agent gaffer:loop-driver` keeps `Task`/`Bash`/`Read` for the run and `Edit`/`Write` for after the stop report. |
| `agents/chief-engineer.md` | **opus** orchestrator: interprets intent, routes work, delegates, gates risk, owns routine commits on non-`main` branches. Also the **interim stand-in escalation decider** the loop dispatches on `ACTION=decider`, until `escalation-decider` ships. |
| `agents/architect.md` | **opus** read-mostly design authority and spec author; writes design/spec prose under `docs/**`, `adr/**`, and any doc/spec paths the repo declares in `.agents/project-overrides.yaml` (`allowed_paths.docs`/`.specs`, e.g. `gspec/**`) — never code; flags security/auth/financial concerns. |
| `agents/ux-designer.md` | **opus** visual/UX design specialist; iterates against the rendered UI via a **context-adaptive** preview loop — a web DOM preview or a live Unity Editor (via the Unity MCP), selected by `ux.preview_mode` in `.agents/project-overrides.yaml` (auto-detected, **web** default; ADR 0010) — and researches comparable products; writes presentation only under `allowed_paths.frontend` + `.agents/ux-references.md` + `.claude/launch.json` (web). Opt-in for repos with a user-facing surface. |
| `agents/reviewer.md` | **opus** read-only reviewer: diff vs acceptance criteria, spec↔code drift, security. Returns one of three verdicts on exclusive triggers — `pass` / `fix` / `escalate` — which is what the loop routes on. |
| `agents/implementer.md` | **sonnet** scoped code writer; escalates on auth/schema/secrets and any domain risk the repo declares in `.agents/domain-rules.md`. |
| `agents/researcher.md` | **sonnet** read-only investigator; researches libraries/APIs, compares options, sweeps in-repo context, and returns a compact cited brief — offloads retrieval so the opus reasoners' context stays clean. Never edits. |
| `agents/doc-writer.md` | **haiku** documentation/summarization agent; writes README/setup/usage docs and changelog-style summaries from established fact under `allowed_paths.docs`. Never touches code, tests, ADRs, or design decisions. |
| `skills/new-project/SKILL.md` | Chain: bootstrap a spec-driven repo — generic overlay + **version-pinned** gspec + a seeded `.agents/roadmap.yaml` — stops before the initial commit. |
| `skills/review-change/SKILL.md` | Chain: review uncommitted changes → ready/issues/risks/next-step. |
| `skills/run-loop/SKILL.md` | The guided loop: drive a backlog of packets — isolate, implement→test→review, commit on branch if green, check in, repeat (ADR 0004). One sequential mode; backlog size no longer switches execution modes (ADR 0012, superseded). The session running it is in **driver mode** (ADR 0028) — it dispatches rather than edits, and no packet is implemented inline. |
| `skills/pause/SKILL.md` | Pause the loop at a safe checkpoint: roll to the last green commit, persist run-state, emit a check-in, stop. |
| `skills/resume/SKILL.md` | Resume a run from `.agents/run-state.yaml` in a fresh session, from wherever it left off. |
| `skills/migrate/SKILL.md` | Retrofit a consumer repo from an older plugin layout to the current one, and sequence the upgrade to pinned gspec: convert `gspec/roadmap.md` → `.agents/roadmap.yaml`, stamp missing spec frontmatter, order the gspec 3.x relocation (which `/gspec-migrate` performs, not this), clean up the retired parallel-mode/rate-limit-pause footprint, then **verify the backlog actually parses**. |
| `skills/metrics/SKILL.md` | Assemble / show / analyze a run-metrics packet (ADR 0019): where a run's compute went, per packet, agent, model, tool, and skill. |
| `scripts/migrate.sh` | Deterministic half of `/gaffer:migrate`: detect / plan / apply / verify. Refuses a dirty tree, never deletes, never overwrites, and ends by counting packets. |
| `scripts/gspec-backlog.sh` | **The one place this plugin reads gspec** (ADR 0020): version-pin assertion, derived feature completion, next-feature selection, packet nodes, the two-drivers interlock, the fingerprint-guarded file-scope sidecar, and `handoff` — a packet's whole brief, including the acceptance criteria its `covers:` names. Nothing else may parse `gspec/`. |
| `templates/task-packet.yaml` | Fillable contract handed to a specialist agent. |
| `templates/run-state.yaml` | Schema for the durable `.agents/run-state.yaml` checkpoint file. |
| `templates/status-line.md` | The one line every loop-dispatched agent returns (ADR 0028): status · what changed · whether the result file needs reading · its path. The same line opens the result file. |
| `templates/check-in.md` | The two check-in shapes — status update, severity-tagged blocking question. **The loop no longer uses them** (ADR 0028); they are for a Chief Engineer dispatched for self-contained work outside a loop packet. |
| `templates/spec-driven-base/` | The stack-agnostic overlay `new-project` copies into a fresh repo. |
| `hooks/hooks.json` + `hooks/guard.sh` | PreToolUse guardrail: hard-denies high-risk actions; refuses a driver-mode session's own main-thread writes outside `.agents/` (ADR 0028); one fixed set of git gates — `git commit` on a non-`main` branch with no secret path staged, and `git merge`/`rebase`/`push` onto a non-`main` target, never forced — with everything onto `main`/`master` denied. |
| `hooks/session-start.sh` | SessionStart hook: on reopen, surfaces an in-flight guided run (crash-safe resume, ADR 0005), and clears the reopened session's own driver-mode mark. |
| `hooks/driver-mode-compact.sh` | SessionStart hook on `compact` only: if the compacted session still holds a driver-mode mark, points it back at `agents/loop-driver.md` so it keeps driving (ADR 0028). Silent otherwise. |
| `hooks/report-conventions.sh` | SessionStart hook: injects the report-format card so reports follow the house format without being asked each session — silent when the repo's own `CLAUDE.md` already carries it (ADR 0023). Advisory, never enforcement. |
| `scripts/runstate.sh` | Durable run-state I/O (atomic writes) + the crash-recovery `reconcile` decision. Also the driver-mode core (ADR 0028): `driver-mode`, `begin-run`, `handoff`, `write-result`, `route`, `run-digest`, `periodic-pause`, `compact-threshold`. |
| `scripts/report-lint.sh` | Checks a rendered stop report or kickoff against the `run-digest` it was rendered from: `--shape <B\|C> <report> <digest>` prints `REPORT_LINT=clean`, `findings` with one `FINDING=` per broken mechanical rule, or `unjudged` with a `REASON=`. Glyph vocabulary and section order are derived from `templates/report-conventions.md`. Writes nothing and always exits 0. A clean result means no mechanical rule was broken, not that the report is good. |
| `.mcp.json` | Stubbed git / github / filesystem MCP servers (tokens via env vars only). |

### Model routing intent

- **opus** — reasoning, architecture, security, review (`chief-engineer`, `architect`, `ux-designer`, `reviewer`).
- **sonnet** — narrow implementation (`implementer`) and retrieval-heavy research (`researcher`).
- **haiku** — summarization / documentation (`doc-writer`).
- **inherit** — `loop-driver`, which is not dispatched but *adopted* by the session
  already running the loop, so it runs on whatever model that session runs on.

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
approval instead of a dead end. An unattended loop still stops at the prompt.

**Hard gates — always denied (exit 2, matched rule on stderr):**

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

**Driver-mode writes — the one rule keyed to *who* is calling (ADR 0028).** While a
session is driving the loop, the guard refuses that session's **own main-thread**
`Edit`/`Write`/`MultiEdit`/`NotebookEdit` and the shell write forms it recognises,
unless the target is under `.agents/`. The refusal names driver mode as the reason and
`/gaffer:pause` as the way out. Its subagents are unaffected, and so are `git`, gaffer's
own scripts, and any command with no recognised write form. It is checked **after** the
secret floor and **before** the ask tier, and it is a hard deny — `bypass-ask-tier` does
not skip it. See ["Driver mode"](#driver-mode-the-loop-session-stops-editing-adr-0028)
below for what it is for.

**Soft gates — one fixed git rule set (ADR 0004 / 0006, levels retired).** `git commit`
is allowed when **both** hold: the branch is not `main`/`master`, and the staged diff
(plus what `-a` sweeps in) touches no sensitive path. **`git merge` / `rebase` / `push`
are likewise allowed** — but only onto a **non-`main`** target, never forced or
interactive, and a merge carrying a sensitive path re-escalates. Anything else denies
with an explanation and fails **closed** on any error (not a repo, detached HEAD,
unreadable diff). The same rules apply in every repository and every session; there
is no level to set and nothing to opt into (`retire-autonomy-levels`).

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

## The guided loop

What the Chief Engineer may do without you is the same in every repository and
every session (ADR 0004 / 0006, whose level definitions are superseded in part by
`retire-autonomy-levels`): it commits routine green work on a feature branch, and
the loop merges, rebases and pushes onto **non-`main`** branches — integrating
feature branches into the integration branch and pushing them for CI on its own.
There is no level to set — the levels and the controls that selected them are
retired (`retire-autonomy-levels`), and `/gaffer:migrate` removes their leftovers
from a consumer repo.

*Which* `.agents/` is consulted is not simply "the repo you are in" (ADR 0011). The
guard walks up from both `CLAUDE_PROJECT_DIR` and the shell's cwd, collecting every
ancestor that declares an `.agents/` directory — so a command run from a
subdirectory, a submodule, or a package cache still finds the project's rules. When
that walk finds more than one root, they are merged **restrictively**:
`guard-extra-*` patterns are **unioned**, and `bypass-ask-tier` applies only when
every root opts in. Adding a root can only tighten the guard, never loosen it — so
ambiguity fails closed by construction.

Hard gates (commit/merge/push to **`main`**, migrations, secrets, deploys,
dependency installs, sensitive paths, history rewrite) always require the human.
The loop integrates onto a non-`main` branch and stops at "ready for the human to
release." **Merging to `main`, releasing, and opening a PR are never automated.**

A semi-attended run looks like:

```bash
cd ~/workspace/your-app
claude
#   ...then inside the session:
#   /gaffer:run-loop        # drive the backlog (gspec features or run-state)
#   /gaffer:pause           # stop at a safe green checkpoint, any time
#   /gaffer:resume          # pick the run back up in a later session
```

### The loop runs one sequential mode (ADR 0012, superseded)

`run-loop` and `resume` run a single sequential mode — backlog size no longer
switches execution modes, and no run dispatches a per-packet coordinator
subagent. `--relay`/`--inline`/`--parallel` are still accepted on the command
line for compatibility; they print a one-line notice that the mode they name is
retired and the loop runs its one mode regardless.

> **On the numbers, why relay was retired rather than kept as an option:** the
> one real production comparison (62 packets across two repos) measured relay at
> **1.84x inline per packet** — the opposite direction from the token
> extrapolation that originally set its 20-packet crossover (later raised to
> 40). The regime relay was built for was **never reached**: the largest real
> run observed across this repo's own history is **9–14 packets**, well under
> even the original threshold. This is a scope decision, not a retraction of
> that measurement — see [ADR 0012](docs/adr/0012-delegated-loop-driver.md) for
> the full record, including the v2 measurement revision.

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
behind (ADR 0005). Loop reports are **produced** by the plugin and **delivered** by
the frontend (Claude Desktop / Dispatch) — there is no notification transport
here.

### Driver mode: the loop session stops editing (ADR 0028)

The most expensive context in a long run is the session **driving** it, not the agents
it dispatches — everything the driver reads is re-cached on every later turn for the
rest of the run. So while `/gaffer:run-loop` or `/gaffer:resume` is running, that
session takes the `loop-driver` role: it passes **paths**, reads **one status line** per
agent, and never opens a result file.

**The mark and the refusal.** Entering driver mode writes a file —
`.agents/driver-mode/<session-id>`, managed only by `runstate.sh driver-mode`. Its
existence is the whole signal. While it is there, the guard refuses that session's own
main-thread writes outside `.agents/` (above). It is keyed to **one session**: it never
blocks another, a subagent's writes are never refused, and a mark left behind by a
session that crashed blocks nothing — it names an id nothing will reuse, and reopening
that session clears it. Compaction keeps it, and a compacted session is pointed back at
its driver instructions. The way out is a **pause**: `/gaffer:pause` ends the run at a
green checkpoint and hands the keyboard back.

**What the driver reads instead of the repo.** Each packet gets a **handoff file** under
`.agents/loop/<run_id>/<packet-id>/` — its task text, its file scope, and the acceptance
criteria its `covers:` names, assembled by `gspec-backlog.sh handoff`. Every dispatched
agent takes that path as its whole brief, writes its detail to a **result file** through
`runstate.sh write-result` (which refuses any path outside the run directory), and
returns a single line: `<status> · <what changed> · result: <needs-reading|no> ·
<path>`. Because the result files are written by a *script*, the read-only agents stayed
read-only — the reviewer, researcher and chief-engineer gained no `Edit` or `Write` tool.

**Routing is mechanical.** The reviewer returns `pass`, `fix` or `escalate` on exclusive
triggers, and `runstate.sh route` — not a judgment call — turns that into an action,
logging every decision to `.agents/loop/<run_id>/routing.jsonl`:

| Verdict / decision | Action |
| --- | --- |
| `pass` | **land** — commit the packet green |
| `fix` | **attempt** a fresh agent while attempts remain, else **decider** |
| `retry` | **attempt** while attempts remain; past the limit it is refused as a **stop**, never looped |
| `escalate` | **decider** |
| `reorder`, `append-task`, `hand-off-feature` | **discard-advance** — roll back to the last green checkpoint and move on |
| `ask-operator` | **stop** |

Attempts count `fix` and `retry` together since the packet's latest start, against
`packet_attempts` in `.agents/project-overrides.yaml` (default **1**). **There is no
escalation decider agent yet:** on `decider` the driver dispatches the `chief-engineer`
as an **interim stand-in**, which decides with its existing judgment and returns one of
the five decisions above. A planned `escalation-decider` feature replaces that section
of `agents/chief-engineer.md` and the single dispatch line in the loop skill.

**Run directories are per run and pruned.** `runstate.sh begin-run` mints a `run_id`
into run-state once — a resume keeps it, so a run spans sessions — and keeps the current
run's directory plus the newest previous one, removing older ones. Human-facing reports
are assembled from `runstate.sh run-digest` over those files, so a stop report is
correct even in a session that resumed someone else's run or has compacted since it
started.

**Two lines your repo needs.** Add both to the consumer repo's `.gitignore`:

```
.agents/driver-mode/
.agents/loop/
```

Unignored, a pause's `git stash --include-untracked` sweeps the run's own files and
`reconcile` reads them as scratch to discard. `/gaffer:migrate` reports a repo missing
either entry.

### Auto-pause before a usage limit (ADR 0018, superseded)

The plugin used to ship a `statusLine` sensor that watched Claude Code's rolling
5-hour/7-day usage percentages and armed a pause before either limit hit. It
never worked reliably in practice and is retired: the sensor script, the
`/gaffer:rate-limit-pause` toggle skill, and the `rate_limit_pause:` overrides
block are all deleted. The cooperative whole-run pause it amended is
unaffected — `/gaffer:pause` and `/gaffer:resume` still work exactly as
described above. `/gaffer:migrate` cleans up a leftover `rate_limit_pause:`
block or a stale `statusLine` entry in a repo that had adopted it. See
[ADR 0018](docs/adr/0018-rate-limit-aware-cooperative-pause.md) for the
historical record.

### Measuring runs (ADR 0019)

To find where a run spends its compute, the
plugin captures a **run-metrics packet**: one self-contained
`.agents/metrics/<run-id>/run-metrics.json` per run, built to be read by a human or
**handed to Claude for optimization advice**. Collection is automatic and costs zero
tokens: a `PostToolUse` hook logs tool events (metadata + low-sensitivity labels —
per-tool `duration_ms`, the running skill, the dispatched `subagent_type`, and a Bash
command **head** only; never full command text, arguments, or paths) as the run goes,
and `scripts/metrics.sh collect` joins that event spine with
packet boundaries derived from the `[orch packet:<id>]` commit trailers and
best-effort token/cost from the session transcripts:

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
**duration**, an **active/idle wall split**, and same-file concurrent-edit
counts (`totals.same_file_overlaps` — the observability that replaces the
retired parallel scheduler's file-disjointness guarantee). Tokens come from the
transcripts by default (a **version-fragile** source, so the collector **fails soft** to
structural-only and stamps `token_source` — a partial run is never misread as complete);
**Tier 0 OpenTelemetry** is an optional, deferred richer source, not required. Enable/
disable and retention live in `.agents/project-overrides.yaml` under `metrics:` (env
fast-path `ORCH_METRICS=off`). `.agents/metrics/` is gitignored bookkeeping — archive a
run by copying its `run-metrics.json` out. See
[ADR 0019](docs/adr/0019-run-metrics-observability.md).

**Tests.** `scripts/test-guard.sh` is the guardrail regression sweep (allow/deny
pairs for every category, the closed cross-tree bypasses, the branch×diff commit
matrix, and the `guard-extra` loading); run it after any change to
`guard.sh`. `scripts/test-runstate.sh` is the pause/resume + crash-recovery sweep
(the reconcile decision table, atomic writes, the SessionStart hook; ADR
0004/0005/0009 — plus read-only compatibility cases proving a legacy
`mode: parallel` run-state still parses now that the lane-writing subcommands
are gone); `scripts/test-pause.sh` covers the cooperative-pause sentinel/hook
(ADR 0017) — run it after any change to `runstate.sh` or `pause-check.sh`.
`scripts/test-metrics.sh` covers the run-metrics core (ADR 0019) — the
event-log → trailer/token join, fail-soft to structural-only, the
skill/command-class/duration enrichment and its head-only command classifier
(leak-tested), and the logger hook's no-`permissionDecision` contract —
against a synthetic git repo and fake transcripts (no live agent). CI runs
them on every push.

## Develop it (working on the plugin itself)

```bash
git clone https://github.com/ahocking/gaffer.git
cd gaffer

# Start Claude Code with this directory loaded as a plugin.
# REQUIRED here — see "Which copy of the plugin is running?" below.
claude --plugin-dir .

# Inside the session, after editing plugin files:
/reload-plugins

# Validate the manifest & structure
claude plugin validate .
```

### Which copy of the plugin is running?

Working *on* gaffer is not like consuming it, and getting this wrong is silent.

`gaffer` is normally installed from its marketplace, which copies a **snapshot**
into `~/.claude/plugins/cache/gaffer-marketplace/gaffer/<version>/` pinned to one
commit. Every skill and agent reaches `scripts/` and `templates/` through
`${CLAUDE_PLUGIN_ROOT}`, so in a session using that install, **your working tree
is not what runs** — the snapshot is. Editing `scripts/` or `skills/` changes
nothing, and the loop executes whatever the snapshot froze.

Note the marketplace `source` is this very directory, so it *looks* live. It is
not: install still snapshots to the cache, and the copy only moves when you
reinstall.

This repo therefore commits `.claude/settings.json` with:

```json
{ "enabledPlugins": { "gaffer@gaffer-marketplace": false } }
```

Project scope overrides user scope, so the installed copy is **off here and on
everywhere else** — other repos keep using their installed version, untouched.
The live plugin comes from `--plugin-dir .`.

The trade-off is deliberate: forget the flag and this repo has *no* gaffer
skills, which is loud and obvious. The alternative — silently running a months-old
snapshot against a current checkout — is the failure that costs you an afternoon.

To confirm which copy is live, run something whose behaviour changed recently. If
`/gaffer:run-loop`'s kickoff schedules features marked `deferred: true` in
`.agents/roadmap.yaml`, you are on a snapshot older than that feature.

### This repo self-hosts its own backlog

`gaffer` drives its own development through its own gspec adapter. The backlog
lives in `gspec/` (feature PRDs + task plans) sequenced by `.agents/roadmap.yaml`.
Inspect it without a session:

```bash
scripts/gspec-backlog.sh features
```

**gspec is pinned to 3.1.1.** gspec does not stamp its own version into a project
and this repo has no `package.json`, so this line and
`GSPEC_PINNED_VERSION` in `scripts/gspec-backlog.sh` are the only durable records
of which gspec produced these specs. Reinstall exactly that version — never bare
`npx gspec`, which installs whatever is current and silently defeats the pin:

```bash
npx --yes gspec@3.1.1 --target claude
```

Raising the pin is a deliberate, reviewed change: bump it, extend the supported
`spec-version` set, re-run `scripts/test-gspec-backlog.sh`, and amend ADR 0020.

**Upgrading gspec in a consumer repo has an order, and getting it wrong costs a
second migration.** Install the new gspec *first*, then run `/gspec-migrate`: a repo
still on the old gspec has the *old* `/gspec-migrate` in `.claude/commands/`, and it
migrates toward the layout you are trying to leave — reporting success as it does.
`/gaffer:migrate` sequences this for you and verifies packets still come out.

The full sequence, with the hazards and the two checks that tell a broken
migration from a finished backlog, is
**[docs/gspec-3.1.1-migration.md](docs/gspec-3.1.1-migration.md)**.

Try it out inside the session:

- Skills are **namespaced by plugin**: `/gaffer:new-project`,
  `/gaffer:review-change`, `/gaffer:run-loop`,
  `/gaffer:pause`, `/gaffer:resume`,
  `/gaffer:metrics`, `/gaffer:migrate`.
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
