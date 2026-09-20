# Migrating a consumer repo to gspec 3.1.1

The ordered sequence for moving a repo onto gspec 3.x's feature-folder layout
without breaking the guided loop.

**Who this is for.** A human driving the migration in a consumer repo, across
more than one session. The agent-facing version of the same sequence lives in
`skills/migrate/SKILL.md` §2b, and the two are deliberately different documents:

| | authority for | read by |
| --- | --- | --- |
| `skills/migrate/SKILL.md` | what `/gaffer:migrate` **does** — findings, apply, verify | an agent, mid-task |
| this file | the **order a human runs things in**, and why | a person, before starting |

Where they overlap they must change together. This file states the sequence and
the hazards; it does not restate the skill's internal behaviour, so that the
skill stays the single source of truth for the plugin's own mechanics. The one
fact both must agree on — the pinned version — is asserted mechanically by
`scripts/test-migrate.sh`, so a pin bump that forgets this file fails the sweep
rather than rotting quietly.

---

## Read this first

**Nothing is broken today.** The adapter reads all three gspec layouts
(ADR 0020 D3), so an unmigrated repo drives the loop exactly as before. There is
no urgency and no outage to fix.

Migrate because **`/gspec-plan` at 3.x writes to the new location**. The next
replan of any feature therefore leaves a second plan beside the old one, and the
repo ends up with two plans for one feature. That is the cost of waiting, and it
is the only one.

## Where your repo can be

| Layout | PRD | Plan |
| --- | --- | --- |
| **3.x** (`spec-version: v2`) | `gspec/features/<slug>/prd.md` | `gspec/features/<slug>/tasks.md` |
| **2.x** (`v1`) | `gspec/features/<slug>.md` | `gspec/tasks/<slug>.md` |
| **pre-2.0** | `gspec/features/<slug>.md` | `gspec/features/<slug>.plan.md` |

Find out which, without guessing:

```bash
scripts/gspec-backlog.sh plans .
# <slug>  <path>  <layout>  <task-lines-read>  <unchecked>
```

The 3.x feature folder also holds `arch.md` and `design.html`. Neither is in the
plugin's consumed contract — they say *what to build*, which is gspec's half of
the seam — so the loop hands an implementer their paths and never parses them.

---

## The sequence

### 1. Branch, and start clean

Never on `main`. `migrate.sh apply` refuses a dirty tree on purpose: a migration
you cannot read as one `git diff` is not one you can review or revert.

```bash
git switch -c chore/gspec-311
git status --porcelain   # must be empty
```

### 2. Baseline the backlog — before anything moves

This is the step that turns *"it looks migrated"* into proof.

```bash
scripts/gspec-backlog.sh nodes-all . > /tmp/nodes.before.tsv
scripts/gspec-backlog.sh features  . > /tmp/feat.before.tsv
```

**Why it matters.** A rename that breaks task parsing yields an *empty backlog*,
which reads as "nothing to do" rather than as an error — the silent-failure class
ADR 0020 exists to prevent. Measured on two real repos before the adapter learned
their legacy task shapes: **0 packets from 31 plan files**. Step 8 is where this
baseline pays off.

### 3. Install gspec 3.1.1 — *before* touching any spec

```bash
npx --yes gspec@3.1.1 --target claude
```

> **Do not reorder this.** A repo still on old gspec has the **old**
> `/gspec-migrate` sitting in `.claude/commands/`, and that version migrates
> *toward* `gspec/tasks/` — the exact layout you are leaving. It reports success
> while doing it. You would then migrate twice, the second pass over files the
> first already rewrote.

Confirm the plugin agrees on the pin:

```bash
scripts/gspec-backlog.sh pin
# GSPEC_PINNED_VERSION=3.1.1
# GSPEC_SPEC_VERSIONS=v1 v2
```

The supported set is **both** versions on purpose. Narrowing it to `v2` would
make `check` return rc=3 — stopping the loop — on a repo whose backlog the
adapter reads perfectly well. The pin catches a format the code *cannot parse*;
it is not a lever for nagging a repo into migrating.

### 4. Commit the install on its own

A large, purely vendored change to `.claude/**`, plus the installer-owned
preamble block in `CLAUDE.md`. Mixing it with the spec moves makes both
unreviewable.

### 5. Run `/gspec-migrate`

Main conversation, in that repo's own session — a dispatched agent has no `Skill`
tool, so if you are inside one, hand this step back.

It relocates the PRDs and plans into `gspec/features/<slug>/`, removes an emptied
`gspec/tasks/`, stamps `spec-version: v2`, applies the `deployable:` → `module:`
rename in `architecture.md` and any `architecture/<name>.md`, and repairs the
relative links the move breaks. It asks before moving anything.

**Decline placeholder `arch:` lines if it offers them.** The v2 plan bar adds a
required `arch:` line per task, naming anchors in that feature's `arch.md`.
Migration never writes `arch.md`, so no anchor resolves — and gspec's own
`plan-lint` floor then *rejects* an `arch:` that does not. Obliging here produces
files gspec itself refuses.

**Two things it will not do. Neither is a failure:**

- **It never writes `arch.md` or `design.html`.** Migration relocates the two
  files that already existed; the other two are a judgement call, not a reformat.
  `/gspec-architect` writes them. Until then each folder is simply incomplete —
  the loop does not read them, and a feature with no UI correctly gets no
  `design.html` at all.
- **It reports architecture altitude and stops there.** v2 cut the architecture
  budget from 3,000 to 1,500 words, with entity field lists and endpoint
  signatures moving to the feature that introduces them. Splitting that rewrites
  specs a human already reviewed, so it is `/gspec-architect`'s later pass.

### 6. Commit the relocation

Use `git mv` semantics so history follows. A correct relocation shows as
**renames with only the version line changed**, not as mass delete-plus-add:

```bash
git show --stat -M HEAD | head
# gspec/features/{auth.md => auth/prd.md}   | 2 +-
```

### 7. Run `/gaffer:migrate` for the plugin-owned half

Converts `gspec/roadmap.md` → `.agents/roadmap.yaml`, drops the legacy
`backlog.done` block (ADR 0025), stamps the report conventions into `CLAUDE.md`,
and walks the findings triage one entry at a time. It ends by verifying.

Then update the plugin-owned files it deliberately leaves to you:

- **`.agents/project-overrides.yaml`** — `gspec/features/**` now covers a
  feature's whole folder, so a separate `gspec/tasks/**` entry is vestigial.
  Keep it only while some feature is still unmigrated, and say which.
- **`.agents/task-files.yaml`** — any `files:` entry naming a moved spec. **Leave
  the `fingerprint` values alone**: they must keep matching task text you did not
  edit, and rewriting one silently drops that task's file scope.
- **`.agents/roadmap.yaml` and `CLAUDE.md`** — describe whichever layout is
  actually on disk, and never both. `CLAUDE.md` is the operating brief every
  session reads; stale paths there outlive the file move.

### 8. Verify — two checks, and the second is the real one

```bash
scripts/migrate.sh verify .
scripts/gspec-backlog.sh nodes-all . > /tmp/nodes.after.tsv
diff /tmp/nodes.before.tsv /tmp/nodes.after.tsv   # expect no output
```

`VERIFY=ok`, plus a line reading:

```
· 24 plan file(s), 514 task line(s) read -> 28 unchecked packet(s)
```

**Read the task-line count, not just the packet count.** A migration that broke
parsing reports `0 task line(s) read`. A *finished* backlog reports a non-zero
count with `0 unchecked packet(s)`. Those are different states and the packet
count alone cannot tell them apart — which was a real defect in this plugin's own
`verify` until it was caught by running the migration on this repo.

The `diff` should be empty. **Byte-identical packet nodes before and after** is
the strongest available statement that the move changed nothing the loop sees.

---

## Migrated is not the same as v2-conformant

After step 8 the repo is **migrated**: every path resolves, the backlog is
unchanged, the loop is unaffected. It is **not** yet v2-conformant, and
conflating the two is easy because `VERIFY=ok` reads like completion.

A v2 feature folder holds four files. Migration relocates two. Closing the gap is
a separate project, in this order and no other:

| Step | Writes | Why it must come after |
| --- | --- | --- |
| `/gspec-architect` | `arch.md`, `design.html` | Needs the relocation done; a feature with no UI correctly gets no design. |
| `/gspec-plan` | `arch:` lines on tasks | An `arch:` anchor can only resolve once `arch.md` exists. |

Scope this honestly before starting: one architecture pass per feature, and the
altitude thinning is judgement work on specs a human already signed off. Measured
against the new 1,500-word budget, two real repos sat at **2.2x** and **16.7x**
over — that is not a tidy-up.

## If something goes wrong

Every step above is a separate commit on a branch, so recovery is
`git reset --hard` to the previous one. That is the entire reason for the commit
discipline in steps 4 and 6 — not tidiness.

---

## What has actually been exercised

Steps 1–2 and 6–8 were run end to end against clones of two real consumer repos
plus this plugin's own backlog — 43 PRDs and 37 plans in total. All three
produced **byte-identical** packet nodes and feature tables before and after, and
introduced **zero** broken links (one repo had six pre-existing broken links; the
same six, unchanged, afterwards).

Confirmed working:

- Relocation, `spec-version` stamping, and link repair across five distinct
  relative-depth classes
- `style.html`'s first-line `<!-- spec-version: -->` marker
- `gspec/design/` left untouched — 3.1.1 retires the concept but never migrates
  or deletes it
- Pre-2.0 legacy task-line shapes still read, and still warned about
- `migrate.sh` detect / apply / verify, including the finished-vs-unreadable
  distinction

**Not yet exercised, and worth watching the first time:**

- **`/gspec-migrate` itself.** All three relocations above were performed by
  script following gspec's documented flow, so step 5's hazards are read from its
  agent briefs rather than observed.
- **The `deployable:` → `module:` rename.** None of the three repos had a
  Deployables section for it to act on.
