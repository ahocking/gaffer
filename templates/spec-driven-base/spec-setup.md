# Spec-Driven Development Setup

Use this document as the setup brief for an AI coding agent. The goal is to configure a specification workflow that uses **gspec** for long-lived product and architecture knowledge, **feature PRDs plus per-feature task plans** for disciplined feature execution, and **ADRs** for durable architectural decisions.

This repository is also coordinated by the `gaffer` Claude Code plugin (chief-engineer / architect / implementer / reviewer subagents + an approval guardrail). Orchestration sequences the workflow below and enforces approvals; it does not replace gspec or ADRs. See `CLAUDE.md` for the orchestration and approval specifics. Reviews may optionally run a **brooks-lint** decay-risk lens (advisory maintainability findings, configured by `.brooks-lint.yaml`); it is opt-in and does not own any spec artifact.

> **History:** earlier versions of this brief used a hybrid gspec + **GitHub Spec Kit**
> workflow. Spec Kit was removed ([ADR 0013](docs/adr/0013-remove-speckit-gspec-only-backlog.md)):
> it was never a live driver in practice and its execution role now lives in gspec's
> per-feature task plans, sequenced by `.agents/roadmap.yaml`, as described below.

## Objective

Set up this repository so AI coding agents can work from persistent, version-controlled context instead of guessing product intent, architecture, design language, engineering standards, or implementation approach.

The desired model is:

```text
gspec = source of truth for product, stack, style, practices, research, architecture,
        feature PRDs, the execution backlog, analysis, and audit
ADRs  = source of truth for durable architectural decisions
```

Do not create a second source of truth for any artifact type. Avoid duplicate specifications that can drift apart.

---

## High-Level Workflow

Use the following workflow for substantial features:

```text
1. gspec profile/style/stack/practices
2. gspec research, when market or product discovery is useful
3. gspec feature PRD              (gspec/features/<slug>.md)
4. gspec architecture, when technical design is non-trivial
5. ADRs for durable architectural decisions
6. gspec analyze to reconcile spec-to-spec conflicts
7. Author the feature's execution backlog:
   - gspec plan  ->  gspec/tasks/<slug>.md (ordered, dependency-aware tasks)
   - add the feature entry to .agents/roadmap.yaml (order + why)
8. Implement from the plan (the orchestration loop walks roadmap -> gspec/tasks/)
9. gspec audit to detect drift between specs and code
```

For small changes, it is acceptable to skip research, architecture, and ADR creation, but the agent must still honor the existing gspec documents and ADRs.

AI coding agents must not create checkpoint commits or otherwise commit code automatically. They may only run `git commit` when the user explicitly requests a commit (or as delegated by the autonomy level; see `CLAUDE.md`).

---

## Directory Structure

Create or preserve the following structure:

```text
repo-root/
├── gspec/
│   ├── profile.md
│   ├── style.md or style.html
│   ├── stack.md
│   ├── practices.md
│   ├── research.md
│   ├── architecture.md
│   ├── design/
│   ├── features/
│   │   └── <feature-slug>.md        # the PRD (capability checkboxes)
│   └── tasks/
│       └── <feature-slug>.md        # the per-feature ordered task plan
│
├── docs/
│   └── adr/
│       ├── 0001-record-architecture-decisions.md
│       └── <next-adr>.md
│
└── spec-setup.md
```

Prefer `docs/adr/` for ADRs rather than placing them inside a framework's internal folder. This keeps architectural decisions framework-neutral and easy for all tools to consume.

---

## The execution backlog

gspec owns **what to build and in what order within a feature**. This repo's
orchestration plugin owns **cross-feature sequencing**, because gspec has no
feature-level ordering at all.

### 1. `gspec/tasks/<slug>.md` — the per-feature ordered plan

Produced by the gspec `plan` skill from the feature PRD. This is what the loop
executes. Tasks carry stable IDs, explicit dependencies, and parallel markers:

```markdown
---
spec-version: v1
feature: <feature-slug>
---

# Plan: <Feature Name>

## Plan

- [ ] **T1** **P0** create the schema migration
  - deps: —
  - covers: "Users can be stored with a unique email"
- [ ] **T2** [P] **P0** add the repository layer
  - deps: T1
  - covers: "Users can be looked up by email"
```

**A checked task is immutable.** Once `- [x]` it is frozen — never edited,
renumbered, deleted, or unchecked; replanning appends a new task carrying
`supersedes: T<n>`. A gspec hook enforces this. The orchestration loop relies on
it: a task's ID is a packet's identity across sessions.

`[P]` is gspec's parallel-safety hint. The orchestration loop does **not** schedule
from it — it computes file-disjointness itself and isolates concurrent work in git
worktrees. Treat `[P]` as advisory.

### 2. `.agents/roadmap.yaml` — cross-feature sequencing (plugin-owned)

```yaml
# Plugin-owned feature sequencing. An OVERRIDE, not a prerequisite: with no
# entries the loop orders by dependency, then slug.
schema: 1
features:
  - slug: user-auth
    order: 10
    why: "every authenticated surface depends on it"
    depends_on: []      # interim — moves into PRD frontmatter upstream
```

Four fields only. **`why` is required** — it carries the sequencing rationale, so
this file is the single place a human re-sequences work.

**Deliberately absent**, because both are derived and storing them creates drift:

| Not stored | Where it actually comes from |
|---|---|
| `status` / `done` | the PRD's capability checkboxes — a feature is done when all are `[x]` |
| `parallel_group` | computed by the orchestration plugin's packet graph, per run |

It lives in `.agents/`, **not** `gspec/`, because everything under `gspec/` is
governed by gspec's own spec-integrity floor, which would flag a file gspec does
not own.

**Do not keep a second hand-maintained roadmap or backlog** (`docs/roadmap.md`,
`docs/backlog.md`, …) beside it. If a human-readable rollup is ever wanted,
generate it.

## Artifact Ownership Rules

Use this ownership model:

| Artifact | Owner | Notes |
|---|---|---|
| Product identity | gspec | `gspec/profile.md` |
| Audience and positioning | gspec | `gspec/profile.md` |
| Design system | gspec | `gspec/style.md` or `gspec/style.html` |
| Tech stack | gspec | `gspec/stack.md` |
| Engineering practices | gspec | `gspec/practices.md` |
| Competitive/product research | gspec | `gspec/research.md` |
| Feature PRDs | gspec | `gspec/features/<feature>.md` |
| System architecture overview | gspec | `gspec/architecture.md` |
| Cross-feature sequencing | orchestration plugin | `.agents/roadmap.yaml` (order + why) |
| Per-feature task breakdown | gspec | `gspec/tasks/<feature>.md` |
| Requirement clarification | gspec | in the PRD + `gspec/tasks/<feature>.md`; do not restate product strategy |
| Execution plan | gspec | `gspec/tasks/<feature>.md` |
| Durable architectural decisions | ADRs | `docs/adr/*.md` |
| Spec-to-spec reconciliation | gspec | gspec `analyze` |
| Spec-to-code drift detection | gspec | gspec `audit` |

Do not add off-map documents to gspec. In particular, do **not** create a
`gspec/constitution.md` or other bundled "non-negotiable principles" doc: put product
identity/philosophy in `profile.md`, architectural invariants in a "Core Invariants"
section of `architecture.md`, testing/verification rules in `practices.md`, tech
constraints in `stack.md`, and the enforceable "MUST never / refuse or escalate"
subset in `.agents/domain-rules.md`.

---

## Installation Tasks

### 1. Install gspec

From the repository root, run the platform-specific install command.

For Claude Code:

```bash
npx gspec --target claude
```

For Cursor:

```bash
npx gspec --target cursor
```

For Codex:

```bash
npx gspec --target codex
```

On Claude Code, gspec installs as **Skills** under `.claude/skills/`.

If the repository already has gspec documents, preserve them. If no gspec documents exist, create the foundational specs:

```text
gspec/profile.md
gspec/style.md or gspec/style.html
gspec/stack.md
gspec/practices.md
```

Ask only essential clarifying questions. Otherwise, create reasonable starter documents and mark assumptions clearly.

### 2. Seed the execution backlog

Create `.agents/roadmap.yaml` with an empty `features: []` list, using the schema
above. Entries and their `gspec/tasks/<slug>.md` plans are added per feature as work
is scoped (see the Feature
Workflow).

### 3. Create ADR Infrastructure

Create:

```text
docs/adr/
```

Then add:

```text
docs/adr/0001-record-architecture-decisions.md
```

Use this initial ADR:

```markdown
# 0001. Record Architecture Decisions

Date: YYYY-MM-DD

## Status

Accepted

## Context

This project uses AI-assisted development. Long-lived architectural decisions need a stable, version-controlled home that can be read by both humans and AI agents. Some decisions affect many future features and should not be buried inside one feature specification or implementation plan.

## Decision

We will record durable architectural decisions as Architecture Decision Records in `docs/adr/`.

The `gspec/architecture.md` file provides the current system overview. ADRs explain why important decisions were made, what alternatives were considered, and what consequences follow.

Planning and implementation must read relevant ADRs before proposing plans, tasks, or code changes.

## Consequences

- Major architectural decisions have a single canonical location.
- AI agents must not re-litigate accepted ADRs unless explicitly asked.
- Superseded decisions must be recorded by creating a new ADR rather than silently editing history.
- `gspec/architecture.md` may summarize ADRs but should not duplicate their full rationale.
```

---

## ADR Rules

Use ADRs for decisions that are durable, cross-cutting, or expensive to reverse.

Examples:

- Backend framework
- Frontend framework
- Database choice
- Authentication model
- Authorization model
- Multi-tenancy model
- AI provider strategy
- Cloud provider
- Integration provider
- Messaging/eventing strategy
- Deployment topology
- Observability strategy
- Security boundary decisions

Do not create ADRs for ordinary implementation details, small refactors, or one-off feature behavior.

### ADR Template

Use this template for new ADRs:

```markdown
# NNNN. Title

Date: YYYY-MM-DD

## Status

Proposed | Accepted | Superseded by NNNN

## Context

What problem, constraint, or tradeoff led to this decision?

## Decision

What did we decide?

## Alternatives Considered

- Option A: summary and tradeoffs
- Option B: summary and tradeoffs
- Option C: summary and tradeoffs

## Consequences

What becomes easier, harder, required, prohibited, or risky because of this decision?

## Related Artifacts

- `gspec/architecture.md`
- `gspec/stack.md`
- `gspec/features/<feature>.md`
```

ADR filenames should be sequential and kebab-cased:

```text
0002-choose-primary-datastore.md
0003-choose-frontend-framework.md
0004-select-integration-provider.md
```

---

## Agent Context Instructions

Add or update the repository's agent instruction file so every AI coding agent follows this rule:

```markdown
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
  research, feature PRDs, the execution backlog (gspec/tasks/<slug>.md),
  analysis, and audit.
- ADRs own durable architectural decisions.

Do not duplicate product, architecture, or decision content. Link to the authoritative artifact instead.

If a requested change conflicts with an accepted ADR, stop and ask whether to create a superseding ADR before implementing.

If implementation reveals that specs are stale, update the appropriate gspec file or recommend running the gspec audit skill.
```

Place this in the appropriate file for the active agent platform. For Claude Code, use the repository's root `CLAUDE.md` (the convention this template ships).

---

## gspec Integration Rules

Use gspec for specification maintenance and execution planning (on Claude Code these are Skills under `.claude/skills/`):

- gspec `profile` for product identity and audience
- gspec `style` for design system and visual language
- gspec `stack` for technology stack
- gspec `practices` for engineering standards
- gspec `research` for competitive/product research
- gspec `feature` for feature PRDs
- gspec `architect` for architecture blueprints
- gspec `analyze` for spec-to-spec contradictions
- gspec `audit` for spec-to-code drift

When gspec `architect` identifies a durable decision, create or propose an ADR.

When gspec `audit` finds drift caused by an intentional architectural change, create or update the relevant ADR before updating high-level architecture docs.

The feature PRD, its `gspec/tasks/<slug>.md` plan, and the `.agents/roadmap.yaml` entry must reference the relevant gspec and ADR sources rather than redefining them. Example:

```markdown
## Upstream Context

This feature is governed by:

- `gspec/profile.md`
- `gspec/stack.md`
- `gspec/practices.md`
- `gspec/architecture.md`
- `docs/adr/0003-use-openid-connect.md`
```

---

## Feature Workflow

For each substantial feature, follow this sequence:

### 1. Create or update the gspec feature PRD

Create:

```text
gspec/features/<feature-slug>.md
```

Include:

- Problem statement
- User goals
- Non-goals
- Capabilities
- Acceptance criteria
- UX notes, if relevant
- Dependencies
- Security/privacy considerations
- Open questions

### 2. Create or update architecture docs

If the feature affects architecture, update:

```text
gspec/architecture.md
```

If the feature introduces a durable decision, create:

```text
docs/adr/<next-number>-<decision>.md
```

### 3. Run gspec analyze

Use gspec `analyze` to check for contradictions between profile, stack, practices, architecture, feature PRD, and ADRs. Resolve contradictions before planning implementation.

### 4. Author the execution backlog

- Add or update the feature's entry in `.agents/roadmap.yaml` (`order`, `why`, and
  an interim `depends_on`). Never add `status` or `parallel_group` — both are derived.
- Run the gspec `plan` skill to write `gspec/tasks/<feature-slug>.md`: an ordered task checklist with
  `[GATE:*]`/`[STOP:*]` tags where a task crosses an approval boundary, an
  `## Upstream Context` block, and the test strategy. The plan operationalizes the
  PRD — it does not restate product direction.

### 5. Implement

Implement from the plan. The orchestration loop reads `.agents/roadmap.yaml` to pick
the next feature, then walks that feature's `gspec/tasks/<slug>.md` tasks, honoring
the gate tags and the session autonomy level. Implementation must comply with:

- `gspec/stack.md`
- `gspec/practices.md`
- `gspec/style.*`
- `gspec/architecture.md`
- relevant ADRs

### 6. Run gspec audit

After implementation, use gspec `audit` to compare specs against code. Resolve findings by choosing one of:

```text
A. Update spec to match intentional code change
B. Fix code to match spec
C. Defer with a tracked follow-up
```

---

## Anti-Drift Rules

The agent must follow these rules:

1. Do not duplicate architectural rationale in multiple places.
2. Do not create a second source of truth for product requirements.
3. Do not keep a second, hand-maintained roadmap/backlog beside `.agents/roadmap.yaml`.
4. Do not allow implementation to contradict accepted ADRs without creating a superseding ADR.
5. Prefer links/references over copied content.
6. Update gspec after intentional behavior changes.
7. Create ADRs for durable decisions, not temporary implementation notes.
8. Keep the gspec doc set standard — no off-map docs (see Artifact Ownership).

---

## Initial Setup Checklist

Complete the following:

- [ ] Install gspec for the selected agent platform.
- [ ] Create `gspec/` directory if missing.
- [ ] Create or preserve `gspec/profile.md`.
- [ ] Create or preserve `gspec/style.md` or `gspec/style.html`.
- [ ] Create or preserve `gspec/stack.md`.
- [ ] Create or preserve `gspec/practices.md`.
- [ ] Seed `.agents/roadmap.yaml` (empty `features:` list).
- [ ] Create `docs/adr/`.
- [ ] Create `docs/adr/0001-record-architecture-decisions.md`.
- [ ] Create or update root agent instructions (`CLAUDE.md` for Claude Code).
- [ ] Add rules requiring agents to read gspec and ADRs before planning and implementation.
- [ ] Add rules preventing duplicate sources of truth (incl. one roadmap, no off-map gspec docs).
- [ ] Verify that `gspec/tasks/*.md` plans reference upstream gspec and ADR artifacts.
- [ ] Commit the setup files only when the user explicitly requests it.

---

## Expected Result

After setup, the repository should support this operating model:

```text
Long-lived knowledge lives in gspec.
Durable decisions live in ADRs.
Feature execution happens through gspec feature PRDs + gspec/tasks/<slug>.md, sequenced by .agents/roadmap.yaml.
All AI agents read the same authoritative context before modifying code.
Specs are periodically audited against the actual codebase.
```

This setup should make AI-assisted development more consistent, reduce architectural drift, and preserve rationale as the system evolves.
