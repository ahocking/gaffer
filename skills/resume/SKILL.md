---
name: resume
description: Resume a paused guided autonomy run from its durable checkpoint. Read .agents/run-state.yaml, switch to the feature branch at the last green commit in the local checkout, surface any pending blocking questions, and continue the loop from the backlog cursor. Use when picking a run back up in a fresh session after /gaffer:pause.
argument-hint: (optional — a specific run-state path if not .agents/run-state.yaml)
---

# Resume the run $ARGUMENTS

Pick a paused run back up from disk. Because the previous session is gone, the
**only** trustworthy memory is `.agents/run-state.yaml` — read it first and let it
drive. The **Chief Engineer** executes this — either here, or one packet at a time
in a dispatched subagent, **decided by the remaining backlog in §0**. See
[ADR 0004](../../docs/adr/0004-graduated-autonomy-and-pausable-loop.md) and
[ADR 0012](../../docs/adr/0012-delegated-loop-driver.md).

## The report contract — `Read` it before you emit anything

**`Read` both of these now, once, before you surface anything to the human:**
`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md` (the glyph vocabulary, the
indentation contract, the header tally, the decision block) and
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md` (shape **C** for the resuming
kickoff, **A** per landing, **B** when it stops again). **Naming a path is not reading
it** — unread, you will render from memory and produce free prose. One read covers the
whole run; do not re-read per packet. A **dispatched** Chief Engineer or lane returns
the wire format (`templates/check-in.md`) and must not read either file.

## Parallel runs — the `--parallel` flag

**If the run-state is `mode: parallel` (or `$ARGUMENTS` contains `--parallel`),
resume the parallel driver instead of §0–§4:** read run-state v3, run
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh reconcile-parallel .agents/run-state.yaml .`
and act on each lane's decision (`clean`/`adopt`/`discard`/`restart`/`escalate` — an
`escalate` lane is the human's), resurface any blocking questions, **clear the pause
sentinel** (`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh clear-pause .agents/pause` —
the request that paused the run is now consumed, ADR 0017), then re-enter the parallel
driver — `Read ${CLAUDE_PLUGIN_ROOT}/skills/run-loop/parallel.md` and enter its §P1
scheduler — from the surviving packet/lane state (ADR 0016). Everything below is the
sequential resume.

## 0. Relay or inline — decided by remaining backlog (ADR 0012)

**Decide this first.** A resume flows straight into the loop, so it inherits
`/gaffer:run-loop` §0's rule — read it there; the summary is:

1. **Read the checkpoint's shape from disk:**
   `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh summary .agents/run-state.yaml`.
   If there is no run-state, say so and stop — reconstruction (§1) is the executing
   Chief Engineer's job, not the relay's.
2. **Count what REMAINS, not what the run started with** — `pending` + the cursor.
   A run that began at 40 packets and has 4 left is a *small* backlog now, and the
   relay would cost ~29% more to finish it.
   - **`--inline` / `--relay` in `$ARGUMENTS` wins**, else: **< 20 remaining →
     inline** (run §1–§4 yourself); **≥ 20 remaining → relay** (below).
   - Say which you chose and the remaining count in one line.
3. **Relay mode — dispatch a fresh `gaffer:chief-engineer`** with a brief
   containing **only**: the repo root, the resolved autonomy level, the run-state
   path, and —
   > Read `${CLAUDE_PLUGIN_ROOT}/skills/resume/SKILL.md` and follow §1–§4: load the
   > checkpoint, reconcile the working tree, surface any blocking questions, then
   > continue **exactly one packet** from the cursor and stop. Return **only** the
   > check-in from `${CLAUDE_PLUGIN_ROOT}/templates/check-in.md`.

   **Give it the file path — it has no `Skill` tool** (ADR 0012, finding 4).
   The reconcile in §2 is deliberately inside the dispatch: it is git-state work,
   and its output belongs in the subagent's context, not yours.
4. **Render the returned check-in into the human check-in shape**
   (`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, shape A — from the returned
   text alone, never by re-reading the repo), then hand off to
   `/gaffer:run-loop` §0 — the same contract drives every packet after this
   one. If the check-in reports `escalate`, a red tip, or a blocking question,
   **stop and surface it** as a stop report (shape B) with the question written as an
   answerable decision; those are the human's, not yours to resolve.

Everything below §0 is written for **whoever executes the resume** — you, at
`--inline`/a small remaining backlog, or the dispatched Chief Engineer under the
relay.

## 1. Load the checkpoint

**First, the gspec preflight (ADR 0020), same as `/gaffer:run-loop` §1.** If
the repo has a `gspec/` directory, run
`${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh check` and `… interlock`. A
`CHECK=fail` means the specs moved to a gspec version this plugin does not support —
stop and say so rather than resuming against a contract you cannot read. An
`INTERLOCK=busy` means a `gspec build` is driving this repo right now — stop; a
resume that starts driving beside it puts two drivers in one checkout. Both are
no-ops without a gspec project.

Read `.agents/run-state.yaml` (or the path in $ARGUMENTS). From it take: `status`,
`branch`, `last_green_commit`, `backlog.cursor`/`done`/`pending`, and
`pending_questions`.

**Then read the finding INDEX — and only the index** (ADR 0022):
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh findings .agents/run-state.yaml`. One line
each; the bodies live in `.agents/findings/<id>.md`. Open a body **only** when its
summary bears on the packet you are about to run, and say which you opened and why.

Both failure modes are real, so neither instinct is safe on its own. Reading every
body rebuilds the 41k-token run-state this design took apart, just in another file.
Skipping the index means a gotcha recorded specifically to prevent rework goes unseen
and the rework happens — which costs more than the reading would have. The index is
cheap and mandatory; the bodies are not free and are conditional.

**If the file is missing, reconstruct it from git before giving up** (it is
gitignored local bookkeeping — ADR 0009 — so a lost disk or a fresh checkout will
not have it, but the feature branch and its commit trailers usually survive):

1. Get onto the run's feature branch. If you are on `main`/`develop`, list
   candidates with `git branch --list 'orch/*'` and `git switch orch/<task-id>`.
2. Run `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh reconstruct .` — it prints
   `BRANCH=`, `TIP=` (a **candidate** `last_green_commit`), `BASE=`, and `DONE=`
   (the packet ids already committed, from the `[orch packet:<id>]` trailers), or
   `RECONSTRUCT=escalate` with what to fix first.
3. **Verify `TIP` is actually green** — run the packet build+tests on it. The
   script cannot; you must. If it is **red**, do not fabricate a green
   checkpoint — treat it as crash scratch and **escalate to the human**.
4. Rebuild the backlog **through the adapter** (ADR 0020 D2) — never by parsing
   `gspec/` yourself: `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh next` for the
   feature, then `… nodes <slug>` for its unchecked tasks (or `$ARGUMENTS`).
   `backlog.done` = `DONE`; `pending` = backlog minus done, in order; `cursor` =
   first pending. Note the adapter already omits tasks that are checked off, so a
   task completed before the crash will not reappear.
5. `pending_questions`: **empty** — flag clearly in your first check-in that any
   outstanding blocking questions could **not** be recovered from git (they lived
   only in the lost file; the human should re-supply them, e.g. from the last
   delivered check-in).
6. Write the rebuilt file with `runstate.sh write .agents/run-state.yaml` and set
   `status: running`, so step 2's reconcile runs and treats this as a crash
   recovery. Then continue below.

If reconstruction is impossible (no `orch/*` branch anywhere, no committed
backlog), there is genuinely nothing to resume — say so and stop.

**Read `status` first — it tells you HOW the last session ended (ADR 0005):**

- **`paused`** — the previous session called `/gaffer:pause` and verified a
  clean checkpoint. Expect the working tree clean at `last_green_commit`.
- **`blocked`** — same, but stopped on a `blocking` question (see step 3).
- **`running`** — the previous session **crashed** (reboot, sleep-death, hard
  close) without pausing. The working tree may hold uncommitted scratch, or a
  torn-write orphan commit that landed green but was never recorded. **Do not
  trust the tree — reconcile it in step 2 before doing anything else.**

## 2. Re-establish the working tree at the green checkpoint

Switch to the packet's feature branch in the local checkout (idempotent —
`git switch orch/<task-id>`; the branch already exists from the paused run), then
let the reconcile helper decide what the real git state means relative to the
durable checkpoint. Pass the checkout itself (`.`) as the work-tree. **Never
eyeball this — the helper encodes the crash-recovery decision table so a torn
write is adopted, not discarded:**

```bash
git switch orch/<task-id>
${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh reconcile .agents/run-state.yaml .
```

Act on the `DECISION=` it prints:

- **`clean`** — HEAD is the green checkpoint, tree clean. Nothing to do; continue.
- **`discard`** — uncommitted scratch sits on top of green. Set it aside
  non-destructively with `git stash --include-untracked` (recoverable — note the
  stash ref), leaving a clean tree at `last_green_commit`, then continue from the
  cursor.
- **`adopt`** — a single clean orphan commit tagged `[orch packet:<cursor>]` is one
  ahead of the recorded green SHA: a **torn write** (the packet committed but the
  crash beat the run-state update). **Re-verify build+tests are green on that
  commit yourself** (the helper cannot run the suite), then adopt it: set
  `last_green_commit` to that SHA, move the cursor packet from `pending` to `done`,
  advance `cursor`, and write run-state atomically via `runstate.sh write`. The
  packet is done — do not redo it.
- **`escalate`** — diverged history, multiple unexplained commits, or an untagged /
  mismatched orphan. **Stop and ask the human.** Do not discard commits you cannot
  account for.

Once reconciled, set `status: running` (`runstate.sh set .agents/run-state.yaml
status running`) and **claim the driver**
(`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh claim-driver .agents/run-state.yaml`) —
you now own the run again. The claim is not bookkeeping: `status: running` alone
cannot tell a crashed session from *this* one, so without it the next session reads
your live run as a crash and starts driving too (ADR 0020 D5). Beat it
(`runstate.sh heartbeat .agents/run-state.yaml`) at each packet boundary, as
`/gaffer:run-loop` §3.5 does. **Clear the pause sentinel**
(`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh clear-pause .agents/pause`): the request
that paused the previous session is consumed, so it must not immediately re-halt this
one (ADR 0017).

**Snapshot run-metrics for the prior segment (best-effort, ADR 0019).** If the last
session **crashed** (`status: running` on entry), it never ran the pause snapshot, so
its perishable token data may still be on disk but uncollected — capture it now, before
it is lost to transcript rotation:
`${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect || true`. Non-critical bookkeeping —
if it errors or `jq` is absent, ignore it and continue.

## 3. Surface pending questions before doing work

If `pending_questions` contains any `blocking` entry for the packet at
`backlog.cursor`, the loop **cannot** proceed on it — present those questions to
the human and wait. Present them as the **Decisions for you** block of the stop
report (`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, shape B): each one an
answerable choice with what follows from each option and your lean, not the raw
`pending_questions` text. These were written by a session that no longer exists, so
give the human the plain-English title of the packet they block — they will not
recognise the id. Non-blocking questions are surfaced but do not halt progress on
unrelated packets.

## 4. Continue from the cursor

**First, emit the kickoff** — shape C in
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, headed `### Resuming`. State what
is **left**, not what the original run set out to do: the remaining packets in plain
words, what is expected to need a decision, and where this session will stop. The
human may be days removed from the run and remembers none of the ids; the checkpoint
you just loaded is the only thing that does. Where the tree needed reconciling (§2),
say so in one line — whether anything was adopted or set aside, and whether the
resumed state matches where they think they left off.

Then pick up the packet at `backlog.cursor` and
continue the implement → test → review → commit-on-branch loop under the session's
autonomy level. Honor the same gates as before: the Chief Engineer owns routine
commits above `interactive` (and merge/rebase/push onto non-`main` branches at
`full-autonomy`), verifying green build+tests itself; hard gates — `main`, releases,
migrations, secrets, deploys, the danger floor — still stop for the human. Keep
`.agents/run-state.yaml` current as packets land, so the next pause is cheap.
