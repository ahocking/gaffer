---
name: migrate
description: Retrofit a consumer repo from an older orchestration-plugin layout to the current one (v2.0.0) — move gspec plan files to gspec/tasks/, convert gspec/roadmap.md into the plugin-owned .agents/roadmap.yaml, stamp missing spec frontmatter, refresh .agents/project-overrides.yaml and CLAUDE.md, then VERIFY the backlog actually parses. Use when a repo was set up under an earlier version of this plugin, when /gaffer:run-loop reports no backlog, or after upgrading the plugin.
argument-hint: (optional — a repo path; defaults to the current repo)
---

# Migrate this repo to the current plugin layout $ARGUMENTS

Bring a repo set up under an older version of this plugin onto the v2.0.0 layout
([ADR 0020](../../docs/adr/0020-gspec-boundary-and-version-pin.md)). The
deterministic moves live in `${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh`; **your**
job is the judgment around them — approval, the prose no converter can translate,
and reading the verification honestly.

**The failure this exists to prevent.** The headline change renames
`gspec/features/<slug>.plan.md` to `gspec/tasks/<slug>.md`. Renaming is trivial and
the result *looks* migrated — but if the moved plans' task lines cannot be parsed,
the backlog reads as **"nothing to do"** rather than as "unreadable", and the loop
cheerfully reports a finished project. Measured on two production repos: a pure
rename yielded **0 packets from 31 plan files**. So a migration is not done when the
files have moved. It is done when packets come out the other end.

**Before the closing summary and approval request, `Read`
`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md`** — the glyph vocabulary, the
indentation contract, and the decision block that every human-facing report in this
plugin owes. That summary has **no shape of its own**, so those conventions *are* its
format; naming the path is not reading it, and unread they produce free prose. You do
**not** need `report-templates.md`: it holds the guided loop's shapes, which this never
emits.

## 1. Preflight

- **Resolve the target repo** from `$ARGUMENTS`, else the current working directory.
- **The tree must be clean.** `migrate.sh apply` refuses on a dirty tree unless
  `--force`, and that is deliberate: a migration you cannot read as one `git diff`
  is not one you can review or revert. If the tree is dirty, say so and stop —
  offer to continue once the user has committed or stashed.
- **Never migrate `main`.** If HEAD is `main`/`master`, ask the user to branch
  first (`git switch -c chore/plugin-v2-migration`). You are about to move a lot of
  files; that belongs on a branch.

## 2. Detect and explain

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh detect <root>
```

It prints `FROM=<pre-2.0|current|no-gspec>` and a `FINDING=` line per item, each
with **what** and **why it matters**. Relay them in plain language — the `why` is
the part the user needs, because several findings look cosmetic and are not (a
roadmap left under `gspec/` trips gspec's own spec-integrity floor on every write,
and hard-blocks every turn on Codex).

`FINDINGS=0` means the repo is already current — say so and stop.

## 3. Get approval before touching anything

Show the plan (`migrate.sh plan <root>`) and **wait**. This rewrites a repo's spec
layout; it is not a routine edit. Name explicitly:

- how many plan files will move,
- that `gspec/roadmap.md` is **converted, not deleted** — the original stays until
  the user removes it,
- that `status` and `parallel_group` are **dropped on purpose** (completion is
  derived from PRD capability checkboxes, concurrency is computed per run — storing
  either is how they drift),
- and the one thing `apply` **does** delete outright: the legacy `backlog.done`
  block in `.agents/run-state.yaml` — completion is derived from the gspec
  checkbox now (ADR 0025), so the block is dead state with no reader left, and
  `apply` reports any id on it whose task is still unchecked before dropping it.
  **A finding is different** — `apply` never deletes one, because a finding may
  hold the only copy of something nobody has decided about yet (§5f).

## 4. Apply the mechanical moves

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh apply <root>
```

It moves plans with `git mv` (history preserved), stamps `spec-version` + `feature:`
frontmatter onto plans that lack it, converts the roadmap, and then verifies. Relay
its `MOVED=` / `STAMPED=` / `CONVERTED=` / `SKIP=` / `DROPPED=` / `UNCHECKED=` /
`UNRECOGNIZED_BACKLOG_DONE=` lines — `SKIP=`, `UNCHECKED=` and
`UNRECOGNIZED_BACKLOG_DONE=` need a decision from the user; `MOVED=`, `STAMPED=`,
`CONVERTED=` and `DROPPED=` are informational.

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

## 5. The parts no script can do

**a. `.agents/roadmap.yaml` — review the conversion.** Only structured
`features:` entries convert. Any prose in the old roadmap (`## Notes`,
`## Unsequenced`, rationale in HTML comments) is **not** translated and is still in
`gspec/roadmap.md`. Read it, and fold anything still true into the `why:` of the
entry it belongs to. Any entry whose `why` reads
`"(carry the rationale over from the old roadmap)"` had none to convert — fill it in
or ask. `why` is required precisely because it is the one thing a human needs when
re-sequencing later.

Also check for entries with no matching PRD: the roadmap may list features that were
never written. Report them; do not invent PRDs.

**b. `.agents/project-overrides.yaml`.** Update `allowed_paths` so `specs`/`docs`
cover `gspec/tasks/**` and `.agents/roadmap.yaml`, and drop `gspec/roadmap.md`.

**c. The repo's `CLAUDE.md`.** This one outlives the file move and matters most:
it is the operating brief every session reads. Replace descriptions of the two-tier
`roadmap.md` + `.plan.md` backlog with the current model — gspec owns
`gspec/features/<slug>.md` and `gspec/tasks/<slug>.md`; the plugin owns
`.agents/roadmap.yaml` (order + why). Use
`${CLAUDE_PLUGIN_ROOT}/templates/spec-driven-base/CLAUDE.md` as the reference
wording. Keep everything project-specific.

**The report conventions are stamped in for you.** `migrate.sh apply` copies
`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions-card.md` into `CLAUDE.md`
byte-verbatim when the marker `gaffer:report-conventions` is absent, and reports
`STAMPED=report conventions…`. Leave it exactly as inserted — **do not reword or
summarize it**. The marker is what stops `hooks/report-conventions.sh` injecting the
same text again at every session start, and a paraphrase drifts from the plugin's own
contract. This is the layer that makes reports come out in the house format *without
the human asking each session*; a repo without it gets free prose on every turn that
is not inside a gaffer skill.

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

**f. The finding index — triage, one entry at a time.**
`${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh findings-audit <root>` is read-only and
never opens a body; per entry it reports `ENTRY=<id> PACKETS=<yes|no>
VERDICT=<live|dead|unknown> SUMMARY_BYTES=<n> BODY=<yes|no> BODY_BYTES=<n>`, plus
index and body totals for the run. `apply` acts on none of this — the index may
hold the only copy of something nobody has decided about, so the triage is a
conversation with the user, not a batch prompt: walk the entries **one at a
time**, reading the summary (and the body, when `BODY=yes` and it looks
load-bearing), and act per entry:

- **`VERDICT=live`** — it still names a packet that is genuinely pending. No
  action; move on.
- **`VERDICT=dead`** — every packet it names has finished. Apply the same
  capture-then-drop rule the loop applies at packet close: if the finding is
  really "this should be built/fixed" and nothing has filed it yet, file the
  backlog task first — that filing *is* the capture; an owner-gate sign-off or a
  scoping note that only gated a now-finished packet is not durable knowledge and
  needs no capture. Either way, drop it once decided.
- **`VERDICT=unknown`** — routes to the user, not to a rule: the entry names no
  `packets:` at all, or it names a packet that is neither pending nor
  demonstrably finished. "Demonstrably finished" means the gspec checkbox or an
  `[orch packet:<id>]` commit trailer — never the `done:` block dropped in step
  4, above, which carried no fresher a signal than the boxes it mirrored.
  Present the entry and ask for one of the same three outcomes: drop it (it
  turned out to be spent), capture then drop it (file the backlog task, then
  drop), or keep it and repair it — there is no `--packets` command for an
  existing entry, so add the missing scope by hand to the entry in
  `.agents/run-state.yaml`, in the **flow** form `add-finding` itself writes:
  `packets: [<id>, <id>]`. A YAML *block* sequence (`packets:` then indented
  `- <id>` lines) is valid YAML and parses cleanly, but `runstate.sh` reads this
  key as an inline value only, so a block-form repair yields an empty scope and
  the entry reads `unknown` forever — the repair fails silently, which is the one
  outcome this triage exists to prevent. Re-run `migrate.sh findings-audit`
  afterwards and confirm the entry's `VERDICT` has moved off `unknown`.

Every drop is `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh drop-finding
<run-state-file> <id>`, which removes the index entry and its body together —
there is no path that leaves one orphaned.

## 6. Verify — and read it honestly

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/migrate.sh verify <root>
```

`VERIFY=ok` is the goal. The line that actually matters is the packet count:

> `· 24 plan file(s) -> 3 unchecked packet(s)`

- **Plans > 0 and packets = 0** is a **failed migration**, not a finished project.
  The plans moved but nothing can read them. Do not report success. Inspect one
  plan's task lines and treat it as (b) below.
- **A low count is often correct** — only *unblocked, incomplete* features
  contribute, so a mostly-finished repo legitimately yields few packets. Confirm by
  reading the `features` table
  (`${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh features <root>`) rather than
  assuming either way.

**Legacy task shapes.** Pre-2.0 plans were authored by this plugin's architect, not
by `/gspec-plan`, so their task lines use non-canonical ids and usually carry no
`deps:`/`covers:`. The adapter **reads them** (that is what makes migration a safe
move) and warns on stderr. Do **not** "fix" them by rewriting task lines: that edits
**checked** tasks, which gspec's immutability floor blocks and which destroys the
record of what was built. The supported path is to regenerate a plan with
`/gspec-plan <slug>` when that feature next comes up for work — checked tasks are
reproduced verbatim and only unchecked work is re-decomposed.

## 7. Report

Follow the conventions in `${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md` — the
glyph vocabulary, sections flush left with facts inside a `>` quote bar, plain-English
titles before any id, one line per thing, empty sections omitted. No header tally: a
migration is not a run and has nothing to count.

- **✅ What moved, converted, and was stamped.**
- **⚠️ What is left for the human** — `gspec/roadmap.md` awaiting deletion, prose to
  fold in, any `SKIP=` collisions, any plan worth regenerating, any `UNCHECKED=` id
  to reconcile, any `UNRECOGNIZED_BACKLOG_DONE=` block to drop by hand, and any
  finding you kept-and-repaired or left for later in the §5f triage. These are
  alerts, not chores: an unrecognized capability line means a feature can never
  read as done, so everything depending on it stays blocked forever and the
  backlog quietly reports nothing to do.
- **The verification line, quoted** — and the packet count with it. A migration is not
  done when the files have moved; it is done when packets come out the other end, so
  lead with that number rather than the file count.
- **▶ The single next action** — usually: *review the diff, then commit the migration
  on its own branch.* **Do not commit it yourself.** If anything about the migration
  is a genuine choice (regenerate a plan now vs. when the work next comes up), make it
  a decision block rather than a recommendation buried in prose.
