# {{PROJECT_NAME}}

> {{PROJECT_PURPOSE}}

<!-- Bootstrapped by the `gaffer` plugin's /new-project chain. -->

## Spec-driven development

This project is developed spec-first. The specs are the source of truth; code
follows them. `spec-setup.md` is the authoritative setup brief; `CLAUDE.md` adds
the Claude Code and orchestration specifics.

- **gspec** (`gspec/`, `gspec-*` skills under `.claude/skills/`) — product, stack,
  style, practices, research, architecture, feature PRDs, and the execution backlog
  (`gspec/tasks/<slug>.md`, one ordered plan per feature).
- **`.agents/roadmap.yaml`** — cross-feature sequencing (`order` + `why`). gspec has
  no feature-level ordering, so the orchestration plugin supplies one. It is an
  override: with no entries the loop orders by dependency, then slug.
- **ADRs** (`docs/adr/`) — durable architectural decisions.

Typical flow for a substantial feature:

```text
gspec profile/stack/practices/style   →  foundation specs (once)
gspec feature                          →  PRD for the capability
gspec architect + ADRs                 →  design + durable decisions
gspec analyze                          →  reconcile spec-to-spec conflicts
gspec plan                             →  gspec/tasks/<slug>.md (ordered tasks)
.agents/roadmap.yaml entry             →  where this feature sits in the order
implement (orchestration loop)         →  build it (roadmap → gspec/tasks/)
gspec audit                            →  detect spec↔code drift
```

The `gaffer` plugin coordinates this: the chief-engineer delegates scoped
task packets, the reviewer checks diffs against acceptance criteria, and risky
actions (commits, migrations, auth/secrets/deploys) stop for human approval.

Reviews can optionally run a **brooks-lint** decay-risk lens (advisory
maintainability findings). It is configured by `.brooks-lint.yaml`; enable the
plugin once with `/plugin marketplace add hyhmrright/brooks-lint` and
`/plugin install brooks-lint@brooks-lint-marketplace`, or delete the config to
opt out.

## Getting started

1. Establish the foundation specs (run the gspec `profile`, `stack`, `practices`,
   and — if there's a UI — `style` skills).
2. Confirm the tech stack in `gspec/stack.md`, then add stack-specific entries to
   `.gitignore` and fill in the sections below.
3. Fill in `.agents/domain-rules.md` with this project's risk boundaries.

## Running the application

<!-- Keep current whenever a change affects how the app is run (new service,
     port, env var, migration/seed). Update in the same change. -->

_TODO: document once the stack is chosen._

## Configuration

<!-- Environment variables, config files, secrets handling. -->

_TODO: document once the stack is chosen._
