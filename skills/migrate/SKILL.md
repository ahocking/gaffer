---
name: migrate
description: Retrofit a consumer repo from an older orchestration-plugin layout to the current one, and onto the pinned gspec version — sequence the gspec upgrade and /gspec-migrate's move into gspec/features/<slug>/, convert gspec/roadmap.md into the plugin-owned .agents/roadmap.yaml, stamp missing spec frontmatter, refresh .agents/project-overrides.yaml and CLAUDE.md, then VERIFY the backlog actually parses. Use when a repo was set up under an earlier version of this plugin or an older gspec, when /gaffer:run-loop reports no backlog, or after upgrading either.
argument-hint: (optional — a repo path; defaults to the current repo)
---

# Migrate this repo to the current plugin layout $ARGUMENTS

Bring a repo set up under an older version of this plugin onto the v2.0.0 layout
([ADR 0020](../../docs/adr/0020-gspec-boundary-and-version-pin.md)). The
deterministic moves live in `${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh`; **your**
job is the judgment around them — approval, the prose no converter can translate,
and reading the verification honestly.

**A migration is done when packets come out the other end, not when the files
have moved** — a plan whose task lines cannot be parsed reads as "nothing to do",
not as "unreadable". So every path through this skill ends at `verify`, and the
packet count is the number you lead the report with.

**Two migrations may be in play, and they are not the same job.** The plugin's own
retrofit (`gspec/features/<slug>.plan.md` → `gspec/tasks/<slug>.md`, the roadmap
conversion, the run-state cleanups) is `migrate.sh`'s. The **gspec** upgrade to the
pinned version (read it with `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh pin`;
never assume it) — everything about a feature moving into `gspec/features/<slug>/`
— is **`/gspec-migrate`'s**, and this skill does not do it (§2b). Read §2b before
running anything: the wrong order makes the repo worse. The human-facing version of
the same sequence is the runbook
[`docs/gspec-migration.md`](../../docs/gspec-migration.md).

**Before the closing summary and approval request, `Read`
`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md`** — that summary has **no
shape of its own**, so those conventions *are* its format; naming the path is not
reading it. You do **not** need `report-templates.md`: it holds the guided loop's
shapes, which this never emits.

## 1. Preflight

- **Resolve the target repo** from `$ARGUMENTS`, else the current working directory.
- **The tree must be clean.** `migrate.sh apply` refuses on a dirty tree unless
  `--force`, so the migration reads as one reviewable, revertable `git diff`. If the
  tree is dirty, say so and stop — offer to continue once the user has committed or
  stashed.
- **Never migrate `main`.** If HEAD is `main`/`master`, ask the user to branch
  first (`git switch -c chore/plugin-v2-migration`).

## 2. Detect and explain

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh detect <root>
```

It prints `FROM=<pre-2.0|current|no-gspec>`, a `GSPEC_INSTALLED=<version|unknown>`
line (the `gspecVersion` stamp in `.gspec/config.json` against the plugin pin — when
they differ it names the re-emit command; that is information, never a finding,
since a stale install reads fine), and a `FINDING=` line per item, each with
**what** and **why it matters**. Relay them in plain language, the `why` included,
since several findings look cosmetic and are not.

`FINDINGS=0` means the repo is already current — say so and stop.

Two of those findings are about **gspec's** layout rather than the plugin's, and
they route to §2b instead of to `apply`:

- **`FINDING=gspec-v2-layout`** — the repo's features are still flat
  (`gspec/features/<slug>.md` + `gspec/tasks/<slug>.md`). **This is not breakage,
  and must not be relayed as breakage** — the adapter reads all three gspec
  layouts. The reason to migrate: `/gspec-plan` at 3.x **writes** to
  `gspec/features/<slug>/tasks.md`, so the next replan of any feature quietly
  strands the old plan beside the new one. Say that, not "your backlog is broken".
- **`FINDING=half-moved`** — `prd.md` is in the feature folder while its plan is
  still at the flat `gspec/tasks/<slug>.md`. Nothing breaks today, but the next
  `/gspec-plan` writes to the folder and the repo ends up with two plans for one
  feature.
- **`FINDING=plan-without-prd`** — a folder with `tasks.md` and no `prd.md`.
  Report the **fact** and let the user supply the cause: completion is **derived**
  from the PRD's capability checkboxes, so that feature contributes no packets and
  can never read as done. **Do not diagnose this one for them** — it may be an
  interrupted `/gspec-migrate` or a deliberate infra plan. Ask which; if it is
  deliberate and undocumented, the useful outcome is a line in the roadmap so the
  next reader does not re-investigate.

## 2b. The gspec upgrade — sequence it, don't improvise it

Skip this section entirely when `detect` reported neither finding above.

`migrate.sh` **will not** move a feature into `gspec/features/<slug>/`: gspec owns
spec **format and layout**, this plugin owns **execution**
([ADR 0020](../../docs/adr/0020-gspec-boundary-and-version-pin.md)).

**Run these in order:**

1. **Upgrade gspec first**, to exactly the version the plugin pins. Read it from
   the `GSPEC_PINNED_VERSION=` line of
   `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh pin`, then:

   ```bash
   npx --yes gspec@<pinned version> --target claude
   ```

   **Do not skip this and go straight to `/gspec-migrate`** — an old gspec's
   `/gspec-migrate` migrates **toward `gspec/tasks/`**, the layout you are leaving,
   and reports success.

   Confirm the pin matches before and after:
   `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh pin`.

2. **Commit that on its own** — a large, purely-vendored diff (`.claude/**`) mixed
   into the spec moves makes both unreviewable.

3. **Run `/gspec-migrate`.** It relocates `features/<slug>.md` → `features/<slug>/prd.md`
   and `tasks/<slug>.md` → `features/<slug>/tasks.md`, removes an emptied
   `gspec/tasks/`, stamps `spec-version: v2`, applies the `deployable:` → `module:`
   rename in `architecture.md` and any `architecture/<name>.md`, and repairs the
   links the move breaks. It asks before it moves anything.

   You must be in the **main conversation** to invoke it — a dispatched agent has no
   `Skill` tool, so if you are running inside one, stop and hand this step back with
   the command to run.

   **Two things it deliberately will not do**, and both belong in your report as
   ⚠️ items rather than as failures:

   - **It never writes `arch.md` or `design.html`.** Name **`/gspec-architect`** as
     what writes them, and say plainly that until then each feature folder is
     simply incomplete — nothing breaks, and the loop does not need them. A feature
     with no UI correctly gets no `design.html` at all.
   - **It cannot make plans v2-conformant, and must not try.** If the migrator
     offers to add placeholder `arch:` lines, decline — with no `arch.md` yet,
     gspec's own `plan-lint` floor rejects every such anchor. The order is migrate
     → `/gspec-architect` → `/gspec-plan`, and only the last step can honestly add
     `arch:`. Say plainly in the report that "migrated" and "v2-conformant" are not
     the same state.
   - **It reports architecture altitude and stops there.** If `architecture.md` still
     carries entity field lists or endpoint signatures, that content now belongs to
     the feature that introduces it, and splitting it is `/gspec-architect`'s job on
     a later pass. Relay the warning; do not act on it here.

4. **Commit that too**, before returning to §3 — `migrate.sh apply` refuses on a
   dirty tree.

Then continue with §3 for the plugin-owned half. `apply` will usually find the
plan-move step already satisfied: `/gspec-migrate` at the pinned version takes a
pre-2.0 `features/<slug>.plan.md` straight to the feature folder in one hop.

## 3. Get approval before touching anything

Show the plan (`migrate.sh plan <root>`) and **wait** — this rewrites a repo's spec
layout. Name explicitly:

- how many plan files will move,
- that `gspec/roadmap.md` is **converted, not deleted** — the original stays until
  the user removes it,
- that `status` and `parallel_group` are **dropped on purpose** (completion is
  derived from PRD capability checkboxes and concurrency is computed per run, so a
  stored copy drifts),
- and the one thing `apply` **does** delete outright: the legacy `backlog.done`
  block in `.agents/run-state.yaml`, dead state since completion is derived from
  the gspec checkbox (ADR 0025); `apply` reports any id on it whose task is still
  unchecked before dropping it. **A finding is different** — `apply` never deletes
  one, since it may hold the only copy of something undecided (§5f).
- **and it cleans up parallel-mode / rate-limit-pause leftovers** (both retired):
  the `rate_limit_pause:` block and `max_parallel_packets:` key in
  `.agents/project-overrides.yaml`, leftover per-lane `.agents/pause.<task-id>`
  files, and the **tracked** `.agents/packet-graph.yaml`. It only ever **lists**
  extra git worktrees (never deletes — one may hold unmerged work) and only ever
  **reports** a stale `statusLine`/lines in the repo's own `CLAUDE.md` — see §4 and
  §5c.
- **and it cleans up the autonomy-level leftovers** (retired): it deletes
  `.agents/autonomy` wherever present and strips the `autonomy_ceiling:` paragraph
  from `.agents/project-overrides.yaml`, since the guard resolves no level any more.
  Three files it only ever **reports**, never edits, because they are the human's:
  the repo's `CLAUDE.md`, its `spec-setup.md`, and an `ORCH_AUTONOMY` entry in its
  `.claude/settings.json` — see §4 and §5c.

## 4. Apply the mechanical moves

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh apply <root>
```

It moves plans with `git mv` (history preserved), stamps `spec-version` + `feature:`
frontmatter onto plans that lack it, converts the roadmap, cleans up the retired
parallel-mode/rate-limit-pause and autonomy-level footprints, and then verifies.
Relay its `MOVED=` /
`STAMPED=` / `CONVERTED=` / `SKIP=` / `DROPPED=` / `UNCHECKED=` /
`UNRECOGNIZED_BACKLOG_DONE=` / `CLEANED=` / `FOUND=` / `REMOVED=` / `NOTE=` /
`WORKTREES=` / `CLAUDEMD_ROUTES=` / `SPECSETUP_ROUTES=` / `SETTINGS_AUTONOMY=`
lines — `SKIP=`, `UNCHECKED=`,
`UNRECOGNIZED_BACKLOG_DONE=`, `FOUND=`, `CLAUDEMD_ROUTES=`, `SPECSETUP_ROUTES=`
and `SETTINGS_AUTONOMY=` need a decision or
follow-up from the user; `MOVED=`, `STAMPED=`, `CONVERTED=`, `DROPPED=`, `CLEANED=`,
`REMOVED=` and `WORKTREES=` are informational.

A `SKIP=` means a destination already existed — it left both files in place rather
than overwrite. Those are for the user to reconcile; never resolve one by deleting.

A `DROPPED=` reports the legacy `backlog.done` block being removed — informational,
nothing to decide.

An `UNCHECKED=` names an id that was recorded done but whose gspec task is still
unchecked — the work may have been reverted, so reconciling it (check the box by
hand, or leave it) is the user's call; `apply` will not flip it for you.

An `UNRECOGNIZED_BACKLOG_DONE=` means the `done:` key exists in a shape the script
does not trust itself to touch, so `apply` left it byte-for-byte. Point the user at
the line range it names and let them drop it by hand once they have reviewed it.

A `CLEANED=` means retired key paragraphs were removed from
`.agents/project-overrides.yaml` — `rate_limit_pause:`, `max_parallel_packets:`
and/or `autonomy_ceiling:`. Informational. The line names **only the keys that
were actually there**, so read it rather than assuming all three; every other
line of that file (in particular `bypass-ask-tier`, `integration_branch`,
`escalate_to_human_on`) is untouched, blank lines included.

A `REMOVED=` covers four different things, all informational, all already done:
a leftover per-lane pause file, or the **tracked** `.agents/packet-graph.yaml`
(name it as a change the user must `git add`/commit — `apply` never commits), or
`.agents/autonomy` (the line says whether it was **tracked**, and so a change to
commit, or untracked and nothing to commit; relay which, do not assume), or
a statusLine actually removed from `settings.json` (see the `FOUND=`/`NOTE=`
pair below — a `REMOVED=` here still carries a `NOTE=` and is still not a
promise the sensor is inert *this* session).

A `FOUND=` means a user-level `statusLine` still points at the retired
`scripts/statusline-pause-sensor.sh`. `apply` **never removes it without your
explicit say-so** — this is global config, outside the repo, and could in
principle be something else's. **Ask the user before re-running with
`--remove-statusline`.** Whatever they decide, relay the `NOTE=` that always
follows: the status line is only re-read at session **start**, so neither a
declined removal nor one just made this run is a promise the sensor is inert —
it may still arm a pause until the next session. Never phrase a same-run
removal as "now safe."

A `WORKTREES=` lists extra git worktrees found — informational, and `apply`
deletes **none** of them (one may hold unmerged work). If the user wants them
gone, that is their call to make by hand.

A `CLAUDEMD_ROUTES=` names line(s) in the repo's own `CLAUDE.md` that route to
a retired mode or command, or that name a retired autonomy level. `apply` only
ever reports these — see §5c for rewriting them.

A `SPECSETUP_ROUTES=` does the same for the repo's `spec-setup.md`, and a
`SETTINGS_AUTONOMY=` for an `ORCH_AUTONOMY` entry in its
`.claude/settings.json`. Both are **reported, never edited** — these are the
human's files, the same rule that leaves a foreign `statusLine` alone. Show the
lines and offer to rewrite them, since the guard reads no level any more.

## 5. The parts no script can do

**a. `.agents/roadmap.yaml` — review the conversion.** Only structured
`features:` entries convert. Any prose in the old roadmap (`## Notes`,
`## Unsequenced`, rationale in HTML comments) is **not** translated and is still in
`gspec/roadmap.md`. Read it, and fold anything still true into the `why:` of the
entry it belongs to. Any entry whose `why` reads
`"(carry the rationale over from the old roadmap)"` had none to convert — fill it in
or ask; `why` is what a human needs to re-sequence later.

Also check for entries with no matching PRD: the roadmap may list features that were
never written. Report them; do not invent PRDs.

**b. `.agents/project-overrides.yaml`.** Update `allowed_paths` so `specs`/`docs`
cover `gspec/features/**` and `.agents/roadmap.yaml`, and drop `gspec/roadmap.md`.

On a repo now at gspec 3.x, `gspec/features/**` already covers a feature's whole
folder, so a separate `gspec/tasks/**` entry is vestigial. Keep it only while some
feature is still unmigrated, and say which when you do.

**c. The repo's `CLAUDE.md`** — the operating brief every session reads. Replace
descriptions of the two-tier `roadmap.md` + `.plan.md` backlog with the current
model — gspec owns the feature folder `gspec/features/<slug>/` (`prd.md` +
`tasks.md`, and `arch.md` / `design.html` where they exist); the plugin owns
`.agents/roadmap.yaml` (order + why). A repo you have **not** taken through §2b
keeps the flat `gspec/features/<slug>.md` + `gspec/tasks/<slug>.md` — describe
whichever layout is actually on disk, and never both, since an agent trusts this
file without checking. Use
`${CLAUDE_PLUGIN_ROOT}/templates/spec-driven-base/CLAUDE.md` as the reference
wording. Keep everything project-specific.

If `apply` printed `CLAUDEMD_ROUTES=`, it found line(s) in this same file routing
to a mode or command that is retired: `--parallel`, `/gaffer:build-packet-dependency-tree`,
`/gaffer:rate-limit-pause`, relay mode, or worktree lanes — or naming a retired
autonomy level (`full-autonomy`, `/gaffer:set-autonomy`, `ORCH_AUTONOMY`,
`.agents/autonomy`, `autonomy_ceiling`). It only ever **reports**
these — `CLAUDE.md` is the human's standing instruction, never rewritten for
them. Show the lines and rewrite them yourself, in the same pass as the rest of
this section: the loop now runs one sequential mode regardless of backlog size,
and there is no separate parallel/relay path to route toward; and there is one
fixed rule set with no level to choose, so a sentence that says what this repo's
level *is*, or how to change it, should say what the guard allows instead.

`SPECSETUP_ROUTES=` and `SETTINGS_AUTONOMY=` are the same job on two more of the
human's files: `spec-setup.md` (level references in the setup narrative) and
`.claude/settings.json` (an `ORCH_AUTONOMY` entry that now sets nothing).
`apply` edits neither. Offer the rewrite/removal and let the user decide — and
never delete a key from their `settings.json` on their behalf.

**The report conventions are stamped in for you.** `migrate.sh apply` copies
`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions-card.md` into `CLAUDE.md`
byte-verbatim when the marker `gaffer:report-conventions` is absent, and reports
`STAMPED=report conventions…`. Leave it exactly as inserted — **do not reword or
summarize it**, since a paraphrase drifts from the plugin's own contract.

The **one** case left to you: the marker is present at an **older version**
(`v1`, `v2`, …). `apply` will not touch it — replace that whole section with the
current card rather than merging the two.

**d. Removed skills.** If the repo's docs reference `/gaffer:implement-feature`
or the `test-driven-development` / `systematic-debugging` /
`verification-before-completion` skills, they are gone (ADR 0020 D7). Point feature
work at the chief-engineer or `/gaffer:run-loop`, and testing method at
`gspec/practices.md`.

**e. `.gitignore`.** Ensure `.agents/pause` and `.agents/pause.*` are ignored
(ADR 0017), plus `.agents/run-state.yaml` and `.agents/metrics/` if missing.
`detect` also flags `FINDING=driver-mode-ignore` when either `.agents/loop/` or
`.agents/driver-mode/` is not ignored, since the pause path's stash and `resume`'s
reconcile would sweep or discard an untracked file there. Add whichever line(s)
the finding names.

Also `FINDING=compact-threshold`, only when `.claude/settings.json` **exists**
and lacks the `autoCompactWindow` key — the one carrier
`runstate.sh compact-threshold` reads (ADR 0028); the finding never fires when the
repo commits no settings file. Without the key there is no committed, team-shared
value, so sessions here fall back to an operator-scope value
(`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `settings.local.json`, or the user-wide
settings file) if one is set, else gaffer's own default — never a value the team
chose. `apply` never writes this file; add `"autoCompactWindow": <tokens>` by hand
if you want the team to share one (an operator-scope value still takes precedence
over it).

**f. The finding index — triage, one entry at a time.**
`${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh findings-audit <root>` is read-only and
never opens a body; per entry it reports `ENTRY=<id> PACKETS=<yes|no>
VERDICT=<live|dead|unknown> SUMMARY_BYTES=<n> BODY=<yes|no> BODY_BYTES=<n>`, plus
index and body totals for the run. `apply` acts on none of this, since the index
may hold the only copy of something undecided: the triage is a conversation with
the user, not a batch prompt. Walk the entries **one at a time**, reading the
summary (and the body, when `BODY=yes` and it looks load-bearing), and act per
entry:

- **`VERDICT=live`** — it still names a packet that is genuinely pending. No
  action; move on.
- **`VERDICT=dead`** — every packet it names has finished. Apply the same
  capture-then-drop rule the loop applies at packet close: if the finding is
  really "this should be built/fixed" and nothing has filed it yet, file the
  backlog task first — that filing *is* the capture; an owner-gate sign-off or a
  scoping note that only gated a now-finished packet needs no capture. Either
  way, drop it once decided.
- **`VERDICT=unknown`** — routes to the user, not to a rule: the entry names no
  `packets:` at all, or it names a packet that is neither pending nor
  demonstrably finished. "Demonstrably finished" means the gspec checkbox or an
  `[orch packet:<id>]` commit trailer — never the `done:` block dropped in step
  4, above. Present the entry and ask for one of the same three outcomes: drop
  it, capture then drop it (file the backlog task, then drop), or keep it and
  repair it — there is no `--packets` command for an existing entry, so add the
  missing scope by hand to the entry in `.agents/run-state.yaml`, in the **flow**
  form `add-finding` itself writes: `packets: [<id>, <id>]`. **Never the block
  form** (`packets:` then indented `- <id>` lines): `runstate.sh` reads this key
  as an inline value only, so a block-form repair silently leaves the entry
  `unknown`. Re-run `migrate.sh findings-audit` afterwards and confirm the
  entry's `VERDICT` has moved off `unknown`.

Every drop is `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh drop-finding
<run-state-file> <id>`, which removes the index entry and its body together.

## 6. Verify — and read it honestly

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh verify <root>
```

`VERIFY=ok` is the goal. The line that actually matters is the packet count:

> `· 24 plan file(s) -> 3 unchecked packet(s)`

- **Plans > 0 and packets = 0** is a **failed migration**, not a finished project.
  Do not report success. Inspect one plan's task lines and treat it as (b) below.
- **A low count is often correct** — only *unblocked, incomplete* features
  contribute. Confirm by reading the `features` table
  (`${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh features <root>`) rather than
  assuming either way.

`verify` also prints a layout line:

> `· gspec layout: 6 feature(s) on 3.x, 2 still pre-3.x (run /gspec-migrate; the loop reads both)`

That line is **informational and `VERIFY=ok` still goes green through it** — a
mixed repo is a normal state, not a fault. The per-feature census is
`${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh plans <root>`, which prints
`<slug>  <path>  <layout>` and shows *which* features were left behind.

**Legacy task shapes.** Pre-2.0 plans were authored by this plugin's architect, so
their task lines use non-canonical ids and usually carry no `deps:`/`covers:`. The
adapter **reads them** and warns on stderr. Do **not** "fix" them by rewriting task
lines: that edits **checked** tasks, which gspec's immutability floor blocks. The
supported path is to regenerate a plan with `/gspec-plan <slug>` when that feature
next comes up for work — checked tasks are reproduced verbatim and only unchecked
work is re-decomposed.

## 7. Report

Follow the conventions in `${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md` — the
glyph vocabulary, sections flush left with facts inside a `>` quote bar, plain-English
titles before any id, one line per thing, empty sections omitted. No header tally: a
migration is not a run.

- **✅ What moved, converted, and was stamped.**
- **⚠️ What is left for the human** — `gspec/roadmap.md` awaiting deletion, prose to
  fold in, any `SKIP=` collisions, any plan worth regenerating, any `UNCHECKED=` id
  to reconcile, any `UNRECOGNIZED_BACKLOG_DONE=` block to drop by hand, any feature
  folder still missing its `arch.md` / `design.html` (name `/gspec-architect`), any
  architecture-altitude warning `/gspec-migrate` raised, and any finding you
  kept-and-repaired or left for later in the §5f triage. These are alerts, not
  chores: an unrecognized capability line leaves a feature, and everything
  depending on it, blocked forever.
- **The verification line, quoted** — and the packet count with it, leading with
  that number rather than the file count.
- **▶ The single next action** — usually: *review the diff, then commit the migration
  on its own branch.* **Do not commit it yourself.** If anything about the migration
  is a genuine choice (regenerate a plan now vs. when the work next comes up), make it
  a decision block rather than a recommendation buried in prose.
