# ADR 0016 — Opt-in parallel packet execution via worktree lanes

- Status: Accepted
- Date: 2026-07-18
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0004](0004-graduated-autonomy-and-pausable-loop.md) (autonomy /
  pausable loop), [ADR 0005](0005-crash-safe-resume.md) (crash reconcile),
  [ADR 0006](0006-full-autonomy-branch-integration.md) (branch integration soft
  gates), [ADR 0012](0012-delegated-loop-driver.md) (delegated relay driver).
- **Amends [ADR 0009](0009-single-directory-feature-branch-workflow.md).** ADR 0009
  removed worktrees for the *sequential* loop and explicitly left the door open
  ("parallelism is removed, not forbidden … doing so would simply mean bringing back
  an isolation mechanism for that case"). This is that case. The single-checkout
  sequential loop remains the **default and unchanged**; worktrees return **only**
  under an opt-in `--parallel` mode.

## Context

The guided loop is strictly sequential: run-state carries one `branch`, one `cursor`,
one `last_green_commit`, and only one packet is ever in flight (ADR 0009). Yet the
gspec roadmap already declares feature-level independence (`depends_on`,
`parallel_group`), and many packets within a feature touch disjoint files. An
N-independent-packet backlog therefore takes sum-of-durations when it could take
max-of-durations. The user wants an opt-in mode that runs the maximum number of
dependency-independent packets concurrently and integrates the results.

The hard problem is not running agents in parallel — it is **reconciling their work
back into one branch without silently corrupting it.** Two lanes that edited the same
file produce a merge conflict (or, worse, a clean-but-wrong auto-merge) that no
unattended loop should resolve.

## Decision

**Add an opt-in `--parallel` mode to `/gaffer:run-loop` and
`/gaffer:resume`. It runs each concurrent packet in its own git *worktree
lane*, and it is safe because file-set disjointness is a *scheduling invariant*, not
a hope.**

1. **Worktrees, only in parallel mode.** Each concurrent lane is a worktree at
   `../<repo>-worktrees/<task-id>` (`ORCH_WORKTREES_ROOT` override) on an
   `orch/<task-id>` branch cut from the integration base, managed by
   `scripts/worktree.sh` (revived from the pre-0009 implementation). The sequential
   loop still runs in the single checkout with no worktree.

2. **The dependency graph makes merges conflict-free by construction.**
   `/gaffer:build-packet-dependency-tree` (+ the deterministic
   `scripts/packet-graph.sh`) computes a packet DAG with two edge kinds:
   - **ordering** — B depends on A when B `consumes` a signature A `produces`, or B's
     feature `depends_on` A's feature. Drives topological waves.
   - **mutual exclusion** — P and Q may never run concurrently when their
     `allowed_files` could touch a common path (glob-prefix overlap). *Unknown/empty
     file scope excludes everything* (serialize what we cannot prove disjoint).
   The scheduler only ever co-dispatches packets that are pairwise non-excluding, so
   concurrent lanes have **disjoint file sets** — and a serialized merge of disjoint
   changes cannot textually conflict.

3. **A real conflict is an escalation, never an auto-resolve.** If a merge does
   conflict, the disjointness analysis missed a shared file (a lane wrote outside its
   declared `allowed_files`, or two globs overlapped). The loop STOPS and escalates,
   naming the packets and the file. Auto-resolving unreviewed conflicts is a hard
   gate; the guard hard-denies the `reset --hard`/`--force` escapes regardless.

4. **Integration is serialized and full-autonomy-gated (ADR 0006).** At
   `full-autonomy` the scheduler merges green lanes back into the integration branch
   **one at a time** (`git merge --no-ff`), rides the existing non-`main` merge soft
   gate, and removes each lane's worktree (which refuses on unmerged work). Below
   `full-autonomy` it stops at "N green `orch/*` branches ready for review." **Merge
   to `main`, releases, PRs, and the danger floor stay human at every level.**

5. **Wave-chaining requires `full-autonomy`.** A dependent packet's worktree is cut
   from the integration base *after* its dependencies are merged in, so it sees them.
   Below `full-autonomy` (no auto-integration) parallel mode runs only the first ready
   wave and stops — it never chains onto work the human has not integrated.

6. **The driver is the single writer of run-state.** run-state schema advances to
   **v3** (`mode: parallel`, `max_parallel`, `graph`, a `packets[]` status map, and a
   `lanes[]` list). The top-level scheduler owns every run-state write; dispatched
   lane agents are stateless workers that return only a check-in. This removes any
   multi-writer race on the one file that survives a session.

7. **Crash reconcile becomes per-lane, reusing the proven table.**
   `runstate.sh reconcile-parallel` applies the ADR 0005 `clean`/`adopt`/`discard`/
   `escalate` decision — factored into one shared `_reconcile_tree` core — to **each
   lane** (its worktree if still live, else its branch in the shared `.git`), plus a
   `restart` outcome for a lane that never checkpointed. One lane escalating stops
   that lane; the others proceed.

8. **The guard is unchanged; lanes get `ORCH_AUTONOMY` by env.** The guard already
   resolves config from any cwd and honors committed `.agents/` policy inside a
   worktree (verified: `autonomy_ceiling` still clamps, `guard-extra-*` and the SECRET
   floor still fire from a worktree cwd). The one gap — a session-written
   `.agents/autonomy` is gitignored and absent in a fresh worktree — is closed by the
   driver **exporting `ORCH_AUTONOMY` to each lane**, which `resolve_autonomy` reads
   first. No guard code change was required.

9. **The concurrency cap is per-repo.** `.agents/project-overrides.yaml` →
   `max_parallel_packets` (default **5**) caps concurrent lanes, on top of the
   harness's own subagent cap and account limits.

## Consequences

- **Opt-in, isolated blast radius.** Nothing changes for anyone who does not pass
  `--parallel`; the default loop is byte-for-byte ADR 0009. Worktree lifecycle,
  sibling directories, and the packet graph exist only for parallel runs.
- **Packet-level parallelism is only as parallel as file structure allows.** A
  feature with a shared spine (one service, one schema, one route table) serializes
  those packets via overlap edges. The win concentrates at the feature-group level,
  where the roadmap already asserts independence; intra-feature parallelism is a
  bonus where files are genuinely disjoint. It degrades gracefully to sequential —
  never *unsafely* parallel.
- **New testable cores, pinned before the driver depends on them.**
  `scripts/packet-graph.sh` (+ `test-packet-graph.sh`), the revived
  `scripts/worktree.sh` (+ `test-worktree.sh`), and the multi-lane `runstate.sh`
  additions (+ `test-runstate.sh` v3 cases) are unit-tested without a live agent;
  CI runs the two new suites alongside the existing guard/runstate sweeps.
- **Two levels of subagent nesting.** The scheduler dispatches N chief-engineers, each
  of which delegates to an implementer — the same depth the ADR 0012 relay already
  uses, done N-wide. It assumes the harness permits nested delegation (it does today).
- **Resume is same-machine, as before.** run-state v3 is still gitignored local
  bookkeeping; the `orch/*` lane branches and their `[orch packet:<id>]` trailers are
  what survive in git, and `reconcile-parallel` rebuilds lane state from them.
