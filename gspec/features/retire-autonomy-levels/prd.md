---
spec-version: v2
depends_on: [retire-unused-loop-modes]
---

# Feature: retire-autonomy-levels

## Overview

The guard (`hooks/guard.sh`) uses an autonomy level to decide which of `git commit`, `git merge`, `git rebase` and `git push` to allow. The level is one of `interactive`, `supervised`, `autonomous` or `full-autonomy`. It comes from an environment variable or a per-repository file and can be capped by a per-repository ceiling. No level below the top one is in use: all ten repositories on the operator's primary machine set `.agents/autonomy` to `full-autonomy`, none sets `autonomy_ceiling`, and no session transcript shows `/gaffer:set-autonomy` being typed.

This feature is part of the 2026-09-14 loop-cost redesign. It removes the levels and locks every repository to what `full-autonomy` allows today. A setting held at one value everywhere is not a real choice, yet it still costs upkeep: a policy branch in the guard, per-level cases in its regression sweep, and level branches in the loop and agent instructions. Every later part of the redesign would otherwise have to carry that branch too.

## Users & Use Cases

- **The operator** runs the loop across many repositories, always at `full-autonomy`. They need one rule set everywhere, not a setting to maintain in each repository.
- **The plugin maintainer** keeps the guard and its regression sweep correct. They need fewer policy branches and fewer per-level cases to keep passing, without losing a case that protects an action the guard always denies.
- **A consumer repository** upgrades through `/gaffer:migrate` and is left with no level configuration.

## Scope

**In**
- the four capabilities below
- level references in every shipped file the first success metric counts, restated as the fixed rule set wherever they grant or withhold a git step, including the kickoff report shape in `templates/report-templates.md`, `hooks/session-start.sh` and the level cases in `scripts/test-metrics.sh`

**Out**
- any change to what the guard always denies or asks about, or to `bypass-ask-tier`; the first capability keeps these as they are
- the thin loop driver and the escalation decider (`thin-loop-driver`, `escalation-decider`)

**Deferred**
- nothing beyond the Deferred Decisions below

## Capabilities

- [ ] **P0**: One fixed rule set
  - in every repository, including one with no `.agents/autonomy` (which today defaults to `interactive`), `hooks/guard.sh` allows exactly what `full-autonomy` allows today. That means `git commit` on a branch other than `main`/`master`, and a `git merge` into, `git rebase` of, or `git push` to such a branch
  - in every repository it still denies a commit on `main`/`master`; a merge into, rebase of, or push to `main`/`master`; history rewrites such as `git commit --amend`; and a commit that stages a secret path. Secret-path writes still hard-deny, and the ASK tier (dependencies, migrations, deploys, review paths) and every hard-deny floor are unchanged
  - the level definitions in ADRs 0004 and 0006 are marked superseded in part; the gate split, pausable loop and integration onto non-main branches they decide stay in force

- [ ] **P0**: Level controls are removed
  - `/gaffer:set-autonomy` (`skills/set-autonomy`) is gone from the shipped plugin, and the guard no longer reads `ORCH_AUTONOMY`, `.agents/autonomy` or `autonomy_ceiling`. A lower level left in any of them changes no guard decision
  - the `run-loop`, `resume` and `pause` instructions and the `chief-engineer`, `architect` and `implementer` agents no longer branch on a level or tell an agent to check one
  - `scripts/test-guard.sh` drops every per-level case, meaning one that expects a denial only a level below `full-autonomy` produces, or that tests how the level is resolved (precedence, the ceiling clamp), and every case that exists only for `.agents/autonomy` or `ORCH_AUTONOMY`. It keeps every other case, including every always-denied, ask and `full-autonomy` allow case outside the dropped set, with its level setting removed

- [ ] **P1**: Migration cleans up
  - `/gaffer:migrate` deletes `.agents/autonomy` wherever present, reporting the deletion as a change to commit when the file was tracked
  - it removes the `autonomy_ceiling` key and the comment block that introduces it from `.agents/project-overrides.yaml`, each only where present, and leaves the rest of that file as it was
  - it reports, never edits, each line in the repository's own `CLAUDE.md` and `spec-setup.md` that refers to an autonomy level or `/gaffer:set-autonomy`, and any `ORCH_AUTONOMY` entry in the repository's `.claude/settings.json`, because those belong to the human
  - its report names every change it made and everything it left in place, and a second run on the same repository changes nothing

- [x] **P1**: Metrics stay comparable
  - a run whose window starts after the plugin that ships this feature is installed records the level as `full-autonomy` in the same field as before, without reading `ORCH_AUTONOMY` or `.agents/autonomy`; re-collecting a run whose window started before that install records `unknown`
  - a run packet collected before that install and not re-collected keeps the level it recorded, `unknown` included

## Dependencies

- `retire-unused-loop-modes`: built first, so the parallel-mode and rate-limit files that also reference levels are already gone.
- `thin-loop-driver`: depends on this feature, because it builds on a loop with no level branching.

## Assumptions & Risks

- A repository that relied on the `interactive` default to gate commits loses that gate. Every repository checked on the primary machine already runs `full-autonomy`, but other machines are unverified.
- Ad hoc sessions in any repository with the plugin installed can now commit, merge, rebase and push onto branches other than `main`/`master` without the guard stopping them. Releases and PRs are not guard-gated; they stay the human's by convention and remote branch protection, and the denials in the first capability still hold.
- Dropping per-level cases could also drop a case that protects an always-denied action or a `full-autonomy` allow. The second success metric is how that gets caught.

## Success Metrics

- **No level left to offer.** Count the shipped skill, agent, script, template and documentation files, plus the plugin and marketplace descriptions, that name `interactive`, `supervised` or `autonomous` as an autonomy level, or mention `autonomy_ceiling`, `ORCH_AUTONOMY`, `.agents/autonomy` or `/gaffer:set-autonomy`, or present autonomy as a selectable setting. Excluded are the migrate path that removes them and historical records (ADRs, the changelog, completed feature specs). Target: 0 files at the release commit. Baseline: the count on the commit this feature starts from, after `retire-unused-loop-modes` has landed.
- **Guard cases survive.** The number of `scripts/test-guard.sh` cases the second capability keeps is the same at the release commit as on the commit this feature starts from. Every one of them passes, and every regression sweep passes at release.

## Implementation Context

> This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Whether a stricter mode ever returns.** This waits until a repository actually needs one. It would then be specced fresh, not by restoring the four levels.
