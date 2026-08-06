# CLAUDE.md — {{PROJECT_NAME}}

> {{PROJECT_PURPOSE}}

This repository uses a **gspec-driven development workflow** (gspec + ADRs),
coordinated from Claude Code by the `gaffer` plugin. Execution runs off
gspec's per-feature plans (`gspec/tasks/<slug>.md`), sequenced by the plugin-owned
`.agents/roadmap.yaml`; Spec Kit was removed (ADR 0013).

**`spec-setup.md` at the repo root is the authoritative setup brief.** It defines
the workflow, artifact ownership, the execution backlog, ADR rules, gspec integration
rules, and anti-drift rules. Read it first and follow it. This file adds only what is
specific to Claude Code and to orchestration; it does not restate the brief
(anti-drift rule #5: prefer references over copied content).

---

## Specification Context

Before planning or implementing non-trivial changes, read:

1. `spec-setup.md`
2. `gspec/profile.md`
3. `gspec/stack.md`
4. `gspec/practices.md`
5. `gspec/style.md` or `gspec/style.html`, when UI is involved
6. `gspec/architecture.md`, when architecture is involved
7. Relevant `gspec/features/*.md` (and the matching `gspec/tasks/*.md`)
8. `.agents/roadmap.yaml`, when sequencing or picking the next feature
9. Relevant `docs/adr/*.md`
10. `.agents/domain-rules.md` — this repo's domain guardrails and risk boundaries

Artifact ownership:

- gspec owns product context, design, stack, practices, architecture overview,
  research, feature PRDs, the execution backlog (`gspec/tasks/<slug>.md`),
  analysis, and audit.
- ADRs own durable architectural decisions.

Do not duplicate product, architecture, or decision content. Do not add off-map
gspec docs (no `gspec/constitution.md`; see `spec-setup.md`'s Artifact Ownership).
Link to the authoritative artifact instead. If a requested change conflicts with
an accepted ADR, stop and ask whether to create a superseding ADR before
implementing. If implementation reveals that specs are stale, update the
appropriate gspec file or recommend running the gspec audit skill.

---

## Where the tooling lives on Claude Code

Both spec frameworks install as **Claude Code Skills** under `.claude/skills/`:

- **gspec** — skills named `gspec-*` (`gspec-profile`, `gspec-stack`,
  `gspec-feature`, `gspec-architect`, `gspec-analyze`, `gspec-audit`, …). Because
  `gspec/` exists, route requests through the matching gspec skill instead of
  producing the equivalent output ad hoc — even for casual phrasing like "just
  build it". The gspec installer appends its own usage guide to this file below.
- **Execution backlog** — **gspec-owned**: `gspec/tasks/<slug>.md`, one ordered,
  dependency-aware task plan per feature (stable `T<n>` ids, `deps:`, `covers:`;
  a checked task is immutable). Tasks may carry `[GATE:*]`/`[STOP:*]` tags so the
  loop knows its hard/soft gate split.
- **Cross-feature sequencing** — **plugin-owned**: `.agents/roadmap.yaml`
  (`order` + `why`). gspec has no feature-level ordering, so the plugin supplies
  one. It is an override, not a prerequisite — with no entries the loop orders by
  dependency, then slug. Completion is **derived** from PRD capability checkboxes
  and concurrency is **computed** by the packet graph, so neither is stored there.
  (Spec Kit was removed — ADR 0013.)
- **ADRs** live in `docs/adr/`. Start each feature PRD / task plan with an
  `## Upstream Context` block listing the governing gspec/ADR files.

---

## Orchestration & approval

This repo runs under the `gaffer` plugin, which sequences the
`spec-setup.md` workflow and enforces approvals. The **chief-engineer** keeps
global coherence and delegates scoped task packets; the **architect** owns design
docs/ADRs; the **ux-designer** owns visual/UX design of the user-facing surface
(layout, usability, accessibility — iterating against the rendered UI); the
**implementer** makes narrow code changes; the **reviewer** is read-only.
Per-project routing and guardrails live in `.agents/`
(`project-overrides.yaml`, `domain-rules.md`, `ux-references.md`).

The review chain (`/gaffer:review-change`) can also run an optional
**brooks-lint** decay-risk lens when that plugin is installed — an advisory
maintainability pass (book-cited Symptom→Source→Consequence→Remedy findings)
configured by `.brooks-lint.yaml` at the repo root. It complements the reviewer
(authoritative on security/correctness) and the guardrail (gates irreversible
actions); it never auto-fixes. Enable it once with
`/plugin marketplace add hyhmrright/brooks-lint` then
`/plugin install brooks-lint@brooks-lint-marketplace`, or delete
`.brooks-lint.yaml` to opt out.

**Stop and get explicit human approval before:** commits, merges, pushes,
database migrations, destructive filesystem operations, dependency
installs/upgrades, deploys, and any change to auth/authz, secrets, or the risk
boundaries listed in `.agents/domain-rules.md`. This repo ships at the conservative
default — per `spec-setup.md`, agents create no automatic commits until the human
raises the autonomy level. **Which git steps are delegated is governed by the
autonomy level** (ADR 0004 / 0006, set via `/gaffer:set-autonomy` or
`ORCH_AUTONOMY`, clamped by `autonomy_ceiling`): `supervised`/`autonomous` delegate
routine commits on a feature branch; `full-autonomy` additionally delegates
merge/rebase/push onto **non-`main`** branches. **Commit/merge/push to `main`,
releases, migrations, secrets, deploys, and the danger floor stay human at every
level.** The guardrail hook blocks the most dangerous calls, but it is a backstop,
not your only defense.

---

## Routing — how to engage the team

The human drives this repo in **plain language** and should not have to name a
skill or agent. Treat each request as *intent* and route it to the right chain
rather than answering ad hoc — though the human may always invoke a skill
explicitly to force that chain. Default routing:

| The request is… | Route to |
| --- | --- |
| Add / build / change a feature or behavior | The **chief-engineer**: it scopes a task packet, delegates implement → test → review to the specialist agents, and stops for approval before any commit. For a whole feature already planned in `gspec/tasks/<slug>.md`, use `/gaffer:run-loop`. |
| Design / lay out / improve a screen or flow — "make this look right", "the UI feels off", "design the X page" | The **ux-designer**: it studies comparable products, iterates against the rendered UI through a preview loop, and logs decisions in `.agents/ux-references.md`. On a **web** surface it boots the app via `.claude/launch.json`; on a **Unity** surface (`ux.preview_mode: unity`) it drives the already-open Unity Editor through the Unity MCP. |
| "Review what I changed" / check uncommitted work | `/gaffer:review-change`. |
| Work through the backlog / "do the next tasks" / an unattended stretch | `/gaffer:run-loop` (reads `.agents/run-state.yaml`, else `.agents/roadmap.yaml` → `gspec/tasks/<slug>.md`); `/gaffer:pause` / `/gaffer:resume` at checkpoints. |
| Run the backlog **in parallel** / "do as much as possible at once" / a wide independent backlog | `/gaffer:build-packet-dependency-tree` then `/gaffer:run-loop --parallel` — runs the max number of file-disjoint packets concurrently in git worktree lanes, integrating green lanes at `full-autonomy` (ADR 0016). Opt-in; the default loop is sequential. |
| Author a spec / PRD / design — "spec out X", "should we…", "design the…" | Delegate to the **architect**, which drives the spec tooling for you — the `gspec-*` skills — and writes the PRD, the `gspec/tasks/<slug>.md` plan, the `.agents/roadmap.yaml` entry, and any ADR in place. The human states intent; they do not hand-run the spec commands. |
| Ambiguous, multi-step, or cross-cutting | The **chief-engineer**: decompose, decide what needs research / spec / plan / implementation / review, then route. |
| A quick question, lookup, or explanation | Just answer — no chain needed. |

In every case: **read the Specification Context above first**, honor the risk
boundaries in `.agents/domain-rules.md`, and remember the guardrail hook gates
every mutation regardless of how the work was initiated — routing is about
*doing the right thing well*, not about safety (that is always enforced).
