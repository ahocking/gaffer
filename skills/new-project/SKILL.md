---
name: new-project
description: Bootstrap a new, stack-agnostic, spec-driven repository configured for Claude Code and this orchestration plugin. Lays down the generic overlay (CLAUDE.md operating brief, .agents/ config, ADR seed, .gitignore, README), then installs gspec with its Claude target and seeds the gspec execution backlog, and stops for human approval before the initial commit. Use when the user wants to start/scaffold/create a new project or repo.
argument-hint: <project-name> [one-line purpose]
---

# New project: $ARGUMENTS

Bootstrap a new spec-driven repo. The human is the product owner and approves the
first commit — you do not commit. Work through the stages in order; skip one only
if it is genuinely unnecessary and say why.

**Before the closing summary and approval request, `Read`
`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md`** — the glyph vocabulary, the
indentation contract, and the decision block that every human-facing report in this
plugin owes. That summary has **no shape of its own**, so those conventions *are* its
format; naming the path is not reading it, and unread they produce free prose. You do
**not** need `report-templates.md`: it holds the guided loop's shapes, which this never
emits.

The **authoritative setup brief is `spec-setup.md`**, which the overlay ships to
the new repo root. This chain implements its Installation Tasks and Initial Setup
Checklist for Claude Code. If anything here appears to conflict with
`spec-setup.md`, `spec-setup.md` wins.

Spec Kit was removed ([ADR 0013](../../docs/adr/0013-remove-speckit-gspec-only-backlog.md)):
this chain installs **gspec only**. Do not install `.specify/` / `speckit-*`.

**gspec is version-PINNED** ([ADR 0020](../../docs/adr/0020-gspec-boundary-and-version-pin.md)
D3) — it changes rapidly, and a fixed known-good target means each upstream change
is adapted to deliberately rather than arriving as a silent breakage. Read the pin
from the adapter, never hardcode it here:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh pin
```

It prints `GSPEC_PINNED_VERSION`, the supported `spec-version` set, and the exact
install command. Raising the pin is a reviewable change to
`scripts/gspec-backlog.sh` plus an amendment to ADR 0020 — not something to decide
here, per-project.

## 1. Gather inputs (Chief Engineer)
Delegate to the **chief-engineer**. From "$ARGUMENTS" determine:
- **project name** (kebab-case for the directory),
- **one-line purpose**,
- **target parent directory** (default: `~/workspace`), so the repo path is
  `<parent>/<project-name>`.
Confirm these back to the human in one line. If the target path already exists
and is non-empty, **stop and ask** — do not scaffold over an existing project
(that is the future existing-app onboarding path, not this chain).

## 2. Lay down the generic overlay
Create the target directory and copy the template overlay from
`${CLAUDE_PLUGIN_ROOT}/templates/spec-driven-base/` into it, **including dotfiles**
(`.agents/`, `.gitignore`). Then substitute placeholders in every copied file:
- `{{PROJECT_NAME}}` → the project name
- `{{PROJECT_PURPOSE}}` → the one-line purpose
- `{{DATE}}` → today's date (`YYYY-MM-DD`)

Verify no `{{...}}` placeholders remain (`grep -rn '{{' <target>` should be empty).

## 3. Install gspec (Claude target, at the PIN)

**Read the version from the adapter and install exactly that** — never bare
`npx gspec`, which installs whatever is current and silently defeats the pin:

```bash
PIN="$(${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh pin | sed -n 's/^GSPEC_PINNED_VERSION=//p')"
npx --yes "gspec@${PIN}" --target claude
```

State the version you installed in your step-6 report. If `PIN` resolves empty,
**stop** — an unpinned install is the failure mode ADR 0020 D3 exists to prevent,
and it will not announce itself.

This creates the `gspec/` docs directory and installs gspec as **Skills** under
`.claude/skills/`. If the installer prompts interactively despite `--target`,
report what it asked and pause — do not blindly accept seeding from `~/.gspec`.

Also record the pin in the new repo so a human can see it without reading the
plugin: add `gspec@<PIN>` as a `devDependency` if the project has a `package.json`,
otherwise note it in the repo's `README.md`. gspec does not stamp its own version
into a project (that is upstream proposal `U4`), so this is the only durable local
record of which gspec produced the specs.

## 4. Seed the sequencing overlay
gspec owns the specs and the per-feature plans (`gspec/features/<slug>.md`,
`gspec/tasks/<slug>.md`). It has **no cross-feature ordering**, so this plugin
supplies one — as a plugin-owned file, deliberately **outside `gspec/`**
(ADR 0020 D2: anything under `gspec/` is governed by gspec's `spec-integrity`
floor, which would flag a file gspec does not own).

`.agents/roadmap.yaml` ships in the overlay (`templates/spec-driven-base/.agents/`)
and is copied with the rest of it in step 2 — seeded with `features: []` and its
own explanatory header. Confirm it landed; do not hand-write it.

Four fields per entry, added later as features are scoped: `slug` (matches
`gspec/features/<slug>.md`), `order`, `why` (one line of rationale, required), and
an interim `depends_on` that moves into PRD frontmatter once upstream proposal U5
lands. **Do not add `status` or `parallel_group`** — completion is derived from the
PRD's capability checkboxes and concurrency is computed by `packet-graph.sh`;
storing either is a drift source. Do **not** install Spec Kit (`.specify/` /
`speckit-*`) — removed in
[ADR 0013](../../docs/adr/0013-remove-speckit-gspec-only-backlog.md).

There is a second plugin-owned file, **`.agents/task-files.yaml`**, which is
deliberately **not** seeded: it records per-task file scope and is written on
demand by `/gaffer:build-packet-dependency-tree` as features get scoped. An
absent file already means "no scope known", which serializes conservatively, so an
empty one would add nothing. Mention it exists when you report — it is what unlocks
`--parallel` later.

## 5. Wire orchestration & verify (Chief Engineer)
- Confirm the `gaffer` plugin is enabled for this repo (via the user's
  Claude Code plugin config). Do not hardcode any absolute machine path.
- The overlay ships a `.brooks-lint.yaml` that opts the repo into the optional
  **brooks-lint** decay-risk review lens (advisory input to
  `/gaffer:review-change`). The config is committable and inert on its
  own; the plugin itself is enabled once by the human (interactive `/plugin`) —
  surface that as a recommended next action in step 6, do not attempt to run
  `/plugin` yourself. If the human does not want the lens, they can delete
  `.brooks-lint.yaml`; the review chain skips it silently when the plugin is absent.
- Sanity-check the result against the `spec-setup.md` Initial Setup Checklist and
  report it as a short tree:
  - `spec-setup.md`, `CLAUDE.md`, `README.md`, `.gitignore`, `.brooks-lint.yaml`,
    `.agents/` (incl. `ux-references.md`),
    `docs/adr/0001-record-architecture-decisions.md`
  - `gspec/` present; `gspec-*` skills under `.claude/skills/`;
    `.agents/roadmap.yaml` seeded (empty `features:` list)
  - `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh check` reports `CHECK=ok`
    (the artifact pin — ADR 0020 D3)
  - **no** `.specify/` and **no** `speckit-*` skills (Spec Kit removed, ADR 0013)
- Assert the overlay stayed **stack-agnostic** — no .NET/React/Docker/Postgres
  assumptions leaked in. Stack is decided later via the gspec `stack` skill.

## 6. Summarize and request approval (Chief Engineer)

Follow the conventions in `${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md` — glyph
vocabulary, sections flush left with facts inside a `>` quote bar, one line per thing,
empty sections omitted, no header tally (a bootstrap is not a run). **✅** what was
laid down, **⚠️** anything that needs the human's eye (an installer prompt you paused
on, a `PIN` that resolved empty), **▶** the next action. The closing approval request
is itself an ask, so it takes a **decision block** — the human is choosing whether to
`git init` and commit now or inspect first, and both options have consequences worth
one line each.

Report: the repo path, what was installed (gspec skills under `.claude/skills/` +
overlay + seeded `.agents/roadmap.yaml`), the pinned gspec version installed, any
installer prompts you paused on, and the
**single recommended next
action** — normally: run the gspec `profile`, `stack`, and `practices` skills to
establish the foundation specs. Also note, as a one-time optional setup, that the
human can enable the brooks-lint review lens with
`/plugin marketplace add hyhmrright/brooks-lint` then
`/plugin install brooks-lint@brooks-lint-marketplace` (the repo already carries
`.brooks-lint.yaml`). Then **stop** and ask the human to approve
`git init` + the initial commit. Do not commit, push, or merge — the guardrail
hook and the human gate that step.
