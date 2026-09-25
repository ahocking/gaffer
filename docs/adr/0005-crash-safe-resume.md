# ADR 0005 — Crash-safe resume: auto-detect on session start, a status signal, and write-ahead orphan-commit adoption

- Status: Accepted
- Date: 2026-07-04
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0004](0004-graduated-autonomy-and-pausable-loop.md) (the
  pausable/resumable loop and durable `.agents/run-state.yaml` this hardens).
  Frontend-agnostic throughout: produce check-ins/context; do not build delivery.
- Superseded in part by: [ADR 0009](0009-single-directory-feature-branch-workflow.md).
  The crash signal, atomic writes, and write-ahead orphan-commit **reconcile
  decision table all stand** — only the mechanics change for a single checkout:
  `reconcile` inspects the local checkout (`.`) rather than a worktree path (the
  git-worktree split described below is gone), and `run-state.yaml` is now
  **gitignored local bookkeeping** rather than a git-tracked file.

## Context

ADR 0004 made the guided loop resumable **on a clean pause**: `/gaffer:pause`
rolls to a green commit, verifies the tree, and writes `.agents/run-state.yaml`.
`/gaffer:resume` reads that file and continues. That covers the *planned*
stop. It does not cover the *unplanned* one — an accidental reboot, the lid
closing into a sleep-death, Claude Desktop being force-quit, or a plain crash —
which is precisely when durability matters most. Three gaps remained:

1. **Nothing auto-detected an in-flight run when the session reopened.** The
   "read run-state at session start" instruction lived only in the Chief-Engineer
   prompt, so it fired only if that agent happened to be invoked. Reopening a
   plain session silently forgot the run.
2. **The commit→run-state update was not crash-atomic.** The loop commits a packet
   *then* advances run-state. A crash in that window leaves a green "orphan" commit
   one ahead of `last_green_commit` that the file does not know about — and resume
   treated any unexpected committed work as a hard **escalate/stop**, even though
   that commit was a legitimately-completed packet.
3. **A resuming session could not tell a clean pause from a crash.** run-state had
   no lifecycle field, so "human paused" and "laptop died mid-run" were
   indistinguishable, and reconciliation could not be tailored to either.

## Decision

Add a thin recovery layer on top of ADR 0004's durable checkpoint. No new
persistent process, daemon, or heartbeat thread — the execution model is
model-driven tool calls, not a long-lived process, so liveness detection would be
unreliable. Everything hangs off state already on disk (git + run-state).

### 1. A `status` lifecycle field is the crash signal

`.agents/run-state.yaml` gains `status: running | paused | blocked | done`
(schema bumped to 2). The loop sets `running` when it picks up a packet; pause
sets `paused` (or `blocked` when stopping on a blocking question); completion sets
`done`. The signal is simple and reliable: **a fresh session that finds
`status: running` knows the previous session ended without pausing** — i.e. it
crashed — because a new session starting is itself proof the old one is gone. We
deliberately do *not* rely on pid liveness or wall-clock staleness (`updated_at`
is informational only): a legitimate loop iteration can run for many minutes
between writes, so a timeout would produce false crash calls.

### 2. Auto-detect on session start (a `SessionStart` hook)

`hooks/session-start.sh` runs on `startup|resume`. If `.agents/run-state.yaml`
exists with `status != done`, it injects `additionalContext` describing the run
(branch, cursor, pending/blocking counts) and the recommended action, tailored to
`status` — `running` → "treat as a crash, reconcile first"; `blocked` → "surface
the blocking question and wait"; `paused` → "resume normally". This makes
reopening Claude *spin the run back up* (offer to resume; auto-resume only under
`autonomous`) instead of waiting for the human to remember. The hook only
**produces context** — the session acts on it; no bespoke
delivery transport is built. The hook is purely additive and **fails open**: any
error, or no in-flight run, yields exit 0 with no output and never blocks a
session. It is jq-free (reads the repo root from `$CLAUDE_PROJECT_DIR`).

### 3. Write-ahead recovery: tag commits, adopt torn writes

Every packet commit carries the trailer `[orch packet:<cursor>]`. Because the
commit lands *before* the run-state write, the trailer turns the crash window from
an escalation into a deterministic recovery: on resume,
`scripts/runstate.sh reconcile` compares the durable checkpoint to the worktree's
real git state and emits one decision:

| Situation | `DECISION` | Resume action |
|---|---|---|
| HEAD == `last_green_commit`, tree clean | `clean` | continue from cursor |
| Uncommitted scratch on top of green | `discard` | reset to green, continue |
| One **clean** orphan commit tagged for the **cursor** packet | `adopt` | re-verify green, adopt as new checkpoint, advance cursor |
| Diverged history, >1 ahead, untagged, tag≠cursor, or mixed with scratch | `escalate` | stop, ask the human |

`adopt` is the torn-write fix: the packet was really done, so resume records it
rather than redoing or discarding it. The helper is **read-only** and encodes the
table so the decision is unit-testable without a live agent; re-running the suite
before adopting stays the Chief Engineer's job (a hook cannot).

### 4. Atomic run-state writes

All run-state persistence goes through `scripts/runstate.sh write` (compose the
full file, write to a temp file, `rename` over the original). Rename is atomic on
the same filesystem, so a crash *during* the write cannot corrupt the only memory
the loop has — the reader sees either the old file or the new one, never a torn
one.

## Consequences

- **An unplanned reboot/sleep/crash is now recoverable to the same guarantee as a
  clean pause:** worst case, the single in-flight packet is discarded as scratch;
  a torn-write orphan is adopted, not lost or repeated. Reopening Claude
  auto-surfaces the run.
- **`scripts/runstate.sh` is the new home for checkpoint I/O and the reconcile
  decision** (git-worktree mechanics stay in `worktree.sh`). `test-runstate.sh`
  gains cases for the status field, atomic writes, the SessionStart summary, and
  every reconcile branch.
- **run-state schema → 2**, adding `status` and (informational) `updated_at`.
  Readers that only parse `branch`/`last_green_commit`/`backlog` are unaffected.
- **The commit-message trailer is now load-bearing** for recovery — the loop,
  pause, and Chief-Engineer prompts all emit `[orch packet:<cursor>]`.
- **No new failure surface for normal sessions:** the SessionStart hook is silent
  and fail-open unless an in-flight run exists; the guardrail's hard/soft gates
  (ADR 0004) are unchanged — reconcile only ever discards scratch or adopts a
  branch commit, never touches `main` or a hard-gate path.

## Relocated from skills (2026-09-25) — the pause skill's write-ahead and atomic-write reasons

Moved out of `skills/pause/SKILL.md` by `skill-prompt-trim`. The skill keeps each
rule with at most a one-clause reason; the fuller wording is recorded here.

- **Why the pause's work-in-progress commit carries the trailer** (pause step 1):

  > Put the write-ahead trailer `[orch packet:<cursor>]` in the commit message (its
  > own line), so that if a crash strikes between this commit and the run-state
  > write below, a later resume can *adopt* the commit instead of escalating (ADR
  > 0005).

- **How the run-state write is atomic** (pause step 3):

  > compose the full file and pipe it through the run-state helper (it writes to a
  > temp file and renames)

## Relocated from skills (2026-09-25) — the resume skill's reconcile and adopt reasons

Moved out of `skills/resume/SKILL.md` by `skill-prompt-trim`. The skill keeps each
rule with at most a one-clause reason; the fuller wording is recorded here. The
membership-recovery reason moved with its rule into `skills/run-loop/SKILL.md` §3's
**Form this packet's members** step, which keeps one clause of it.

- **Why `discard` escalates on doubt instead of stashing** (resume §2). The skill
  keeps "the checkout is shared, and `reconcile`'s reviewed-output patterns cannot
  cover everything". It used to read:

  > Because the loop shares this single checkout, that scratch may include
  > work you did not produce — `reconcile` already escalates instead of `discard`
  > when it recognizes a reviewed-output path (e.g. `.gspec/memory/pending/`, agent
  > memories awaiting `/gspec-memorize`), but its pattern list cannot cover
  > everything: **escalate to the human before stashing if there is any doubt it
  > is disposable loop scratch** rather than deliberate output someone else
  > produced, matching the instinct `skills/pause/SKILL.md` carries for the same
  > shared-checkout risk.

- **Why `adopt` re-reads every trailer, anchored** (resume §2). The skill keeps
  "`reconcile` checks only that first trailer", "so prose that mentions a trailer is
  never read as a member", "never loosen the anchor for it" and "`reconcile`'s own
  match is unanchored". It used to read:

  > (`reconcile` only checks that first trailer — `orphan_packet_tag` reads no
  > further)

  > — anchored to the whole line so prose elsewhere in the commit body that merely
  > *mentions* another packet's trailer cannot be read as a member, and
  > deduplicated so a repeated trailer cannot hand `record-outcome` the same id
  > twice. [...] That is the intended, safe outcome for a shape this anchored read
  > cannot confirm, not a regression to loosen the anchor for. **If the first id in
  > `$MEMBERS` is not `<cursor>` itself, escalate to the human instead of
  > adopting** — `reconcile`'s own `orphan_packet_tag` match is unanchored and only
  > reads the first hit it finds, so an orphan whose real first trailer differs from
  > what `orphan_packet_tag` matched can still reach `DECISION=adopt`; this
  > re-read, anchored, is what catches that case before anything is attested.

- **Why no adopted member is redone** (resume §2):

  > this is exactly the crash window the task exists to close, so a crash between
  > a bundled commit and the run-state write can never leave a landed member
  > unchecked and queued for re-execution.

- **Why a recovered bundle never re-runs `group`** (resume §4, now run-loop §3's
  **Form this packet's members** step). Run-loop keeps "it could shrink or grow a
  membership a start record already covers". The consequence it named:

  > the sweep below would then close members the run had started as
  > `interrupted`, or silently start a member no start record covers

## Relocated from skills (2026-09-25) — the run-loop skill's entry-routing reasons

Moved out of `skills/run-loop/SKILL.md` §2's entry-routing bullet by
`skill-prompt-trim`. No ADR owns the loop-entry routing rule; this one, which owns
the resume path it routes into, is the closest. The skill keeps each rule with at
most a one-clause reason; the fuller wording is recorded here.

- **Why entry routes on the checkpoint's status, not its existence.** The skill keeps
  "a completed run leaves its checkpoint on disk too". It used to read:

  > a completed run leaves its checkpoint on disk, so existence alone cannot tell a
  > run to continue from a run already finished.

- **Why exactly `paused`, `blocked` and `running` redirect to resume.** The skill
  keeps "(it keeps `run_id`; its `driver-mode enter` is idempotent). These are
  exactly the three statuses resume resolves." It used to read:

  > (it keeps `run_id` via its own `begin-run` call; calling `driver-mode enter`
  > again there is harmless — idempotent). These are exactly the three that entry
  > point's own decision table resolves: **`paused`** a run that called
  > `/gaffer:pause` and verified a clean checkpoint, **`blocked`** the same but
  > stopped on a blocking question, and **`running`** a run left mid-flight by a
  > session that did not pause — a crash, which that skill reconciles before it
  > trusts the tree.

- **Why a `done` checkpoint with a cursor still takes the fresh-run branch.** The
  skill keeps "the status is the authority". It used to read:

  > A `done` checkpoint that still carries a cursor or pending packets disagrees
  > with itself; the status is the authority, so it takes that same branch.

- **Why an unrecognised status writes nothing before stopping.** The skill keeps
  "the checkpoint is untracked, so a guess at it cannot be undone". It used to read:

  > and no kickoff or lint files, since no run directory exists yet. The checkpoint
  > is not tracked by version control, so guessing at a file whose state you cannot
  > read is the least recoverable move available at this point in the run.
