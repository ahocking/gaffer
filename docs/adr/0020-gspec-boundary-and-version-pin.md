# ADR 0020 — The gspec boundary: governed execution, a pinned contract, and what this plugin stops owning

- Status: Accepted
- Date: 2026-08-03
- Deciders: user (tech lead), orchestration plugin
- Amends: [ADR 0013](0013-remove-speckit-gspec-only-backlog.md) (the backlog file
  contract), [ADR 0002](0002-spec-driven-bootstrap-via-live-installers.md) (the
  bootstrap half), [ADR 0012](0012-delegated-loop-driver.md) (which deliberately
  left `implement-feature` alone; D7 now retires it)
- Audited against: **gspec 2.7.0** (npm `latest`, commit `7cb6791`, 2026-07-28);
  re-audited against **gspec 3.1.1** (npm `latest`, 2026-08-23) — see the D3
  revision below, which raises the pin and records the layout change
- Revision (2026-08-23): **pin raised to gspec 3.1.1; the artifact pin widened to
  `v1 v2`; the adapter now reads three layouts behind one seam; the 3.x relocation
  is `/gspec-migrate`'s move, not this plugin's.** D3 revision, below.
- Revision (2026-08-03, at implementation): **`U1` split into `U1-local` (built) and
  `U1-up` (still to send).** Only the `files:` field half was ever something this
  plugin needed, and it needs no gspec change: `.agents/task-files.yaml` supplies
  file scope locally, fingerprint-guarded. The remaining upstream half — the
  `Promise.all` disjointness check — benefits gspec alone and is re-pitched as a bug
  report rather than a feature request. See D2 → *`U1-local`* and D9 `U1-up`.
- Revision (2026-08-03, at implementation): **D5's pid borrow was wrong and is
  replaced by a heartbeat.** Implementing it proved it: `runstate.sh` is a
  short-lived subprocess, so `claim-driver` recorded its OWN pid, which was dead the
  instant the command returned — every later check would have reported `crashed`.
  gspec's pid check works because gspec's driver IS one long-lived node process;
  this driver is a Claude Code session issuing discrete tool calls, so **no
  long-lived process exists to point at**. Staleness is the transferable idea: the
  driver stamps `driver_heartbeat` at each safe checkpoint (where it already polls
  the pause sentinel) and a heartbeat older than `ORCH_DRIVER_STALE_SECS`
  (default 900) means nobody is driving. An explicit caller-vouched pid is still
  accepted and OUTRANKS the heartbeat, for a genuinely long-lived runner. Everything
  else in D5 — the control/terminal split, `foreign` never being guessed as dead —
  stands as written. See D5 and `scripts/runstate.sh`.
- Revision (2026-08-03, same day): **D2's roadmap clause amended.** The original text
  retained `gspec/roadmap.md` in place as a plugin-owned overlay. A check of
  `floors/spec-integrity.mjs` found that placement is an **active conflict**, not a
  cosmetic one — the floor governs *every* `.md` under `gspec/`, so an un-versioned
  roadmap violates it on every write (and hard-blocks every turn on Codex). Feature
  sequencing therefore moves to a slimmed, plugin-owned `.agents/roadmap.yaml`, two of
  its seven fields are **derived rather than stored**, and the hard-dependency field is
  proposed upstream as `U5`. See D2 → *Feature sequencing*, D9 `U5`, and Consequences.

## Context

ADR 0013 (2026-07-17) settled this plugin's execution backlog on two gspec-owned
files. Three weeks later a re-audit of gspec found that both the **artifact
contract** and the **project's scope** had moved out from under it.

### What gspec became

gspec is no longer a spec-document generator. v2 is an agent-team framework with a
deterministic Node runtime: **25 agents, 15 commands, 8 persona + 5 convention
skills, 10 Claude hooks over 6 pure floor modules**, a 1,863-line build driver
(`lib/build.js`) and a 2,218-line CLI. Its organizing thesis — *skills are brains ·
agents are hands · commands are conversations · the runtime is the deterministic
driver · hooks are the hard floors* — is structurally the same thesis as this
plugin's. `/gspec-build` now takes an idea to a built codebase unattended, with
producer≠checker QA gates, self-heal retries, content-hash memoization, a resumable
manifest, per-agent model routing, and distinct exit codes per terminal state.

That is a direct overlap with `/gaffer:run-loop`, and gspec is ahead on
several axes this plugin also claims: crash/resume instrumentation (`status.json`
with pid liveness and exit codes 0/1/2/3), a deterministic code gate (a committed
`verify.sh` whose exit code *is* the gate), multi-harness reach (6 targets, 3 wired
engines), and a learning loop (per-agent memory silos → `distiller` →
`/gspec-distill`) that this plugin has no answer to.

### The break

ADR 0013 named `gspec/features/<x>.plan.md` as the execution backlog. **gspec 2.x
writes `gspec/tasks/<slug>.md`**, and `/gspec-migrate` explicitly relocates the old
files. This plugin has **zero references to `gspec/tasks/`** and stale `.plan.md`
references in `run-loop`, `resume`, `build-packet-dependency-tree`,
`implement-feature`, `new-project`, `architect.md`, `chief-engineer.md`, the base
template README, and `spec-setup.md`. Pointing `/gaffer:run-loop` at a
current gspec project finds no backlog.

Separately, `gspec/roadmap.md` — ADR 0013's feature-level DAG — is **this plugin's
invention, not a gspec artifact**. gspec has no cross-feature ordering at all;
`plan-decomposer` records cross-feature dependencies as a prose *note*, not a field.

The defect was never that gspec moved. It is that **nothing checked**, and the
breakage was silent.

### The two things gspec structurally does not do

1. **No git model.** `lib/build.js` contains not a single `git` invocation — no
   branches, no commits, no worktrees, no rollback. Durability is a checkbox in a
   file plus a stage manifest. Consequently `lib/build.js:1322` fans out same-wave
   scopes with `Promise.all` into **one working directory**, where the only thing
   preventing two implementers from writing the same file is a model's judgment that
   the scopes are disjoint. Their own `plan-validator` claims to check that `[P]`
   markers have "no file overlap", but the task format
   (`**T<n>** [P] **P<n>** / deps: / covers: / supersedes:`) **carries no file-scope
   field**, so the criterion is structurally unverifiable and there is no green
   commit to roll back to.
2. **No repo-risk guardrail.** gspec's floors govern `gspec/*.md` — frontmatter,
   profile-identity leakage, checked-task immutability, style token literals. One
   floor does touch code (`floors/practices.mjs`: nesting depth, function length,
   file naming, parsed from an `## Enforcement` block), but that is **style
   conformance, not irreversible-action risk**. Nothing there stops an `.env` write,
   a migration, a dependency install, a deploy, or a force-push. Their Codex adapter
   escalates to `danger-full-access` for build stages.

Those two absences are not oversights; they are gspec's scope boundary. They are
also precisely this plugin's `guard.sh`, ADR 0009 branch-per-packet, and ADR 0016
worktree lanes.

## Decision

### D1 — The seam: gspec owns specification; this plugin owns governed execution

**gspec answers *what to build and in what order*. This plugin answers *how much do
I trust this session, and what is the blast radius when it is wrong*.**

This plugin's purpose is restated as a **governed execution runtime for AI coding
agents**, on five pillars, each with a deterministic core and a matching test sweep:

1. **Guardrail** — what an agent may never do at any autonomy level (`guard.sh`:
   three-tier bash judgment, two-tier path model, per-repo `guard-extra-*`).
2. **Autonomy** — four levels and the hard/soft gate split. Merge-to-`main`, PRs,
   migrations, dependency changes, and deploys stay the human's gate, always.
3. **Checkpointing** — branch per packet, green commits carrying `[orch packet:]`
   trailers, crash-safe resume, cooperative pause, rate-limit auto-pause.
4. **Isolation** — worktree lanes scheduled off *computed* file-disjointness, with
   real merge-conflict escalation.
5. **Measurement** — where compute went, per packet / agent / model / tool / skill.

The unifying abstraction stays the **task packet**: a commit-sized unit carrying a
scope contract (`allowed_files`, `forbidden`), a risk `tier`, an autonomy level, and
a durable checkpoint. gspec's `T<n>` says *what to build*; the packet says *what this
unit may touch and what happens when it goes wrong*.

Consequence: **the plugin stops being spec-aware.** It reads a task list through one
adapter. No PRDs, no architecture documents, no style guides, no roadmap authoring.
ADRs are the sole exception — they are decisions, not specifications, and gspec
generates no decision log.

### D2 — One adapter, one path contract

The consumed contract is **`gspec/tasks/<slug>.md`** and nothing else: the
`- [ ] **T<n>** [P] **P<n>**` task line with `deps:`, `covers:`, `supersedes:`, and
the YAML frontmatter `feature:` slug + `spec-version`.

All gspec reads move behind **a single adapter module**. A gspec format change is
then one file to fix, not seven skills and two agents. The adapter emits packet
nodes for both `run-loop` §2 (initial backlog) and `packet-graph.sh` (graph nodes).
`.plan.md` is accepted as a deprecated fallback that warns.

**Ordering edges come from gspec's `deps:`. Exclusion edges stay ours.** `[P]` is
treated as a hint and never as a scheduling authority — it is a model's guess with no
isolation behind it (see Context). `packet-graph.sh` continues to compute
mutual-exclusion edges from `allowed_files` overlap, and the
empty-scope-serializes-conservatively default becomes *more* load-bearing, not less,
because gspec tasks carry no file list for us to inherit.

#### `check-task` — the adapter's one write (ADR 0025 D1)

The adapter is read-only except for one write: `check-task` flips `[ ]` to `[x]`
on a single `gspec/tasks/<slug>.md` task line, and touches nothing else on that
line or in the file. It records that a unit of work **executed** — the plugin's
half of the seam this ADR draws — never what to build or in what order, which
stays gspec's. Flipping the state of gspec's own tracking primitive is the
sanctioned mutation of that format, not authoring into it (ADR 0025 D1, where the
loop's use of this write — atomically, in the packet commit — is decided).

This raises **coupling, not dependence**, and the distinction is why the write
stays this narrow. A format change on a *read* is a loud parse failure `check`
already catches; a format change on a *write* can corrupt a file the plugin does
not own. So the write is confined to one character on one line — never
re-rendering the line, never touching an already-checked task's text, never
growing into a general plan editor — which is what keeps that failure mode a
parse error instead of data loss.

#### `U1-local` — file scope without waiting on upstream

Nothing about `files:` requires gspec to change. `.agents/task-files.yaml` supplies
the same data locally, keyed by the `<feature>#T<n>` token the adapter already
builds, and slots into the existing precedence pattern — **a plan-authored `files:`
line (the `U1-up` shape) wins, the sidecar fills in, empty still serializes
conservatively**. It lives in `.agents/`, so gspec's spec-integrity floor never
sees it.

**Every entry is fingerprint-guarded, and that is the load-bearing part.**
`plan-decomposer` preserves task IDs on regenerate but **re-decomposes unchecked
work**, so an unchecked `T5` can keep its id while its text becomes different work.
An unguarded sidecar would then hand a stale, *narrow* scope to two lanes that
genuinely collide — the one input here that costs correctness rather than speed. So
a missing or mismatched fingerprint **drops the entry to empty scope**, with a
stderr notice, and `gspec-backlog.sh files-status` audits every entry as
ok/stale/unfingerprinted/done/orphan. Comparison is normalized for case, markdown
emphasis, and whitespace, so reformatting a task does not invalidate its entry but
rewording one does.

**What `U1-up` would still add** is quality, not capability: `plan-decomposer`
authors file scope *at decomposition time*, holding the PRD, architecture, and stack
in context — the best-informed moment anyone will have. The sidecar is filled in
later by an agent reading task text, which is strictly worse information plus
permanent manual maintenance. A reason to still send `U1-up`, not a reason to wait
for it.

#### Feature sequencing — `.agents/roadmap.yaml`, and what is derived

**`gspec/roadmap.md` moves out of `gspec/` to `.agents/roadmap.yaml`.** Its current
placement is an active conflict, not a naming preference:
`floors/spec-integrity.mjs` governs **every** `.md`/`.html` under `gspec/`, excluding
only `gspec/design/` and any `README.md`, and requires `spec-version` frontmatter. An
un-versioned `gspec/roadmap.md` therefore violates the floor — flagged by the
`gspec-spec-integrity` PostToolUse hook on Claude, and **hard-blocking every turn** on
Codex, where `gspec-stop-gate.mjs` scans the whole tree at each turn end. Adding
`spec-version: v1` would silence it only by stamping gspec's version marker on a file
gspec does not own, inside the directory its `audit`/`analyze`/`migrate` commands
sweep — re-litigated on every gspec release. `.agents/` is ignored selectively (only
`run-state.yaml`, `metrics/`, and the pause sentinels), so the new file is committed
by default, and it sits beside `project-overrides.yaml` and `packet-graph.yaml` where
execution config belongs.

The old roadmap conflated four jobs with three different owners:

| Job | Nature | Owner | Disposition |
|---|---|---|---|
| Hard technical dependency | fact about the feature | **gspec** (PRD) | `depends_on` — upstream (D9 `U5`); carried in the roadmap in the interim |
| Desired order + rationale | planning preference | **this plugin** | `order` + `why` — the roadmap's only durable job |
| What may run concurrently now | computed | **`packet-graph.sh`** | **derived** — `parallel_group` dropped |
| Is the feature done | derived | **gspec** (capability checkboxes) | **derived** — `status` dropped |

Both dropped fields were drift sources. `status` duplicated the PRD capability
checkboxes, giving two artifacts a claim on completion. `parallel_group` was worse:
`build-packet-dependency-tree` §4 wrote *computed* wave results back into a
hand-maintained file, which goes stale the moment the graph is regenerated — so this
decision also **deletes that write-back step**. `prd`/`plan` links are dropped as
derivable from the slug. Seven fields become four:

```yaml
# .agents/roadmap.yaml — plugin-owned feature sequencing
schema: 1
features:
  - slug: auth          # must match gspec/features/<slug>.md
    order: 10
    why: pilot login gate          # required — one line of rationale
    depends_on: []                 # INTERIM: moves to PRD frontmatter when U5 lands
```

**Next-feature procedure.** (1) Load `order`/`why` from the roadmap. (2) A feature is
**done** when every capability checkbox in `gspec/features/<slug>.md` is `[x]` —
derived, never stored. (3) **Blocked** when any `depends_on` is not done, read from
PRD frontmatter once `U5` lands and from the roadmap until then. (4) Take the lowest
`order` among unblocked-and-incomplete. (5) Hand that feature's
`gspec/tasks/<slug>.md` to the adapter → packet nodes → `packet-graph.sh` → waves.

**The roadmap is an override, not a prerequisite.** With no roadmap present — the
normal state for a user who ran `npx gspec` and `/gspec-plan` without this plugin's
`new-project` — the loop falls back to all incomplete features ordered by dependency
then slug, and says so in the check-in. This is what keeps D4 honest.

ADR 0013's "one roadmap" standing rule is unchanged and now easier to hold: there is
one sequencing source, it is smaller, and two of its former fields cannot drift
because they are no longer written down.

### D3 — Pin gspec, on two independent axes

gspec is published to npm (all releases 1.0.0 → 2.7.0; `latest` = 2.7.0), so
`npx gspec@2.7.0` and `npm i -D gspec@2.7.0` are both reproducible.

**The pin is `gspec@2.7.0`.** The tech lead's rationale is explicit and accepted:
gspec is changing rapidly, and a fixed known-good target means each upstream change
is adapted to *deliberately*, rather than arriving as a silent breakage. This was
adopted over the alternative recommendation of a floating minimum version with a
format assertion only; the upgrade-friction cost is acknowledged in Consequences.

Because **gspec does not stamp its own package version into a project** — verified:
`.gspec/config.json` holds only install-time target metadata and the `models` map —
a single pin is not enforceable from inside a consumer repo. Two axes are therefore
pinned:

- **Tool pin.** `GSPEC_PINNED_VERSION=2.7.0` is recorded in the plugin and used by
  `new-project` (`npx gspec@$GSPEC_PINNED_VERSION`). Consumer repos additionally
  record it as a `devDependency` so the installer version is committed.
- **Artifact pin.** The D2 adapter reads `spec-version` from task frontmatter,
  compares it against a supported set, and **fails loud** on a mismatch:
  *"supports gspec spec-version X–Y (pinned gspec 2.7.0); found Z — run
  `/gspec-migrate`, or update the plugin's pin."* This is the only version signal
  available inside an installed project, and it is what actually protects the loop.

Raising the pin is a deliberate, reviewed change: bump the constant, extend the
supported `spec-version` set, re-run the sweeps, and note the delta in this ADR.

**Anything read outside the pinned artifact contract must fail soft** — notably the
D5 interlock, since `spec-version` governs spec format and says nothing about
`.gspec/build/status.json`.


### D3 revision (2026-08-23) — raised to gspec 3.1.1, and what the layout change taught

**The pin is now `gspec@3.1.1`** (tool axis), with the artifact axis at **`v1 v2`**.
gspec 3.0 relocated everything about a feature into one folder:

> `gspec/features/<slug>/prd.md` — was `gspec/features/<slug>.md`
> `gspec/features/<slug>/tasks.md` — was `gspec/tasks/<slug>.md`
> `gspec/features/<slug>/arch.md` and `design.html` — **new**, written by
> `/gspec-architect`, and deliberately **outside the consumed contract**: they say
> what to build, which is gspec's half of the seam. The loop hands an implementer
> their paths; the adapter never parses them.

Plus `spec-version: v1` → **`v2`**, `deployable:` → `module:` in architecture specs,
and `gspec/design/` retired as a concept.

**Three things this revision decides, each of which was a live alternative:**

**(a) The artifact pin accepts `v1` AND `v2`, not `v2` alone.** The original D3
framing — "fails loud on a mismatch" — reads as though newer is the only acceptable
answer. It is not. An unmigrated consumer repo's backlog is *readable*, so returning
rc=3 and stopping the loop over it would be the pin working against the thing it
protects. **The pin catches a format this code cannot parse; it is not a lever for
nagging a repo into migrating.** That nudge belongs to `/gaffer:migrate`, which
reports the layout and names `/gspec-migrate`. The still-must-fail-loud half is
preserved and tested with an unsupported `v9`.

**(b) All three layouts are read, behind one seam.** `_resolve_plan_path` /
`_resolve_prd_path` (enumerated by `_plan_paths` / `_prd_paths`) are now the only
places a gspec path is constructed, and the newer layout **shadows** the older for a
given slug — `/gspec-migrate` moves rather than copies, so a slug in both is a
half-finished migration and the destination is the truth. This is the same
conclusion gspec reached independently: its own `plugin/hooks/floors/paths.mjs`
accepts both forms, because the `task-immutability` block it feeds **fails open**
and a matcher that knew one layout would stop firing with no error anywhere.

The concrete trap, worth recording because it is invisible in review: every call
site derived a slug with `basename <path> .md`, which in the folder layout yields
the literal `"prd"` / `"tasks"` **for every feature at once**. N features read as
one, every sidecar key and packet id resolves to nothing, and the symptom is an
empty backlog rather than an error — the exact failure class D2's single-adapter
rule exists to prevent, reappearing one directory deeper.

**(c) `/gaffer:migrate` detects and sequences the relocation; it does not perform
it.** This is the seam applied to migration itself: gspec owns spec **format and
layout**, so the move is `/gspec-migrate`'s. Three independent reasons, any one
sufficient — it must repair the relative links the move breaks in *both* directions
(inbound links from specs that did not move are the ones missed), it must reformat
each file to the v2 body through gspec's own `spec-migrator` agent, and it edits
files gspec's `task-immutability` floor is watching, so a shell `mv` racing that
floor loses intermittently. What this plugin owns is the half gspec cannot do:
detect the layout (`FINDING=gspec-v2-layout`, `FINDING=half-moved`) and **verify
packets still come out**.

**The ordering is load-bearing and belongs in the record**: install gspec 3.1.1
*before* running `/gspec-migrate`. A repo still on old gspec has the *old*
`/gspec-migrate` in `.claude/commands/`, which migrates *toward* `gspec/tasks/` —
the layout being left — and reports success doing it.

**One defect this bump exposed in the plugin's own verification.** `migrate.sh
verify` tested `plans > 0 && packets == 0` and called it a failed migration. That
cannot separate "no task line can be parsed" from "every task is checked": both
yield zero packets, so the alarm fired hardest on the repos that had done the most
work — and it fired on this one, over 5 correctly-relocated plans holding 66 checked
task lines. The discriminator is how many task lines the adapter can **read**, now
reported by `gspec-backlog.sh plans` and computed with the same pattern `_nodes_for`
uses. It is the same error as (a) one level down, and the shared lesson is worth
stating once: **a zero licenses no conclusion until you know which zero it is.**

Migration of this repo's own backlog under this revision: 11 PRDs and 5 plans
relocated, 66 task lines still parsing afterwards, all 33 `.agents/task-files.yaml`
entries still resolving (`FILES=ok stale=0 orphan=0`). Three path references inside
**checked** blocks were deliberately left naming pre-3.x locations — they are the
historical record of where a file was when the work happened, the immutability floor
blocks editing them, and it is right to.

Sweeps re-run for this revision: `test-gspec-backlog.sh` (257) and
`test-migrate.sh` (234), plus the other eight, all green.

### D4 — gspec is the only supported spec source, but is not required

**One spec source, three backlog sources.** Do not build or accept a second spec
framework — that is ADR 0013's standing rule and it holds. But a *backlog* is not a
*spec*: it may come from `.agents/run-state.yaml`, from gspec tasks via the D2
adapter, or from an explicit argument.

Four and a half of the five pillars have zero spec dependency. Gating `guard.sh`
behind installing a spec framework would tax exactly the users who need it most —
someone hardening an existing repo that has no specs. The gspec-dependent surface is
**two places**: `run-loop` §2 and `build-packet-dependency-tree` §1. `resume`
already reads run-state.

Making gspec optional costs a fallback in two spots — backlog source, and acceptance
criteria. The second is already solved: `templates/task-packet.yaml` carries
acceptance criteria itself. That pre-existing decoupling point is why optional is
nearly free.

### D5 — `run-state.yaml` stays ours; `run.json` is read-only, in one place

They are not rivals and they do not merge. gspec's `run.json` is a **fixed 9-stage
spec-pipeline manifest** (`stages.<id>.{status, attempts, verdict, passed:{key→sha256},
elapsedMs}`) keyed to pipeline stages. `run-state.yaml` is a **variable-length packet
backlog cursor** keyed to git SHAs, plus worktree lanes. They *nest*: this plugin's
entire run-state is a decomposition of gspec's single `implement` stage.

This plugin **never writes `run.json`**. It reads `.gspec/build/status.json` in
exactly **one** place — a **preflight interlock**: if a gspec build reports
`state: running`, `run-loop` refuses to start. Two drivers fanning implementers into
one checkout is a collision that would never be diagnosed. The read is fail-soft per
D3.

Two design borrows from gspec are adopted into `run-state.yaml`:

- **Split control state from terminal state.** gspec learned this the hard way — a
  completed build and a build paused for review both exited 0. This plugin's
  `status:` field currently serves both roles.
- **Record a driver claim (and host).** Today the crash signal is "`status:
  running` in a fresh session ⇒ crashed", which cannot distinguish a crash from *a
  second session driving right now*. Parallel mode's safety rests on the driver being
  the single writer of run-state, and nothing currently enforces it. A claim turns
  that invariant from a convention into a check.

  **As built, the claim is a HEARTBEAT, not a pid** (see the revision note above).
  `claim-driver` stamps `driver_host`/`driver_since`/`driver_heartbeat`; the loop
  re-stamps via `heartbeat` at each packet boundary; `driver-status` reports
  `none|live|dead|foreign`. A pid is recorded **only** when a caller explicitly
  vouches for a long-lived one, and then outranks the heartbeat in both directions.
  `foreign` (a claim from another host) is never guessed as dead — resume is
  same-machine (ADR 0009), so a remote claim says nothing local, and guessing would
  invite exactly the second driver this is meant to prevent.

### D6 — Agents: keep all seven, narrow two

No agent is deleted. The overlap with gspec's 25 agents is real but concentrated in
*spec authoring*, which is one half of one agent.

| Agent | Disposition |
|---|---|
| `chief-engineer` | **Keep whole.** gspec's `build-orchestrator` only emits a wave JSON — it cannot converse, dispatch, gate, or commit. gspec's real driver is JS. |
| `implementer` | **Keep, narrowed.** Same name as gspec's, different unit: theirs takes a feature scope, ours takes a *packet* with `allowed_files`/`forbidden`. That scope contract is what makes worktree lanes safe. |
| `reviewer` | **Keep.** gspec's `implementation-validator` judges a *built scope*; ours reviews a *diff* for security/correctness/maintainability plus the whole-branch final pass. gspec has no diff concept. |
| `architect` | **Keep; cut its spec-authoring half.** gspec authors `architecture.md`/`stack.md` behind a QA gate we do not have. Ours retains ADRs, `.agents/domain-rules.md` risk analysis, and design-heavy packet design. |
| `ux-designer` | **Keep.** gspec's `style-writer` authors a design-system *spec*; ours iterates against *rendered output* via the preview loop (ADR 0010). Authoring vs. iterating — no overlap. |
| `researcher` | **Keep, weakened.** gspec covers market research (`competitor-researcher`) and in-repo scanning (`codebase-inspector`). External library/API/version research remains uncovered. Its main caller was `implement-feature` (retired in D7) — review it after one full cycle. |
| `doc-writer` | **Keep.** Not as "the documentation agent": `run-loop` §3.3 routes `tier: docs` → `doc-writer`, and it is **the haiku tier's landing spot**. Removing it collapses `docs` packets onto sonnet, a direct cost regression against ADR 0019's routing thesis. |

### D7 — Skills: 13 → 9

**Dropped — general engineering method, not orchestration mechanism:**

- `test-driven-development` (+ `testing-anti-patterns.md`) — gspec's `practices.md`
  is the correct home for "how we test": per-project, validated, with an enforcement
  block. A global TDD skill overrides a decision that belongs to the project.
- `verification-before-completion` — **redundant as a skill, essential as a rule.**
  Evidence-before-claims guards the commit gate and is already stated inline in
  `run-loop` §3.3. Keep the rule in `run-loop` and `implementer`; drop the file.
- `systematic-debugging` (+ 3 supporting files + `find-polluter.sh`) — not a gspec
  overlap but a *scope* judgement: nothing in it is orchestration-specific.

≈845 lines of SKILL.md plus supporting files, with only **three soft reference
sites** to patch (`run-loop:173`, `run-loop:175`, `task-packet.yaml:67`). No
behaviour is lost provided the verification rule is preserved inline. If this content
is still wanted it belongs as its own plugin, where it also applies to repos not
running this loop.

**Retired:** `implement-feature` — `/gspec-implement` plus `run-loop` cover it.

**Shrunk:** `new-project` reduces to *install pinned gspec → lay down the `.agents/`
governance overlay → seed ADR 0001 → seed `roadmap.md`*.
`templates/spec-driven-base/spec-setup.md` mostly retires; it narrates a gspec
workflow that gspec now documents itself.

**Retained:** `run-loop` (+`parallel.md`), `resume`, `pause`, `rate-limit-pause`,
`set-autonomy`, `metrics`, `review-change`, `build-packet-dependency-tree`,
`new-project`.

### D8 — Explicit non-goals

This plugin will not build, and will not accept contributions that build: spec
authoring of any kind, PRD/architecture/style/practices document generation, spec
validators, a second wave scheduler for gspec-authored plans, harness adapters
beyond Claude Code, or a learning/memory loop. Where gspec covers a need, depend on
it or upstream to it.

### D9 — Upstream rather than absorb

gspec's maintainer is a known collaborator, so improvements are proposed
**upstream**, not forked in. Forking would inherit an npm build system, a 6-target
emitter matrix, 25 agents, and a website — none of which would change — while
diverging immediately at gspec's release cadence, and would buy nothing a dependency
does not.

Five **upstream proposals**, `U1`–`U5`, best first. Each is small, in gspec's own
idiom, fixes something gspec would agree is a problem, and drags none of this
plugin's architecture along.

> **Naming.** These are referred to as `U<n>` throughout this ADR, never as "PR *n*".
> A bare `PR #n` reads as — and in most tooling auto-links to — a *pull request*
> number in **this** repository, which these are not: they are proposed changes to a
> separate upstream project, and they are proposals before they are patches. Reserve
> "PR" for real pull requests, referenced by full URL.

- **U1-up — Deterministic wave disjointness.** *Split from the original U1 on
   2026-08-03; the half this plugin needs is `U1-local`, built locally — see below.*

   **Pitch it as the bug report it is, not as a feature request.**
   `lib/build.js:1322` fans out concurrent implementers into **one working
   directory** on the strength of a `[P]` marker that `plan-validator` claims to
   verify for "no file overlap" — but the task format carries no file data, so that
   check cannot be performed by anything, model or code. The `files:` field is the
   fix's *prerequisite*, not the ask. The fix is a pure `floors/wave-disjoint.mjs`
   that checks a wave's scopes for overlap before `Promise.all` and downgrades to
   sequential on a collision **or on missing data**.

   Offer the *check*, not our worktree lanes — isolation is git-specific and stays
   on this side. Note this half benefits **gspec only**: this plugin never runs
   gspec's driver, so `wave-disjoint.mjs` buys it nothing directly. What it would
   gain from `files:` is better-sourced scope (see `U1-local`).
- **U2 — Per-stage cost accounting** in the engine adapters. gspec records elapsed ms;
   cost is what users tune. Its driver spawns every agent itself, so it can measure
   natively what ADR 0019's collector reconstructs from hooks and transcripts.
- **U3 — Usage-cap resilience.** `runWriterResilient` already names "a rate limit, or a
   usage cap" as a cause of exit-0-with-no-output and treats it as a retry. ADR
   0018's insight is that it is categorically different — retrying burns the
   remaining budget. Distinguish it and pause resumably.
- **U4 — Stamp the gspec version into `.gspec/config.json`.** Trivial, and it removes
   the two-axis pin D3 was forced into for every downstream integrator.
- **U5 — a `depends_on:` field in feature PRD frontmatter.** Cross-feature dependency is
   a property of a feature, and features are gspec's. Today gspec has no such field —
   `feature-writer` is told to "cross-link dependencies", but only as prose in the
   body — so `build-orchestrator` **guesses** wave order from that prose. A declared
   `depends_on: [<slug>]` makes gspec's own autonomous build deterministic and lets
   `feature-validator` check the cheap invariants (no cycles, every slug resolves to
   an existing PRD). It benefits gspec's build more than it benefits this plugin, and
   when it lands it removes `depends_on` from `.agents/roadmap.yaml` entirely,
   reducing that file to pure planning preference (`order` + `why`).

## Alternatives Considered

- **Adopt gspec wholesale and retire this plugin.** Rejected. gspec has no git model
  and no repo-risk guardrail, and its parallelism writes concurrently into one
  checkout on model judgment alone. For a repo with history worth protecting and
  domain risk declared in `.agents/domain-rules.md`, that is a regression, not a
  simplification.
- **Fork gspec and merge this plugin's features into it.** Rejected — see D9.
- **Upstream everything, including the guardrail and the git workflow.** Rejected. It
  would roughly double gspec's surface, make its maintainer own security policy, force
  a VCS-workflow opinion on users who do not share it, and — being Claude- and
  git-specific — undercut the multi-target story `docs/harness-parity.md` shows gspec
  takes seriously. A maintainer would be right to decline it.
- **Continue as a "wrapper around gspec".** Rejected as a *framing*, which is what
  caused the break: a wrapper assumes its base is stable, so it hardcodes paths and
  never version-checks. The test that settles it — delete gspec entirely and the
  guardrail, autonomy levels, branch-per-packet checkpointing, pause, and metrics all
  still work on a repo with no specs. A component valuable with its dependency removed
  is a peer, not a wrapper.
- **Floating minimum gspec version with format assertion only.** Rejected by the tech
  lead in favour of D3's hard pin, to make each upstream change a deliberate
  adaptation rather than a surprise.

## Consequences

**Better.** The boundary is stated and testable. Roughly 5,800 of ~9,400 lines
survive untouched — and it is the tested, deterministic half (`guard.sh`,
`runstate.sh`, `worktree.sh`, `packet-graph.sh`, `metrics.sh`, the sensors and their
sweeps). The plugin's purpose fits in one sentence. The silent-breakage class of bug
is closed by the D3 artifact assertion. Effort stops being spent on spec authoring,
validators, harness adapters, and a learning loop.

**Costs.** The hard pin means gspec releases do not arrive for free: each upgrade is
a deliberate task (bump the constant, extend the supported `spec-version` set, re-run
the sweeps, amend this ADR), and consumer repos sit on 2.7.0 until that happens. This
is the accepted trade for never being surprised again. The two-axis pin is
unavoidable extra machinery until `U4` lands.

**Watch.** (a) `researcher` may not earn its keep once `implement-feature` retires —
review after one full cycle. (b) Deriving feature completion from PRD capability
checkboxes makes the loop's "what's next" answer only as good as the implementer's
checkbox discipline; gspec's `task-immutability` floor protects checked tasks from
being rewritten, but nothing forces a checkbox to be *flipped*. A feature built
without its boxes ticked reads as incomplete and will be re-selected. (c) gspec's
installer merges into `.claude/settings.json` and this plugin's ADR 0018 status-line
sensor writes user settings — both additive, but a now-shared surface. (d) The D5
interlock reads outside the pinned contract and must stay fail-soft. (e) Until
`U5` lands, `depends_on` lives in two possible places; the adapter must
prefer PRD frontmatter and fall back to the roadmap, never merge the two.

**Implemented 2026-08-03.** `scripts/gspec-backlog.sh` (the D2 adapter + D3 artifact
pin + D5 interlock) with `scripts/test-gspec-backlog.sh` (58 checks); `runstate.sh`
gains `claim-driver`/`heartbeat`/`driver-status`/`outcome` with 29 new cases in
`scripts/test-runstate.sh` (95 total); the `.plan.md` → `gspec/tasks/` migration and
the `gspec/roadmap.md` → `.agents/roadmap.yaml` move across `run-loop`, `resume`,
`build-packet-dependency-tree`, `new-project`, `architect`, `chief-engineer`,
`task-packet.yaml`, and the whole `spec-driven-base` overlay; the
`parallel_group` write-back deleted from `build-packet-dependency-tree` §4; the D7
deletions and their three reference patches; the `new-project`/`spec-setup.md`
shrink; and the leftover Spec Kit `specs/` directory and `.gitignore` reference
(both surviving ADR 0013) removed. All eight sweeps green: guard 159, runstate 95,
packet-graph 29, worktree 29, pause 34, parallel-pause-e2e 23, metrics 178,
gspec-backlog 58.

**Also implemented (same day):** `U1-local` — the `.agents/task-files.yaml` sidecar
with fingerprint guarding, the plan-`files:`-wins precedence chain, a
`files-status` audit subcommand, and 19 further cases (gspec-backlog now 77),
including an end-to-end check that scoping two disjoint packets actually moves them
from `conservatively_serialized: 2` to concurrently dispatchable.

**Completion audit (2026-08-03).** A pass over D1–D9 found four decisions
implemented only on the sequential path and closed them: `.agents/roadmap.yaml` now
ships in the overlay template (it was described in `new-project` prose but existed
nowhere, so a bootstrapped repo would not have got one); `resume` and the
`--parallel` scheduler now **claim the driver and beat the heartbeat** (only
`run-loop` did — and parallel mode is where the single-writer invariant matters
most, since a second scheduler would open lanes against the same worktrees);
`resume` also runs the D3 version check and D5 interlock; and `architect` §4, which
still declared the agent "the author" of PRDs/plans, now defers spec authoring to
gspec and keeps blast-radius analysis, ADRs, risk review, and packet scoping. That
section directly contradicted D1 — the seam would have been stated in the ADR and
violated by an agent prompt.

**Upstream proposals drafted 2026-08-03, NOT sent.** All five (`U1-up`, `U2`, `U3`,
`U4`, `U5`) exist as independent `git diff` patches against gspec 2.7.0 in
`scratch/gspec-proposals/` (gitignored working material), each verified to apply to
a pristine checkout on its own and to pass `npm test`: baseline 140 →
`U1-up` 153, `U2` 147, `U3` 146, `U4` 140 (+1 assertion), `U5` 152. Two of them
(`U1-up`, `U5`) add a declared field specifically to make an existing but
unverifiable quality-bar claim verifiable, and both back it with a pure
`floors/*.mjs` module plus unit tests, matching gspec's own idiom.

**Nothing has been pushed, and no issue or pull request has been opened** — sending
them is the tech lead's call, and `scratch/gspec-proposals/README.md` carries the
per-proposal pitch (including the framing note that `U1-up` should lead as a bug
report about `Promise.all`, not as a feature request) and a suggested order.

## Related Artifacts

- [ADR 0013](0013-remove-speckit-gspec-only-backlog.md) — the backlog contract this
  amends
- [ADR 0009](0009-single-directory-feature-branch-workflow.md),
  [ADR 0016](0016-parallel-worktree-lanes.md) — the git model gspec lacks
- [ADR 0008](0008-guard-three-tier-enforcement.md),
  [ADR 0014](0014-auth-code-is-ask-not-deny.md) — the guardrail gspec lacks
- [ADR 0017](0017-graceful-cooperative-pause.md),
  [ADR 0018](0018-rate-limit-aware-cooperative-pause.md) — pause; source of `U3`
- [ADR 0019](0019-run-metrics-observability.md) — metrics; source of `U2`,
  and the routing thesis that keeps `doc-writer`
- [ADR 0012](0012-delegated-loop-driver.md) — relay/inline crossover; a dispatched
  agent has no `Skill` tool, so briefs must carry file paths
- gspec 2.7.0: `README.md`, `docs/gspec-v2-design.md`, `docs/harness-parity.md`,
  `lib/build.js`, `plugin/hooks/floors/`, `plugin/skills/personas/gspec-engineer.md`
- gspec 3.1.1 (the D3 revision): `lib/spec-version.js` (`SPEC_VERSION = 'v2'`),
  `plugin/hooks/floors/paths.mjs` (the layout vocabulary, and its own both-layouts
  rationale), `dist/claude/commands/gspec-migrate.md` (the relocation it performs),
  `dist/claude/commands/gspec-plan.md` and `agents/feature-architect.md` (where the
  new artifacts are written), `templates/preamble.md`
