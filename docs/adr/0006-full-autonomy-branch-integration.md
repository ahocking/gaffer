# ADR 0006 — `full-autonomy`: delegated branch-integration git workflow under a preserved danger floor

- Status: Accepted
- Date: 2026-07-05
- Deciders: user (tech lead), orchestration plugin
- Extends: [ADR 0004](0004-graduated-autonomy-and-pausable-loop.md) (graduated
  autonomy + the hard/soft gate split). This ADR adds a fourth level above
  `autonomous` and moves three more git operations from hard gates to soft gates;
  it does not change any level at or below `autonomous`.

## Context

ADR 0004 gave the Chief Engineer the routine **commit** on a feature branch as its
only delegated ("soft") gate. Everything else in the git workflow —
**merge, rebase, push**, and any commit to `main`/`master` — stayed a hard gate at
every level, so the guided loop deliberately stops at "branch ready for review":
every green landing is a commit on an `orch/<task>` branch, and a human must then
integrate and publish it.

The user wants to be out of the loop as much as possible: let the orchestration
layer own the whole day-to-day git workflow — branch, commit, **merge, rebase, and
push** — and be asked only about **critical design/architecture decisions that are
not already captured in the design docs**. The commit-only delegation makes that
impossible: even a fully-green, low-risk backlog cannot be integrated without a
human at every merge.

## Decision

### 1. A fourth autonomy level, `full-autonomy`

Add `full-autonomy` above `autonomous` (rank 3). It is a strict superset of
`autonomous`; the three existing levels keep their exact current behavior, so no
existing run's posture changes silently. Resolution and clamping are unchanged
(env `ORCH_AUTONOMY` > `.agents/autonomy` > default `interactive`, clamped down to
`autonomy_ceiling`). A repo that never wants this level sets
`autonomy_ceiling: autonomous` (or lower).

### 2. Merge / rebase / push become soft gates — but only onto NON-`main` targets

At `full-autonomy` only, three operations move from hard to soft, delegated to the
Chief Engineer:

- **`git merge`** — merge a feature branch **into a non-`main` branch** (the
  integration branch, e.g. `develop`, or another feature branch). Merging into
  `main`/`master` stays a hard gate.
- **`git rebase`** — rebase a **non-`main`** branch to keep it current. Interactive
  rebase (`-i`) is history rewrite and stays a hard gate.
- **`git push`** — push a **non-`main` ref** (feature or integration branch) to the
  remote. Pushing `main`/`master`, and any forced push, stay hard gates.

The **integration target** a repo uses is recorded in
`.agents/project-overrides.yaml` as `integration_branch:` (informs where the loop
merges); the guard's invariant is simply *target ≠ `main`/`master`*.

### 3. The danger floor is preserved in full

`full-autonomy` delegates **only** the git workflow above (plus resolving design
questions already answered in the docs — see §4). Everything ADR 0004 called a
hard gate still hard-stops at `full-autonomy`: money/auth/authz/PII, DB schema or
migrations, secrets/`.env`/credentials, CI/deploy config, production deploys,
dependency installs/upgrades, git history rewrite (`--amend`, `-i` rebase,
force-push, `reset --hard`), and **commit/merge/push to `main`**. A merge that would
carry a change to a hard-gate path **re-escalates to the human even at
`full-autonomy`** (the guard checks the incoming diff best-effort; the commit gate
already blocks such paths from landing on loop-made branches in the first place).

### 4. Design-doc-driven escalation

The point of the level is to be asked *only* about genuinely open decisions. Before
escalating a design/architecture question, the Chief Engineer and Architect consult
the durable design record — `docs/adr/*`, the specs (gspec / Spec Kit), and
`.agents/domain-rules.md`. If the decision is **already captured** there, follow it
and proceed without asking. Escalate only design/architecture decisions that are
**not** captured (or that conflict with an accepted ADR — which means proposing a
superseding ADR, not deciding unilaterally). The danger floor in §3 escalates
regardless of what the docs say.

### Division of enforcement (unchanged from ADR 0004)

- **`guard.sh`** enforces the cheap, synchronous invariants: the active level, and
  for merge/rebase/push the *non-`main` target* + *no forced/interactive rewrite* +
  *best-effort no sensitive path in a merge*. It is the backstop.
- **The Chief Engineer / loop driver** is the primary decision-maker: it verifies
  green build+tests before integrating, and it owns the design-doc-driven
  escalation judgment a hook cannot make.

## Consequences

- **The loop can now integrate on its own** at `full-autonomy`: land green packets
  on feature branches, merge them into the integration branch, keep branches
  current with rebase, and push feature/integration branches for CI — while `main`,
  releases, and the entire danger floor stay human-gated. The safety posture for the
  dangerous, irreversible surface is unchanged from ADR 0004.
- **`guard.sh` gains three soft gates** (`check_merge_policy`,
  `check_rebase_policy`, `check_push_policy`) alongside `check_commit_policy`, plus
  a shared branch resolver. `scripts/test-guard.sh` adds cases covering
  merge/rebase/push × (`full-autonomy` vs lower) × (`main` vs non-`main`) × (forced /
  `-i` / sensitive-merge), and confirms the danger floor still denies at
  `full-autonomy`.
- **`main` is still the human's gate.** Publishing (merge to `main`, release, deploy)
  remains an explicit human step; `full-autonomy` never crosses it.
- **Risk:** a mis-scoped `full-autonomy` run could churn merges/pushes on an
  integration branch. Mitigation: `main` is untouched and every step is in git
  history and revertible; force-push/history-rewrite stay denied so the remote
  history of pushed branches is append-only under the loop;
  `autonomy_ceiling` caps the level per repo.
