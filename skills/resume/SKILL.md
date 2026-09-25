---
name: resume
description: Resume a paused guided autonomy run from its durable checkpoint. Read .agents/run-state.yaml, switch to the feature branch at the last green commit in the local checkout, surface any pending blocking questions, and continue the loop from the backlog cursor. Use when picking a run back up in a fresh session after /gaffer:pause.
argument-hint: (optional — a specific run-state path if not .agents/run-state.yaml)
---

# Resume the run $ARGUMENTS

Pick a paused run back up from disk. The previous session is gone, so
`.agents/run-state.yaml` is the **only** trustworthy memory — read it first and
let it drive. This session takes on the **loop-driver** role (ADR 0028) for the
rest of the run, in the loop's one sequential mode, exactly as a fresh
`/gaffer:run-loop` does. See
[ADR 0004](../../docs/adr/0004-graduated-autonomy-and-pausable-loop.md).

**This skill states only what is unique to resuming**: loading the checkpoint,
rebuilding it from git, reconciling the working tree, and surfacing pending
questions. Everything else is `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md`,
named here by its `##` heading or, inside its `## 3. Loop`, by a step's bold
title. If this session has not read that file already (it has when
`/gaffer:run-loop` redirected here), `Read` it once now, and follow each section
this skill names exactly as written there.

## The report contract — `Read` it before you emit anything

**`Read` both of these now, once, before you surface anything to the human:**
`${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md` (the glyph vocabulary, the
indentation contract, the header tally, the decision block) and
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md` (shape **C** for the resuming
kickoff, **A** per landing, **B** when it stops again). **Naming a path is not
reading it** — unread, you render from memory. One read covers the whole run; do
not re-read per packet.

## Flags this run no longer has

`--relay` and `--inline` are still accepted in `$ARGUMENTS` and must **not**
error: resume normally and add one ⚠️ line per flag to the kickoff (§4), in the
form run-loop's `## Flags this loop no longer has` gives. `--parallel` never
triggers the stop below on its own — only a run-state that records `mode:
parallel` does.

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

Run `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh driver-mode exit` immediately after
that stop report — it is idempotent, and `/gaffer:run-loop` enters driver mode
before redirecting here. Everything below is the sequential resume, for a
run-state that does not record `mode: parallel`.

## 0. Enter driver mode

Right after the parallel-mode check above returns normal, before reading anything
else (ADR 0028):

```
runstate.sh compact-threshold   # THRESHOLD=<n|unknown> SOURCE=repo|operator|unknown APPLIED=no
runstate.sh session-effort      # EFFORT=<level|unknown> REASON=<why> EFFORT_ENV=set|unset
runstate.sh driver-mode enter --model <this session's model> \
  --effort <EFFORT, exactly as printed> --threshold <unknown, or THRESHOLD per the rule below>
```

The rule for each of these three calls is the one run-loop's
`## 2. Enter driver mode` states beside the same block: the effort passed exactly as printed and never
inferred, the threshold passed or replaced by `unknown` according to `SOURCE`, the
kickoff wording for each, never asking the operator to change either, and
**stopping** with a stop report when `enter` refuses — never resume the loop
unmarked. Keep `EFFORT_ENV` and the threshold reading for the kickoff (§4). `Read`
`${CLAUDE_PLUGIN_ROOT}/agents/loop-driver.md` now too — it is your role for the rest
of this session.

Call `begin-run` only once §1 has established the checkpoint — it dies on a missing
run-state, and §1's reconstruct path may still be building it — right before §2.

## 1. Load the checkpoint

**Preflight first**, as run-loop's `## 1. Preflight` states it: its gspec contract +
interlock bullet, and its model-routing bullet (keep `validate`'s and `table`'s
output for the kickoff, §4). Driver mode is already active, so a stop there — a
`CHECK=fail` or an `INTERLOCK=busy` — runs `runstate.sh driver-mode exit` right
after its stop report.

**Resume runs neither of that section's two drift scans.** The `adopt` path in §2
reconciles the one case a crash can leave — an orphan commit that landed a
capability's last covering task but never recorded it; any other capability
finished mid-run is left to the end-of-run scan in run-loop's `## 4. Termination`.

When the run-state file exists, first run
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh prune-questions .agents/run-state.yaml`
(or the path in $ARGUMENTS), before `pending_questions` is read or rendered
anywhere below.

Then read `.agents/run-state.yaml` (or the path in $ARGUMENTS). From it take: `status`,
`branch`, `last_green_commit`, `backlog.cursor`/`pending`, and
`pending_questions`.

**Then read the finding INDEX — and only the index** (ADR 0022):
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh findings .agents/run-state.yaml`. One line
each; the bodies live in `.agents/findings/<id>.md`. Open a body **only** when its
summary bears on the packet you are about to run, and say which you opened and why.
The index is mandatory and the bodies conditional, since skipping the index repeats
the rework a finding was recorded to prevent.

**If the file is missing, reconstruct it from git before giving up** (it is
gitignored — ADR 0009 — but the feature branch and its commit trailers usually
survive):

1. Get onto the run's feature branch. If you are on `main`/`develop`, list
   candidates with `git branch --list 'orch/*'` and `git switch orch/<task-id>`.
2. Run `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh reconstruct .` — it prints
   `BRANCH=`, `TIP=` (a **candidate** `last_green_commit`), `BASE=`, and `DONE=`
   (the packet ids already committed, from the `[orch packet:<id>]` trailers), or
   `RECONSTRUCT=escalate` with what to fix first.
3. **Verify `TIP` is actually green** — run the packet build+tests on it; the
   script cannot. If it is **red**, do not fabricate a green checkpoint — treat it
   as crash scratch, **escalate to the human** with a stop report, and run
   `runstate.sh driver-mode exit` right after it.
4. Rebuild the backlog **through the adapter** (ADR 0020 D2) — never by parsing
   `gspec/` yourself: `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh next` for the
   feature, then `… nodes <slug>` for its unchecked tasks (or `$ARGUMENTS`).
   `pending` = the committed backlog minus `DONE` (from step 2), in order;
   `cursor` = first pending. There is no `backlog.done` field to populate (ADR
   0025): `DONE` is scratch used only to compute `pending`, and nothing is written
   from it automatically. The adapter already omits checked tasks, so a task
   completed before the crash will not reappear.
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

**Keep this reading**: the sweep in run-loop §3's **Form this packet's members**
step decides whether this session's first packet is a continuation from it, and
step 2 overwrites `status` to `running` before that sweep runs.

## 2. Re-establish the working tree at the green checkpoint

**Begin the run now** — `.agents/run-state.yaml` exists at this point:
`runstate.sh begin-run .agents/run-state.yaml`. It keeps the existing `run_id`,
since a run spans sessions. Keep the `RUN_DIR=` value it prints: the adopt path
below, the membership recovery and every lint name it, written out literally.

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
  cursor. **Escalate to the human before stashing if there is any doubt it is
  disposable loop scratch** — the checkout is shared, and `reconcile`'s
  reviewed-output patterns cannot cover everything. **Record no outcome here**:
  the sweep in run-loop §3's **Form this packet's members** step decides whether
  the cursor's bundle's open starts read `interrupted`.
- **`adopt`** — a clean orphan commit one ahead of the recorded green SHA carries a
  `[orch packet:<cursor>]` trailer first (`reconcile` checks only that first
  trailer): a **torn write** — the packet committed, but the crash beat the
  run-state update. **Re-verify build+tests are green on that commit yourself**
  (the helper cannot run the suite). A landed bundle writes one trailer per
  member, cursor first, in the same commit, so read **every** trailer on it, in
  commit order:
  ```bash
  MEMBERS="$(git log -1 --format=%B HEAD \
    | grep -oE '^[[:space:]]*\[orch packet:[a-z0-9][a-z0-9-]*\][[:space:]]*$' \
    | sed -E 's/^[[:space:]]*\[orch packet:(.*)\][[:space:]]*$/\1/' \
    | awk '!seen[$0]++' | paste -sd, -)"
  ```
  This is the anchored, deduplicated read of run-loop's `## 1. Preflight`
  **Drifted completion record** bullet, so prose that mentions a trailer is never
  read as a member. A commit whose trailers sit inline in prose — predating this
  convention — matches nothing, so `$MEMBERS` comes back empty and the check
  below escalates; never loosen the anchor for it. **If the first id in
  `$MEMBERS` is not `<cursor>` itself, escalate to the human instead of
  adopting** — `reconcile`'s own match is unanchored, so this is what catches a
  mismatched first trailer. (A lone `<cursor>` trailer reads back as
  `MEMBERS=<cursor>`.) Then adopt it: set `last_green_commit` to that SHA and
  **remove every member of `$MEMBERS` from `pending`** — there is no `done` list to
  move them into (ADR 0025). **Record whatever completion the commit missed** — in
  one call, restoring from `HEAD`:
  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh record-completion \
    --tasks "$MEMBERS" --feature <the handoff's FEATURE= value> --restore head
  ```
  passing `--feature`, from the cursor's own `<RUN_DIR>/<cursor>/handoff.md`,
  **only when that file exists**.
  - **`TASK_DRIFT=<member>\t<reason>`** — note it by name and do not halt: the
    commit already landed whether or not its checkbox could be flipped.
  - **`HALT=<member>\t<reason>`** (the call exits 1) — a malformed id; the
    commit is already made, so instead of stopping before a commit as a fresh land would,
    **escalate to the human** naming the member; an already-landed trailer
    failing this way should not be guessed past.
  - **No slug and no handoff** — `<RUN_DIR>/<cursor>/handoff.md` does not exist
    and no member printed a `CHECKED=<feature>#T<n>` value, so the call reads
    `RECORD_COMPLETION=skipped`: there is **no restore and no commit** for
    capabilities here — say so in the kickoff. The end-of-run scan in run-loop's
    `## 4. Termination` reconciles that feature's judgeable drift instead.
  - **`HELD=<slug>\t<reason>`** — a held feature: name it in the kickoff,
    carrying that reason, in the per-row form run-loop's `## 1. Preflight`
    **Drifted capability checkboxes** bullet uses, which states what a held
    feature is.
  - **`CAPABILITIES=<slug>\tfailed`** — report it by name — never escalate for
    this, and never change anything already decided above. The call has already
    restored that PRD from `HEAD` (`RESTORED=`, the path the handoff's `PRD=`
    line names), so a partial write never rides into the commit below.

  **Commit the flips.** Stage every `STAGE=` path, then commit only when that
  left a change against `HEAD` (`git diff --cached --quiet` exits 1) — a
  `CHECKED=already` member's plan file is named but unchanged. That one commit
  uses the reconciliation form run-loop's `## 1. Preflight` and
  `## 4. Termination` use, with site `adopt`: `spec: reconcile capability record
  (adopt)`. It is **never an amend of the orphan commit**, which is already
  recorded, and it carries **no `[orch packet:]` trailer**,
  so run metrics count no packet for it.
  A failure in the call or in this commit is reported by name as stated above —
  never escalated, never halting — and never changes the `green` attestation
  below: the packet already landed, and the end-of-run scan in run-loop's
  `## 4. Termination` reconciles what this step could not.

  **Attest the outcome** for every member in one call:
  `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh record-outcome "$MEMBERS" green`.
  Set `cursor` to whatever entry remains first in `pending` (or none), by the
  cursor-advance rule of run-loop §3's **Land** step, and write run-state
  atomically via `runstate.sh write`. Every member of the bundle is done — do not
  redo any of them.
- **`escalate`** — diverged history, multiple unexplained commits, an untagged /
  mismatched orphan, or a dirty tree holding a reviewed-output path (deliberate
  output the loop did not create, sitting where `discard` would otherwise stash
  it unseen). **Stop and ask the human**, then `runstate.sh driver-mode
  exit` right after that stop report. Do not discard commits — or unreviewed
  output — you cannot account for.

Once reconciled, set `status: running` (`runstate.sh set .agents/run-state.yaml
status running`) and **claim the driver**
(`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh claim-driver .agents/run-state.yaml`),
so the next session does not read this live run as a crash (ADR 0020 D5); beat it
at each packet boundary, per run-loop §3's **Advance** step. **Clear the pause
sentinel** (`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh clear-pause .agents/pause`)
so the consumed request does not re-halt this session (ADR 0017).

**Snapshot run-metrics for the prior segment (best-effort, ADR 0019).** If the last
session **crashed** (`status: running` on entry), it never ran the pause snapshot,
so capture its token data before transcript rotation loses it:
`${CLAUDE_PLUGIN_ROOT}/scripts/metrics.sh collect || true`. If it errors or `jq` is
absent, ignore it and continue.

## 3. Surface pending questions before doing work

If `pending_questions` contains any `blocking` entry for the packet at
`backlog.cursor`, the loop **cannot** proceed on it — present those questions to the
human and wait. Assemble, tally and lint the surrounding stop report (shape B)
exactly as run-loop's `## 4. Termination` does — `runstate.sh run-digest
.agents/run-state.yaml` with **no** `--since`, so it names every packet this run
began even when this session ran none of them; the four tally figures from
`runstate.sh run-tally`; the lint on `<RUN_DIR>/stop-report.md` and
`<RUN_DIR>/stop-digest.tsv`, read as that section says — and slot these questions in
as its **Decisions for you** block: each one an answerable choice with what follows
from each option and your lean, not the raw `pending_questions` text, naming the
packet it blocks by its plain-English title, since the human will not recognise the
id. Non-blocking questions are surfaced but do not halt progress on unrelated
packets. When this stop report is the whole of what this session does, run
`runstate.sh driver-mode exit` right after emitting it.

## 4. Continue from the cursor

**First, emit the kickoff** — shape C in
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, headed `### Resuming`,
rendered from `runstate.sh run-digest .agents/run-state.yaml` with **no** `--since`:
its `packet` lines are what THIS run already did, across however many sessions
drove it, so render those as one ⚠️ **Picked up** line naming what is unfinished
rather than a second stop report. Render the `▶ **Session**`, `⚠️ **Routing
config**`, `▶ **Routing**` and `⚠️ **Effort override**` lines exactly as run-loop's
`## 2. Enter driver mode` renders them, from §0's and §1's outputs. State what is
**left**, not what the original run set out to do: the remaining packets in plain
words, what is expected to need a decision, and where this session will stop. Where
the tree needed reconciling (§2), say so in one line — whether anything was adopted
or set aside, and whether the resumed state matches where the human thinks they left
off — plus any line §2's adopt path owes the kickoff. If `$ARGUMENTS` carried
`--relay`/`--inline`, add the one `⚠️` line per flag described above.

**Lint the kickoff before you emit it**, exactly as run-loop's
`## 2. Enter driver mode` lints a fresh run's: `<RUN_DIR>/kickoff-digest.tsv` and `<RUN_DIR>/kickoff.md`,
with `<RUN_DIR>` the value §2's `begin-run` printed, **written out literally** —
never `$RUN_DIR` or any other variable, which driver mode refuses.

**Then run run-loop's `## 3. Loop`** from its **Form this packet's members** step —
§2 above already made the **Branch** step's switch — through its
`## 4. Termination`, for the cursor packet and every packet after it: recover the cursor's
membership from its existing handoff, sweep (this first packet's continuation
decided from the `status` §1 read), write the handoff, record the start, then
dispatch, route, land, integrate and advance exactly as a fresh run does —
including running `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve <agent>`
immediately before each dispatch, passing a non-empty result as `model` and
omitting `model` when it is empty. Honor the gates in run-loop's `## Never`. Keep
`.agents/run-state.yaml` current as packets land, so the next pause is cheap, and
run `runstate.sh driver-mode exit` immediately after whichever stop report
run-loop's `## 4. Termination` renders.
