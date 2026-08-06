# ADR 0004 — Graduated autonomy: Chief-Engineer commit authority, branch-scoped auto-commit, a pausable loop, and async check-ins

- Status: Accepted
- Date: 2026-07-04
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0003](0003-defer-custom-voice-frontend.md) (frontend-agnostic
  stance; the check-in delivery surface). Supersedes, in part, the placement of
  the "graduated-autonomy revisit" as a sub-bullet of the API-specialists phase
  in the original roadmap — that work is promoted here to its own phase
  (roadmap **Phase 4**).
- Extended by: [ADR 0006](0006-full-autonomy-branch-integration.md), which adds a
  fourth level, `full-autonomy`, above `autonomous` — delegating merge/rebase/push
  onto non-`main` branches while keeping `main`, releases, and the danger floor
  human-gated. The three levels defined here are unchanged.
- Superseded in part by: [ADR 0009](0009-single-directory-feature-branch-workflow.md),
  which replaces the **worktree-isolation** mechanism referenced below with a
  single-checkout feature-branch workflow. The autonomy levels, hard/soft gate
  split, pausable loop, and checkpoint semantics here all stand; only the claim that
  "Phase 3 worktree isolation is a prerequisite" no longer holds — isolation is now
  a per-packet `orch/<task-id>` branch in the one checkout, and a pause sets scratch
  aside with `git stash` rather than resetting a throwaway worktree.

## Context

The plugin today hard-gates **every** mutation: `hooks/guard.sh` denies (exit 2)
on every commit, dependency install, migration, deploy, and sensitive-path write,
and the agent prompts forbid any auto-commit. That default is correct for a
human-present financial session, but it means an unattended run **cannot make
progress past the first commit**.

The goal is guided-loop engineering: point the orchestration at a repo (e.g.
the reference consumer repo), let the agents do the work, and check in only for reviews and
genuinely critical decisions. Three concrete requirements drive this ADR:

1. **Defer the commit decision to the Chief Engineer** unless a change *truly*
   requires human approval.
2. **The loop must be pausable** so the user can shut the laptop or close Claude
   Desktop without losing work or leaving the tree in a bad state.
3. **Async check-ins** reach the user via **Claude Desktop** on the MacBook
   (synced to **Claude Dispatch** on the phone) or direct interaction.

## Decision

### 1. Two tiers of gate — hard (always human) vs soft (delegable)

Split the guardrail's gates explicitly:

- **Hard gates — always require the human, at every autonomy level:** money /
  auth / authz / PII, DB schema or migrations, secrets / `.env` / credentials,
  CI / deploy config, production deploys, git history rewrite, and **commit or
  merge to `main`/`master`**. Plus whatever a repo adds in
  `.agents/domain-rules.md` / `.agents/guard-extra-*`.
- **Soft gates — delegable above `interactive`:** commit on an isolated feature
  branch, scoped edits inside `allowed_files`, tests, docs, formatting.

The hard-gate surface — the dangerous, irreversible stuff — keeps its exact
current safety posture. Only the soft gates move.

### 2. Autonomy levels

An explicit level, set by the user **per session or per task packet** and honored
by both `guard.sh` and the agent prompts:

- **`interactive`** (default) — current behavior; the human approves every
  mutation gate.
- **`supervised`** — the Chief Engineer may auto-commit on a feature
  branch/worktree when build+tests are green, the diff stays inside
  `allowed_files`, and it crosses no hard gate. Every hard gate still stops.
- **`autonomous`** — the Chief Engineer drives the loop across task packets,
  committing on branch, pausing only for hard gates and critical questions.

**Never, at any level:** auto-merge to `main`, auto-cross a hard gate, or auto
history-rewrite. `.agents/project-overrides.yaml` can raise or lower a repo's
ceiling.

### 3. The Chief Engineer owns routine commits

Above `interactive`, "commit" moves from an unconditional hard gate to a
**Chief-Engineer-owned soft gate**, permitted only when **all** hold:

- autonomy ≥ `supervised`,
- current branch is **not** `main`/`master`,
- the staged diff touches **no** hard-gate path, and
- build+tests are **green**.

If a staged change touches a hard-gate path, the commit **re-escalates to the
human** even under `autonomous`.

**Division of enforcement** (this matters — a PreToolUse hook cannot run a test
suite):

- **`guard.sh`** enforces the cheap, synchronous, checkable invariants: the
  active autonomy level (read from an env var / `.agents/`), branch ≠ `main`,
  and "staged diff contains no sensitive path" (`git diff --cached --name-only`
  vs the sensitive-path patterns). It is the backstop.
- **The Chief Engineer / loop driver** is the primary decision-maker and is
  responsible for verifying green build+tests *before* it ever issues the commit.

### 4. Pause/resume via durable checkpoints

The loop is **pausable**. Because it runs inside a Claude Code session, closing
Desktop or shutting down ends the session — so resumability must be **durable on
disk, not in memory**.

- **Pause** means: roll forward to the next **safe checkpoint** (a green commit on
  the feature branch — *never* mid-edit), persist run state, emit a check-in, and
  stop cleanly.
- **Run state** lives in the repo (e.g. `.agents/run-state.yaml`): branch, backlog
  position, task packets done/pending, last green commit, and any questions
  pending for the human.
- **Resume**: a fresh session reads run-state and continues from the last
  checkpoint (driven by an explicit pause/resume affordance).

**Invariant:** a pause must never leave the tree unrecoverable. Worst case it
discards uncommitted scratch work back to the last green checkpoint — which is
exactly why **Phase 3 worktree isolation is a prerequisite**.

### 5. The plugin produces check-ins; the frontend delivers them

Consistent with ADR 0003 (frontend-agnostic). The plugin's job is to **produce**
well-formed check-ins at the right moments — **status updates** at checkpoints and
**severity-tagged blocking questions** at hard gates or genuine ambiguity.
**Delivery** stays the frontend's job: Claude Desktop on the MacBook, synced to
Claude Dispatch on the phone, or direct interaction. No bespoke notification
transport is built into the plugin.

## Consequences

- **Unattended progress becomes possible on feature branches** while money, auth,
  schema, secrets, deploys, and `main` stay human-gated. The safety posture for
  the dangerous surface is unchanged.
- **`guard.sh` gains autonomy-awareness** plus branch and staged-sensitive-path
  checks on commit. `scripts/test-guard.sh` must add cases covering each autonomy
  level × (`main` vs feature branch) × (sensitive vs clean staged diff).
- **Resumability constrains the loop to commit-sized atomic steps** and depends on
  Phase 3 worktrees.
- **Answers the open question** *"How should approvals be represented for fully
  hands-free use?"* — graduated autonomy levels + the hard/soft gate split, with
  routine commits delegated to the Chief Engineer.
- The task-packet template gains an `autonomy` field (and the commit/checkpoint
  semantics above); the Chief-Engineer and implementer prompts gain the
  autonomy-aware commit/pause behavior. (Implementation, not part of this ADR.)
- **Risk:** a mis-scoped `autonomous` run could churn many commits on a branch.
  Mitigation: branch isolation (nothing reaches `main`), the whole run is in git
  history and fully revertible, and `.agents/project-overrides.yaml` can cap the
  ceiling.
