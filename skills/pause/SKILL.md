---
name: pause
description: Pause the guided autonomy loop at a safe checkpoint. Roll to the last green commit on the feature branch (never mid-edit), discard scratch, persist .agents/run-state.yaml, emit a status check-in, and stop cleanly so a later session can resume exactly here. Use when the user wants to stop for now, shut the laptop, close Claude Desktop, or hand off.
argument-hint: (optional reason to record in the check-in, e.g. "shutting down for the night")
---

# Pause the run $ARGUMENTS

Bring the run to a **safe, resumable rest state** and stop: the loop's working
tree ends **clean** at a **green commit**, and `.agents/run-state.yaml` records
enough to reconstruct the backlog in a fresh session. Never pause mid-edit
([ADR 0004](../../docs/adr/0004-graduated-autonomy-and-pausable-loop.md)). The
**loop-driver** session (ADR 0028) runs this, not the Chief Engineer. Never cross
a hard gate to pause — no migration, `main` commit, dependency change or
sensitive-path edit.

A human or frontend may request a pause mid-run through the sentinel
(`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh request-pause .agents/pause "<reason>"`,
ADR 0017); the loop polls it at safe boundaries and hands here. The steps are the
same however you were triggered, and once the checkpoint is durable you **clear
the sentinel** (step 3) so a later resume starts clean.

**Before step 4, `Read` both `${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md`**
(glyph vocabulary, indentation contract, decision block) **and
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`** (shape **B**, which step 4
emits) — naming a path is not reading it. Do it while the checkpoint work is in
flight: you stop as soon as step 4 is written.

## 1. Reach a safe checkpoint (never mid-edit)

Inspect the single local checkout, on the `orch/<task-id>` feature branch. In
order of preference:

- **Already green + committed** → that commit is the checkpoint; nothing to
  discard.
- **Uncommitted work that is green and in policy** (build+tests pass, branch not
  `main`/`master`, no hard-gate path in the diff) → commit it on the branch as
  the checkpoint (`git commit` is not a write the guard's driver-mode edit block
  refuses). **You verify green build+tests before this commit — the guardrail
  hook cannot run the suite.** Put the write-ahead trailer `[orch
  packet:<cursor>]` on its own line in the message, so a later resume can
  *adopt* the commit after a crash before the run-state write below (ADR 0005).
  **This commits unfinished work, and a pause is never an ending: record no
  outcome here.** The packet's start stays open (the trailer is not a green
  outcome); a later session continues it (`record-start <cursor> --continue`)
  and ends it there.
- **Uncommitted scratch that is NOT a safe checkpoint** (red, incomplete, or
  touches a hard gate) → **set it aside non-destructively** with `git stash`,
  leaving a clean tree at the last green commit — never `reset --hard`/`clean
  -f`, which the guardrail hard-denies:

  ```bash
  git stash push --include-untracked -m "orch pause scratch: <task-id>"
  ```

  `--include-untracked` leaves the run record in place: `.agents/run-state.yaml`,
  `.agents/findings/` and `run-state-note-archive.md` are gitignored (ADR 0009,
  ADR 0022). Record the stash ref in the check-in (step 4) so the human can
  recover or drop it. **Escalate to the human before stashing if there is any
  doubt it is disposable loop scratch** — the loop shares your **single
  checkout**, so it may hold work you have not reviewed.

## 2. Verify the checkpoint

Confirm both before writing state. If either fails, stop and report, then run
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh driver-mode exit` immediately after
that stop report (idempotent even if this session never entered driver mode);
never write a run-state that lies:

```bash
git status --porcelain      # must be EMPTY (clean tree)
git rev-parse HEAD          # must equal your chosen green SHA
```

## 3. Persist run-state

Write (or update) **`.agents/run-state.yaml`** in the local checkout from
`${CLAUDE_PLUGIN_ROOT}/templates/run-state.yaml`, truthfully:

- `status` — **`paused`**, or **`blocked`** when stopping on an unanswered
  `blocking` question. A non-`running` value is what tells the next session you
  exited *cleanly* rather than crashed (ADR 0005).
- `branch` — the `orch/<task-id>` branch; `last_green_commit` — the SHA verified
  in step 2; `backlog.cursor` / `pending` — where the loop stopped and what
  remains.
- `pending_questions` — every unanswered blocking/high question, with severity,
  in the template's block-entry shape. **First run
  `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh prune-questions .agents/run-state.yaml`**
  (skip it only when the file does not exist yet), then carry the existing
  entries through exactly as they stand in that pruned file on disk — read after
  the prune, never from an earlier read — each `asked_at` unchanged. New entries
  go after them:
  - the question the `stop` action handed over gets `asked_at:` set to the `ts`
    of the cursor's latest record routed `stop` in `$RUN_DIR/routing.jsonl`,
    copied verbatim and written **quoted** (`asked_at: '<ts>'`);
  - any other new entry — a `hand-off-feature` question, or one from a plain
    pause — gets **no** `asked_at:` line, so `prune-questions` always keeps it.

**When you write `blocked` because the `stop` action (run-loop §3's **Act on
`route`'s action** step) handed a question here, this pause is a terminal
outcome for the packet**, unlike step 1's WIP commit, which records none. `stop`
writes no run-state itself, so persisting the question and recording the outcome
are both this step's job. The question's `packet:` already names the whole
bundle (a bundle's packet id is its first member's), but the *outcome* must
cover every member.

Recover the membership by run-loop §3's **Form this packet's members** rule when
this session does not hold `$MEMBERS` from earlier in the packet: the cursor's
`$RUN_DIR/<cursor>/handoff.md` (`RUN_DIR` being the `.agents/loop/<run_id>/`
directory `begin-run` printed) always exists when `stop` reaches here, so take
`$MEMBERS` from its `BUNDLE=` line — absent means `MEMBERS=<cursor>` alone. Then
re-check only the mechanical refusals —
`${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh task-status "$MEMBERS"`, dropping
any member reading `finished` or `gone` (never the cursor itself) — never
re-deriving the scope/deps/cap judgment `group` applies to a fresh bundle. With
no handoff at all there is nothing to recover: `$MEMBERS` stays `<cursor>`
alone, never a re-formed group. Before writing the file, record the surviving
bundle's outcome in one call, never once per member:
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh record-outcome "$MEMBERS" blocked` —
so no member reads as open work a later sweep would close as `interrupted`.

**Route what you learned before you write** (ADR 0022) — only the last row
belongs in run-state:

| What you have | Where it goes |
|---|---|
| "this should be built/fixed" | **backlog** — a gspec task/feature, sequenced in `.agents/roadmap.yaml`. Not a finding (ADR 0020). |
| a gotcha, a constraint, a decision **and its rationale**, a resolved question | **a finding** — `runstate.sh add-finding .agents/run-state.yaml <id> "<one line>" --packets <id[,id...]>` (mandatory — ADR 0024, there is no run-wide finding), detail into `.agents/findings/<id>.md` if you also pass `--body` |
| the single-sentence "where we stopped" | `note:` |

Never write findings into `note:`, and never invent a `resolved_questions:` list
— every later dispatch pays for it. The one-line summary stays in run-state; the
next session opens the body **only if the summary tells it to**.

**Write it atomically** through the helper, so a crash mid-write cannot corrupt
the loop's only memory:

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

**`write` REPLACES the whole file and `add-finding` APPENDS, so write first,
findings second**: run every `add-finding` from the table *after* this write — a
finding recorded first is erased by it and leaves an orphaned body. Carry every
finding already in the index through the heredoc verbatim; dropping a line
unlinks a body still on disk.

Steps 1–2 come **before** this write — a run-state saying `paused` must be true
when written. This file is tracked; committing it is fine (not a hard-gate path)
on the feature branch, or leave it staged for the human — never on `main`.

**Then clear the pause sentinel** so the fulfilled request cannot re-halt a later
resume: `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh clear-pause .agents/pause`
(it sweeps any per-lane `.agents/pause.<task-id>` too; ADR 0017).

## 3b. Snapshot run-metrics (best-effort, ADR 0019)

Only once the checkpoint is verified and persisted (steps 1–3), pin the run's
perishable token data:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect || true
```

**Strictly non-critical**: it only reads bookkeeping and writes
`.agents/metrics/<run-id>/run-metrics.json`. **Never let it affect the pause** —
if it errors or `jq` is absent, ignore it. You may fold a one-line
`metrics.sh show` summary into the check-in.

## 4. Emit the stop report, then stop

A pause gets the **stop report** — shape B in
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, assembled from
`runstate.sh run-digest .agents/run-state.yaml` with **no** `--since`, so its
`packet` lines name every packet the run began, with its outcome, whichever
session ran it. Do not re-open the repo to embellish it:

- the opening sentence — why it stopped ("$ARGUMENTS", if given) and whether
  anything is at risk (normally "nothing" after steps 1–3). **When a periodic
  pause triggered this** (the caller's reason names `pause_every_packets`, or
  check: `runstate.sh periodic-pause`), name the setting — the
  `pause_every_packets` key in `.agents/project-overrides.yaml`, with the count
  `periodic-pause` prints as `EVERY=` — so it reads as scheduled, never as a
  failure,
- **Shipped** — the digest's `green` `packet` lines, one per landed packet, what
  each made true in plain words, the packet id at most in parentheses; never a
  packet-id list.
- **Not done** — the digest's other `packet` lines (`failed`, `rolled-back`,
  `blocked`, `interrupted`, `abandoned`, `open`, and `paused`), what is left and
  why, one clause each. **The cursor you just paused on reads `paused` — name it
  with the word *paused*** under ⚠️ Unfinished (shape B), never folded silently
  into the general "left and why" text,
- **Decisions for you** — every unanswered **blocking** question (from
  `pending_questions` and the digest's `handoff-feature` lines) as an answerable
  choice: the two real options, what follows from each, your lean, and what
  happens by default if they say nothing.
- **Recommended next** — the single action that unblocks the most,
- **State** — branch, green SHA, tree clean, `/gaffer:resume`, and the stash ref
  if step 1 set scratch aside.

**Its four digest-derived tally figures come from `runstate.sh run-tally
.agents/run-state.yaml`, and you compute none of them** — rendered exactly as
`${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md`'s `## 4. Termination` states:
`SHIPPED=`, `FAILED=`, `UNFINISHED=` and `DECISIONS=` as ✅, ⛔, ⚠️ and 🔀, as
printed, never recounted; ⬚ queued stays `runstate.sh summary`'s `N pending`.

**Lint the stop report before you emit it**, once fully rendered, exactly as
run-loop's `## 4. Termination` lints its own: the digest you rendered from to
`<RUN_DIR>/stop-digest.tsv` (`runstate.sh run-digest .agents/run-state.yaml >
<RUN_DIR>/stop-digest.tsv`), the report to `<RUN_DIR>/stop-report.md`, with
`<RUN_DIR>` (`.agents/loop/<run_id>/`, as `begin-run` printed) **written out
literally**, never a variable — then run
`${CLAUDE_PLUGIN_ROOT}/scripts/report-lint.sh --shape B <RUN_DIR>/stop-report.md
<RUN_DIR>/stop-digest.tsv`, and act on its result as that section states
(findings corrected **at most once**, never re-linted; a finding changes
nothing already persisted here; `REPORT_LINT=clean` never means the report
conforms, and `REPORT_LINT=unjudged` is **not** clean).

Reporting into an automated caller rather than the human? Also emit the wire
check-in from `${CLAUDE_PLUGIN_ROOT}/templates/check-in.md` — the scheduler
parses it.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh driver-mode exit` immediately
after the stop report — driver mode ends whenever the loop renders its stop
report (ADR 0028). Then **stop cleanly**: do not start the next packet. A later
session resumes with `/gaffer:resume`.
