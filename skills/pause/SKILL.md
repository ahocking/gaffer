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

The session running the loop as the **loop-driver** (ADR 0028) runs this, not
the Chief Engineer — the Chief Engineer is only ever dispatched, per packet, as
the interim escalation-decider stand-in. Do **not** cross a hard gate to
pause — pausing never justifies a migration, a `main` commit, a dependency
change, or a sensitive-path edit.

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
  first (this is the driver's soft-gate commit — `git commit` is not a write
  the guard's driver-mode edit block refuses), making it the
  checkpoint. **You are responsible for verifying green build+tests before this
  commit — the guardrail hook cannot run the suite.** Put the write-ahead trailer
  `[orch packet:<cursor>]` in the commit message (its own line), so that if a
  crash strikes between this commit and the run-state write below, a later resume
  can *adopt* the commit instead of escalating (ADR 0005). **This commits
  unfinished work, and a pause is never an ending: record no outcome here.**
  The packet's start stays open — the trailer is not a green outcome, and the
  sweep must not later read this still-open start as an interruption. A later
  session continues it (`record-start <cursor> --continue`) and ends it there.
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

Confirm both hold before writing state — if either fails, stop and report
(then run `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh driver-mode exit`
immediately after that stop report — idempotent even if this session never
entered driver mode); do not write a run-state that lies:

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
- `backlog.cursor` / `pending` — where the loop stopped and what remains,
- `pending_questions` — every unanswered blocking/high question, with severity.

**When the `status` you are about to write is `blocked` because the `stop`
action (`skills/run-loop/SKILL.md` §3.5) handed a question here, this pause
is a terminal outcome for the packet, not a checkpoint on work still open** —
the opposite of the WIP-commit case in step 1 above, which records none. The
`stop` action hands the question here with `packet: <cursor>` and writes no
run-state itself, so persisting `pending_questions` above and recording the
outcome below are both this step's job. `packet-bundling` means `<cursor>`
may be a bundle rather than a single task, so the question's `packet:` field
already names the whole bundle unchanged — a bundle's packet id is always its
first member's — but the *outcome* record must cover every member, not just
the cursor.

Recover the bundle's membership by the same rule T9 (`resume/SKILL.md`) and
T10 (`run-loop/SKILL.md` §3.2) state — one rule, stated once, not restated
differently here — in case this session does not already hold `$MEMBERS` as
shell state from earlier in the same packet: the cursor's own
`$RUN_DIR/<cursor>/handoff.md` (the run directory `begin-run` printed,
`.agents/loop/<run_id>/`) already exists whenever the `stop` action reaches
here (it always follows a dispatched packet), so take `$MEMBERS` from its
`BUNDLE=` line — absence means `MEMBERS=<cursor>` alone, the single-task
case, unchanged. Then re-check only the mechanical refusals against it —
`${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh task-status "$MEMBERS"`,
dropping any member whose line reads `finished` or `gone` (never the cursor
itself) — never re-deriving the scope/deps/cap judgment `group` applies when
forming a bundle fresh. Only when no handoff exists at all is there nothing
to recover, and `$MEMBERS` stays `<cursor>` alone by construction rather than
re-forming the group. Before writing the file below, record the outcome for
the surviving bundle in one call, never once per member:
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh record-outcome "$MEMBERS" blocked`
— so a bundle's later tasks share the cursor's own terminal outcome rather
than reading as still-open work a later sweep would close as `interrupted`.
A single-task packet has no `BUNDLE=` line, so `$MEMBERS` is `<cursor>` alone
and this reads exactly as `record-outcome <cursor> blocked` — the single-task
`blocked` record run-loop §3.6 already names, unchanged in shape.

**A pause is where findings pile up, so route them before you write** (ADR 0022).
Everything you learned this run that the next session would want is one of three
things, and only the last belongs in run-state:

| What you have | Where it goes |
|---|---|
| "this should be built/fixed" | **backlog** — a gspec task/feature, sequenced in `.agents/roadmap.yaml`. Not a finding; a findings file holding future work is a shadow backlog competing with gspec (ADR 0020). |
| a gotcha, a constraint, a decision **and its rationale**, a resolved question | **a finding** — `runstate.sh add-finding .agents/run-state.yaml <id> "<one line>" --packets <id[,id...]>` (mandatory — ADR 0024, there is no run-wide finding), detail into `.agents/findings/<id>.md` if you also pass `--body` |
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
  pending: [ ... ]
pending_questions: [ ... ]
findings:
  - id: <carry EVERY existing index entry through verbatim>
    summary: <...>
    packets: [<id[,id...]>]
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
frontend delivers them — ADR 0004). Assemble it from `runstate.sh run-digest
.agents/run-state.yaml` with **no** `--since` — its `packet` lines name every packet
the run began, with its outcome, whichever session ran each one, so this report reads
the same right after landing or after a compaction; do not re-open the repo to
embellish it:

- the opening sentence — why it stopped ("$ARGUMENTS", if given) and whether
  anything is at risk (after steps 1–3, the answer is normally "nothing"). **When a
  periodic pause triggered this** (the caller's reason names `pause_every_packets`,
  or check yourself: `runstate.sh periodic-pause`), name the setting here —
  *"Paused after 5 packets — `pause_every_packets: 5` in
  `.agents/project-overrides.yaml`."* — so it reads as scheduled, never as a
  failure,
- **Shipped** — the digest's `green` `packet` lines, one per landed packet, what
  each made true in plain words. Not a packet-id list: `wbr-t14` means nothing to
  the human a week later, **Rate-limit auto-pause** (`wbr-t14`) does.
- **Not done** — the digest's other `packet` lines (`failed`, `rolled-back`,
  `blocked`, `interrupted`, `abandoned`, `open`, and `paused`), what is left and
  why, one clause each. **The cursor packet you just paused on reads `paused`
  in the digest — name it with the word *paused*** (`report-templates.md`
  shape B: "the paused packet is named with the word *paused*, under
  ⚠️ Unfinished"), never folded silently into the general "left and why" text,
- **Decisions for you** — every unanswered **blocking** question (from
  `pending_questions` and the digest's `handoff-feature` lines), rewritten as an
  answerable choice: the two real options, what follows from each, your lean, and
  what happens by default if they say nothing. A question the human must go reading
  to understand is a question that stalls the run.
- **Recommended next** — the single action that unblocks the most,
- **State** — branch, green SHA, tree clean, `/gaffer:resume`. Name the stash ref
  here too if step 1 set scratch aside, so they can recover or drop it.

**Its four digest-derived tally figures come from `runstate.sh run-tally
.agents/run-state.yaml`, and you compute none of them** — exactly as
`${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` §4 takes them: `SHIPPED=`,
`FAILED=`, `UNFINISHED=` and `DECISIONS=` are ✅, ⛔, ⚠️ and 🔀, counted by the
core from the same whole-run digest with the 🔀 dedup already applied; render
each as printed, never recounted from the `packet` or `decision` lines. ⬚ queued
is not one of them: it stays the `N pending` from `runstate.sh summary`.

**Lint the stop report before you emit it**, once it is fully rendered, exactly
as run-loop §4 lints its own: write the digest you rendered from to
`<RUN_DIR>/stop-digest.tsv` (`runstate.sh run-digest .agents/run-state.yaml >
<RUN_DIR>/stop-digest.tsv`) and the rendered report to
`<RUN_DIR>/stop-report.md`, with `<RUN_DIR>` the run directory `begin-run`
printed (`.agents/loop/<run_id>/`) **written out literally**, never a variable —
then run `${CLAUDE_PLUGIN_ROOT}/scripts/report-lint.sh --shape B
<RUN_DIR>/stop-report.md <RUN_DIR>/stop-digest.tsv`. On findings, correct the
lines they name **at most once**, then emit; never re-lint in a loop. A finding
records nothing, blocks nothing, rolls back nothing, flips nothing and halts
nothing — the pause is already persisted above. `REPORT_LINT=clean` means *no
mechanical rule was broken*, never that the report conforms to the contract, and
`REPORT_LINT=unjudged` is **not** clean; what the lint cannot judge is stated
once, in run-loop §4's "How to read the lint's result".

If you are reporting into an automated caller rather than to the human, emit the
wire check-in from `${CLAUDE_PLUGIN_ROOT}/templates/check-in.md` as well — it is what
the scheduler parses.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh driver-mode exit` immediately
after emitting that stop report — driver mode ends whenever the loop renders
its stop report, whether it stopped, paused, or finished (ADR 0028), and a
pause is exactly that: a stop.

Then **stop cleanly**. Do not start the next packet. A later session resumes with
`/gaffer:resume`.
