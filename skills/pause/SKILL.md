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

**Before step 4, `Read` both `${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md`**
(the glyph vocabulary, the indentation contract, the decision block) **and
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`** (shape **B**, which step 4 emits).
Naming a path is not reading it, and unread they produce free prose. Do this while the
checkpoint work is in flight, not after — you stop immediately once step 4 is written.

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

  `.agents/run-state.yaml` is gitignored (ADR 0009) — as are the finding bodies in
  `.agents/findings/` and `run-state-note-archive.md`, which travel with it (ADR
  0022) — so `--include-untracked` sweeps the disposable scratch but leaves the
  whole run record in place. Record
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

**A pause is where findings pile up, so route them before you write** (ADR 0022).
Everything you learned this run that the next session would want is one of three
things, and only the last belongs in run-state:

| What you have | Where it goes |
|---|---|
| "this should be built/fixed" | **backlog** — a gspec task/feature, sequenced in `.agents/roadmap.yaml`. Not a finding; a findings file holding future work is a shadow backlog competing with gspec (ADR 0020). |
| a gotcha, a constraint, a decision **and its rationale**, a resolved question | **a finding** — `runstate.sh add-finding .agents/run-state.yaml <id> "<one line>"`, detail into `.agents/findings/<id>.md` |
| the single-sentence "where we stopped" | `note:` |

Do **not** write findings into `note:`, and do **not** invent a
`resolved_questions:` list — a real run grew one to 21,664 chars because there was
nowhere else to put it, and every later dispatch paid for it. The one-line summary
is what stays in run-state; the body is what the next session opens **only if the
summary tells it to**.

**Write it atomically** so a crash mid-write cannot corrupt the only memory the
loop has — compose the full file and pipe it through the run-state helper (it
writes to a temp file and renames):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh write .agents/run-state.yaml <<'YAML'
schema: 3
status: paused
updated_at: <now-UTC>
branch: orch/<task-id>
last_green_commit: <verified-green-sha>
backlog:
  cursor: <next-packet>
  done: [ ... ]
  pending: [ ... ]
pending_questions: [ ... ]
findings:
  - id: <carry EVERY existing index entry through verbatim>
    summary: <...>
    file: .agents/findings/<id>.md
YAML
```

**`write` REPLACES the whole file, `add-finding` APPENDS to it — so the order is
write first, findings second.** Run every `add-finding` from the routing table
above *after* this write, not before: a finding recorded first is erased by the
write, and because the body in `.agents/findings/` survives on disk you are left
with an orphaned body and no index entry pointing at it — the one failure the
index exists to prevent. For the same reason, any finding already in the index
from earlier in the run must be carried through the heredoc verbatim; dropping a
line here silently unlinks a body that is still sitting on disk.

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

## 4. Emit the stop report, then stop

A pause is a stop, so the human gets the **stop report** — shape B in
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md` (the plugin produces reports; the
frontend delivers them — ADR 0004). Fill it from what you already know; do not
re-open the repo to embellish it:

- the opening sentence — why it stopped ("$ARGUMENTS", if given) and whether
  anything is at risk (after steps 1–3, the answer is normally "nothing"),
- **Shipped** — what each landed packet made true, in plain words. Not a packet-id
  list: `wbr-t14` means nothing to the human a week later, **Rate-limit auto-pause**
  (`wbr-t14`) does.
- **Not done** — what is left and why, one clause each,
- **Decisions for you** — every unanswered **blocking** question, rewritten as an
  answerable choice: the two real options, what follows from each, your lean, and
  what happens by default if they say nothing. A question the human must go reading
  to understand is a question that stalls the run.
- **Recommended next** — the single action that unblocks the most,
- **State** — branch, green SHA, tree clean, `/gaffer:resume`. Name the stash ref
  here too if step 1 set scratch aside, so they can recover or drop it.

If you are reporting into an automated caller rather than to the human, emit the
wire check-in from `${CLAUDE_PLUGIN_ROOT}/templates/check-in.md` as well — it is what
the scheduler parses.

Then **stop cleanly**. Do not start the next packet. A later session resumes with
`/gaffer:resume`.
