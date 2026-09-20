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
runstate.sh compact-threshold   # THRESHOLD=<n|unknown> SOURCE=repo|operator|unknown APPLIED=no
runstate.sh driver-mode enter --model <this session's model> \
  --effort unknown --threshold <unknown, or THRESHOLD per the rule below>
```

Pass `--effort unknown` unless the operator has explicitly stated their
effort level this session — nothing records it automatically yet.
`compact-threshold` is a pure reader — it never writes a settings file, so
`APPLIED` is always `no`. When `SOURCE` reads `repo` or `operator`, pass
`THRESHOLD` straight through to `driver-mode enter` and state that number in
the kickoff — the harness genuinely enforces it. When `SOURCE` reads
`gaffer-default` or `unknown` — the enumerated set naming no value in effect
— pass `--threshold unknown` instead, regardless of what `THRESHOLD`
printed, and state no threshold in the kickoff at all: the measurement should
read unmeasured rather than flag a threshold nothing enforces. **Never ask the
operator to change either** — state what applies, as read, and move on. If
`driver-mode enter` refuses (no session id available, from neither an
argument nor `$CLAUDE_CODE_SESSION_ID`), **stop now** with a stop report
saying so; never resume the loop unmarked. `Read`
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

**Then the model-routing preflight, same as `/gaffer:run-loop` §1.** Run
`${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh validate` and
`${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh table` once, and keep both outputs
for the kickoff (§4). Running them after §0's driver-mode entry is harmless:
`routing.sh` is read-only. Both exit 0 on every config state, and **a
`validate` report never stops the resume** — an ignored entry already falls
back to its agent's frontmatter model. Do not read `model_routing` yourself.

**Resume runs no capability-drift scan of its own** — it neither repeats
`run-loop` §1's drifted-completion-record scan nor its drifted-capability-checkbox
scan. The `adopt` path in §2 below reconciles the one case a crash can leave —
an orphan commit that landed a capability's last covering task but never
recorded it — as part of adopting that commit; any capability finished mid-run
but not by an adopted commit is left for the resumed run's own `run-loop` §4
end-of-run scan to reconcile when it terminates. That is the only phrasing of
the rule this file carries — reconciling judgeable drift is the loop's job,
never the human's, and this file assigns it nowhere else.

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

**Keep this reading** — step 4's sweep needs to know whether it read `paused` or
`blocked` **here**, before step 2 overwrites `status` to `running`.

## 2. Re-establish the working tree at the green checkpoint

**Begin the run now** — `.agents/run-state.yaml` is guaranteed to exist at
this point (it either already did, or §1's reconstruct path just wrote it):
`runstate.sh begin-run .agents/run-state.yaml`. It **keeps** the existing
`run_id` (a run spans sessions, and this one is continuing) while pruning old
run directories down to the current run and the newest previous one. Calling
it any earlier, before the checkpoint file is confirmed to exist, would die.
Capture its `RUN_DIR=` line into `$RUN_DIR` — §4 needs it to check for the
cursor's own existing `handoff.md` before deciding how to re-form its bundle
membership.

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
  cursor. Because the loop shares this single checkout, that scratch may include
  work you did not produce — `reconcile` already escalates instead of `discard`
  when it recognizes a reviewed-output path (e.g. `.gspec/memory/pending/`, agent
  memories awaiting `/gspec-memorize`), but its pattern list cannot cover
  everything: **escalate to the human before stashing if there is any doubt it
  is disposable loop scratch** rather than deliberate output someone else
  produced, matching the instinct `skills/pause/SKILL.md` carries for the same
  shared-checkout risk. **Record no outcome here** — nothing finished; whether
  the cursor's bundle's open starts read `interrupted` is step 4's sweep to
  decide, once it re-forms the bundle's membership.
- **`adopt`** — a clean orphan commit one ahead of the recorded green SHA
  carries a `[orch packet:<cursor>]` trailer FIRST (`reconcile` only checks
  that first trailer — `orphan_packet_tag` reads no further): a **torn
  write** (the packet committed but the crash beat the run-state update).
  **Re-verify build+tests are green on that commit yourself** (the helper
  cannot run the suite). The commit may carry more than one
  `[orch packet:...]` trailer — a landed bundle (`packet-bundling`) writes
  one per member, cursor first, in the same commit (§3.6) — so read
  **every** trailer on it, in commit order, rather than trusting the cursor
  alone (T7), the same read `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md`
  §4 uses to recover a landed bundle's membership:
  ```bash
  MEMBERS="$(git log -1 --format=%B HEAD \
    | grep -oE '^[[:space:]]*\[orch packet:[a-z0-9][a-z0-9-]*\][[:space:]]*$' \
    | sed -E 's/^[[:space:]]*\[orch packet:(.*)\][[:space:]]*$/\1/' \
    | awk '!seen[$0]++' | paste -sd, -)"
  ```
  the same anchored, deduplicated read the drifted-completion-record preflight
  uses (`${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` :69-72) — anchored to
  the whole line so prose elsewhere in the commit body that merely *mentions*
  another packet's trailer cannot be read as a member, and deduplicated so a
  repeated trailer cannot hand `record-outcome` the same id twice. **A commit
  predating this trailer convention — one whose `[orch packet:...]` trailers
  sit inline within prose rather than each on its own line — matches nothing
  here, so `$MEMBERS` comes back empty and the check below escalates instead
  of adopting.** That is the intended, safe outcome for a shape this anchored
  read cannot confirm, not a regression to loosen the anchor for. **If the
  first id in `$MEMBERS` is not `<cursor>` itself, escalate to the human
  instead of adopting** — `reconcile`'s own `orphan_packet_tag` match is
  unanchored and only reads the first hit it finds, so an orphan whose real
  first trailer differs from what `orphan_packet_tag` matched can still reach
  `DECISION=adopt`; this re-read, anchored, is what catches that case before
  anything is attested. (a lone `<cursor>` trailer reads back as
  `MEMBERS=<cursor>`, byte-identical to a single-member adoption). Then adopt
  it: set `last_green_commit` to that SHA and **remove every member of
  `$MEMBERS` from `pending`** — there
  is no `done` list to move them into (ADR 0025). For each member, in the
  same trailer order, check whether it already carries the gspec checkbox
  flip (it should — §3.6 lands every member's flip in the same commit;
  `git show --stat <sha> -- gspec/` tells you) and flip it now if not:
  `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh check-task <member>`, same
  exit-code rules as §3.6 (`CHECKED=none` is skipped, not failed, for a
  non-gspec backlog; exit 4 is drift — note it by name, do not halt, and
  move on to the next member — the commit already landed regardless of
  whether its own checkbox could be flipped; exit 1 is a malformed id, a
  real usage error §3.6 treats as grounds to stop before committing — here
  the commit is already made, so instead **escalate to the human** naming
  the member, since an already-landed trailer failing `check-task` this way
  is not expected and should not be guessed past). Note any exit-0
  `CHECKED=<feature>#T<n>` line as you go — the capability step just below
  needs it.

  **Complete the feature's capabilities.** Once every member above has been
  flipped or drifted, run `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh
  complete-capabilities <slug>` once for the adopted feature — an adopted
  commit is always one feature, same as a fresh land. Take the slug from any
  member's own `CHECKED=<feature>#T<n>` line noted above; when none was
  printed (every member read `CHECKED=already`, or read `CHECKED=none` at
  exit 4), fall back to the cursor's own `FEATURE=` line in
  `$RUN_DIR/<cursor>/handoff.md`, the same fallback §3.6 uses for a fresh
  land. Skip the call entirely only when every member returned `CHECKED=none`
  **at exit 0** — nothing gspec-sourced resolved for any member, so there is
  no capability to complete. `CHECKED=none` on its own does not mean that: an
  **exit-4** drift member prints the same line (the plan no longer names its
  task id), and that member *is* gspec-sourced — it takes the `FEATURE=`
  fallback just above, so the call still runs. One member at exit 4 is
  enough; the skip needs every member at exit 0.

  **Skip the call too when that fallback has nothing to read** — no member
  printed a `CHECKED=<feature>#T<n>` line **and**
  `$RUN_DIR/<cursor>/handoff.md` does not exist (a crash before §4 ever wrote
  that handoff, or a run directory pruned since). There is then no slug to
  pass and no `PRD=` path to restore from, so make **no call, no restore and
  no commit** for capabilities here, and say so in the kickoff. Nothing is
  lost by skipping: the resumed run's own `run-loop` §4 end-of-run scan
  reconciles this feature's judgeable capability drift when the run
  terminates, exactly as §1 above leaves any capability finished mid-run but
  not by an adopted commit to that same scan.

  - **exit 0** — stage the `FILE=` PRD into the commit below **only when
    that call's own summary line reads `completed=<n>` with `n` greater than
    0** — equivalently, it printed at least one `COMPLETED=` line. This is
    the same test §3.6 applies at a fresh land, and §1 and §4 at their
    scans. `FILE=` alone does not mean anything flipped: it is printed
    whenever the feature resolved, including a `blocked` hold and a
    `completed=0` resolve, so staging on `FILE=` presence would stage a PRD
    nothing changed on.
  - **`COMPLETE_CAPABILITIES=blocked` — a held feature.** An unchecked
    task's `covers:` quote matches no capability, so every flip for that
    feature is held until it is fixed. **Nothing is flipped, restored or
    committed for a held feature**: `blocked` is exit 0 with `completed=0`,
    so it stages no PRD, joins no commit, and leaves nothing to restore. It
    is **neither a failure nor a flip** — name the feature in the kickoff
    below, carrying that call's own `REASON=` text, the same per-row form
    `run-loop` §1 and §4 name a held feature in.
  - **exit 4, exit 1, or anything else** — report it by name — never
    escalate for this, and never change anything already decided above —
    then, since no `FILE=` line is ever printed on a failure, restore the
    PRD with `git checkout HEAD -- <path>`, taking `<path>` from the `PRD=`
    line in `$RUN_DIR/<cursor>/handoff.md`, the same file the `FEATURE=`
    fallback above already reads, so a partial write from the failed call
    never rides into the commit below. That is the `HEAD` form §1 and §4
    use, not §3.6's `git checkout -- <path>`: this step runs outside any
    packet and stages the PRD itself, so the index entry is precisely the
    thing that has to go.

  **Commit the flips.** When the per-member loop above already needed its
  own follow-up commit, stage this capability flip's PRD into that same
  commit before making it. When it did not, but this step flipped a
  capability anyway, make a small commit for the capability flip alone. When
  neither flipped anything, make no commit here — a held feature, a
  `completed=0` resolve, a skipped call and a failure all land here, and
  none of them is a reason to commit. Either way — task flips and
  capability flip together when combined, or the capability flip alone —
  that commit uses the reconciliation form (the same form `run-loop`
  §1/§4 use for preflight and end-of-run reconciliation) with site `adopt`:
  `spec: reconcile capability record (adopt)`. It is **never an amend of the
  orphan commit** — the orphan commit is already recorded, so amending it
  would rewrite history, the same reason the task-flip commit above is never
  an amend — and it carries **no `[orch packet:]` trailer**, so run metrics
  count no packet for it. A failure in the call or in this commit is
  reported by name as stated above — never escalated, never halting — and
  never changes the `green` attestation below: the packet already landed
  regardless of whether its capability could be flipped, so a crash between
  landing and recording this leaves no capability drift this step has to
  chase — the resumed run's own `run-loop` §4 end-of-run scan reconciles
  whatever this step could not, the same scan the skip above hands to.

  **Attest the outcome** — it landed, just was not recorded, for every
  member in one call: `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh
  record-outcome "$MEMBERS" green`. Set `cursor` to whatever entry remains
  first in `pending` (or none, if nothing does — the same rule §3.6's own
  cursor-advance uses, since `group` forms a bundle from the plan's order
  while `pending` is the loop's own chosen order, so a member is never
  assumed to sit at a consecutive prefix of it), and write run-state
  atomically via `runstate.sh write`. Every member of the bundle is done —
  do not redo any of them: this is exactly the crash window the task exists
  to close, so a crash between a bundled commit and the run-state write can
  never leave a landed member unchecked and queued for re-execution.
- **`escalate`** — diverged history, multiple unexplained commits, an untagged /
  mismatched orphan, or a dirty tree holding a reviewed-output path (deliberate
  output the loop did not create, sitting where `discard` would otherwise stash
  it unseen). **Stop and ask the human**, then `runstate.sh driver-mode
  exit` right after that stop report. Do not discard commits — or unreviewed
  output — you cannot account for.

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
unrelated packets. Take its four digest-derived tally figures from `runstate.sh
run-tally .agents/run-state.yaml` and compute none of them, and lint it before you
emit it — `<RUN_DIR>/stop-digest.tsv`, `<RUN_DIR>/stop-report.md` and
`${CLAUDE_PLUGIN_ROOT}/scripts/report-lint.sh --shape B <RUN_DIR>/stop-report.md
<RUN_DIR>/stop-digest.tsv`, with `<RUN_DIR>` the `RUN_DIR=` value §2's
`begin-run` printed **written out literally**, never `$RUN_DIR` — both exactly as
run-loop §4 does, correcting the lines a finding names at most once and never
re-linting in a loop. `REPORT_LINT=clean` means *no mechanical rule was broken*,
never that the report conforms to the contract, and `REPORT_LINT=unjudged` is
**not** clean; what the lint cannot judge is stated once, in run-loop §4's "How
to read the lint's result". When this stop report is the whole of what this session does,
run `runstate.sh driver-mode exit` right after emitting it.

## 4. Continue from the cursor

**First, emit the kickoff** — shape C in
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, headed `### Resuming`,
rendered from `runstate.sh run-digest .agents/run-state.yaml` with **no** `--since`:
its `packet` lines are what THIS run already did, across however many sessions
drove it, so render those as one ⚠️ **Picked up** line naming what is unfinished
rather than a second stop report, and its `enter` line gives the `▶ **Session**`
line (model/effort/threshold), exactly as a fresh run's kickoff does. Render
`⚠️ **Routing config**` only when §1's `validate` printed something, and `▶
**Routing**` only when §1's `table` printed something, exactly as run-loop §2
does — empty output means no line. State what
is **left**, not what the original run set out to do: the remaining packets in plain
words, what is expected to need a decision, and where this session will stop. The
human may be days removed from the run and remembers none of the ids; the checkpoint
you just loaded is the only thing that does. Where the tree needed reconciling (§2),
say so in one line — whether anything was adopted or set aside, and whether the
resumed state matches where they think they left off. If `$ARGUMENTS` carried
`--relay`/`--inline`, add the one `⚠️` line per flag described above.

**Lint the kickoff before you emit it**, exactly as
`${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` §2 lints a fresh run's: write
`runstate.sh run-digest .agents/run-state.yaml > <RUN_DIR>/kickoff-digest.tsv`
and the rendered kickoff to `<RUN_DIR>/kickoff.md`, with `<RUN_DIR>` the
`RUN_DIR=` value §2's `begin-run` printed **written out literally** — never
`$RUN_DIR` or any other variable, which driver mode refuses — then run
`${CLAUDE_PLUGIN_ROOT}/scripts/report-lint.sh --shape C <RUN_DIR>/kickoff.md
<RUN_DIR>/kickoff-digest.tsv` (both paths literal). On findings, correct the
lines they name **at most once**, then emit — never re-lint in a loop. A finding
records nothing, blocks nothing, rolls back nothing, flips nothing and halts
nothing. `REPORT_LINT=clean` means *no mechanical rule was broken*, never that
the kickoff conforms to the contract, and `REPORT_LINT=unjudged` is **not**
clean; what the lint cannot judge is stated once, in run-loop §4's "How to read
the lint's result".

**Form the cursor's bundle membership before anything else here** (T7,
membership rule settled T9). A paused or crashed session's cursor may be a
multi-task bundle (`packet-bundling`), exactly as a fresh packet's cursor can
be — `$MEMBERS` is driver-held shell state (the same convention
`$SINCE`/`$SWEEP` use) that does not survive a crash or a pause on its own,
so this session must re-establish it before the sweep below can know every
member to exempt. **Two paths, tried in this order:**

- **The cursor's own `handoff.md` already exists** (`$RUN_DIR/<cursor>/
  handoff.md`, from §2) — this session is continuing work a prior session
  (this one or an earlier one, paused or crashed) already started on this
  exact cursor, and `record-start` was already called against whatever
  membership that prior session decided. **Recover that same membership
  rather than re-deriving it** — re-running `group` here could shrink or
  grow it (T7's bug: the sweep below would then close members the run had
  started as `interrupted`, or silently start a member no start record
  covers). Read the file's own header and body:
  - `tier:` and `agent:` come straight off its header lines (`grep
    '^tier:\|^agent:'`) — they were decided once, against this same
    membership, when the handoff was first written (§3.3); do not re-judge
    them from titles here.
  - Membership comes off its body's `BUNDLE=` line (`grep -m1 '^BUNDLE='`).
    **Its absence means a single-member bundle**: set `MEMBERS=<cursor>`
    alone, so a bundle cap of 1 — which never writes a `BUNDLE=` line in the
    first place — behaves exactly as it always has, byte-for-byte.

  Then re-run only the **mechanical refusals**, never the scope/deps/cap
  judgment `group` applies when forming a bundle fresh — this is recovery,
  not re-formation. Resolve each non-cursor member's state with
  `gspec-backlog.sh task-status "$MEMBERS"` (the same read the sweep below
  already uses for `--gone`): a member whose line reads `finished` (its task
  was checked off while this session was away — by a hand fix, another
  branch's merge, anything) or `gone` (re-decomposed out of the plan) drops
  out of `$MEMBERS`; **the cursor itself is never dropped by this rule**,
  regardless of what its own line reads. The third mechanical refusal —
  already routed `hand-off-feature` this run — needs no separate check here:
  it is caught a few steps below, when the (possibly narrowed) `$MEMBERS` is
  piped into `gspec-backlog.sh handoff` and its `HANDOFF=refused` line is
  read exactly as it always is.

- **No `handoff.md` exists yet for the cursor** — nothing was ever started on
  it (a fresh cursor this session is about to begin, or a crash before the
  handoff was written), so there is nothing to recover and the group is
  formed exactly as `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` §3.2
  does: read the cap (`runstate.sh bundle-cap` → `CAP=<n>`), form the
  candidate group at the cursor (`gspec-backlog.sh group <cursor> --cap
  <n>`), then walk its `MEMBER=` lines in that printed (plan) order and
  judge each one's tier from its title exactly as §3.2 judges a fresh
  packet's — the first one is the cursor itself: judging it design-heavy
  ends the group right there (`MEMBERS=<cursor>` alone); otherwise keep
  walking and stop before the first member you would judge design-heavy,
  dropping it and everything after it. A leading `HANDOFF=unknown` from
  `group` (no gspec, a non-gspec packet, or a cursor already checked) means
  this packet does not bundle at all: set `MEMBERS=<cursor>` and decide
  `tier`/`--agent` for it alone, exactly as you would today. Otherwise
  `MEMBERS` is the comma-joined ids that survive the walk, cursor first, in
  plan order, and `tier`/`--agent` are decided for the whole of `MEMBERS`
  the same way §3.2 decides them.

Use `$MEMBERS` everywhere below in place of `<cursor>` alone.

**Then sweep before recording the packet** (T3, T7, T8): run
`${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh sweep-open --list`, passing
`--paused-cursor "$MEMBERS"` exactly when this session is about to continue it
(cosmetic on the `--list` call, which only lists — it costs extra ids in
`OPEN=` if omitted; run-loop's own `--list` call below omits it and passes it
only on the real sweep, which is the call that matters) —
`status` read `paused` **or** `blocked` in step 1, both of which leave every
member of the cursor's bundle open for this same session to pick back up; the
cursor's whole bundle is what this session is about to continue, not what the
sweep should close. A crash (`status` read `running`) is not this situation —
no member of `$MEMBERS` is excluded there, and each still closes as
`interrupted` (or `abandoned`, if it is also gone) like any other open packet.
It prints one `OPEN=<id>` line per open
packet. If it printed any, comma-join the ids (the `paste -sd,` idiom at
run-loop/SKILL.md :84–87) into one
string and resolve them —
`${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh task-status "<id,id,...>"` — which
prints one `<id>\t<state>\t<reason>` TSV line per id plus a trailing
`FINISHED=<csv>` line; the `gone` set is the ids whose second column reads `gone`.
Comma-join THOSE into `GONE="<id,id,...>"` and pass it to `--gone` (skip
`task-status` and `--gone` entirely when `--list` printed nothing —
`task-status` refuses an empty id list, and no open packets means nothing
for the real sweep to close either — and leave `SWEEP` empty). Otherwise
sweep for real, same `--paused-cursor`/`--gone`, capturing the sweep's own
output:
`SWEEP="$(${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh sweep-open --paused-cursor
"$MEMBERS" --gone "$GONE")"`. `$SWEEP` holds one
`SWEPT=<id>`/`OUTCOME=<interrupted|abandoned>` line pair per packet the sweep
actually closed — every open packet, not only the gone ones; a gone packet's
pair reads `abandoned`, every other open packet's reads `interrupted` —
**carry `$SWEEP` through to the first shape-A report**, exactly as
`${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` §3.6 renders it (that
section's own `$SWEEP` capture, from its own §3.2, is a separate one for
every packet after this first one) — `run-digest`'s `packet` lines are never
filtered by `--since`, so this sweep's own record of what it just closed is
the only thing marking it as new. The kickoff above needs nothing, since a
sweep always runs after it.

Write the packet's handoff for `$MEMBERS` exactly as
`${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` §3.3 does — `tier`/`--agent`
were already decided above.

**Check for `HANDOFF=unknown` or a non-cursor `HANDOFF=refused` before piping
anything**, the same check §3.3 runs (T7 — a resumed bundle can legitimately
carry a member routed `hand-off-feature` earlier in the same run, same as a
freshly-formed one). Run `gspec-backlog.sh handoff "$MEMBERS"` first and read
its output. A leading `HANDOFF=unknown` line means some id in `$MEMBERS` does
not resolve in gspec. When `$MEMBERS` came from the no-`handoff.md` path
above, this can only be `<cursor>` alone (`$MEMBERS` has one member), since
`group` already confirmed every other candidate resolves. When `$MEMBERS`
was instead recovered from an existing `handoff.md`'s `BUNDLE=` line, a
non-cursor member can reach this too: the mechanical refusal check above only
drops a member `task-status` reads as `finished` or `gone`, and `task-status`
is deliberately conservative — it reads several genuinely-gone shapes as
`unknown` rather than guess (see `gspec-backlog.sh`'s own header comment on
`task-status`), which `handoff`'s fuller per-id resolution then catches here
instead. Treat that the same as a non-cursor `HANDOFF=refused` below —
truncate `$MEMBERS` to the members before it and retry — rather than as the
single-member case. When `<cursor>` itself is the one that does not resolve
(either path), and you have run-state's own task text for this packet
instead (a non-gspec packet, never a bundle), pipe that in its place.
Otherwise **skip the packet with no record** — advance the cursor and report
the skip.

A leading `HANDOFF=refused` line (`REASON=hand-off-feature`) means some id in
`$MEMBERS` was already routed `hand-off-feature` this run — its own
`PACKET=` line names which one. When `PACKET=` is `<cursor>` itself, **skip
the packet with no record** — advance the cursor and report the skip. When
`PACKET=` names a later member instead, **truncate `$MEMBERS` to the members
before it**, dropping the refused member and everything after it, then
re-run `gspec-backlog.sh handoff` on the truncated `$MEMBERS` and proceed
with that narrower bundle — the refused member is left at its place in
`pending` and gets its own packet, refused again in turn, on a later
iteration. Never pipe a `HANDOFF=refused` body through to `runstate.sh
handoff` as if it were real task text.

Once `HANDOFF=<path>` prints clean (or a non-gspec packet's task text is
ready), pipe it (or run-state's own task text, always a single id in that
case) into `runstate.sh handoff .agents/run-state.yaml <cursor> --tier
<tier> --agent <agent>` (still exactly one packet id, the bundle's own —
never `$MEMBERS` — same as §3.3). Only once it is written do you attest the start —
capture `SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` first, the same capture
run-loop/SKILL.md §3.3 pairs with this exact step, so the first shape-A report
after this resume scopes `run-digest --since "$SINCE"` to only this packet's
own decisions rather than every decision the whole run has ever recorded —
then `runstate.sh record-start "$MEMBERS" --continue` when this session is
about to continue the cursor's bundle — the same condition the sweep above
used to exclude it from closing — else `runstate.sh record-start "$MEMBERS"`
(a fresh start for every member — its prior attempt, if any, already closed
with a recorded outcome, since a crash is not excluded from the sweep
above); either call writes one start (or continuation) record per member in
a single call, sharing a timestamp and session, exactly as §3.3 does.

Then `Read` `${CLAUDE_PLUGIN_ROOT}/skills/run-loop/SKILL.md` §3.4 onward
(dispatch with the handoff path, route every verdict, land, integrate,
advance) and §4 (termination) — this resume dispatches and routes exactly as
a fresh run does, for the cursor packet
and every packet after it — including running
`${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve <agent>` immediately before
each dispatch, passing a non-empty result as `model` and omitting `model` when
it is empty. Honor the same gates as before: the driver owns
routine commits, and merge/rebase/push onto non-`main`
branches; hard gates — `main`, releases, migrations,
secrets, deploys, the danger floor — still stop for the human. Keep
`.agents/run-state.yaml` current as packets land, so the next pause is cheap,
and run `runstate.sh driver-mode exit` immediately after whichever stop
report run-loop §4 renders.
