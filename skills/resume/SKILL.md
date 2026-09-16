---
name: resume
description: Resume a paused guided autonomy run from its durable checkpoint. Read .agents/run-state.yaml, switch to the feature branch at the last green commit in the local checkout, surface any pending blocking questions, and continue the loop from the backlog cursor. Use when picking a run back up in a fresh session after /gaffer:pause.
argument-hint: (optional — a specific run-state path if not .agents/run-state.yaml)
---

# Resume the run $ARGUMENTS

Pick a paused run back up from disk. Because the previous session is gone, the
**only** trustworthy memory is `.agents/run-state.yaml` — read it first and let it
drive. This session takes on the **loop-driver** role (ADR 0028) for the rest of
the run — passing paths, reading status lines, routing mechanically — the same
role a fresh `/gaffer:run-loop` takes on. There is one sequential mode; the
remaining backlog size never switches it. See
[ADR 0004](../../docs/adr/0004-graduated-autonomy-and-pausable-loop.md).

## The report contract — `Read` it before you emit anything

**`Read` both of these now, once, before you surface anything to the human:**
`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md` (the glyph vocabulary, the
indentation contract, the header tally, the decision block) and
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md` (shape **C** for the resuming
kickoff, **A** per landing, **B** when it stops again). **Naming a path is not reading
it** — unread, you will render from memory and produce free prose. One read covers the
whole run; do not re-read per packet.

## Flags this run no longer has

`--relay` and `--inline` are still accepted in `$ARGUMENTS` and must **not** error —
relay dispatch was retired
([ADR 0012](../../docs/adr/0012-delegated-loop-driver.md), superseded). If either is
present, resume normally and note it in the kickoff (§4) the same way
`/gaffer:run-loop` does: one `⚠️ **--<flag>** no longer does anything — this loop
runs one sequential mode.` line per flag, using the existing ⚠️ glyph. `--parallel`
is handled separately, immediately below — it does not resurrect the retired
parallel driver; only a run-state that actually records `mode: parallel` does.

## A `mode: parallel` run-state stops here — no auto-migration

**Check this before anything else, read-only.** If `.agents/run-state.yaml` records
`mode: parallel` (parallel mode was retired —
[ADR 0016](../../docs/adr/0016-parallel-worktree-lanes.md), superseded), do **not**
run any packet and do **not** write anything — not to run-state, not to any branch.
Read the surviving read-only projection:
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh lanes .agents/run-state.yaml` — one line
per lane: id, branch, worktree, packet, last green commit, status. Then stop and
report (shape B):

- **Every lane, by branch and worktree** — straight off the `lanes` output, one line
  each.
- **Whether run-state records each as merged.** `status: done` is the only value
  this schema ever recorded for "merged, worktree removed" — say that plainly per
  lane; `running`/`green`/`integrating`, or no status at all, is **not** recorded as
  merged.
- **State plainly that this session merged none of them.** It stopped before
  touching any lane.
- **Name what the operator must clear before the loop can run again** — each
  unmerged lane's branch and worktree (review and land or discard by hand), and
  `.agents/run-state.yaml` itself, which still reads `mode: parallel` — nothing here
  rewrites or migrates it.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh driver-mode exit` immediately
after that stop report. This check runs first, but this session can still
reach it already marked — `/gaffer:run-loop` §2 enters driver mode before
its own redirect to this skill, so this stop path may run with a mark
already set. `driver-mode exit` is idempotent (a no-op if there is no mark),
so calling it here is always safe regardless of which caller reached this
skill.

`$ARGUMENTS` containing `--parallel` does **not** trigger this on its own — there is
no parallel driver left to resume into. Only the run-state's own recorded `mode:`
does. Everything below is the sequential resume, for a run-state that does not
record `mode: parallel`.

## 0. Enter driver mode and resume the run

Right after the parallel-mode check above returns normal (no `mode: parallel`),
before reading anything else (ADR 0028):

```
runstate.sh compact-threshold   # THRESHOLD=<n|unknown> SOURCE=repo|operator|gaffer-default|unknown APPLIED=no
runstate.sh driver-mode enter --model <this session's model> \
  --effort unknown --threshold <THRESHOLD just printed>
```

Pass `--effort unknown` unless the operator has explicitly stated their
effort level this session — nothing records it automatically yet.
`compact-threshold` is a pure reader — it never writes a settings file, so
`APPLIED` is always `no`; pass its `THRESHOLD` straight through regardless of
`SOURCE`. If `driver-mode enter` refuses (no session id available, from
neither an argument nor `$CLAUDE_CODE_SESSION_ID`), **stop now** with a stop
report saying so; never resume the loop unmarked. `Read`
`${CLAUDE_PLUGIN_ROOT}/agents/loop-driver.md` now too — it is your role for
the rest of this session, same as a fresh `/gaffer:run-loop`.

**`begin-run` waits until §1 has established the checkpoint** (below) — it
dies on a missing run-state, and at this point the file may not exist yet
(the reconstruct path in §1 can still be building it). Call it once §1
concludes, right before §2.

## Concurrency

**File-editing agents run one at a time, unless their declared file scopes are
disjoint** — a resumed run dispatches a single `implementer` per packet, same as a
fresh one. **Read-only agents** (a `researcher`, a `reviewer`, an `Explore`-style
search) may fan out freely; nothing they do needs serializing. **Worktree isolation
is not part of this resume.** Reach for it only on self-contained work starting
fresh off the default branch — a spike, an experiment, a deliberate refactor —
**never** for an implementer continuing a packet on this run's own `orch/<task-id>`
branch: a worktree branched mid-run lacks the earlier packets' commits and is never
merged back automatically, so it silently drops the packet from the branch the run
is building.

## 1. Load the checkpoint

**First, the gspec preflight (ADR 0020), same as `/gaffer:run-loop` §1.** If
the repo has a `gspec/` directory, run
`${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh check` and `… interlock`. A
`CHECK=fail` means the specs moved to a gspec version this plugin does not support —
stop and say so rather than resuming against a contract you cannot read, then run
`runstate.sh driver-mode exit` right after that stop report (driver mode is already
active from §0). An `INTERLOCK=busy` means a `gspec build` is driving this repo
right now — stop the same way, with the same exit call; a resume that starts
driving beside it puts two drivers in one checkout. Both checks are no-ops
without a gspec project.

Read `.agents/run-state.yaml` (or the path in $ARGUMENTS). From it take: `status`,
`branch`, `last_green_commit`, `backlog.cursor`/`pending`, and
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
   checkpoint — treat it as crash scratch, **escalate to the human** with a
   stop report, and run `runstate.sh driver-mode exit` right after it.
4. Rebuild the backlog **through the adapter** (ADR 0020 D2) — never by parsing
   `gspec/` yourself: `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh next` for the
   feature, then `… nodes <slug>` for its unchecked tasks (or `$ARGUMENTS`).
   `pending` = the committed backlog minus `DONE` (from step 2), in order;
   `cursor` = first pending. There is no `backlog.done` field to populate (ADR
   0025) — `DONE` here is scratch used only to compute `pending`, same as
   `reconstruct`'s own note that nothing is written from it automatically. Note
   the adapter already omits tasks that are checked off, so a task completed
   before the crash will not reappear.
5. `pending_questions`: **empty** — flag clearly in your first check-in that any
   outstanding blocking questions could **not** be recovered from git (they lived
   only in the lost file; the human should re-supply them, e.g. from the last
   delivered check-in).
6. Write the rebuilt file with `runstate.sh write .agents/run-state.yaml` and set
   `status: running`, so step 2's reconcile runs and treats this as a crash
   recovery. Then continue below.

If reconstruction is impossible (no `orch/*` branch anywhere, no committed
backlog), there is genuinely nothing to resume — say so, stop, and run
`runstate.sh driver-mode exit` immediately after that stop report.

**Read `status` first — it tells you HOW the last session ended (ADR 0005):**

- **`paused`** — the previous session called `/gaffer:pause` and verified a
  clean checkpoint. Expect the working tree clean at `last_green_commit`.
- **`blocked`** — same, but stopped on a `blocking` question (see step 3).
- **`running`** — the previous session **crashed** (reboot, sleep-death, hard
  close) without pausing. The working tree may hold uncommitted scratch, or a
  torn-write orphan commit that landed green but was never recorded. **Do not
  trust the tree — reconcile it in step 2 before doing anything else.**

**Keep this reading** — step 4's sweep needs to know whether it read `paused`
**here**, before step 2 overwrites `status` to `running`.

## 2. Re-establish the working tree at the green checkpoint

**Begin the run now** — `.agents/run-state.yaml` is guaranteed to exist at
this point (it either already did, or §1's reconstruct path just wrote it):
`runstate.sh begin-run .agents/run-state.yaml`. It **keeps** the existing
`run_id` (a run spans sessions, and this one is continuing) while pruning old
run directories down to the current run and the newest previous one. Calling
it any earlier, before the checkpoint file is confirmed to exist, would die.

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
  cursor. **Record no outcome here** — nothing finished; whether the cursor's open
  start reads `interrupted` is step 4's sweep to decide.
- **`adopt`** — a single clean orphan commit tagged `[orch packet:<cursor>]` is one
  ahead of the recorded green SHA: a **torn write** (the packet committed but the
  crash beat the run-state update). **Re-verify build+tests are green on that
  commit yourself** (the helper cannot run the suite), then adopt it: set
  `last_green_commit` to that SHA and **remove the cursor packet from `pending`**
  — there is no `done` list to move it into (ADR 0025). If the orphan commit does
  not already carry the gspec checkbox flip (it should — §3.4 lands it in the same
  commit; `git show --stat <sha> -- gspec/` tells you), perform it now:
  `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh check-task <cursor>`, same exit
  codes as §3.4 (`CHECKED=none` is skipped, not failed, for a non-gspec backlog;
  exit 4 is drift — note it, do not halt). Commit that flip as its own small
  commit if you had to make it — the orphan commit is already recorded, so
  amending it would rewrite history. **Attest the outcome** — it landed, just
  was not recorded: `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh record-outcome
  <cursor> green`. Advance `cursor`, and write run-state atomically via
  `runstate.sh write`. The packet is done — do not redo it.
- **`escalate`** — diverged history, multiple unexplained commits, or an untagged /
  mismatched orphan. **Stop and ask the human**, then `runstate.sh driver-mode
  exit` right after that stop report. Do not discard commits you cannot
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
the human and wait. Assemble the surrounding stop report exactly as
`${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` §4 does — `runstate.sh run-digest
.agents/run-state.yaml` with **no** `--since`, so it names every packet this run
began with its outcome even when this session did not run all of them — and slot
these questions in as its **Decisions for you** block
(`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, shape B): each one an
answerable choice with what follows from each option and your lean, not the raw
`pending_questions` text. These were written by a session that no longer exists, so
give the human the plain-English title of the packet they block — they will not
recognise the id. Non-blocking questions are surfaced but do not halt progress on
unrelated packets. When this stop report is the whole of what this session does,
run `runstate.sh driver-mode exit` right after emitting it.

## 4. Continue from the cursor

**First, emit the kickoff** — shape C in
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, headed `### Resuming`,
rendered from `runstate.sh run-digest .agents/run-state.yaml` with **no** `--since`:
its `packet` lines are what THIS run already did, across however many sessions
drove it, so render those as one ⚠️ **Picked up** line naming what is unfinished
rather than a second stop report, and its `enter` line gives the `▶ **Session**`
line (model/effort/threshold), exactly as a fresh run's kickoff does. State what
is **left**, not what the original run set out to do: the remaining packets in plain
words, what is expected to need a decision, and where this session will stop. The
human may be days removed from the run and remembers none of the ids; the checkpoint
you just loaded is the only thing that does. Where the tree needed reconciling (§2),
say so in one line — whether anything was adopted or set aside, and whether the
resumed state matches where they think they left off. If `$ARGUMENTS` carried
`--relay`/`--inline`, add the one `⚠️` line per flag described above.

**Then sweep before recording the cursor packet** (T3, T8): run
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh sweep-open --list`, passing
`--paused-cursor <cursor>` **only** if `status` read `paused` in step 1 — the
cursor packet is the one this session is about to continue, not the one the sweep
should close. It prints one `OPEN=<id>` line per open packet. If it printed any,
comma-join the ids (the `paste -sd,` idiom at run-loop/SKILL.md :84–87) into one
string and resolve them —
`${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh task-status "<id,id,...>"` — which
prints one `<id>\t<state>\t<reason>` TSV line per id plus a trailing
`FINISHED=<csv>` line; the `gone` set is the ids whose second column reads `gone`.
Comma-join THOSE into `SWEPT="<id,id,...>"` and pass it to `--gone` (skip both
`task-status` and `--gone` when `--list` printed nothing, and leave `SWEPT`
empty: `task-status` refuses an empty id list). Then sweep for real, same
`--paused-cursor`/`--gone`:
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh sweep-open --paused-cursor <cursor>
--gone "$SWEPT"`. Each id in `$SWEPT` now reads `interrupted` in
`run-digest`'s `packet` line for it — **carry `$SWEPT` through to the first
shape-A report**, exactly as `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md`
§3.6 renders it (that section's own `$SWEPT` capture, from its own §3.2, is a
separate one for every packet after this first one) — `run-digest`'s `packet`
lines are never filtered by `--since`, so this sweep's own record of what it
just closed is the only thing marking it as new. The kickoff above needs
nothing, since a sweep always runs after it.

Write the cursor packet's handoff exactly as
`${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` §3.3 does — decide its
`tier`/`--agent`, pipe `gspec-backlog.sh handoff` (or its non-gspec task text)
into `runstate.sh handoff`, and skip the packet with no record if the handoff
is refused. Only once it is written do you attest the start — capture
`SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` first, the same capture
run-loop/SKILL.md §3.3 pairs with this exact step, so the first shape-A report
after this resume scopes `run-digest --since "$SINCE"` to only this packet's
own decisions rather than every decision the whole run has ever recorded —
then `runstate.sh record-start <cursor> --continue` when the same
paused-on-entry reading held in step 1, else `runstate.sh record-start
<cursor>` (a fresh start — its prior attempt, if any, already closed with a
recorded outcome).

Then `Read` `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` §3.4 onward
(dispatch with the handoff path, route every verdict, land, integrate,
advance) and §4 (termination) — this resume dispatches and routes exactly as
a fresh run does, under the session's autonomy level, for the cursor packet
and every packet after it. Honor the same gates as before: the driver owns
routine commits above `interactive` (and merge/rebase/push onto non-`main`
branches at `full-autonomy`); hard gates — `main`, releases, migrations,
secrets, deploys, the danger floor — still stop for the human. Keep
`.agents/run-state.yaml` current as packets land, so the next pause is cheap,
and run `runstate.sh driver-mode exit` immediately after whichever stop
report run-loop §4 renders.
