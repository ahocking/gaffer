---
name: run-loop
description: Drive the guided autonomy loop across a backlog of task packets, in driver mode (ADR 0028). For each packet — branch off the integration base, write its handoff file, dispatch a fresh agent with only that path, route the reviewer's verdict mechanically, commit on branch if green, update run-state — then pull the next. Honors the session autonomy level and the hard/soft gate split; pauses at a safe checkpoint on any hard gate or ambiguity. Produces reports; it integrates onto a non-`main` branch at full-autonomy but never merges/pushes to `main`, opens a PR, or crosses a hard gate. Use to run a semi-attended engineering session over the gspec backlog (a feature's plan under gspec/features/<slug>/) or a run-state backlog.
argument-hint: (optional — a backlog source or a starting packet; else reads .agents/run-state.yaml, then the gspec backlog)
---

# Run the guided loop $ARGUMENTS

`Read` `${CLAUDE_PLUGIN_ROOT}/agents/loop-driver.md` now, once, before anything
else — it is your role for the rest of this run (ADR 0028). That file holds the
**judgment**: routing, the escalation-decider stand-in, operator Q&A, and
mid-run edits. This skill holds the **mechanics**: preflight, the backlog,
dispatch ordering, commit trailers, and termination. Read both once; your
context persists across packets, so do not re-read either per packet.

There is **one sequential mode**; backlog size never switches it, and no
packet is implemented inline — every packet goes to a dispatched agent. Its
safety rests on the layers below it — the guard's driver-mode edit block
(`hooks/guard.sh`), per-packet `orch/<task-id>` feature branches in the single
local checkout, and the durable checkpoint in `.agents/run-state.yaml` — so
honor them, do not route around them. See
[ADR 0004](../../docs/adr/0004-graduated-autonomy-and-pausable-loop.md),
[ADR 0009](../../docs/adr/0009-single-directory-feature-branch-workflow.md),
and [ADR 0028](../../docs/adr/0028-loop-driver-mode.md).

## Flags this loop no longer has

`--relay`, `--inline`, and `--parallel` are still accepted in `$ARGUMENTS` and
must **not** error — something invoking this skill may still pass one from
habit. None of them change anything any more: relay dispatch was retired
([ADR 0012](../../docs/adr/0012-delegated-loop-driver.md), superseded) and
worktree parallel mode was retired
([ADR 0016](../../docs/adr/0016-parallel-worktree-lanes.md), superseded). If
`$ARGUMENTS` contains any of them, run the loop below and say so in the
kickoff (§2) with one `⚠️ **--<flag>** no longer does anything — this loop
runs one sequential mode.` line per flag present.

## The report contract — `Read` it before you emit anything

`Read` `${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md` (the glyph
vocabulary, the indentation contract, the header tally, the decision block)
and `${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md` (shapes **C**
kickoff, **A** check-in, **B** stop report) now, once, before the kickoff.
**Naming a path is not reading it** — unread, you render from memory and
produce free prose, which is the exact failure these files exist to prevent.

## 1. Preflight (stop here if unmet) — driver mode is NOT yet entered

Nothing in this section needs `driver-mode exit` on a stop: entering driver
mode is deliberately deferred to §2, after preflight passes, so a preflight
stop never has a mark to clear.

- **gspec contract + interlock (ADR 0020).** If the repo has a `gspec/` directory,
  run `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh check` and
  `… interlock`. A `CHECK=fail` means the specs are a gspec version this plugin
  does not support — **stop and say so** (the remedy is `/gspec-migrate`, or
  raising the pin); do not read the backlog anyway. An `INTERLOCK=busy` means a
  `gspec build` is driving this repo right now — **stop**: two drivers fanning
  implementers into one checkout will collide. Both are no-ops when there is no
  gspec project — gspec is optional (ADR 0020 D4).
- **Drifted completion record (ADR 0025 D1, gspec repos only).** Scan **every
  ref**, not just the current branch — at preflight the checkout is normally
  still on the integration branch, so a scan bounded to "the branch I'm on"
  almost never fires, and the case this exists to catch — a packet that
  landed, merged, and never got its checkbox flipped — usually lives in
  already-merged history. Anchor the match to the **whole line** — a real
  trailer, not prose that mentions one:
  ```bash
  IDS=$(git log --all --format=%B \
    | grep -oE '^[[:space:]]*\[orch packet:[a-z0-9][a-z0-9-]*\][[:space:]]*$' \
    | sed -E 's/^[[:space:]]*\[orch packet:(.*)\][[:space:]]*$/\1/' \
    | awk '!seen[$0]++' | paste -sd, -)
  ```
  Empty `$IDS` → nothing committed yet, skip. Otherwise check every id's gspec
  task, read-only:
  `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh task-status "$IDS"`. Any line
  reading `unchecked` names a packet that landed but whose task checkbox is not
  set — a genuine **drift**. **Say so in the kickoff (§2); do not flip the
  checkbox and do not block the run** — reconciling a drifted record is the
  human's call.
- **Autonomy level.** Resolve it (env `ORCH_AUTONOMY` > `.agents/autonomy` >
  `interactive`, clamped by `autonomy_ceiling`). The loop is meant for
  **`supervised`**, **`autonomous`**, or **`full-autonomy`**. At **`interactive`** it
  cannot commit unattended — either say so and stop, or run a single packet and halt
  at the commit for human approval. `autonomous` and `full-autonomy` drive *across*
  packets without checking in between green landings; **`full-autonomy`
  additionally integrates** (merge/rebase/push onto non-`main` branches — see §3.7).
- **Branch.** Never run on `main`/`master`. Work happens on `orch/<task-id>`
  feature branches **in the single local checkout**; `git commit`/`merge`/`push` to
  a protected branch is denied by the guard at every level anyway. The integration
  base the loop branches from and (at `full-autonomy`) merges back into is the
  **non-`main`** `integration_branch` from `.agents/project-overrides.yaml`
  (default `develop`, else `main`/`master`).

## 2. Enter driver mode, then establish the backlog and the run

**Enter driver mode now, right after preflight passes and before anything
else here:**

```
runstate.sh driver-mode enter --model <this session's model, from SessionStart> \
  --effort unknown --threshold unknown
```

Pass `--effort unknown` unless the operator has explicitly stated their
effort level this session — nothing records it automatically yet.
(`compact-threshold`, a real threshold lookup, is a later addition — pass
`unknown` for `--threshold` until it exists.) **Never ask the operator to
change either** — state them as read, in the kickoff, and move on.

**If `enter` refuses** (no session id available, from neither an argument nor
`$CLAUDE_CODE_SESSION_ID`), **stop now** with a stop report saying so. Never
run the rest of this loop unmarked — driver mode's whole safety property is
the guard's edit block, and there is nothing to block without a mark.

`Read` `${CLAUDE_PLUGIN_ROOT}/templates/task-packet.yaml` once now, before
building or continuing the backlog — the template carries two REQUIRED rules
every packet's handoff must carry regardless of source: an acceptance
criterion naming the matching regression sweep when its file scope touches
enforcement or automation code (a hook, a guard/policy script, CI logic), and
a `session_boundary` declaration when its file scope touches a surface
loaded at session start (`hooks.json`, a settings file that registers hooks,
or an agent/skill's frontmatter). §3.3 applies these per packet; do not
re-read this file per packet.

- If **`.agents/run-state.yaml` exists**, you are resuming — `Read`
  `${CLAUDE_PLUGIN_ROOT}/skills/resume/SKILL.md` and follow it instead of the
  rest of this section (it keeps `run_id` via its own `begin-run` call;
  calling `driver-mode enter` again there is harmless — idempotent).
- Otherwise build the backlog **through the adapter** — the single place this
  plugin reads gspec (ADR 0020 D2). Never parse `gspec/` yourself:
  - `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh next` picks the feature —
    lowest `order` among incomplete-and-unblocked, where **completion is derived**
    from the PRD's capability checkboxes and never stored. It prints `NEXT=<slug>`
    and the `PLAN=` file.
  - `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh nodes <slug>` turns that
    feature's plan into packet nodes (one per **unchecked** task). Each node
    becomes one packet.
  - Or take `$ARGUMENTS` / an explicit backlog instead — gspec is one of three
    backlog sources, not a requirement. **For a packet not sourced from
    gspec**, its task text (written into run-state now, from the template
    you just read) is what `gspec-backlog.sh handoff` has no equivalent for —
    it becomes that packet's handoff body directly at §3.3.

  Write an initial `.agents/run-state.yaml` from
  `${CLAUDE_PLUGIN_ROOT}/templates/run-state.yaml` (cursor = first packet,
  everything else pending), atomically:
  `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh write .agents/run-state.yaml`.

**Mark the run live, begin it, and claim the driver.**

```
runstate.sh set .agents/run-state.yaml status running
runstate.sh begin-run .agents/run-state.yaml      # RUN_ID=, RUN_DIR=, REMOVED=...
runstate.sh claim-driver .agents/run-state.yaml
runstate.sh clear-pause .agents/pause
```

`begin-run` mints `run_id` only when absent (a resume keeps it — a run spans
sessions) and prunes every run directory except the current and newest
previous one. `status: running` is the crash signal; the **driver claim** is
what tells a crashed run apart from *another session driving right now* (ADR
0020 D5). Keep the status truthful — only `/gaffer:pause`
(→ `paused`/`blocked`) and completion (→ `done`) clear it. Clearing the pause
sentinel here stops a stale request from immediately re-halting this run.

**Then emit the kickoff** — shape C in
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`: the packet list in
plain words, the model/effort/threshold `driver-mode enter` recorded (stated,
never offered for change), the one assumption most likely to be wrong, which
packets you expect will need a decision, the hard gates this backlog gets
near, the autonomy level, and where the run stops. Emit it **here**, after
preflight and after the backlog resolves. At **`interactive`**, the kickoff is
also the approval request: emit it and wait.

## 3. Loop — for the packet at `backlog.cursor`

1. **Branch.** Create (or switch to) the packet's feature branch:
   `git switch -c orch/<task-id> <base>` (integration branch from
   `.agents/project-overrides.yaml` → `integration_branch`, else `develop`,
   else `main`/`master`); `git switch orch/<task-id>` if it already exists. No
   worktree, no separate directory.
2. **Sweep for packets left open, before recording this one.**
   `runstate.sh sweep-open --list` prints one `OPEN=<id>` line per open
   packet. If it printed any, comma-join the ids and resolve them —
   `gspec-backlog.sh task-status "<id,id,...>"` (one `<id>\t<state>\t<reason>`
   line per id, plus `FINISHED=<csv>`); the `gone` set is every id whose state
   reads `gone`. Comma-join those and pass them to `--gone`, then sweep for
   real: `runstate.sh sweep-open --gone "<id,id,...>"` (omit `--gone` and skip
   `task-status` entirely when `--list` printed nothing). Each `SWEPT=<id>`
   names a packet to report by title in the next report.
3. **Write the handoff, then start.** Decide the packet's `tier`
   (`mechanical`, `integration`, `design-heavy`, or `docs`) and, from it, the
   `--agent`: `implementer` for `mechanical`/`integration`, `architect` or
   `ux-designer` for `design-heavy` (whichever the file hints scope to),
   `doc-writer` for `docs`.

   **Check for `HANDOFF=unknown` before piping anything.** Run
   `gspec-backlog.sh handoff <cursor>` first and read its output: a leading
   `HANDOFF=unknown` line means this id does not resolve in gspec (a
   deleted/renamed task, or a genuinely non-gspec packet). When you have
   run-state's own task text for this packet (a non-gspec-sourced backlog
   entry), pipe that instead of the adapter's output. Otherwise **skip the
   packet with no record** — advance the cursor and report the skip, the
   same as a refused handoff below.

   Append the applicable REQUIRED line(s) from §2's read of
   `task-packet.yaml` — a real instruction, not a formality: a sweep
   criterion when this packet's file scope touches enforcement/automation
   code, a `session_boundary` line when it touches a session-start-loaded
   surface, both if it touches both, neither otherwise. Then write the
   handoff:
   ```
   { gspec-backlog.sh handoff <cursor>
     printf '%s\n' "REQUIRED: the regression sweep covering <area> passes, with a new case for this change"   # only if applicable
     printf '%s\n' "REQUIRED session_boundary: <what could not be verified in this run; what the next session must check>"  # only if applicable
   } | runstate.sh handoff .agents/run-state.yaml <cursor> --tier <tier> --agent <agent>
   ```
   (or pipe run-state's task text in place of the first line, for a
   non-gspec packet, per the `HANDOFF=unknown` check above). **A refused
   handoff (`HANDOFF=refused`, e.g. a packet already routed
   `hand-off-feature` this run) skips the packet — advance the cursor and
   report the skip; do not call `record-start`.** Only once `HANDOFF=<path>`
   prints do you attest the start: `runstate.sh record-start <cursor>` for a
   fresh beginning, or `runstate.sh record-start <cursor> --continue` when
   you are picking a pause-interrupted packet back up rather than beginning
   it anew.

   **Read back the handoff's header** (`grep '^run-state:\|^result:\|^review:'
   <path>`) — it names the exact `run-state`, `result`, and `review` paths,
   absolute, that this packet's dispatches and your own `route` calls use for
   the rest of this packet. Pass the handoff path to the dispatched agent;
   its header is what tells that agent, and you, where to write and route.
4. **Dispatch, then route.** Dispatch a **fresh** agent (the `--agent` from
   §3.3) with the handoff path **only** — on a re-attempt, also pass the
   review file's path (from the handoff header, per §3.3). Read its one
   status line (`${CLAUDE_PLUGIN_ROOT}/templates/status-line.md`); never open
   its result file yourself. Then dispatch the `reviewer` with the handoff
   path (and the review path on a re-attempt) and read its verdict the same
   way. Pass that verdict, with its status line as `--status`, to `route`,
   **using the run-state path from this packet's handoff header** and
   **single-quoting the status text** — never double-quote it, since a
   backtick or `$(...)` in the agent's own text would otherwise execute in
   your shell (`${CLAUDE_PLUGIN_ROOT}/templates/status-line.md` states the
   `'\''`-escape rule once; use it here):
   ```
   runstate.sh route <run-state-from-handoff-header> <cursor> <token> --status '<line>'
   ```
5. **Act on `route`'s action** (judgment for `decider` lives in
   `agents/loop-driver.md` §Routing — this is the mechanical shape):
   - **`land`** — commit green, §3.6.
   - **`attempt`** — dispatch a fresh agent with the handoff and review paths;
     record no start.
   - **`decider`** — dispatch the `chief-engineer` (the interim
     `escalation-decider` stand-in) with the handoff and review paths, **plus
     the `ATTEMPTS=`/`LIMIT=` this same `route` call just printed** (so it
     knows whether a `retry` is even possible), and nothing else. Pass its
     returned token, with its status line as `--status` (single-quoted, same
     rule as above), back to `route`; record nothing yourself.
   - **`discard-advance`** — before discarding, check for a decider commit on
     this branch (`git log <base>..HEAD --grep '\[orch decider:'`); if one
     exists, **do not delete the branch** — it is left behind, unmerged, and
     §4's termination step accounts for it. Then discard the packet's
     uncommitted work non-destructively:
     ```
     git stash push --include-untracked -m "orch discard: <cursor>"
     ```
     (never `git reset --hard`/`git clean -fd` — the guard hard-denies both,
     and a stash is recoverable). `runstate.sh record-outcome <cursor>
     rolled-back`, advance the cursor. **`reorder`'s mechanism is not built**
     (that is `escalation-decider`'s job): treat it exactly like
     `append-task`/`hand-off-feature` here — discard-advance as above — and
     surface the decider's proposed new order as a question in the stop
     report for the operator to act on; do not reorder `pending` yourself.
   - **`stop`** — the hard-gate/genuine-ambiguity path. Take the question
     text verbatim from `route`'s own `question:` line when it printed one
     (the retry-past-limit case); otherwise use the status line of whichever
     agent triggered this (the decider's `ask-operator` line, or the
     reviewer's `escalate` line when no decider was dispatched). Hand that
     question, with severity `blocking` and `packet: <cursor>`, to
     `/gaffer:pause` — **do not write run-state yourself here**; pause's own
     step 3 persists it into `pending_questions` (carrying every existing
     entry through), verifies the checkpoint, sets `status: blocked`, renders
     the stop report, and runs `driver-mode exit` itself (§4 "Blocked" is the
     one-line pointer back to this).
6. **Land (the `land` action).** Flip the gspec checkbox first, so it lands in
   this same commit (ADR 0025 D1):
   `gspec-backlog.sh check-task <cursor>`, and act on its exit code before you
   commit:
   - **exit 0, `CHECKED=<feature>#T<n>` or `CHECKED=already`** — stage the
     touched plan file (`FILE=` names it) alongside the packet's own files, in
     the same commit.
   - **exit 0, `CHECKED=none`** — non-gspec backlog; commit as normal with
     nothing staged from `gspec/`.
   - **exit 4** — the plan no longer names this task id: genuine **drift**.
     Commit as normal, but say so in the report; never a reason to halt.
   - **exit 1** — malformed id: a real usage error. `runstate.sh
     record-outcome <cursor> failed`, then stop and report — do not commit
     over it — and run `runstate.sh driver-mode exit` immediately after that
     stop report.

   **Commit on the branch.** Trailers, each on its own line (ADR 0019
   self-label — a factual record, not a grade):
   - `[orch packet:<cursor>]` — the write-ahead trailer; lets a resume *adopt*
     the commit on a crash between it and the run-state write (ADR 0005).
   - `[orch tier:mechanical|integration|design-heavy|docs]` — the tier §3.3
     decided. If the work turned out to be a different tier, record what it
     *actually* was.
   - `[orch impl:delegated]` — always `delegated`: no packet is implemented
     inline in this loop.

   Then update run-state atomically (`runstate.sh write`): `last_green_commit`
   = the new SHA, `cursor` advances to the **next** packet (call the packet
   you just committed `<landed>` from here on), `status: running` stays, and
   carry the whole `findings:` index through verbatim (`write` REPLACES the
   file — an omitted entry is unlinked, not edited out).

   **Outcome vocabulary — five triggers, each excluding the others; when a
   stop fits more than one, `blocked` wins over `rolled-back` and `failed`,
   and `failed` wins over `rolled-back`:**
   - **green** — right here, on a land.
   - **blocked** — the `stop` action (§3.5) records it, once `/gaffer:pause`
     verifies the checkpoint.
   - **rolled-back** — the `discard-advance` action (§3.5).
   - **failed** — verification is still red after honest diagnosis and the
     loop moves past with no blocking question; the check-task exit-1 usage
     error just above is this trigger.
   - **abandoned** — the operator's answer to a blocking question drops the
     packet rather than retrying it (including on resume, when they say so).
   A retry within a packet is neither a start nor an ending, and records
   nothing.

   Then close it out, every time:
   - `runstate.sh record-outcome <landed> green`.
   - Overwrite `note:` with one line for the resuming session; never append.
   - **Drop stale findings naming `<landed>`**, from evidence, not say-so:
     ```bash
     IDS=$(runstate.sh findings .agents/run-state.yaml | cut -f4 | tr ',' '\n' | sort -u | paste -sd, -)
     # empty IDS -> no findings at all, skip the rest
     FINISHED=$(gspec-backlog.sh task-status "$IDS" | grep '^FINISHED=' | cut -d= -f2-)
     FINISHED="${FINISHED:+${FINISHED},}<landed>"
     runstate.sh findings .agents/run-state.yaml --stale --finished "$FINISHED"
     ```
     For each `STALE=yes` line naming `<landed>`: file a backlog task first if
     it is really "this should be built/fixed" and not already filed (the
     arm 1/arm 2 routing in §4); a spent sign-off needs no capture. Either way
     drop with `runstate.sh drop-finding .agents/run-state.yaml <id>`. That
     same `findings --stale --finished` call also prints `OVER_THRESHOLD=` —
     when it reads `yes`, name the count (`STALE_COUNT`) as `stale-findings:
     <N>` in the report below; its absence means under threshold, never
     checked-and-clean.
   - **Anything worth keeping past this packet is a finding, not note
     content** (ADR 0022): `runstate.sh add-finding .agents/run-state.yaml <id>
     "<one line>" --packets <id[,id...]>`, naming a still-pending packet — never
     `<landed>` itself, which the close you just ran already satisfies.
   - Report the landing — one line naming `<landed>` by plain-English title
     and outcome, per `${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`
     shape A.
7. **Integrate (only at `full-autonomy`).** After the packet lands green, you
   may merge the branch into the integration branch, rebase it to keep it
   current, and push feature/integration branches — never targeting `main`; a
   merge whose incoming diff hits a hard-gate path re-escalates. At
   `supervised`/`autonomous` you stop at the green commit.
8. **Advance.** With no blocker, pull the next packet and repeat.
   Poll the pause sentinel first — `runstate.sh pause-status .agents/pause`
   (or a `Bash`/`Edit` advisory surfacing it sooner) — at each packet boundary,
   and beat the driver heartbeat at the same point: `runstate.sh heartbeat
   .agents/run-state.yaml`. **On `PAUSE=1`:** finish the current packet to a
   green commit if it is already green and in policy, otherwise leave the
   last green commit untouched; then hand to `/gaffer:pause`, which persists
   `status: paused`, clears the sentinel, and stops. A pause records none of
   the outcomes above — the packet's start stays open for a later session.

## 4. Termination

- **Backlog complete** → before declaring done, dispatch **one broad
  whole-branch review** (the `reviewer`, opus) over the integrated diff (`git
  diff <base>...HEAD`, or the integration branch vs its base at
  `full-autonomy`). There is no handoff file for this one — hand it the diff
  directly, plus `.agents/run-state.yaml`'s path and a result path of your
  choosing under the run directory (any path works; this review is not
  packet-scoped). It writes its findings through `write-result` to that path
  and returns one status line as usual.

  **You do not open that review file — this would be the one exception to
  "never open a result file", so instead it stays zero: dispatch the
  `architect` with the review file's path, `.agents/run-state.yaml`'s path,
  and a result path of your own choosing under the run directory** to do the
  ADR 0026 routing itself, for any Critical/Important finding, in two arms
  tried in order, never editing a completed record and never bypassing the
  immutability control with a shell append:

  - **Arm 1** applies when some feature in the backlog is **incomplete**, has
    a plan file with at least one **unchecked** task line, and an **unchecked
    capability in its PRD covers the finding** — both tests hold separately.
    The architect appends a new unchecked task line to that feature's plan
    file as an `Edit` anchored on an unchecked line, carrying a truthful
    `covers:` naming that capability, and **commits that edit itself** (the
    same pattern the escalation-decider stand-in uses for its own
    `append-task`) — write bounds: append only, never modify an existing
    line, never touch a PRD checkbox. Choose the plan by **scope match**,
    never by proximity or convenience.
  - **Arm 2** is everything else, including a fully-checked parent plan: the
    finding becomes a **new feature**. The architect does not run
    `/gspec-feature` itself — it names the proposed slug/scope/parent in its
    result file and reports this in its status line. **You are the main
    context now** (whether a plain session or `claude --agent
    gaffer:loop-driver`, ADR 0028 — there is no separate dispatched
    coordinator here to lack a `Skill` tool), so once driver mode has exited
    below you may run `/gspec-feature` yourself; until then, record it as a
    question in the stop report for the operator.

  The architect returns one status line summarizing what it routed and
  where; relay that, not the review file's contents.

  **Before declaring done, also account for any branch left behind by a
  `discard-advance` carrying a decider commit** (§3.5): `git branch --list
  'orch/*'` and check each for a `[orch decider:` trailer beyond `<base>`.
  At `full-autonomy`, merge each such branch into the integration branch
  now, before finishing. Below `full-autonomy`, list each one (branch name,
  commit, one-line summary of what it did) in the stop report instead of
  merging it — the human decides whether to land it.

  Once every finding is routed and the whole-branch review is clean, set
  `status: done` (`runstate.sh set .agents/run-state.yaml status done`), then
  snapshot run-metrics (best-effort, non-critical): `metrics.sh collect ||
  true`. Emit the **stop report** (`report-templates.md` shape B): what
  shipped in plain words, anything left undone, any decision still open
  (including any arm-2 question and any un-merged decider-commit branch),
  the single recommended next action, and `branch <orch/task-id>` ready for
  review as the state line. **Then `runstate.sh driver-mode exit` —
  immediately after every stop report, no exceptions.**
- **Blocked** → the `stop` action (§3.5) already handed this off to
  `/gaffer:pause`, which verified the checkpoint, persisted the blocking
  question, set `status: blocked`, rendered the stop report, and ran
  `driver-mode exit` — there is nothing further to render here.

## Never, at any autonomy level

Commit/merge/**push to `main`/`master`** (or remote `main`), open a PR, run a
migration or schema change, install/upgrade dependencies, edit a
sensitive/hard-gate path, deploy, or rewrite history (`--amend`, interactive
rebase, force-push, `reset --hard`). **Merging to `main`, releasing, and
opening a PR are the human's hard gate at every level, including
`full-autonomy`** — the loop stops at "ready for the human to release" (a
green commit on the feature branch at `supervised`/`autonomous`; integrated
onto the non-`main` integration branch at `full-autonomy`). Every iteration is
a green commit on a branch, so a crash or shutdown mid-loop resumes cleanly
from the last checkpoint.

At **`full-autonomy` only**, the merge/rebase/push onto **non-`main`** branches
described in §3.7 are delegated — that is the *sole* addition; everything in
the paragraph above still stops for the human.
