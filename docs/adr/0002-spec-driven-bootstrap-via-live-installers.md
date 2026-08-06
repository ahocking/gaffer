# ADR 0002 — Bootstrap new repos with the real gspec + Spec Kit installers, targeting Claude

- Status: Accepted — **superseded in part by [ADR 0013](0013-remove-speckit-gspec-only-backlog.md)**
- Date: 2026-07-04
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0001](0001-phase2-scope-new-apps-first.md)

> **Superseded in part (2026-07-17, ADR 0013):** the **gspec** installer half of
> this decision still stands — new repos install gspec targeting Claude. The
> **Spec Kit** half is retired: the bootstrap no longer runs `specify init`, and
> `.specify/` / `speckit-*` skills are no longer installed. Spec Kit's execution
> role moved into gspec (`gspec/roadmap.md` + `gspec/features/<x>.plan.md`). Read
> the rest of this ADR with that carve-out in mind.

## Context

Phase 2 stands up new application repos on a **spec-driven** foundation using two
external tools the user already relies on in the reference consumer repo:

- **gspec** — <https://github.com/gballer77/gspec> — product/stack/style/practices/
  research/architecture/feature-PRD/analysis/audit specs. Lives in `gspec/`.
- **GitHub Spec Kit** — <https://github.com/github/spec-kit> — clarify → specify →
  plan → tasks → implement execution framework. Lives in `.specify/`.

The reference consumer repo is currently wired for **Junie**: it was initialized
with gspec's and
Spec Kit's *Junie* targets, so its commands live under `.junie/commands/` and its
agent brief is `.junie/AGENTS.md`. That is a property of how the tools were
*invoked*, not a fork of the tools.

Both tools support Claude natively. A dry run (Spec Kit 0.12.5.dev0) confirmed
that on Claude **both install as Skills under `.claude/skills/`** — they do not
collide (distinct `gspec-*` and `speckit-*` subdirectories):

| Tool | Installer | Claude target | Also creates |
|------|-----------|---------------|--------------|
| gspec | `npx gspec --target claude` | `.claude/skills/gspec-*` | `gspec/`, appends a section to `CLAUDE.md` |
| Spec Kit | `uvx … specify init --here --integration claude` | `.claude/skills/speckit-*` (invoked `/speckit-*`) | `.specify/`, `specs/` (does not touch `CLAUDE.md`) |

(An earlier draft of this ADR and the template mistakenly used
`.claude/commands/speckit.*` with dot-separated names — that was the reference
repo's older
*Junie* layout. The Claude installers use hyphenated skills; the dry run caught
it.)

The template must be **stack-agnostic** — no .NET/React/Docker/Postgres
assumptions. It provides only the generic layer that sits on top of what the two
installers produce.

We considered three ways to get the Claude-configured tool output into a new repo:
invoke the live installers, vendor a frozen snapshot, or a hybrid.

## Decision

1. **Invoke the live installers at project-creation time, pinned to known-good
   versions.** The bootstrap runs `npx gspec --target claude` and Spec Kit's
   `specify init` with the Claude integration. This keeps the output native and
   correct rather than maintaining a hand-translated fork of two upstream tools.
   - Trade-off accepted: bootstrap requires `npx` + `uvx` and network access when
     a repo is created. Both are present on the dev machine (`node`, `uv`/`uvx`).
   - Versions are pinned as variables in the bootstrap skill so results are
     reproducible; bumping a pin is a deliberate, reviewable change.

2. **Do not vendor or hand-copy the reference repo's `.junie/*` files.** They are the Junie
   rendering of the same tools; the Claude rendering is different in both location
   (`.claude/skills` vs `.junie/commands`) and form (gspec Skills vs commands).

3. **The template owns only the generic overlay:** the Claude operating brief
   (`CLAUDE.md`), the per-project orchestration config (`.agents/`), the ADR seed,
   `.gitignore`, and `README.md`. Everything spec-tool-specific is produced by the
   installers.

4. **`spec-setup.md` is the authoritative setup brief and ships in the template.**
   A generalized, stack-agnostic copy of the reference repo's `docs/spec-setup.md` is placed at
   the new repo root. It owns the workflow, artifact-ownership, ADR, and anti-drift
   rules. `CLAUDE.md` defers to it (per anti-drift rule #5, "prefer references over
   copied content") and adds only the Claude-surface mapping (both frameworks →
   `.claude/skills/`, as `gspec-*` and `speckit-*`) and the orchestration/approval
   layer.
   The ADR seed is `0001-record-architecture-decisions.md` in the brief's exact
   format.

## Consequences

- The bootstrap is a chain that *orchestrates external installers*, so it must
  verify the exact Claude integration flag for the pinned Spec Kit version
  — the recorded reference-repo value was `junie`; the Claude value is
  `--integration claude` (confirmed by dry run).
- The operating brief must reference Claude surfaces (`.claude/skills/gspec-*` and
  `.claude/skills/speckit-*`), not Junie paths.
- The future existing-app onboarding path (ADR 0001) can reuse the same installer
  invocations in "detect first, then fill gaps" mode.
- If a future environment lacks `npx`/`uvx` or network, bootstrap fails loudly;
  a vendored-snapshot fallback can be added later if that becomes a real need.
