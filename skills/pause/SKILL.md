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
the Chief Engineer. Do **not** cross a hard gate to
pause — pausing never justifies a migration, a `main` commit, a dependency
change, or a sensitive-path edit.

A pause may be requested mid-run by a human/frontend touching the sentinel
(`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh request-pause .agents/pause "<reason>"`,
ADR 0017); the running loop polls it at safe boundaries and hands here. However you
were triggered, the steps below are the same — and once the checkpoint is durable
you **clear the sentinel** (step 3) so a later resume starts clean.

**Before step 4, `Read` both `${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md`**
(the glyph vocabulary, the indentation contract, the decision block) **and
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`** (shape **B**, which step 4 emits)
— naming a path is not reading it. Do this while the
checkpoint work is in flight, not after — you stop immediately once step 4 is written.

## 1. Reach a safe checkpoint (never mid-edit)

Inspect the loop's working tree — the single local checkout, currently on the
`orch/<task-id>` feature branch. Then, in order of preference:

- **Already green + committed** → that commit is your checkpoint. Nothing to
  discard.
- **Uncommitted work that is green and in policy** (build+tests pass, branch is
  not `main`/`master`, no hard-gate path in the diff) → commit it on the branch
  first, making it the checkpoint (`git commit` is not a write the guard's
  driver-mode edit block refuses). **You are responsible for verifying green
  build+tests before this commit — the guardrail hook cannot run the suite.** Put
  the write-ahead trailer `[orch packet:<cursor>]` in the commit message (its own
  line), so a later resume can *adopt* the commit after a crash before the
  run-state write below (ADR 0005). **This commits unfinished work, and a pause is
  never an ending: record no outcome here.** The packet's start stays open, since
  the trailer is not a green outcome. A later session continues it
  (`record-start <cursor> --continue`) and ends it there.
- **Uncommitted scratch that is NOT a safe checkpoint** (red, incomplete, or
  touches a hard gate) → **set it aside non-destructively**, leaving a clean tree
  at the last green commit, with `git stash` — never `reset --hard`/`clean -f`,
  which the guardrail hard-denies:

  ```bash
  git stash push --include-untracked -m "orch pause scratch: <task-id>"
  ```

  `--include-untracked` leaves the run record in place, since
  `.agents/run-state.yaml`, `.agents/findings/` and `run-state-note-archive.md`
  are gitignored (ADR 0009, ADR 0022). Record the stash ref in the check-in
  (step 4) so the human can recover or drop it. **Escalate to the human before
  stashing if there is any doubt it is disposable loop scratch** — the loop
  shares your **single checkout**, so it may hold work you have not reviewed.

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
- `pending_questions` — every unanswered blocking/high question, with severity,
  in the block-entry shape the template documents. **Run
  `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh prune-questions .agents/run-state.yaml`
  first, before you compose the list** (skip it only when the file does not
  exist yet). Then carry through the existing entries exactly as they stand in
  that pruned file on disk — read them after the prune, never from an earlier
  read — with each entry's `asked_at` unchanged. Add new entries after them:
  - the question the `stop` action handed over gets `asked_at:` set to the
    `ts` of the cursor's latest record routed `stop` in
    `$RUN_DIR/routing.jsonl`, copied verbatim and written **quoted**
    (`asked_at: '<ts>'`);
  - any other new entry — a `hand-off-feature` question, or one carried by a
    plain pause — gets **no** `asked_at:` line at all, so `prune-questions`
    always keeps it.

**When the `status` you are about to write is `blocked` because the `stop`
action (run-loop §3's **Act on `route`'s action** step) handed a question here,
this pause is a terminal outcome for the packet, not a checkpoint on work still
open** — unlike step 1's WIP commit, which records none. The `stop` action hands
the question here with `packet: <cursor>` and writes no run-state itself, so
persisting `pending_questions` above and recording the outcome below are both
this step's job. The question's `packet:` field already names the whole bundle
unchanged — a bundle's packet id is always its first member's — but the
*outcome* record must cover every member, not just the cursor.

Recover the bundle's membership by the same rule as run-loop §3's **Form this
packet's members** step, in case this session does not already hold `$MEMBERS`
as shell state from earlier in the same packet: the cursor's own
`$RUN_DIR/<cursor>/handoff.md` (the run directory `begin-run` printed,
`.agents/loop/<run_id>/`) already exists whenever the `stop` action reaches
here, so take `$MEMBERS` from its `BUNDLE=` line — absence means
`MEMBERS=<cursor>` alone. Then re-check only the mechanical refusals against it
— `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh task-status "$MEMBERS"`,
dropping any member whose line reads `finished` or `gone` (never the cursor
itself) — never re-deriving the scope/deps/cap judgment `group` applies when
forming a bundle fresh. Only when no handoff exists at all is there nothing to
recover, and `$MEMBERS` stays `<cursor>` alone rather than re-forming the group.
Before writing the file below, record the outcome for the surviving bundle in
one call, never once per member:
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh record-outcome "$MEMBERS" blocked`
— so no member reads as still-open work a later sweep would close as
`interrupted`.

**A pause is where findings pile up, so route them before you write** (ADR 0022).
Everything you learned this run that the next session would want is one of three
things, and only the last belongs in run-state:

| What you have | Where it goes |
|---|---|
| "this should be built/fixed" | **backlog** — a gspec task/feature, sequenced in `.agents/roadmap.yaml`. Not a finding (ADR 0020). |
| a gotcha, a constraint, a decision **and its rationale**, a resolved question | **a finding** — `runstate.sh add-finding .agents/run-state.yaml <id> "<one line>" --packets <id[,id...]>` (mandatory — ADR 0024, there is no run-wide finding), detail into `.agents/findings/<id>.md` if you also pass `--body` |
| the single-sentence "where we stopped" | `note:` |

Do **not** write findings into `note:`, and do **not** invent a
`resolved_questions:` list — every later dispatch pays for it. The one-line
summary is what stays in run-state; the body is what the next session opens
**only if the summary tells it to**.

**Write it atomically** so a crash mid-write cannot corrupt the only memory the
loop has — compose the full file and pipe it through the run-state helper:

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
pending_questions:
  - id: <carry every entry left by prune-questions through verbatim>
    severity: <blocking | high | normal>
    packet: <packet id>
    asked_at: '<ts of the routing record routed stop; omit on any other new entry>'
    question: <...>
findings:
  - id: <carry EVERY existing index entry through verbatim>
    summary: <...>
    packets: [<id[,id...]>]
    file: .agents/findings/<id>.md
YAML
```

**`write` REPLACES the whole file, `add-finding` APPENDS to it — so the order is
write first, findings second.** Run every `add-finding` from the routing table
above *after* this write, not before, since a finding recorded first is erased
by the write and leaves an orphaned body. Carry any finding already in the index
from earlier in the run through the heredoc verbatim, since dropping a line here
unlinks a body still on disk.

Order matters: reach the safe checkpoint and verify it (steps 1–2) **before**
this write — a run-state that says `paused` must be true when it is written. This
file is tracked; committing it is fine (it is not a hard-gate path), but a `main`
commit is not — commit it on the feature branch or leave it staged for the human,
never on `main`.

**Then clear the pause sentinel** so the fulfilled request cannot re-halt a later
resume: `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh clear-pause .agents/pause`
(sweeps any per-lane `.agents/pause.<task-id>` too; ADR 0017).

## 3b. Snapshot run-metrics (best-effort, ADR 0019)

Now that the checkpoint is durable, assemble a fresh packet to pin the run's
metrics, whose token data is perishable:

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
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`. Assemble it from
`runstate.sh run-digest .agents/run-state.yaml` with **no** `--since`, so its
`packet` lines name every packet the run began, with its outcome, whichever
session ran each one; do not re-open the repo to embellish it:

- the opening sentence — why it stopped ("$ARGUMENTS", if given) and whether
  anything is at risk (after steps 1–3, the answer is normally "nothing"). **When a
  periodic pause triggered this** (the caller's reason names `pause_every_packets`,
  or check yourself: `runstate.sh periodic-pause`), name the setting here — the
  `pause_every_packets` key in `.agents/project-overrides.yaml`, with the count
  `periodic-pause` prints as `EVERY=` — so it reads as scheduled, never as a
  failure,
- **Shipped** — the digest's `green` `packet` lines, one per landed packet, what
  each made true in plain words, the packet id at most in parentheses beside it;
  never a packet-id list.
- **Not done** — the digest's other `packet` lines (`failed`, `rolled-back`,
  `blocked`, `interrupted`, `abandoned`, `open`, and `paused`), what is left and
  why, one clause each. **The cursor packet you just paused on reads `paused`
  in the digest — name it with the word *paused*** under ⚠️ Unfinished
  (`report-templates.md` shape B), never folded silently into the general
  "left and why" text,
- **Decisions for you** — every unanswered **blocking** question (from
  `pending_questions` and the digest's `handoff-feature` lines), rewritten as an
  answerable choice: the two real options, what follows from each, your lean, and
  what happens by default if they say nothing.
- **Recommended next** — the single action that unblocks the most,
- **State** — branch, green SHA, tree clean, `/gaffer:resume`. Name the stash ref
  here too if step 1 set scratch aside, so they can recover or drop it.

**Its four digest-derived tally figures come from `runstate.sh run-tally
.agents/run-state.yaml`, and you compute none of them** — exactly as
`${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md`'s `## 4. Termination` takes
them: `SHIPPED=`, `FAILED=`, `UNFINISHED=` and `DECISIONS=` are ✅, ⛔, ⚠️ and
🔀, with the 🔀 dedup already applied; render each as printed, never recounted
from the `packet` or `decision` lines. ⬚ queued is not one of them: it stays the
`N pending` from `runstate.sh summary`.

**Lint the stop report before you emit it**, once it is fully rendered, exactly
as run-loop's `## 4. Termination` lints its own: write the digest you rendered
from to `<RUN_DIR>/stop-digest.tsv` (`runstate.sh run-digest
.agents/run-state.yaml > <RUN_DIR>/stop-digest.tsv`) and the rendered report to
`<RUN_DIR>/stop-report.md`, with `<RUN_DIR>` the run directory `begin-run`
printed (`.agents/loop/<run_id>/`) **written out literally**, never a variable —
then run `${CLAUDE_PLUGIN_ROOT}/scripts/report-lint.sh --shape B
<RUN_DIR>/stop-report.md <RUN_DIR>/stop-digest.tsv`. On findings, correct the
lines they name **at most once**, then emit; never re-lint in a loop. A finding
records nothing, blocks nothing, rolls back nothing, flips nothing and halts
nothing — the pause is already persisted above. `REPORT_LINT=clean` means *no
mechanical rule was broken*, never that the report conforms to the contract, and
`REPORT_LINT=unjudged` is **not** clean; what the lint cannot judge is stated
once, in run-loop `## 4. Termination`'s **How to read the lint's result**.

If you are reporting into an automated caller rather than to the human, emit the
wire check-in from `${CLAUDE_PLUGIN_ROOT}/templates/check-in.md` as well — it is what
the scheduler parses.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh driver-mode exit` immediately
after emitting that stop report — driver mode ends whenever the loop renders
its stop report (ADR 0028).

Then **stop cleanly**. Do not start the next packet. A later session resumes with
`/gaffer:resume`.
