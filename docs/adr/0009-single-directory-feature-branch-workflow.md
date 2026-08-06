# ADR 0009 — Single-directory feature-branch workflow: remove worktree isolation

- Status: Accepted (amended by [ADR 0016](0016-parallel-worktree-lanes.md))
- Date: 2026-07-07
- **Amended by [ADR 0016](0016-parallel-worktree-lanes.md):** worktrees return, but
  **only** under the opt-in `--parallel` mode, for concurrent packet lanes. The
  single-checkout sequential loop this ADR defines stays the **default and
  unchanged** — 0016 is additive, exactly the "bring back an isolation mechanism for
  that case" this ADR anticipated.
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0004](0004-graduated-autonomy-and-pausable-loop.md) (the
  pausable/resumable loop) and [ADR 0005](0005-crash-safe-resume.md) (crash-safe
  reconcile). Retains the guard cross-tree protection from
  [ADR 0006](0006-full-autonomy-branch-integration.md).
- **Supersedes, in part:** the **worktree-isolation** decision — the "Phase 3
  worktree isolation is a prerequisite" invariant in ADR 0004, the
  worktree-mechanics split in ADR 0005, and the whole worktree-isolation plan.
  The autonomy, gate, checkpoint, and
  crash-recovery decisions in ADR 0004/0005 stand unchanged; only the *isolation
  mechanism* changes.

## Context

The guided loop isolated every packet in its own **git worktree** — a sibling
directory `../<repo>-worktrees/<task-id>` on an `orch/<task-id>` branch, managed by
`scripts/worktree.sh` — to (a) keep automated commits off the user's checkout and
(b) enable parallel specialists.

Two things make that a poor trade in practice:

1. **The loop is strictly sequential.** Run-state carries exactly one `branch`,
   one `cursor`, one `last_green_commit`. Only one packet is ever in flight, so the
   worktree bought *defensive* isolation, not concurrency.
2. **It taxes every consumer repo.** A second working directory that each project
   (and its tooling, and its humans) must reason about — sibling paths, prune/
   remove lifecycle, "which copy am I editing" — for a benefit the sequential loop
   never used.

The user wants the loop to run entirely in the **single local checkout** using a
`develop` integration branch and `orch/<task-id>` feature branches, and to retrofit
that into other projects so none of them has to guard against worktrees.

## Decision

**Work in one checkout, on feature branches. No worktrees, and no toggle for
them.**

- **Branch, don't isolate.** Each packet runs on `orch/<task-id>` cut from the
  integration base in the current checkout: `git switch -c orch/<task-id> <base>`,
  where `<base>` is `.agents/project-overrides.yaml` → `integration_branch` (default
  `develop`, else `main`/`master`). This also fixes the old base-detection bug where
  features always forked from `main`.
- **No replacement script.** `worktree.sh` and `test-worktree.sh` are deleted. The
  operations that survive are ordinary git the agents already run — branch/switch,
  `git diff <base>...HEAD` for review — expressed as guidance in the loop skills,
  not a wrapper. Confirmed against the guard: these plus `git stash` and a
  feature-branch `git commit` are all allowed; only `reset --hard`/`clean -f`/
  `--force` stay hard-denied.
- **Discard is non-destructive.** To drop non-checkpoint scratch, the loop uses
  `git stash --include-untracked` (recoverable) instead of the worktree-era
  `reset --hard`/`clean -fd`. In a shared checkout this is both safer (nothing is
  destroyed) and guard-legal (no wrapper punching through the hard-deny).
- **Run-state is gitignored local bookkeeping.** `.agents/run-state.yaml` moves
  from git-tracked to **gitignored**. This is what makes single-checkout mechanics
  coherent: `git stash -u` skips ignored files (so a discard never eats the
  checkpoint), `git add -A` never commits it, and `git status`/`runstate.sh
  reconcile` never see it as tree dirt — so the `clean`/`discard`/`adopt`/`escalate`
  decision table works unchanged with no code change to `reconcile`.
- **The guard keeps its cross-tree protection.** `resolve_git_dir` (judging the
  branch of the tree a command actually names via `cd`/`git -C`, not just the
  payload cwd) is retained — it closes a real bypass for *any* second repo (clone,
  submodule), independent of worktrees. Only its comments and tests were reworded
  off worktrees (the regression now uses a second clone).

**Parallelism is removed, not forbidden.** Deleting the worktree machinery removes
the only mechanism that ran parallel committing specialists, and the loop stays
sequential. Nothing here bans reintroducing parallel workstreams later; doing so
would simply mean bringing back an isolation mechanism for that case.

## Consequences

- **Consumers reason about one directory.** No sibling trees, no worktree lifecycle,
  nothing to gitignore beyond the run-state file. Retrofit is: adopt `develop` +
  `orch/*` branches and gitignore `.agents/run-state.yaml`.
- **Run-state no longer travels via git.** It persists on local disk across
  sessions (same-machine pause/resume is unaffected) but is no longer committed, so
  cross-machine resume via git is dropped — an acceptable trade for the
  single-user, single-checkout model.
- **A lost run-state is recoverable, not fatal.** Because the `orch/<task-id>`
  branch and its `[orch packet:<id>]` commit trailers *are* committed, and the task
  backlog lives in the committed spec, `/gaffer:resume` reconstructs a
  missing run-state from git via `runstate.sh reconstruct` (branch, candidate green
  tip, and the completed-packet list), then verifies green and rebuilds the backlog.
  The one thing git cannot restore is `pending_questions` — those lived only in the
  file (and in the last delivered check-in), so resume flags them as unrecovered.
- **The crash-recovery guarantees of ADR 0004/0005 are preserved.** Write-ahead
  packet commits with the `[orch packet:<cursor>]` trailer, atomic run-state writes,
  and the reconcile decision table all stand; they now inspect the single checkout
  (`reconcile <file> .`) instead of a worktree path.
- **CI drops `test-worktree.sh`.** The branch workflow is plain git; guard behavior
  is still pinned by `test-guard.sh` and the loop invariants by `test-runstate.sh`
  (rewritten for a single-checkout feature branch).
