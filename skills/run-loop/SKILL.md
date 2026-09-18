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
kickoff, **A** packet line, **B** stop report) now, once, before the kickoff.
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
- **Drifted capability checkboxes (gspec repos only).** Run
  `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh capability-drift`. Each
  `DRIFT=<slug>\t<capability text>` line names a feature whose finished plan has
  outrun its own PRD — every task covering that capability is checked but the
  capability's own box is not. **The loop reconciles this itself, rather
  than handing it to the operator.** For every distinct slug named on a
  `DRIFT=` line, call `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh
  complete-capabilities <slug>` through the adapter — never a main-thread
  edit, one call per slug even when it covers several `DRIFT=` rows. Stage a
  call's `FILE=` PRD path only when that call's own summary line reads
  `completed=<n>` with `n` greater than 0 — equivalently, it printed at
  least one `COMPLETED=` line. `FILE=` alone does not mean anything
  flipped: it is present whenever the feature resolved, including a
  `blocked` hold and a `completed=0` resolve, so staging on `FILE=` presence
  would stage a PRD nothing changed on. If at least one path was staged this
  way, land them as **one commit** on the integration branch, outside any
  packet, message `spec: reconcile capability record (preflight)`, carrying
  neither an `[orch packet:]` nor an `[orch decider:]` trailer — so run
  metrics count no packet for it — through the loop's own scripts and commit
  path. If no call flipped anything, make **no commit**: report no flips,
  and do not treat the absence of a commit as a failure. The checkout is
  normally already on the integration branch here (see the task-drift
  bullet above for why); **if it is not, do not commit** even when something
  flipped — state the flips in the kickoff exactly as below, noting they
  were not committed because the checkout was off the integration branch,
  then restore every PRD this scan touched with `git checkout HEAD -- <path>`
  — this resets the index as well as the working tree, since the path may
  already be staged, unlike `git checkout -- <path>` which restores from the
  index and is a no-op there — and leave the checkout as you found it.
  `complete-capabilities` exits 0
  whether a call flips something, flips nothing (`blocked` — an unrelated
  unmatched `covers:` quote elsewhere in the same feature holds every flip
  for it), or is skipped outright (no `gspec/` at all); exit 1 (malformed
  slug) and exit 4 (no resolvable PRD+plan pair) are the real failures.
  Either failure, or a failed commit, is reported the same way below,
  restores every PRD this scan touched the same way — `git checkout HEAD --
  <path>` — and never halts preflight.

  **Say so in the kickoff (§2): one ⚠️ line per capability actually
  flipped** — from each call's own `COMPLETED=<slug>\t<capability text>`
  lines, not the earlier `DRIFT=` listing (a `blocked` call flips nothing),
  **naming the feature and the capability** — the same per-row form this
  bullet used to report drift in. **Name every feature a call held back
  too: one ⚠️ line per slug whose own summary line reads
  `COMPLETE_CAPABILITIES=blocked`**, in that same per-row form, naming the
  feature and carrying that call's own `REASON=` text (an unchecked task's
  `covers:` quote matches no capability, so every flip for that feature is
  held until it is fixed) — one line per such slug, however many `DRIFT=`
  rows it covered. **Nothing is flipped, restored or committed for a held
  feature**: `blocked` is exit 0 with `completed=0`, so it stages no PRD,
  joins no commit, and leaves nothing to restore. It is **neither a failure
  nor a flip** — a feature this run cannot complete yet, named so the
  operator can fix the quote rather than left silent.
  State the trailing `unjudgeable=<n>` count
  separately, as a figure — never one `UNJUDGEABLE=` line per finding —
  naming only the classes that actually appear among the command's own
  `UNJUDGEABLE=<class>\t<slug>\t<detail>` lines (possible classes:
  `unmatched-quote`, `uncovered-capability`, `unrecognized-capability`; e.g.
  "34 unjudgeable — all unmatched-quote"), never folded into the flip count
  and never flipped, whatever `complete-capabilities` returns for the rest
  of the scan. Say nothing when the scan is fully clean (`CAPABILITY_DRIFT=ok
  drift=0 unjudgeable=0`); state the figure whenever `unjudgeable` is
  nonzero, even if `drift` is `0`. Never treat any exit — including
  `CAPABILITY_DRIFT=attention` — as a stop: the loop reconciles judgeable
  drift itself and reports unjudgeable rows to the operator. The rule holds
  wherever a run entry point states a preflight drift scan, not only at this
  one. A repo with no `gspec/` directory reads `CAPABILITY_DRIFT=none` — a
  silent no-op, same as the check above.
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
runstate.sh compact-threshold   # THRESHOLD=<n|unknown> SOURCE=repo|operator|unknown APPLIED=no
runstate.sh driver-mode enter --model <this session's model, from SessionStart> \
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
operator to change either** — state what applies, as read, and move on.

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
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`. Render its `▶
**Session**` line from `runstate.sh run-digest .agents/run-state.yaml`'s own
`enter` line (model/effort/threshold, exactly as `driver-mode enter` just
recorded it — never restated from memory): a fresh run's digest has no
`packet` lines yet, so the forward plan is the backlog you just resolved
above, a file read moments old. State the one assumption most likely to be
wrong, which packets you expect will need a decision, the hard gates this
backlog gets near, the autonomy level, and where the run stops. Emit it
**here**, after preflight and after the backlog resolves. At
**`interactive`**, the kickoff is also the approval request: emit it and
wait.

## 3. Loop — for the packet at `backlog.cursor`

1. **Branch.** Create (or switch to) the packet's feature branch:
   `git switch -c orch/<task-id> <base>` (integration branch from
   `.agents/project-overrides.yaml` → `integration_branch`, else `develop`,
   else `main`/`master`); `git switch orch/<task-id>` if it already exists. No
   worktree, no separate directory.
2. **Form this packet's members, then sweep for packets left open before
   recording it.** Bundling (`packet-bundling`) turns a run of consecutive,
   same-scope, same-feature tasks into ONE packet, so the sweep below has to
   know every member of a paused bundle, not just the cursor, before it
   decides what stays exempt — that means forming the membership comes
   first.

   Read the cap — `runstate.sh bundle-cap` prints `CAP=<n>` (default `1`, so
   this whole mechanism is inert until a repo raises `bundle_max_tasks`) —
   then form the candidate group at the cursor: `gspec-backlog.sh group
   <cursor> --cap <n>`. **A non-zero exit** (`group`'s own `die` paths — a
   refused id, ADR 0025 D1, or a malformed argument — write to stderr only,
   with no `HANDOFF=`/`GROUP=` line at all) means the command produced no
   group to read: treat it exactly like a leading `HANDOFF=unknown` below —
   `MEMBERS=<cursor>` alone, `tier`/`--agent` judged for it exactly as you
   would today — but say so in whatever report later covers this packet (a
   plain sentence, no new glyph: bundling was skipped this packet because
   `group` exited non-zero), since a silent fallback would read as "nothing
   to bundle" rather than "the check itself failed." Never halt the loop for
   this and never guess membership from a partial or malformed output — the
   fallback is always exactly the cursor alone, nothing wider. A leading
   `HANDOFF=unknown` (no gspec, a non-gspec packet, or a cursor already
   checked) means this packet does not bundle at all: set `MEMBERS=<cursor>`,
   decide the packet's `tier`/`--agent` exactly as you would today (nothing
   about that judgment depended on `group`'s output to begin with — a
   non-gspec packet never had it), and skip straight to the sweep below.
   Otherwise `group` prints `GROUP=<cursor>`,
   one `MEMBER=<node-id>\t<title>` line per candidate in plan order (the
   cursor always first), `FILES=` (their scope union) and
   `STOP=<cap|scope|deps|end>` — `group` has already done the mechanical
   half (scope overlap, deps, the cap, staying within one feature); tier is
   not in the plan, so it stays yours, next.

   Walk the `MEMBER=` lines in that printed order and judge each one's tier
   from its title exactly as you judge a single packet's today. The first
   one is the cursor itself: judging it design-heavy ends the group right
   there — `MEMBERS=<cursor>` alone, since a task in the design-heavy tier
   never joins a group and never starts one. Otherwise keep walking the rest
   and stop **before** the first member you would judge design-heavy,
   dropping it and everything after it — it still gets its own packet later,
   just not this one. `MEMBERS` is the comma-joined ids that survive, cursor
   first, in plan order (a cap of 1 never has a second candidate to judge, so
   `MEMBERS` is always `<cursor>` there — this step then reads byte-for-byte
   as it does today). Decide the packet's own `tier` for the whole of
   `MEMBERS` the same way you decide a single task's today, and the
   `--agent` from it — `implementer` for `mechanical`/`integration`,
   `architect` or `ux-designer` for `design-heavy` (whichever the file hints
   scope to), `doc-writer` for `docs` — a multi-member `MEMBERS` is never
   `design-heavy` by construction, so this can only land on `mechanical`,
   `integration`, or `docs`. §3.3 below picks up from here.

   `$MEMBERS` is driver-held shell state for the rest of this packet, the
   same convention `$SINCE`/`$SWEEP` already use — it does not survive a
   mid-packet compaction, or a session picking this same packet back up,
   on its own. Recover it the **same rule** `${CLAUDE_PLUGIN_ROOT}/skills/
   resume/SKILL.md` gives its own membership recovery (T9) — one rule,
   stated once, never restated differently here: once §3.3 has written the
   handoff, membership is recoverable from that packet's own `handoff.md`
   `BUNDLE=` line (absent means `MEMBERS=<cursor>` alone), then re-check
   only the mechanical refusals against it — `gspec-backlog.sh task-status
   "$MEMBERS"`, dropping any member whose line reads `finished` or `gone`
   (never the cursor itself, regardless of what its own line reads) — never
   re-deriving the scope/deps/cap judgment `group` applies when forming a
   bundle fresh, since that could shrink or grow a membership a start record
   already covers. Before the handoff is written, there is nothing to
   recover and the packet is re-formed from `group` again, exactly as
   above.

   Now sweep, using `MEMBERS` wherever this used to read `<cursor>` alone.
   `runstate.sh sweep-open --list` prints one `OPEN=<id>` line per open
   packet. If it printed any, comma-join the ids and resolve them —
   `gspec-backlog.sh task-status "<id,id,...>"` (one `<id>\t<state>\t<reason>`
   line per id, plus `FINISHED=<csv>`); the `gone` set is every id whose state
   reads `gone`. Comma-join those into `GONE="<id,id,...>"` and pass it to
   `--gone`, then sweep for real — passing `--paused-cursor "$MEMBERS"`
   exactly when this session is about to continue it (§3.3 below is about to
   call `record-start "$MEMBERS" --continue` rather than beginning it
   fresh); the cursor's whole bundle is what this session is about to
   continue, not what the sweep should close — capturing the sweep's own
   output: `SWEEP="$(runstate.sh sweep-open --gone "$GONE")"` (add
   `--paused-cursor "$MEMBERS"` per that rule when it applies; omit `--gone`
   and skip `task-status` entirely when `--list` printed nothing — no open
   packets means nothing for the real sweep to close either — and leave
   `SWEEP` empty). `$SWEEP` holds one `SWEPT=<id>`/`OUTCOME=<interrupted|
   abandoned>` line pair per packet the sweep actually closed — every open
   packet, not only the gone ones; a gone packet's pair reads `abandoned`,
   every other open packet's reads `interrupted` — **carry `$SWEEP` through
   to §3.5/§3.6's report below**,
   since `run-digest`'s `packet` lines are never filtered by `--since` and
   this sweep is the only point that knows which of them are newly closed;
   without it a swept packet's line is never picked out of the digest until
   the eventual stop report.
3. **Write the handoff, then start.** `MEMBERS` and the packet's `tier`/
   `--agent` were already decided in §3.2 above.

   **Check for `HANDOFF=unknown` or a non-cursor `HANDOFF=refused` before
   piping anything.** Run `gspec-backlog.sh handoff "$MEMBERS"` first and
   read its output — a comma-joined `$MEMBERS` takes the bundling path (T5),
   a bare `<cursor>` the original single-id path, byte-identical to today. A
   leading `HANDOFF=unknown` line means some id in `$MEMBERS` does not
   resolve in gspec (a deleted/renamed task, or a genuinely non-gspec
   packet) — this can only be `<cursor>` alone when `$MEMBERS` has one
   member, since `group` already confirmed every other candidate resolves.
   When you have run-state's own task text for this packet (a non-gspec-
   sourced backlog entry — never a bundle; grouping needs gspec's own plan
   to work from), pipe that instead of the adapter's output. Otherwise
   **skip the packet with no record** — advance the cursor and report the
   skip, the same as a refused handoff below.

   A leading `HANDOFF=refused` line (`REASON=hand-off-feature`) means some
   id in `$MEMBERS` was already routed `hand-off-feature` this run — its own
   `PACKET=` line names which one, and this check catches it for **any**
   member, not only the cursor (the single-id refusal `runstate.sh handoff`
   itself can still raise, below, only ever sees `<cursor>`). When
   `PACKET=` is `<cursor>` itself, **skip the packet with no record** —
   advance the cursor and report the skip, exactly as today. When `PACKET=`
   names a later member instead, **truncate `$MEMBERS` to the members before
   it** — the same shape as the design-heavy truncation in §3.2, dropping
   the refused member and everything the group would have carried after it
   — then re-run `gspec-backlog.sh handoff` on the truncated `$MEMBERS` and
   proceed with that narrower bundle; the refused member is left at its
   place in `pending` and gets its own packet, refused again in turn, on a
   later iteration of this loop. Never pipe a `HANDOFF=refused` body through
   to `runstate.sh handoff` as if it were real task text.

   Append the applicable REQUIRED line(s) from §2's read of
   `task-packet.yaml` — a real instruction, not a formality: a sweep
   criterion when this packet's file scope touches enforcement/automation
   code, a `session_boundary` line when it touches a session-start-loaded
   surface, both if it touches both, neither otherwise. **Judge both against
   the union of every member's scope** — `$MEMBERS`'s own `BUNDLE_FILES=`
   line when it bundles (T5; absent, and irrelevant, for a single-member
   packet, whose own `FILES=` line is the whole scope exactly as today) —
   never only the cursor's own scope. Then write the handoff:
   ```
   { gspec-backlog.sh handoff "$MEMBERS"
     printf '%s\n' "REQUIRED: the regression sweep covering <area> passes, with a new case for this change"   # only if applicable
     printf '%s\n' "REQUIRED session_boundary: <what could not be verified in this run; what the next session must check>"  # only if applicable
   } | runstate.sh handoff .agents/run-state.yaml <cursor> --tier <tier> --agent <agent>
   ```
   (or pipe run-state's task text in place of the first line, for a
   non-gspec packet, per the `HANDOFF=unknown` check above — always a single
   id in that case). `runstate.sh handoff` still takes exactly one packet
   id — `<cursor>`, the bundle's own id — never `$MEMBERS`: that single id is
   what names the run directory, the header's `result`/`review` paths, and
   everything §3.4 onward dispatches and routes against, so none of that
   changes shape. Its title (the `# <pkt>: <title>` line, and later
   `run-digest`'s own `<title>` field) is `$MEMBERS`' first `TEXT=` line —
   the cursor's own — never a summary of the whole bundle; §3.6 and §4 below
   are where every member's title actually gets said. **A refused handoff
   (`HANDOFF=refused`, e.g. a member already routed `hand-off-feature` this
   run) skips the packet — advance the cursor and report the skip; do not
   call `record-start`.** Only once `HANDOFF=<path>` prints do you attest
   the start — capture `SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` first, so
   §3.5/§3.6's shape-A report can later scope `run-digest --since "$SINCE"`
   to only the decisions made during THIS packet's own attempts, never one
   already reported for an earlier packet — then `runstate.sh record-start
   "$MEMBERS"` for a fresh beginning, or `runstate.sh record-start
   "$MEMBERS" --continue` when this session is about to continue the
   cursor's bundle rather than beginning it anew — one start (or
   continuation) record per member, sharing a single timestamp and session,
   written in one call (T3); a lone `<cursor>` in `$MEMBERS` prints the same
   single `RECORDED=yes`/`PACKET=`/`KIND=` block as today.

   **Read back the handoff's header** (`grep '^run-state:\|^result:\|^review:'
   <path>`) — it names the exact `run-state`, `result`, and `review` paths,
   absolute, that this packet's dispatches and your own `route` calls use for
   the rest of this packet. Pass the handoff path to the dispatched agent —
   its body carries every member's own text, file scope and acceptance
   criteria in plan order, concatenated (T5), so one dispatch is briefed on
   the whole bundle. Its header is what tells that agent, and you, where to
   write and route.
4. **Dispatch, then route.** Dispatch a **fresh** agent (the `--agent` from
   §3.3) with the handoff path **only** — its body already covers the whole
   bundle (§3.3), so one dispatch, one review and one `route` call cover
   every member of `$MEMBERS`, exactly as they would a single task — on a
   re-attempt, also pass the review file's path (from the handoff header,
   per §3.3). Read its one
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
   - **`attempt`** — dispatch a fresh agent with the handoff and review
     paths; record no start. The handoff still covers every member of
     `$MEMBERS`, so one `attempt` re-does the whole bundle, not just the
     cursor.
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
     and a stash is recoverable — one stash covers the whole bundle's
     uncommitted work, since nothing was ever committed member-by-member).
     `runstate.sh record-outcome "$MEMBERS" rolled-back` — one call, every
     member — then advance the cursor **past every member of `$MEMBERS`**.
     `group` forms `$MEMBERS` from the plan in plan order, but `pending` is
     the loop's own chosen order — a resume, an explicit reorder, or an
     arm-1 `append-task` mid-run can each put a member somewhere other than
     a consecutive prefix of `pending`, or leave one out of `pending`
     altogether — so never assume the prefix shape: **remove every member of
     `$MEMBERS` from `pending` wherever it sits** (a member absent from
     `pending` is simply not there to remove), then set `cursor` to whatever
     entry remains first in `pending` (or none, if nothing does), via
     `runstate.sh write`, so no part of the bundle lands on its own. Then report it the same way §3.6 does — shape A
     rendered from `runstate.sh run-digest .agents/run-state.yaml --since
     "$SINCE"`: the bundle's own `packet` line, its title rendered from
     every member of `$MEMBERS` (the `MEMBER=<id>\t<title>` lines `group`
     printed in §3.2, still in this session's own context — `run-digest`'s
     `<title>` field alone is only the cursor's), one ⚠️ line per
     `SWEPT=`/`OUTCOME=` pair in `$SWEEP` (§3.2, above) reading *swept as
     interrupted* or *swept as abandoned* per that pair's own `OUTCOME`,
     plus one 🔀 per `decision` line other than `retry`.
     **`reorder`'s mechanism is not built**
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
6. **Land (the `land` action).** Flip every member's checkbox first, in plan
   order, so all of them land in this same commit (ADR 0025 D1) — one
   `check-task` call per member (`check-task` stays at exactly one id; T5's
   comma-joined widening is `handoff`'s, a read, and does not touch this
   write), applying the exit-code rules below to each member in turn,
   before you commit anything:
   - **exit 0, `CHECKED=<feature>#T<n>` or `CHECKED=already`** — stage the
     touched plan file (`FILE=` names it) alongside the packet's own files,
     in the same commit. Every member of one bundle names the same feature's
     plan file, so this stages it once however many members touch it.
   - **exit 0, `CHECKED=none`** — non-gspec backlog; commit as normal with
     nothing staged from `gspec/` (a bundle is always gspec-sourced, so this
     is the single-member, non-gspec case, unchanged).
   - **exit 4** — the plan no longer names this member's task id: genuine
     **drift**. Keep going to the next member — commit as normal, but say so
     in the report, naming the member; never a reason to halt, and never a
     reason to skip the rest of the loop. This member still lands with the
     rest of the bundle: it still gets its own `[orch packet:<id>]` trailer
     below and its own `green` record in the single `record-outcome` call —
     drift means its checkbox could not be flipped, not that its work did
     not land.
   - **exit 1** — malformed id: a real usage error. Stop the loop over
     `MEMBERS` right there and treat the whole bundle as ending together —
     `runstate.sh record-outcome "$MEMBERS" failed` — then stop and report;
     do not commit, even a member whose own `check-task` call already
     succeeded earlier in this same loop stays as an uncommitted edit on the
     branch, so no part of the bundle lands on its own — and run `runstate.sh
     driver-mode exit` immediately after that stop report.

   **Complete the feature's capabilities.** Once every member above has
   been flipped or drifted (an exit-1 above already ended the bundle before
   this point is ever reached), run `gspec-backlog.sh complete-capabilities
   <slug>` exactly once for the landed feature — a bundle is always one
   feature. Take the slug from any member's own `CHECKED=<feature>#T<n>`
   line above when one was printed; they all name the same one.
   `CHECKED=already` (the idempotent path) prints no feature slug, and
   neither does the `CHECKED=none` drift case, so when no member printed a
   `<feature>#T<n>` line, fall back to the handoff's own `FEATURE=` line
   (§3.3, still in this session's context — one feature per bundle); that
   still counts as gspec-sourced. Skip the call entirely only when every
   member returned `CHECKED=none` **at exit 0** — nothing gspec-sourced
   resolved for any member, so there is no capability to complete.
   `CHECKED=none` on its own does not mean that: an **exit-4** drift member
   prints the same line (the plan no longer names its task id), and that
   member *is* gspec-sourced — it takes the `FEATURE=` fallback just above,
   so the call still runs. One member at exit 4 is enough; the skip needs
   every member at exit 0.
   - **exit 0** — stage the `FILE=` PRD into this same commit, alongside
     the plan file(s) staged above, **only when that call's own summary
     line reads `completed=<n>` with `n` greater than 0** — equivalently,
     it printed at least one `COMPLETED=` line. This is the same test §1
     and §4 already apply. `FILE=` alone does not mean anything flipped:
     it is printed whenever the feature resolved, including a `blocked`
     hold and a `completed=0` resolve, so staging on `FILE=` presence
     would stage a PRD nothing changed on. A held feature
     (`COMPLETE_CAPABILITIES=blocked`) therefore stages nothing here and
     the bundle commits as normal — neither a failure nor a flip.
   - **exit 4, exit 1, or anything else** — report it on this packet's own
     landing report below (shape A), naming the feature and the failure,
     but never for this reason: halt the loop, withhold the commit, or
     record an outcome other than `green` for `$MEMBERS`. This is **not**
     `check-task`'s exit-1 rule just above — that one is unchanged and
     still ends the bundle without landing it; a capability flip is derived
     bookkeeping on top of tasks that already landed, never a condition of
     landing them, and the task record itself is unaffected either way.
     Since no `FILE=` line is ever printed on a failure here, restore the
     PRD with `git checkout -- <path>` — the same path the handoff's own
     `PRD=` line already named for this bundle — so a partial or unexpected
     write from this call never rides into the commit unstaged. **Restore
     from the index, not from `HEAD`**, and that is the whole reason for
     the form: by the time this call runs, the index already holds the
     packet's own files and the plan file(s) staged a step above, and the
     PRD is itself a file a packet may have edited as one of its own — it
     is what `PRD=` names. `git checkout -- <path>` restores the working
     tree from the index, so it undoes only what is *unstaged* on that
     path, which is exactly this failed call's write (nothing staged it —
     no `FILE=` was printed). `git checkout HEAD -- <path>` would reset the
     index entry too and discard the packet's own staged PRD edit along
     with it. §1 and §4 use the `HEAD` form for the mirror of this reason:
     their scan runs outside any packet and stages the PRD itself, so there
     the index entry is precisely the thing that has to go.
   A single-task packet that completes no capability (`completed=0`, or the
   call skipped outright) reads exactly as it does today: nothing staged,
   nothing to report — and now because the `completed=<n>` test above holds
   the staging back, rather than because `git add` on an unchanged path
   happens to be a no-op; `FILE=` is still printed on a `completed=0`
   resolve either way.

   **Commit on the branch.** Trailers, each on its own line (ADR 0019
   self-label — a factual record, not a grade):
   - `[orch packet:<id>]` — one per member that landed, each on its own
     line, each naming that member's own id, in the same plan order as the
     `check-task` calls above, `<cursor>` always first. The first line is
     still the write-ahead trailer a resume *adopts* on a crash between this
     commit and the run-state write (ADR 0005) — `orphan_packet_tag` reads
     only the FIRST `[orch packet:]` trailer on a commit, so `<cursor>`
     leading the block is load-bearing, not cosmetic. A single-member packet
     prints exactly one such line, byte-identical to today.
   - `[orch tier:mechanical|integration|design-heavy|docs]` — the tier §3.2
     decided, for the bundle as a whole. If the work turned out to be a
     different tier, record what it *actually* was.
   - `[orch impl:delegated]` — always `delegated`: no packet is implemented
     inline in this loop.

   Then update run-state atomically (`runstate.sh write`): `last_green_commit`
   = the new SHA, `cursor` advances **past every member of `$MEMBERS`** —
   the same rule §3.5's `discard-advance` uses, and for the same reason:
   `group` forms `$MEMBERS` from the plan in plan order, but `pending` is
   the loop's own chosen order, so never assume the members are a
   consecutive prefix of it. **Remove every member of `$MEMBERS` from
   `pending` wherever it sits** (a member absent from `pending` is simply
   not there to remove), then set `cursor` to whatever entry remains first
   in `pending` (or none, if nothing does) — call the packet you just
   committed `<landed>` from here on, meaning `$MEMBERS` as a whole —
   `status: running` stays, and carry the
   whole `findings:` index through verbatim (`write` REPLACES the file — an
   omitted entry is unlinked, not edited out).

   **Outcome vocabulary — five triggers, each excluding the others; when a
   stop fits more than one, `blocked` wins over `rolled-back` and `failed`,
   and `failed` wins over `rolled-back`. Every trigger below applies to the
   packet as a whole, so a bundle's members share one outcome, recorded for
   every one of them in the single call the trigger names:**
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
   - `runstate.sh record-outcome "$MEMBERS" green` — one call, every member.
   - Overwrite `note:` with one line for the resuming session; never append.
   - **Drop stale findings naming any member of `<landed>`**, from evidence,
     not say-so:
     ```bash
     IDS=$(runstate.sh findings .agents/run-state.yaml | cut -f4 | tr ',' '\n' | sort -u | paste -sd, -)
     # empty IDS -> no findings at all, skip the rest
     FINISHED=$(gspec-backlog.sh task-status "$IDS" | grep '^FINISHED=' | cut -d= -f2-)
     FINISHED="${FINISHED:+${FINISHED},}$MEMBERS"
     runstate.sh findings .agents/run-state.yaml --stale --finished "$FINISHED"
     ```
     (`$MEMBERS` in place of a bare `<landed>` — `task-status`/`findings
     --finished` already accept a comma list, so a finding naming any member
     the bundle just landed, not only the cursor, is caught here too; a
     single-member packet is unaffected, `$MEMBERS` being `<cursor>` alone.)
     For each `STALE=yes` line naming a member of `<landed>`: file a backlog
     task first if it is really "this should be built/fixed" and not already
     filed (the arm 1/arm 2 routing in §4); a spent sign-off needs no
     capture. Either way drop with `runstate.sh drop-finding
     .agents/run-state.yaml <id>`. That same `findings --stale --finished`
     call also prints `OVER_THRESHOLD=` — when it reads `yes`, name the count
     (`STALE_COUNT`) as `stale-findings: <N>` in the report below; its
     absence means under threshold, never checked-and-clean.
   - **Anything worth keeping past this packet is a finding, not note
     content** (ADR 0022): `runstate.sh add-finding .agents/run-state.yaml <id>
     "<one line>" --packets <id[,id...]>`, naming a still-pending packet — never
     any member of `<landed>` itself, which the close you just ran already
     satisfies.
   - Report the landing — shape A in
     `${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, rendered from
     `runstate.sh run-digest .agents/run-state.yaml --since "$SINCE"` (the
     timestamp captured at §3.3): take `<landed>`'s own `packet` line
     (outcome — ✅, or 🔁 instead when a `decision` line for this same id
     reads `retry`), but render its title from **every** member of
     `$MEMBERS`, not `run-digest`'s own `<title>` field — that field is only
     the cursor's `TEXT=` line (§3.3). `$MEMBERS` and the
     `MEMBER=<id>\t<title>` lines `group` printed in §3.2 are still in this
     session's own context, so read titles from there directly; §4 below
     covers naming a landed bundle from a session that no longer has them.
     One ⚠️ line per `SWEPT=`/`OUTCOME=` pair in `$SWEEP` (§3.2,
     above) reading *swept as interrupted* or *swept as abandoned* per that
     pair's own `OUTCOME` — `run-digest`'s `packet` lines are never filtered
     by `--since`, so this sweep's own record of what it just closed is the
     only thing marking these as new, not already carried by an earlier
     report — plus one 🔀 line per `decision` line `<landed>` carries other
     than `retry` (already the 🔁 above, never reported twice), plus one
     ⚠️ line naming the feature whenever the capability-completion call
     above failed (exit 4, exit 1, or anything else) — the packet still
     landed, so this is an alert alongside the ✅/🔁 line, never a reason to
     withhold it. Never write this from the dispatched agent's or
     reviewer's own words — the digest's fields are what render, not your
     memory of their status lines.
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

   **Otherwise, check the periodic pause at the same boundary:** `runstate.sh
   periodic-pause` prints `ENDED=<n>`, `EVERY=<n|off>`, `DUE=yes|no`. `EVERY=off`
   (missing/invalid/0 in `.agents/project-overrides.yaml`, and the default) means
   `DUE` is always `no` — a periodic pause must never fire on its own, since it
   halts an unattended run until a human resumes it. On `DUE=yes`, capture the
   setting itself before you interpolate it — `EVERY=$(runstate.sh
   periodic-pause | grep '^EVERY=' | cut -d= -f2-)` — then request one yourself,
   naming the setting in the reason so the stop report can state it plainly:
   `runstate.sh request-pause .agents/pause "pause_every_packets: $EVERY
   packets ended"`, then hand to `/gaffer:pause` exactly as the `PAUSE=1` case
   above.

## 4. Termination

- **Backlog complete** → before declaring done, dispatch **one broad
  whole-branch review** (the `reviewer`, opus) over **this run's own
  integrated work — not everything the branch has accumulated since its
  base.** A long-lived integration branch already carries earlier runs'
  already-reviewed commits, so a plain branch-vs-base diff re-presents all
  of them: measured on the run that found this defect, branch-vs-base was
  211 files and about 30,000 insertions, against only the files that run
  actually landed. Bound the diff to the packet ids `runstate.sh run-digest
  .agents/run-state.yaml` already prints (no `--since` — every packet this
  run began, landed or not) and the `[orch packet:<id>]` trailers those ids
  carry: walk the branch's commits oldest-to-newest (`git log <base>..HEAD
  --reverse`) to the first one whose trailer names an id from that list,
  and diff from **that commit's own parent** to `HEAD` — `git diff
  <parent>..HEAD`, or that same parent against the integration branch's
  `HEAD` at `full-autonomy`. **Fall back to the old branch-vs-base diff —
  `git diff <base>...HEAD`, or the integration branch vs its base at
  `full-autonomy` — only when the trailer walk finds nothing to anchor
  on: no commit on `<base>..HEAD` carries a trailer naming any id from
  that digest list.** This includes, but is not limited to, a digest that
  names no packet at all — it also covers a run whose packets all ended
  failed, rolled-back, blocked or interrupted, which has a non-empty
  digest and still no such commit. Either way, there is no run-owned
  trailer to anchor a parent on, so the base comparison is the only diff
  available — it may re-present already-reviewed work from earlier runs,
  but a run that landed nothing traceable has no narrower boundary to
  offer instead.
  There is no handoff file for this one — hand it the diff directly, plus
  `.agents/run-state.yaml`'s path and a result path of your choosing under
  the run directory (any path works; this review is not packet-scoped). It
  writes its findings through `write-result` to that path and returns one
  status line as usual.

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
    result file and reports this in its status line. **Neither do you, ever**
    (ADR 0026 revision 2026-09-17): arm 2 **always terminates at a question in
    the stop report** for the operator to act on. Being the main context —
    whether a plain session or `claude --agent gaffer:loop-driver`, ADR 0028 —
    means you *could* run `/gspec-feature`, and that is exactly what is
    refused, whether or not driver mode has exited below. A completed feature
    does not file its successor; the operator decides whether the proposal
    becomes a feature. Record the slug, its scope in a sentence, and its parent
    as a question in the stop report, and stop there.

  The architect returns one status line summarizing what it routed and
  where; relay that, not the review file's contents.

  **Before declaring done, also account for any branch left behind by a
  `discard-advance` carrying a decider commit** (§3.5): `git branch --list
  'orch/*'` and check each for a `[orch decider:` trailer beyond `<base>`.
  At `full-autonomy`, merge each such branch into the integration branch
  now, before finishing. Below `full-autonomy`, list each one (branch name,
  commit, one-line summary of what it did) in the stop report instead of
  merging it — the human decides whether to land it.

  **Also before declaring done, re-run the same capability-drift scan §1
  states** — the same `gspec-backlog.sh capability-drift` invocation, not a
  second reading of its rule — so a capability whose last covering task
  landed during this run is named by this run rather than by the next one's
  preflight. **Reconcile it the same way §1 does**: for every distinct slug
  named on a `DRIFT=` line, call `complete-capabilities <slug>` through the
  adapter — never a main-thread edit, one call per slug even when it covers
  several `DRIFT=` rows. Stage a call's `FILE=` PRD path only when that
  call's own summary line reads `completed=<n>` with `n` greater than 0 —
  equivalently, it printed at least one `COMPLETED=` line; `FILE=` alone
  does not mean anything flipped, the same distinction §1 makes. If at
  least one path was staged this way, land them into **one commit**,
  outside any packet, message `spec: reconcile capability record
  (end-of-run)`, carrying neither an `[orch packet:]` nor an `[orch
  decider:]` trailer. If no call flipped anything, make **no commit** and
  report no flips — not a failure. At `full-autonomy`, if §3.7 actually
  merged this run's packets into the integration branch, that commit goes
  there too, since checking a branch out to merge into it leaves the
  checkout on that branch; if nothing merged — no green `orch/*` branch this
  run, or `full-autonomy` did not apply — the commit goes on the run's own
  branch instead, the same as below `full-autonomy`, where nothing has
  merged — either way, a flip never reaches the integration branch ahead of
  the work it records.
  `complete-capabilities`'s exit codes are read exactly as at preflight:
  exit 0 whether a call flips something, flips nothing (`blocked`), or is
  skipped outright; exit 1 or exit 4 is a real failure. Either failure, or a
  failed commit, is reported below, restores every PRD this scan touched
  (`git checkout HEAD -- <path>` per staged `FILE=` — this resets the index
  as well as the working tree, since the path may already be staged), and
  never withholds `status: done` or otherwise halts.

  Carry each capability this scan actually flipped — from each call's own
  `COMPLETED=<slug>\t<capability text>` lines, not the earlier `DRIFT=`
  listing — into the stop report's `▶ Next` section below — the one section
  the tally does not count — as an unglyphed line naming the feature and the
  capability. This does not reuse ⚠️ (the conventions reserve that glyph for
  a tally-counted section carrying one line per packet, and a capability
  flip is not a packet) and introduces no new glyph, shape, or tally figure.
  **Carry every feature a call held back into that same section too** — one
  unglyphed line per slug whose own summary line reads
  `COMPLETE_CAPABILITIES=blocked`, naming the feature and carrying that
  call's own `REASON=` text (an unchecked task's `covers:` quote matches no
  capability, so every flip for that feature is held until it is fixed) —
  one line per such slug, however many `DRIFT=` rows it covered, in the same
  unglyphed form the flips use here. **Nothing is flipped, restored or
  committed for a held feature**: `blocked` is exit 0 with `completed=0`, so
  it stages no PRD, joins no commit, and leaves nothing to restore. It is
  **neither a failure nor a flip** — a feature this run could not complete
  yet, named so the next run's preflight does not have to be the first to
  say so.
  State the trailing `unjudgeable=<n>` count the same way §1 does, in the
  same section, naming only the classes that actually appear — these rows
  are never flipped, whatever `complete-capabilities` returns for the rest
  of the scan. `CAPABILITY_DRIFT=none` stays a silent no-op, same as at
  preflight. A flip changes no tally figure, no packet count, and never the
  outcome recorded for `status` — the run's stop reason is unaffected either
  way.

  Once every finding is routed and the whole-branch review is clean, set
  `status: done` (`runstate.sh set .agents/run-state.yaml status done`), then
  snapshot run-metrics (best-effort, non-critical): `metrics.sh collect ||
  true`. Emit the **stop report** (`report-templates.md` shape B), assembled
  from `runstate.sh run-digest .agents/run-state.yaml` with **no** `--since`
  — its `packet` lines name every packet the run began, with its outcome,
  whether or not this session was the one that ran it (a compaction or a
  resumed session reads the same report): what shipped in plain words,
  anything left undone, any decision still open (its `handoff-feature`
  lines, including any arm-2 question, plus any un-merged decider-commit
  branch), the single recommended next action, and `branch <orch/task-id>`
  ready for review as the state line.

  **Naming a landed bundle in that report.** `run-digest` still emits
  exactly one `packet` line per packet the run began — a bundle's several
  members share the one directory keyed to its own id, `<cursor>` — so it
  still counts as ONE packet, matching `run-digest`'s own line count and
  this shape's tally: a bundle earns exactly one ✅ line, never one per
  member. But `<title>` on that line is only the cursor's own `TEXT=` line
  (§3.3), so rendering it as-is would read a four-task bundle as one task,
  and the header tally would read `✅ 1` for four landed tasks. That one
  line must still name every member.

  First check cheaply, per `packet` line whose outcome reads `green`,
  whether it bundled at all: read its own `handoff.md`
  (`<run-dir>/<id>/handoff.md`) — this is a body line runstate.sh writes
  below its own header, not part of the header block itself — and look for
  a `BUNDLE=` line (T5). Its absence means a single-member packet — render
  it exactly as `run-digest` gives it, no different than today, and nothing
  further below applies to it. Only a `BUNDLE=<id,id,...>` line means the
  rest of this is needed.

  This session may not be the one that landed it (a compaction, or a
  resumed session inheriting someone else's run), so confirm membership
  from the branch itself rather than trusting the `BUNDLE=` line alone —
  that line was written back at §3.3, before the packet even started, and
  names an intent; the commit's own trailers are the actual record of what
  landed. **Search the packet's own feature branch and the integration
  branch together, never `<base>..HEAD` alone** — at `full-autonomy` §3.7
  merges a landed packet's branch into the integration branch right after
  it lands, so by stop-report time `HEAD` is wherever the *last* packet in
  the run happens to have run, and every earlier bundle's commit is only
  reachable from the integration branch, not from `<base>..HEAD`; that
  range finds nothing for any bundle but the most recent one — exactly the
  resumed/compacted case this step exists to cover. Find the commit whose
  trailers name this packet's id, anchored to the **whole line** — the
  same `^[[:space:]]*\[orch packet:<id>\][[:space:]]*$` shape §1's drift
  scan uses, never a bare substring, so prose that merely mentions a
  trailer can never be read as a landed member:
  `git log orch/<id> <base> -E --grep '^[[:space:]]*\[orch packet:<id>\][[:space:]]*$' --format=%H -1`
  (fall back to `--all` when `orch/<id>` no longer exists, e.g. deleted
  after merging — the same targeted trailer search the branch-cleanup step
  above already runs for `[orch decider:`, and the same read T7 gives
  `resume`'s own `adopt` path) — then read **every** `[orch packet:...]`
  trailer on that ONE commit, each on its own line, in commit order: that
  ordered list is the bundle's full landed membership, `<cursor>` first
  (§3.6 writes it first, and that ordering is load-bearing there for
  orphan-adopt — see that step). For each member's title, read the same
  `handoff.md` again — the member's own `PACKET=<id>` line and the `TEXT=`
  line that follows it name it (T5's per-member block shape), the same
  field `run-digest`'s `<title>` already reads for the first member alone.
  Render the packet's ✅ line (or 🔁, when a `decision` line for this id
  reads `retry`) with every landed member's title recovered this way, still
  as the one line `run-digest` gives you.

  **When no commit is found on either search** — the branch and `--all`
  both come up empty, which should not happen for a `green` packet but must
  never be swallowed silently — render the members from the `BUNDLE=` line
  in `handoff.md` instead (falling back to the cursor alone when even that
  is absent), with a note that this packet's landing could not be confirmed
  from git; never render it silently as a single task.

  **A bundle that did not land** — `rolled-back`, `failed`, `blocked`,
  `interrupted`, `abandoned` — never committed, so there is no trailer to
  recover its membership from; render it exactly as `run-digest` gives it,
  by its packet id and its own (cursor) title, same as any other packet.

  **Then `runstate.sh driver-mode exit` — immediately after every stop
  report, no exceptions.**
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
