---
name: pause
description: Pause the guided autonomy loop at a safe checkpoint. Roll to the last green commit on the feature branch (never mid-edit), discard scratch, persist .agents/run-state.yaml, emit a status check-in, and stop cleanly so a later session can resume exactly here. Use when the user wants to stop for now, shut the laptop, close Claude Desktop, or hand off.
argument-hint: (optional reason to record in the check-in, e.g. "shutting down for the night")
---

# Pause the run $ARGUMENTS

Bring the run to a **safe, resumable rest state** and stop. The invariant you
must guarantee: the loop's working tree ends **clean** at a **green commit**, and
`.agents/run-state.yaml` records enough to reconstruct the backlog in a fresh
session. Never pause mid-edit. See [ADR 0004](../../docs/adr/0004-graduated-autonomy-and-pausable-loop.md).

The **Chief Engineer** runs this. Do **not** cross a hard gate to pause — pausing
never justifies a migration, a `main` commit, a dependency change, or a
sensitive-path edit.

A pause may be requested mid-run by a human/frontend touching the sentinel
(`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh request-pause .agents/pause "<reason>"`,
ADR 0017); the running loop polls it at safe boundaries and hands here. However you
were triggered, the steps below are the same — and once the checkpoint is durable
you **clear the sentinel** (step 3) so a later resume starts clean.

## 1. Reach a safe checkpoint (never mid-edit)

Inspect the loop's working tree — the single local checkout, currently on the
`orch/<task-id>` feature branch. Then, in order of preference:

- **Already green + committed** → that commit is your checkpoint. Nothing to
  discard.
- **Uncommitted work that is green and in policy** (build+tests pass, branch is
  not `main`/`master`, no hard-gate path in the diff) → commit it on the branch
  first (this is the Chief Engineer's soft-gate commit), making it the
  checkpoint. **You are responsible for verifying green build+tests before this
  commit — the guardrail hook cannot run the suite.** Put the write-ahead trailer
  `[orch packet:<cursor>]` in the commit message (its own line), so that if a
  crash strikes between this commit and the run-state write below, a later resume
  can *adopt* the commit instead of escalating (ADR 0005).
- **Uncommitted scratch that is NOT a safe checkpoint** (red, incomplete, or
  touches a hard gate) → **set it aside non-destructively**, leaving a clean tree
  at the last green commit. Use `git stash`, which is recoverable (nothing is
  destroyed) and guard-safe — unlike `reset --hard`/`clean -f`, which the
  guardrail hard-denies:

  ```bash
  git stash push --include-untracked -m "orch pause scratch: <task-id>"
  ```

  `.agents/run-state.yaml` is gitignored (ADR 0009), so `--include-untracked`
  sweeps the disposable scratch but leaves the run-state record in place. Record
  the stash ref in the check-in (step 4) so the human can recover or drop it.
  Because the loop shares your **single checkout**, this scratch may include work
  you have not reviewed — **escalate to the human before stashing if there is any
  doubt it is disposable loop scratch** rather than something they want kept.

## 2. Verify the checkpoint

Confirm both hold before writing state — if either fails, stop and report; do not
write a run-state that lies:

```bash
git status --porcelain      # must be EMPTY (clean tree)
git rev-parse HEAD          # must equal your chosen green SHA
```

## 3. Persist run-state

Write (or update) **`.agents/run-state.yaml`** in the local checkout from the
template at `${CLAUDE_PLUGIN_ROOT}/templates/run-state.yaml`. This file is tracked
on the feature branch and records enough to reconstruct the run in a fresh
session. Fill in truthfully:

- `status` — **`paused`** normally, or **`blocked`** if you are stopping on an
  unanswered `blocking` question. Setting this to a non-`running` value is what
  tells the next session you exited *cleanly* rather than crashed (ADR 0005).
- `branch` — the `orch/<task-id>` branch,
- `last_green_commit` — the SHA you verified in step 2,
- `backlog.cursor` / `done` / `pending` — where the loop stopped and what remains,
- `pending_questions` — every unanswered blocking/high question, with severity.

**Write it atomically** so a crash mid-write cannot corrupt the only memory the
loop has — compose the full file and pipe it through the run-state helper (it
writes to a temp file and renames):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh write .agents/run-state.yaml <<'YAML'
schema: 2
status: paused
updated_at: <now-UTC>
branch: orch/<task-id>
last_green_commit: <verified-green-sha>
backlog:
  cursor: <next-packet>
  done: [ ... ]
  pending: [ ... ]
pending_questions: [ ... ]
YAML
```

Order matters: reach the safe checkpoint and verify it (steps 1–2) **before**
this write — a run-state that says `paused` must be true when it is written. This
file is tracked; committing it is fine (it is not a hard-gate path), but a `main`
commit is not — commit it on the feature branch or leave it staged for the human,
never on `main`.

**Then clear the pause sentinel** so the fulfilled request cannot re-halt a later
resume: `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh clear-pause .agents/pause`
(sweeps any per-lane `.agents/pause.<task-id>` too). The durable record is now
`status: paused` in run-state; the transient request has served its purpose (ADR 0017).

## 3b. Snapshot run-metrics (best-effort, ADR 0019)

A pause is the natural checkpoint to pin the run's metrics — especially the
**perishable** token data, which is parsed from session transcripts that may later be
rotated or reformatted. Now that the checkpoint is durable, assemble a fresh packet:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect || true
```

This is **strictly non-critical**: it only reads bookkeeping and writes
`.agents/metrics/<run-id>/run-metrics.json`. **Never let it affect the pause** — if it
errors or `jq` is absent, ignore it and continue. Do not run it before the checkpoint is
verified and persisted (steps 1–3). You may fold a one-line summary (`metrics.sh show`)
into the check-in below.

## 4. Emit a status check-in, then stop

Produce a well-formed **status check-in** using the shape in
`${CLAUDE_PLUGIN_ROOT}/templates/check-in.md` (the plugin produces check-ins; the
frontend delivers them — ADR 0003/0004). Keep it short and action-oriented:

- what landed (packets done, last green SHA),
- where the cursor is and what is pending,
- any **blocking** questions the human must answer before resume can proceed
  (tag each with its severity),
- the reason for the pause ("$ARGUMENTS", if given).

Then **stop cleanly**. Do not start the next packet. A later session resumes with
`/gaffer:resume`.
