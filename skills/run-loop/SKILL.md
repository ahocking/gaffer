---
name: run-loop
description: Drive the guided autonomy loop across a backlog of task packets, in driver mode (ADR 0028). Per packet, branch off the integration base, write its handoff file, dispatch a fresh agent with only that path, route the reviewer's verdict mechanically, commit on branch if green, update run-state, then pull the next. Pauses at a safe checkpoint on any hard gate or ambiguity; integrates onto a non-`main` branch but never merges/pushes to `main`, opens a PR, or crosses a hard gate. Use to run a semi-attended engineering session over the gspec backlog (a feature's plan under gspec/features/<slug>/) or a run-state backlog.
argument-hint: (optional — a backlog source or a starting packet; else reads .agents/run-state.yaml, then the gspec backlog)
---

# Run the guided loop $ARGUMENTS

`Read` `${CLAUDE_PLUGIN_ROOT}/agents/loop-driver.md` now, once, before anything
else — your role for the rest of this run (ADR 0028). It holds the
**judgment** (routing, the escalation-decider dispatch, operator Q&A, mid-run
edits); this skill holds the **mechanics** (preflight, the backlog, dispatch
ordering, commit trailers, termination). Your context persists across packets,
so re-read neither per packet.

There is **one sequential mode**; backlog size never switches it, and no packet
is implemented inline — every packet goes to a dispatched agent. Its safety
rests on the guard's driver-mode edit block (`hooks/guard.sh`), per-packet
`orch/<task-id>` feature branches in the single local checkout, and the durable
checkpoint in `.agents/run-state.yaml` — honor them, never route around them
([ADR 0004](../../docs/adr/0004-graduated-autonomy-and-pausable-loop.md),
[ADR 0009](../../docs/adr/0009-single-directory-feature-branch-workflow.md),
[ADR 0028](../../docs/adr/0028-loop-driver-mode.md)).

## Flags this loop no longer has

`--relay`, `--inline`, and `--parallel` are still accepted in `$ARGUMENTS` and
must **not** error; none changes anything — relay dispatch and worktree parallel
mode are retired ([ADR 0012](../../docs/adr/0012-delegated-loop-driver.md),
[ADR 0016](../../docs/adr/0016-parallel-worktree-lanes.md)). Run the loop below
and add one `⚠️ **--<flag>** no longer does anything — this loop runs one
sequential mode.` line to the kickoff (§2) per flag present.

## The report contract — `Read` it before you emit anything

`Read` `${CLAUDE_PLUGIN_ROOT}/templates/report-conventions.md` (glyph
vocabulary, indentation contract, header tally, decision block) and
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md` (shapes **C** kickoff,
**A** packet line, **B** stop report) now, once, before the kickoff.
**Naming a path is not reading it** — unread, you render from memory.

## 1. Preflight (stop here if unmet) — driver mode is NOT yet entered

No stop in this section needs `driver-mode exit`: driver mode is entered in §2,
after preflight passes, so a preflight stop has no mark to clear.

- **gspec contract + interlock (ADR 0020).** With a `gspec/` directory, run
  `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh check` and `… interlock`.
  `CHECK=fail` means an unsupported gspec version — **stop and say so** (the
  remedy is `/gspec-migrate`, or raising the pin); never read the backlog
  anyway. `INTERLOCK=busy` means a `gspec build` is driving this repo now —
  **stop**: two drivers fanning implementers into one checkout collide. Both are
  no-ops with no gspec project — gspec is optional (ADR 0020 D4).
- **Drifted completion record (ADR 0025 D1, gspec repos only).** Scan **every
  ref**, not just the current branch — a packet that landed and never got its
  checkbox flipped usually lives in already-merged history. Anchor the match to
  the **whole line** — a real trailer, not prose that mentions one:
  ```bash
  IDS=$(git log --all --format=%B \
    | grep -oE '^[[:space:]]*\[orch packet:[a-z0-9][a-z0-9-]*\][[:space:]]*$' \
    | sed -E 's/^[[:space:]]*\[orch packet:(.*)\][[:space:]]*$/\1/' \
    | awk '!seen[$0]++' | paste -sd, -)
  ```
  Empty `$IDS` → nothing committed yet, skip. Otherwise, read-only:
  `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh task-status "$IDS"`. A line
  reading `unchecked` is a packet that landed without its task checkbox set — a
  genuine **drift**. **Say so in the kickoff (§2); do not flip the checkbox and
  do not block the run** — reconciling a drifted record is the human's call.
- **Drifted capability checkboxes (gspec repos only).** Run
  ```bash
  ${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh capability-drift \
    | ${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh record-completion --drift --restore head
  ```
  Each `DRIFT=<slug>\t<capability text>` line (passed through) names a feature
  whose every task covering a capability is checked but the capability's box is
  not. **The loop reconciles this itself, not the operator**, through that one
  call — never a main-thread edit: it calls `complete-capabilities` per distinct
  slug, reads its exit codes, and restores a failed call's PRD from `HEAD`.
  Stage each `STAGE=` path it prints; if any was staged, land them as **one
  commit** on the integration branch, outside any packet, message `spec:
  reconcile capability record (preflight)`, with neither an `[orch packet:]` nor
  an `[orch decider:]` trailer — so run metrics count no packet for it —
  through the loop's own scripts and commit path. No `STAGE=` line means **no
  commit** and no flips, never a failure. **Commit nothing, and restore every
  `STAGE=` path with `git checkout HEAD -- <path>` instead** (it resets the
  index as well as the working tree, since the path is staged) when the checkout is off the integration branch, when the last line reads `failed=` above 0, or when the commit itself fails; then leave the checkout as you found it. None of these halts preflight.

  **In the kickoff (§2): one ⚠️ line per capability actually flipped**, from
  the `COMPLETED=<slug>\t<capability text>` lines, not the `DRIFT=` listing (a
  held feature flips nothing), **naming the feature and the capability**; flips
  restored rather than committed are stated as not committed, with the reason.
  **One ⚠️ line per `HELD=<slug>\t<reason>` line**, in the same form, carrying
  that reason: an unchecked task's `covers:` quote matches no capability, so
  every flip for that feature is held until the quote is fixed. A held feature
  stages nothing and leaves nothing to restore — **neither a failure nor a
  flip**, named so the operator can fix the quote. One ⚠️ line per
  `CAPABILITIES=<slug>\tfailed` line, naming the feature. State the trailing `unjudgeable=<n>` count
  separately, as a figure — never one `UNJUDGEABLE=` line per finding — naming
  only the classes present among the `UNJUDGEABLE=<class>\t<slug>\t<detail>`
  lines (`unmatched-quote`, `uncovered-capability`, `unrecognized-capability`;
  e.g. "34 unjudgeable — all unmatched-quote"), never folded into the flip count
  and never flipped, whatever the rest of the scan flips. Say nothing when fully
  clean (`CAPABILITY_DRIFT=ok drift=0 unjudgeable=0`); state the figure whenever
  `unjudgeable` is nonzero, even with `drift` `0`. No exit — including
  `CAPABILITY_DRIFT=attention` — is a stop. This holds wherever a run entry
  point states a preflight drift scan. A repo with no `gspec/` reads
  `CAPABILITY_DRIFT=none` — a silent no-op, same as the check above.
- **Branch.** Never run on `main`/`master`. Work happens on `orch/<task-id>`
  feature branches **in the single local checkout**; the guard denies `git
  commit`/`merge`/`push` to a protected branch anyway. The integration base the
  loop branches from and merges into is the **non-`main`** branch
  `.agents/project-overrides.yaml` names under `integration_branch`; when that
  key is absent, the fallback is the one
  `templates/task-packet.yaml`'s header comment states.
- **Model routing — once, here, before driver mode.** Run
  `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh validate` and `… routing.sh table`
  and keep both outputs — the only source of the kickoff's two routing lines
  (§2). Both exit 0 on every config state; **a `validate` report never stops
  the run** — an ignored entry falls back to its agent's frontmatter model.
  Never read `model_routing` yourself.

## 2. Enter driver mode, then establish the backlog and the run

**Enter driver mode now, right after preflight passes and before anything
else here:**

```
runstate.sh compact-threshold   # THRESHOLD=<n|unknown> SOURCE=repo|operator|unknown APPLIED=no
runstate.sh session-effort      # EFFORT=<level|unknown> REASON=<why> EFFORT_ENV=set|unset
runstate.sh driver-mode enter --model <this session's model, from SessionStart> \
  --effort <EFFORT, exactly as printed> --threshold <unknown, or THRESHOLD per the rule below>
```

Run `session-effort` just before `driver-mode enter` and pass its `EFFORT` to
`--effort` exactly as printed, a level or `unknown` alike. It reads this
session's own transcript and always exits 0, so entry proceeds whatever it
printed. **The effort is read, never inferred from the model** — never
substitute a level you expect, never replace `unknown` with a guess. Keep its
`EFFORT_ENV`: shape C's `⚠️ **Effort override**` line renders only on `set`.
`compact-threshold` is a pure reader — it writes no settings file, so `APPLIED`
is always `no`. When `SOURCE` reads `repo` or `operator`, pass `THRESHOLD`
straight through and state that number in the kickoff — the harness enforces
it. When `SOURCE` reads `unknown` (the one value naming no value in effect),
pass `--threshold unknown` whatever `THRESHOLD` printed, and state the absence
in the kickoff in exactly these words — *no compaction threshold in effect for
this session — the settings key `autoCompactWindow` supplies one* — and never a number, so the run reads as unmeasured. **Never ask the operator to change the effort or the threshold** — state what applies, as read, and move on.

**If `enter` refuses** (no session id from an argument or
`$CLAUDE_CODE_SESSION_ID`), **stop now** with a stop report saying so. Never run
the loop unmarked — without a mark the guard's edit block has nothing to block.

`Read` `${CLAUDE_PLUGIN_ROOT}/templates/task-packet.yaml` once now, before
building or continuing the backlog: it carries two REQUIRED rules every
packet's handoff must carry, whatever its source — a criterion naming the
matching regression sweep when its file scope touches enforcement or
automation code (a hook, a guard/policy script, CI logic), and a
`session_boundary` declaration when it touches a surface loaded at session
start (`hooks.json`, a settings file that registers hooks, an agent/skill's
frontmatter). §3.3 applies them per packet; never re-read this file per packet.

- If **`.agents/run-state.yaml` exists**, route on its status, not on the file
  being there — a completed run leaves its checkpoint on disk too. Read it once,
  through the reader, never by eye:
  `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh get .agents/run-state.yaml status`.
  - **`paused`, `blocked` or `running`** — you are resuming: `Read`
    `${CLAUDE_PLUGIN_ROOT}/skills/resume/SKILL.md` and follow it instead of the
    rest of this section (it keeps `run_id`; its `driver-mode enter` is
    idempotent). These are exactly the three statuses resume resolves.
  - **`done`** — nothing to resume: take the
    **fresh-run bullet directly below**, with no redirect, even when the
    checkpoint still carries a cursor or pending packets — the status is the
    authority.
  - **Any other value, including an absent or empty status** — **stop** with a
    report naming the value and `.agents/run-state.yaml`. **Write nothing
    first** — no `set`, `write`, `begin-run`, `claim-driver`, kickoff or lint
    file — the checkpoint is untracked, so a guess at it cannot be undone. Run
    `runstate.sh driver-mode exit` immediately after that stop report — a stop
    that leaves the mark set leaves the session unable to edit.
- Otherwise build the backlog **through the adapter**, the single place this
  plugin reads gspec (ADR 0020 D2); never parse `gspec/` yourself:
  - `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh next` picks the feature —
    lowest `order` among incomplete-and-unblocked, **completion derived** from
    the PRD's capability checkboxes, never stored — and prints `NEXT=<slug>` and
    the `PLAN=` file.
  - `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh nodes <slug>` turns its plan
    into one packet node per **unchecked** task.
  - Or take `$ARGUMENTS` / an explicit backlog — gspec is one of three backlog
    sources, not a requirement. **A packet not sourced from gspec** has its task
    text written into run-state now, from the template; `gspec-backlog.sh
    handoff` has no equivalent, so that text is its handoff body at §3.3.

  Write an initial `.agents/run-state.yaml` from
  `${CLAUDE_PLUGIN_ROOT}/templates/run-state.yaml` (cursor = first packet, the
  rest pending), atomically:
  `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh write .agents/run-state.yaml`.

  **When this write replaces a `done` checkpoint, carry every `findings:`
  index entry into the new content verbatim, and carry nothing else.** `write`
  REPLACES the file, so an omitted entry is unlinked, not edited out — its body
  stays on disk with nothing pointing at it. Carry it **inside this one
  `write`**, never as a follow-up `add-finding` or repair — a crash in between loses it. **Read the index from disk — the
  `findings:` block of the `.agents/run-state.yaml` you are about to replace —
  and copy those lines line-for-line into the new content** (a `Read`, or a
  line-range extraction of the block), so its quoting carries over: the
  `findings:` key through its last indented entry, stopping at the next
  column-0 key; an absent or empty block carries nothing.
  **`runstate.sh findings` is not a source for it** — it strips the
  single-quoting the durable-state writer applies (ADR 0027). Everything else —
  `cursor`, `pending`, `branch`, `last_green_commit`, `note` — comes from the
  new backlog, with **no `run_id` line**, so the `begin-run` below mints its own
  id rather than inheriting the finished run's directory and records.

**Mark the run live, begin it, and claim the driver.**

```
runstate.sh set .agents/run-state.yaml status running
runstate.sh begin-run .agents/run-state.yaml      # RUN_ID=, RUN_DIR=, REMOVED=...
runstate.sh claim-driver .agents/run-state.yaml
runstate.sh clear-pause .agents/pause
```

`begin-run` mints `run_id` only when absent (a resume keeps it — a run spans
sessions) and prunes every run directory except the current and newest
previous one. `status: running` is the crash signal; the **driver claim** tells
a crashed run apart from *another session driving right now* (ADR 0020 D5).
Keep the status truthful — only `/gaffer:pause` (→ `paused`/`blocked`) and
completion (→ `done`) clear it. Clearing the sentinel here stops a stale request
from re-halting this run at once.

**Then emit the kickoff**, here, after preflight and after the backlog resolves
— shape C in `${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`. Its `▶
**Session**` line comes from `runstate.sh run-digest .agents/run-state.yaml`'s
`enter` line (model/effort/threshold as `driver-mode enter` recorded it — never
from memory); a fresh digest has no `packet` lines, so the forward plan comes
from the backlog just resolved. `⚠️ **Routing config**` renders only when §1's
`validate` printed something — one line, each `ROUTING-INVALID` entry's key and
reason — and `▶ **Routing**` only when §1's `table` did — one line, each
`<agent> <frontmatter> <alias>` row as `<agent> <frontmatter> → <alias>`. `⚠️ **Effort override**` renders only when the `session-effort` you ran before `driver-mode enter`
printed `EFFORT_ENV=set`. State the one assumption most likely to be wrong,
which packets you expect will need a decision, the hard gates this backlog gets
near, and where the run stops.

**Lint the kickoff before you emit it.** Write the digest you rendered from
(`runstate.sh run-digest .agents/run-state.yaml > <RUN_DIR>/kickoff-digest.tsv`)
and the kickoff (`<RUN_DIR>/kickoff.md`), with `<RUN_DIR>` the `RUN_DIR=`
value `begin-run` printed, **written out literally** — never `$RUN_DIR` or any
other variable, which driver mode refuses: then run
`${CLAUDE_PLUGIN_ROOT}/scripts/report-lint.sh --shape C <RUN_DIR>/kickoff.md
<RUN_DIR>/kickoff-digest.tsv`. It prints `REPORT_LINT=clean`,
`REPORT_LINT=findings n=<k>` then one `FINDING=<rule>\t<line>\t<detail>` per
finding, or `REPORT_LINT=unjudged` with a `REASON=`, and exits 0 on every path.
Correct the lines findings name **at most once**, then emit — never re-lint in
a loop. A finding records nothing, blocks nothing, rolls back nothing, flips
nothing and halts nothing. Read the result as §4's **How to read the lint's
result** states.

## 3. Loop — for the packet at `backlog.cursor`

1. **Branch.** Create (or switch to) the packet's feature branch:
   `git switch -c orch/<task-id> <base>`, with `<base>` the integration branch
   `.agents/project-overrides.yaml` names under `integration_branch` (its
   absent-key fallback as §1's **Branch** bullet states); `git switch
   orch/<task-id>` if it already exists. No worktree, no separate directory —
   a worktree branched mid-run lacks the earlier packets' commits and is never
   merged back (ADR 0009); keep one for self-contained work off the default
   branch, never a loop packet. File-editing agents run one at a time unless
   their declared file scopes are disjoint; read-only agents (a `researcher`, a
   `reviewer`, an `Explore`-style search) may fan out freely.
2. **Form this packet's members, then sweep for packets left open before
   recording it.** Bundling (`packet-bundling`) turns a run of consecutive,
   same-scope, same-feature tasks into ONE packet. Form the membership first:
   the sweep below exempts every member of a paused bundle, not just the cursor.

   **Recover the membership instead of forming it when the cursor's own
   handoff already exists** — `<RUN_DIR>/<cursor>/handoff.md`, `<RUN_DIR>` as
   `begin-run` printed (a session picking this packet back up, after a compaction or through `/gaffer:resume`). **Never re-run `group` here**:
   it could shrink or grow a membership a start record already covers. Read
   the file instead:
   - `tier:` and `agent:` off its header (`grep '^tier:\|^agent:' <path>`) —
     decided once, against this membership, when the handoff was written;
     never re-judge them from titles.
   - Membership off its body's `BUNDLE=` line (`grep -m1 '^BUNDLE=' <path>`).
     Its absence means a single-member bundle: `MEMBERS=<cursor>` alone.

   Then re-run only the **mechanical refusals**, never `group`'s
   scope/deps/cap judgment: `gspec-backlog.sh task-status "$MEMBERS"`,
   dropping each member whose line reads `finished` (checked off meanwhile, by
   any route) or `gone` (re-decomposed out of the plan) — **never the cursor
   itself**, whatever its line reads. The third refusal, a member already
   routed `hand-off-feature` this run, needs no check here: §3.3's
   `HANDOFF=refused` check catches it. Then go straight to the sweep below.

   Otherwise — no handoff for the cursor yet — read the cap:
   `runstate.sh bundle-cap` prints `CAP=<n>`, the cap in effect, from
   `bundle_max_tasks` in `.agents/project-overrides.yaml`. Form the candidate
   group: `gspec-backlog.sh group <cursor> --cap <n>`. **A non-zero exit**
   (stderr only, no `HANDOFF=`/`GROUP=` line) leaves no group to read: treat it
   exactly like a leading `HANDOFF=unknown` below, and say so in whatever
   report later covers this packet (a plain sentence, no new glyph: bundling
   was skipped because `group` exited non-zero), since a silent fallback reads as "nothing to bundle". Never halt the loop for this, and never
   guess membership from partial or malformed output — the fallback is exactly
   the cursor alone. A leading `HANDOFF=unknown` (no gspec, a non-gspec
   packet, or a cursor already checked) means no bundling: set
   `MEMBERS=<cursor>`, decide its `tier`/`--agent` as for any single packet,
   and skip to the sweep. Otherwise `group` prints `GROUP=<cursor>`, one
   `MEMBER=<node-id>\t<title>` line per candidate in plan order (cursor first),
   `FILES=` (their scope union) and `STOP=<cap|scope|deps|end>` — the
   mechanical half (scope overlap, deps, the cap, one feature) is done; tier is
   not in the plan, so it stays yours.

   Walk the `MEMBER=` lines in printed order, judging each one's tier from its
   title as for a single packet. A design-heavy task never joins or starts a
   group: the cursor judged design-heavy means `MEMBERS=<cursor>` alone;
   otherwise stop **before** the first member you would judge design-heavy,
   dropping it and everything after it (it gets its own packet later).
   `MEMBERS` is the comma-joined survivors, cursor first, in plan order. Decide
   the packet's `tier` for the whole of `MEMBERS` as for a single task, and the
   `--agent` from it — `implementer` for `mechanical`/`integration`,
   `architect` or `ux-designer` for `design-heavy` (whichever the file hints
   scope to), `doc-writer` for `docs`; a multi-member `MEMBERS` is never `design-heavy`.

   `$MEMBERS` is driver-held shell state for this packet, like
   `$SINCE`/`$SWEEP`: it does not survive a mid-packet compaction or another
   session picking the packet up on its own. The recovery rule above brings it
   back once §3.3 has written the handoff; before that, the packet is formed
   from `group` again.

   Now sweep; `--paused-cursor` takes `$MEMBERS`, never the cursor alone.
   `runstate.sh sweep-open --list` prints one `OPEN=<id>` line per open
   packet. If any, resolve the comma-joined ids with `gspec-backlog.sh
   task-status "<id,id,...>"` (one `<id>\t<state>\t<reason>` line per id, plus
   `FINISHED=<csv>`), comma-join those reading `gone` into
   `GONE="<id,id,...>"` for `--gone`, then sweep for real — with
   `--paused-cursor "$MEMBERS"` exactly when this session is about to continue
   the cursor's bundle rather than start it fresh. **That is decided here,
   from the `--list` output in hand** (which omits `--paused-cursor`, so lists
   the cursor too): the cursor's id among its `OPEN=` lines (start still open,
   no outcome since) makes this a continuation; absent (never started, or its
   prior attempt closed with an outcome; including an empty `--list`) makes it
   a fresh start. **The first packet a resumed session runs is the one
   exception:** `/gaffer:resume` decides it from the `status` it read when
   it loaded the checkpoint, not from `--list` — `paused` or `blocked` is a
   continuation, and `running` (a crash) is a fresh start, so every open
   member of the cursor's bundle closes as `interrupted` (or `abandoned`, if
   it is also gone) like any other open packet. On a continuation the whole
   bundle is what this session continues, not what the sweep closes. Capture
   the real sweep's output: `SWEEP="$(runstate.sh sweep-open --gone "$GONE")"`
   (plus `--paused-cursor "$MEMBERS"` per that rule; omit `--gone` and skip `task-status` entirely when `--list` printed nothing, leaving `SWEEP` empty).
   `$SWEEP` holds one `SWEPT=<id>`/`OUTCOME=<interrupted|abandoned>` pair per
   packet the sweep closed — every open packet, gone ones reading `abandoned`,
   the rest `interrupted`. **Carry `$SWEEP` to §3.5/§3.6's report**: this sweep is the only point that knows which packets are newly closed.
3. **Write the handoff, then start.** `MEMBERS`, `tier` and `--agent` come
   from §3.2.

   **Check for `HANDOFF=unknown` or a non-cursor `HANDOFF=refused` before
   piping anything:** run `gspec-backlog.sh handoff "$MEMBERS"` and read its
   output first. A leading `HANDOFF=unknown` means some id in `$MEMBERS` does
   not resolve in gspec (a deleted/renamed task, or a genuinely non-gspec
   packet). From `group`, that can only be `<cursor>` alone — `group`
   confirmed every other candidate resolves.
   When it was **recovered** from an existing handoff's `BUNDLE=` line
   (§3.2), a non-cursor member can reach this too — `task-status` reads
   several genuinely-gone shapes as `unknown` rather than guess, and
   `handoff`'s fuller per-id resolution catches them: treat a non-cursor
   `HANDOFF=unknown` exactly as a non-cursor `HANDOFF=refused` below —
   truncate and re-run `handoff` — never as the single-member case.
   When `<cursor>` itself does not resolve and you have run-state's own task
   text for it (a non-gspec-sourced entry — never a bundle, since grouping
   needs gspec's plan), pipe that instead of the adapter's output; otherwise
   **skip the packet with no record** — advance the cursor and report the
   skip.

   A leading `HANDOFF=refused` (`REASON=hand-off-feature`) means some member
   was already routed `hand-off-feature` this run; its `PACKET=` line names
   which. This check covers **any** member — `runstate.sh handoff`'s own
   refusal below only ever sees `<cursor>`. `PACKET=<cursor>`: **skip the
   packet with no record**, advance the cursor and report the skip. A later
   member: **truncate `$MEMBERS` to the members before it** (as §3.2's
   design-heavy truncation drops a member and everything after it), re-run
   `gspec-backlog.sh handoff` on it and proceed with that narrower bundle; the
   refused member stays in `pending` for its own packet, refused again in
   turn later. Never pipe a `HANDOFF=refused` body to `runstate.sh handoff` as
   if it were task text.

   Append the applicable REQUIRED line(s) from §2's read of
   `task-packet.yaml` — the sweep criterion for enforcement/automation code,
   the `session_boundary` line for a session-start-loaded surface, both or
   neither — **judged against the union of every member's scope**
   (`handoff`'s `BUNDLE_FILES=` line when it bundles, the single member's
   `FILES=` line otherwise), never the cursor's alone. Those two conditional
   lines are all you append — never the verification contract block, which `runstate.sh handoff` adds itself to every handoff, from
   `${CLAUDE_PLUGIN_ROOT}/templates/handoff-required.md`. Then write the
   handoff:
   ```
   { gspec-backlog.sh handoff "$MEMBERS"
     printf '%s\n' "REQUIRED: the regression sweep covering <area> passes, with a new case for this change"   # only if applicable
     printf '%s\n' "REQUIRED session_boundary: <what could not be verified in this run; what the next session must check>"  # only if applicable
   } | runstate.sh handoff .agents/run-state.yaml <cursor> --tier <tier> --agent <agent>
   ```
   (for a non-gspec packet, run-state's task text replaces the first line —
   always a single id then). `runstate.sh handoff` takes exactly one id —
   `<cursor>`, the bundle's own — never `$MEMBERS`: it names the run
   directory, the header's `result`/`review` paths, and everything §3.4 onward
   dispatches and routes against. Its title (the `# <pkt>: <title>` line, and
   `run-digest`'s `<title>` field) is the cursor's own `TEXT=` line, never a
   bundle summary; §3.6 and §4 name every member's title. **A refused handoff
   (`HANDOFF=refused`) skips the packet — advance the cursor and report the
   skip; do not call `record-start`.** Only once `HANDOFF=<path>` prints do you
   attest the start: capture `SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"` first,
   so §3.5/§3.6's report scopes `run-digest --since "$SINCE"` to this packet's own decisions, then `runstate.sh record-start "$MEMBERS"` for a fresh start
   or `runstate.sh record-start "$MEMBERS" --continue` for a continuation, as
   §3.2's sweep decided — one record per member, one timestamp and session,
   one call.

   **Read back the handoff's header** (`grep '^run-state:\|^result:\|^review:'
   <path>`): it names the absolute `run-state`, `result` and `review` paths
   this packet's dispatches and `route` calls use. Pass the handoff path to the
   dispatched agent — its body carries every member's text, file scope and
   acceptance criteria in plan order, so one dispatch covers the whole bundle.
4. **Dispatch, then route.** Every dispatch in this loop, here or later,
   runs the `routing.sh resolve` its site names immediately before it: a
   non-empty result is passed as `model`; an empty one means `model` is
   omitted. A deliberate
   one-dispatch deviation carries `Model override: <alias> — <reason>` in its
   brief and applies to that dispatch only.

   **Check every status line before you act on it.** Run
   `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh check-status --status '<line>'`
   (single-quoted, same `'\''` rule) on **every** status line you read —
   including one nothing routes on, the implementer's and the doc-writer's as
   much as the reviewer's verdict and the decider's token. It prints one
   reason naming the rule that failed and exits non-zero when the line is
   off-grammar. On a refusal, re-dispatch the same agent **once**,
   passing the printed reason and nothing else — not a rewritten brief, not
   your own restatement of the packet. On a second refusal: a line the driver
   does not route on proceeds to the reviewer dispatch exactly as today, and a
   line the driver would have routed on — the reviewer's verdict, the
   decider's token, and the implementer's own line, whose first token
   decides between a continuation and the reviewer — is
   escalated as a blocking question naming the agent and the printed reason,
   never passed to the reviewer, through `/gaffer:pause` exactly as §3.5's
   `stop` does. The driver
   never substitutes a line of its own, at either refusal — a line you wrote
   reports on work you did not do. The reviewer's content gate is unchanged:
   `check-status` reads the line's shape, never whether it is true, and a
   well-formed line that is wrong is still the reviewer's `fix`.

   Run `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve <agent>` for the
   `--agent` from §3.3, then dispatch a **fresh** agent of it with the handoff path **only** (plus the
   review file's path from the header on a re-attempt) — one dispatch, one
   review and one `route` call cover every member of `$MEMBERS`. Read its one
   status line (`${CLAUDE_PLUGIN_ROOT}/templates/status-line.md`); never open
   its result file yourself.

   **Read and `check-status` that line before any reviewer dispatch, and
   branch on its first token.** A first token of `continue` — the implementer
   stopped at its turn budget with work still to do — goes straight to
   `route` as its token, with that same line as `--status` (single-quoted,
   the rule below), and **no reviewer is dispatched for it**: §3.5's
   `continue` arm takes it from there. Any other first token proceeds to the
   reviewer exactly as today:

   Run `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve reviewer`, dispatch
   the `reviewer` with the handoff
   path (and the review path on a re-attempt), and read its verdict the same
   way. Pass the verdict, its status line as `--status`, to `route` **with the
   run-state path from the handoff header**, **single-quoting the status
   text** — never double-quoted, or a backtick or `$(...)` in the agent's text
   executes in your shell (`${CLAUDE_PLUGIN_ROOT}/templates/status-line.md`
   states the `'\''`-escape rule):
   ```
   runstate.sh route <run-state-from-handoff-header> <cursor> <token> --status '<line>'
   ```
5. **Act on `route`'s action** (judgment for `decider` lives in
   `agents/loop-driver.md` §Routing — this is the mechanical shape):
   - **`land`** — commit green, §3.6.
   - **`attempt`** — refresh the handoff first, then re-dispatch. Run
     `${CLAUDE_PLUGIN_ROOT}/scripts/runstate.sh refresh-handoff
     <run-state-from-handoff-header> <cursor>` before **every** `attempt`
     re-dispatch, so the fresh agent is briefed with the partial work the
     failed attempt left on disk; then run
     `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve
     <agent>` for the packet's `--agent` (non-empty → `model`; empty → omit
     `model`), and dispatch a fresh agent with the handoff and review
     paths; record no start. The handoff still covers every member of
     `$MEMBERS`, so one `attempt` re-does the whole bundle, not just the
     cursor.
   - **`continue`** — the implementer stopped at its turn budget; carry the
     same packet on. Do exactly these three, in this order:
     1. `runstate.sh record-start "$MEMBERS" --continue` — one continuation
        record per member.
     2. `runstate.sh refresh-handoff <run-state-from-handoff-header>
        <cursor>`, which rewrites the packet's handoff in place with the
        partial work now on disk.
     3. `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve implementer`
        (non-empty → `model`; empty → omit `model`), then dispatch a fresh
        `implementer` with that same handoff path **and no review path**.
     The order is the point: dispatching before `refresh-handoff` runs
     briefs the continuation without the partial work it exists to carry on
     from. A continuation spends no attempt — `route` printed the packet's
     live `ATTEMPTS=` without incrementing it — and **no reviewer is
     dispatched and no verdict is recorded for it**.
   - **`decider`** — run `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve chief-engineer`,
     then dispatch the `chief-engineer` as the **escalation decider**
     (`${CLAUDE_PLUGIN_ROOT}/agents/chief-engineer.md` §Escalation decider)
     with the handoff path, the review path, and this `route` call's
     `ATTEMPTS=`/`LIMIT=`, nothing else. Its one status line's status is
     `retry`, `reorder`, `append-task`, `hand-off-feature` or `ask-operator`;
     every write the decision needs — `reorder-pending`, `amend-handoff`, the
     `add-finding` and `record-decision` records, any `[orch
     decider:<packet-id>]` commit — is on disk when it returns. Pass the token
     straight to `route`, its status line as `--status` (single-quoted); record
     nothing yourself and apply no order of your own.
   - **`discard-advance`** — first check for a decider commit on this branch
     (`git log <base>..HEAD --grep '\[orch decider:'`); if one exists, **do not
     delete the branch** — `append-task` merges it below and deletes it only
     once merged; any other token leaves it, unmerged, for §4's termination
     step. Then discard the uncommitted work non-destructively:
     ```
     git stash push --include-untracked -m "orch discard: <cursor>"
     ```
     (never `git reset --hard`/`git clean -fd`, which the guard hard-denies; one stash covers the whole bundle's uncommitted work).
     `runstate.sh record-outcome "$MEMBERS" rolled-back` — one call, every
     member. Then set the cursor by the token that brought you here:
     - **`reorder`** — remove nothing from `pending`: the decider's
       `reorder-pending` already placed every entry, this packet included, in
       run order. Set `cursor` to whatever is now first in `pending`, via
       `runstate.sh write`, leaving every entry where it sits. Checkable: the
       `reorder`ed packet is still in `pending` and is not the cursor. If it is
       first, the reorder placed nothing ahead of it and re-dispatching would
       repeat the failed attempt — hand `/gaffer:pause` a blocking question
       naming the packet and the order now in `pending`, as `stop` does.
     - **`append-task`** — merge the decider's branch now; the appended task
       is committed only on this packet's branch, so it is runnable in this run only once that branch is merged. List the branch's commits **without**
       this packet's trailer: `git log <base>..HEAD --invert-grep --grep
       '\[orch decider:<packet-id>\]' --format=%H`. When that prints nothing
       **and** `git log <base>..HEAD --format=%H` prints at least one commit,
       every commit beyond `<base>` is the decider's: switch to the
       integration branch and merge `orch/<packet-id>` at once, rather than
       at §4 — the same merge §3.7 makes, never targeting `main`, and an
       incoming diff hitting a hard-gate path re-escalates. Once merged,
       delete it with `git branch -d orch/<packet-id>` (the non-forcing `-d`,
       which refuses a branch not merged into `HEAD`) so §3.1 recreates it
       from the current `<base>`: left in place, it lacks the appended task's work and the re-run fails the same way. Otherwise — any commit without
       that trailer, or none at all — **do not merge**: hand `/gaffer:pause` a
       blocking question naming `orch/<packet-id>` and why it was not merged,
       as `stop` does, changing nothing in `pending`. After the merge,
       `reorder-pending` has already put the appended task ahead of this
       packet: remove nothing from `pending` and set `cursor` as the
       `reorder` arm does, every member of `$MEMBERS` left where it sits.
       Checkable: the appended task's line is on the integration branch, the
       originating packet is still in `pending` behind it and is not the
       cursor — so the note cannot read "backlog complete" while either is
       unchecked — and its branch, when next dispatched, contains the
       appended task's commit. §4's sweep of decider branches is the backstop
       for a run that stopped between the decision and this merge.
     - **`hand-off-feature`** — advance the cursor **past every member of
       `$MEMBERS`** by §3.6's cursor rule, via `runstate.sh write` — never
       assuming a consecutive prefix of `pending`, since a resume, a decider `reorder`, or an `append-task` can move one or leave it out — so no part
       of the bundle lands on its own.
     No proposed order is ever surfaced as a question — every order the
     decider decided is already applied, and the next report states it as a
     fact. Report as §3.6 does — shape A from `runstate.sh run-digest
     .agents/run-state.yaml --since "$SINCE"`: the bundle's `packet` line
     titled from every member (§3.6's title rule), one ⚠️ line per
     `SWEPT=`/`OUTCOME=` pair in `$SWEEP` reading *swept as interrupted* or
     *swept as abandoned* per its `OUTCOME`, plus one 🔀 per `decision` line
     other than `retry` — a `reorder`'s reads as the order now applied, never
     as a proposal for the operator.
   - **`stop`** — the hard-gate/genuine-ambiguity path. Take the question
     verbatim from `route`'s `question:` line when it printed one (a retry
     past its limit, or a `continue` past its continuation cap, which stops
     exactly as an over-limit `retry` does); otherwise from the triggering
     agent's status line (the decider's `ask-operator`, or the reviewer's
     `escalate` when no decider ran). Hand it, severity `blocking`, `packet:
     <cursor>`, to `/gaffer:pause` — **do not write run-state yourself here**;
     pause's step 3 persists it into `pending_questions` (carrying every
     entry `runstate.sh prune-questions` leaves), verifies the checkpoint,
     sets `status: blocked`, renders the stop report, and runs `driver-mode
     exit` itself (§4's **Blocked** points back here).
6. **Land (the `land` action).** Record every member's completion first, so
   it lands in this same commit (ADR 0025 D1) — one call, the packet's own
   files staged, before you commit anything:
   ```bash
   ${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh record-completion \
     --tasks "$MEMBERS" --feature <the handoff's FEATURE= value> --restore index
   ```
   It flips each member's task in plan order, then the landed feature's
   capabilities, and restores a failed capability call's PRD itself.
   - **Stage every `STAGE=` path** alongside the packet's own files, in the
     same commit. No `STAGE=` line means nothing from `gspec/` is staged.
   - **`TASK_DRIFT=<member>\t<reason>`** — the plan no longer names this
     member's task id: genuine **drift**. Commit as normal and name the member
     in the report; never a reason to halt or skip the rest of the loop. The
     member still lands, with its own `[orch packet:<id>]` trailer and `green`
     record — only its checkbox could not be flipped.
   - **`HALT=<member>\t<reason>`** (the call exits 1) — malformed id, a real
     usage error: the whole bundle ends together —
     `runstate.sh record-outcome "$MEMBERS" failed` — then stop and report; do not commit, so no part of the bundle lands on its own — and run
     `runstate.sh driver-mode exit` immediately after that stop report.
   - **`HELD=<slug>\t<reason>`** — a held feature stages nothing; the bundle
     commits as normal — neither a failure nor a flip.
   - **`CAPABILITIES=<slug>\tfailed`** — name the feature on this packet's
     landing report (shape A), but never for this halt the loop, withhold the
     commit, or record other than `green` for `$MEMBERS`: a capability flip is
     derived bookkeeping on tasks that already landed. The call has already
     restored that PRD (`RESTORED=`, the path the handoff's `PRD=` line names)
     **from the index, not from `HEAD`**, so the packet's own staged PRD edit survives.
   A single-task packet that completes no capability reads exactly as it
   does today: nothing staged, nothing to report.

   **Commit on the branch.** Trailers, each on its own line (ADR 0019
   self-label — a factual record, not a grade):
   - `[orch packet:<id>]` — one per landed member, each naming its own id, in
     the `--tasks` plan order, `<cursor>` always first, because a resume adopts
     by the FIRST `[orch packet:]` trailer on a commit alone (ADR 0005). A
     single-member packet prints exactly one.
   - `[orch tier:mechanical|integration|design-heavy|docs]` — §3.2's tier for
     the whole bundle, or what it *actually* turned out to be.
   - `[orch impl:delegated]` — always: no packet is implemented inline.

   Then update run-state atomically (`runstate.sh write`): `last_green_commit`
   = the new SHA; the cursor advances **past every member of `$MEMBERS`** —
   never assume the members are a consecutive prefix of `pending`, whose order is not the plan's: **remove every member of `$MEMBERS` from `pending`
   wherever it sits** (an absent one is simply not there to remove), then set
   `cursor` to the first entry left (or none). Call the committed packet
   `<landed>` from here on, meaning `$MEMBERS` as a whole.

   **`write` REPLACES the file, so every column-0 key below survives only
   because you carry it into the new content** — none is this close's own
   output, so one left out is gone. The whole list:
   - `schema` — the version line the reader keys off; `write` refuses content
     without it.
   - `run_id` — the run's own identity; losing it fails nothing at the
     write, but `run-digest` then refuses (*run-state has no run_id
     (begin-run has not been called)*) and the next `begin-run` mints a
     second id and creates a second run directory.
   - `branch` — the feature branch this run lives on.
   - every `driver_*` key the file carries: `driver_host`,
     `driver_since`, `driver_heartbeat`, and `driver_pid` when the claim
     recorded one — the driver claim (ADR 0020 D5), which `claim-driver` makes once at §2 and never re-makes.
   - `status: running` — the crash signal, cleared only by a pause (→
     `paused`/`blocked`) or completion (→ `done`); this close is neither.
   - `pending_questions` — every entry, unchanged.
   - the `findings:` block — the whole index, verbatim. An omitted entry is
     unlinked, not edited out.
   **Take every one from the on-disk `.agents/run-state.yaml` you are
   replacing, copied line-for-line** — §2's fresh-run source rule, so the file's quoting survives;
   `runstate.sh findings` is not a source for the index (its projection
   strips that quoting, ADR 0027). This close itself produces exactly
   `last_green_commit`,
   `backlog` (the `cursor` and `pending` above) and `note` (below);
   `updated_at` is the writer's own stamp — never a key you carry.

   **Outcome vocabulary — five mutually exclusive triggers; when a stop fits
   more than one, `blocked` beats `rolled-back` and `failed`, and `failed`
   beats `rolled-back`. Each applies to the packet as a whole, so a bundle's
   members share one outcome, recorded for all in the one call the trigger
   names:**
   - **green** — here, on a land.
   - **blocked** — the `stop` action (§3.5), once `/gaffer:pause` verifies the
     checkpoint.
   - **rolled-back** — the `discard-advance` action (§3.5).
   - **failed** — still red after honest diagnosis, the loop moving past with
     no blocking question; the `HALT=` usage error above is this trigger.
   - **abandoned** — the operator's answer to a blocking question drops the
     packet rather than retrying it (on resume too, when they say so).
   A retry within a packet is neither a start nor an ending: it records
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
     For each `STALE=yes` line naming a member of `<landed>`: first file a
     backlog task if it is really "this should be built/fixed" and not yet
     filed — capture precedes drop (ADR 0024), and such work belongs in the
     backlog, never a findings file (ADR 0022); a spent sign-off needs no
     capture. Either way drop it with `runstate.sh drop-finding
     .agents/run-state.yaml <id>`. The same call prints `OVER_THRESHOLD=`; on
     `yes`, name `STALE_COUNT` as `stale-findings: <N>` in the report below —
     its absence means under threshold, never checked-and-clean.
   - **Anything worth keeping past this packet is a finding, not note
     content** (ADR 0022): `runstate.sh add-finding .agents/run-state.yaml <id>
     "<one line>" --packets <id[,id...]>`, naming a still-pending packet — never
     a member of `<landed>`, which this close already satisfies.
   - Report the landing — shape A in
     `${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md`, from `runstate.sh
     run-digest .agents/run-state.yaml --since "$SINCE"` (§3.3's timestamp):
     `<landed>`'s own `packet` line (✅, or 🔁 when a `decision` line for this
     id reads `retry`), titled from **every** member of `$MEMBERS` — the
     `MEMBER=<id>\t<title>` lines `group` printed in §3.2, still in this
     session's context — never `run-digest`'s `<title>` field alone, which is
     only the cursor's `TEXT=` line; §4 covers a session that no longer has
     them. One ⚠️ line per `SWEPT=`/`OUTCOME=` pair in `$SWEEP` reading *swept
     as interrupted* or *swept as abandoned* per its `OUTCOME`, since that sweep's record is the only thing marking these as new; one 🔀 line per
     `decision` line `<landed>` carries other than `retry` (already the 🔁,
     never reported twice); and one ⚠️ line naming the feature per
     `CAPABILITIES=<slug>\tfailed` line printed above, as an alert alongside the ✅/🔁 line, never a reason to withhold it. Never write
     it from the agent's or reviewer's own words — the digest's fields render,
     not your memory of their status lines.
7. **Integrate.** After the packet lands green you may merge the branch into
   the integration branch, rebase it to keep it current, and push
   feature/integration branches — never targeting `main`; a merge whose
   incoming diff hits a hard-gate path re-escalates.
8. **Advance.** With no blocker, pull the next packet and repeat. At each
   packet boundary, poll the pause sentinel first — `runstate.sh pause-status
   .agents/pause` (or a `Bash`/`Edit` advisory surfacing it sooner) — and beat
   the driver heartbeat: `runstate.sh heartbeat .agents/run-state.yaml`. **On
   `PAUSE=1`:** finish the current packet to a green commit if it is already
   green and in policy, else leave the last green commit untouched; then hand
   to `/gaffer:pause`, which persists `status: paused`, clears the sentinel,
   and stops. A pause records no outcome — the packet's start stays open for
   a later session.

   **Otherwise, check the periodic pause at the same boundary:** `runstate.sh
   periodic-pause` prints `ENDED=<n>`, `EVERY=<n|off>`, `DUE=yes|no`, with
   `EVERY=` read from `pause_every_packets` in `.agents/project-overrides.yaml`.
   `EVERY=off` means `DUE` is always `no`, so a periodic pause never fires on
   its own. On `DUE=yes`, capture the setting before interpolating it —
   `EVERY=$(runstate.sh periodic-pause | grep '^EVERY=' | cut -d= -f2-)` —
   then request a pause naming it, so the stop report can state it plainly:
   `runstate.sh request-pause .agents/pause "pause_every_packets: $EVERY
   packets ended"`, and hand to `/gaffer:pause` as for `PAUSE=1`.

   **With neither pause taking the run, check the periodic review at this
   same boundary** (`agents/loop-driver.md` §The periodic review carries the
   same rule). Between packets — never while one is open — run
   `runstate.sh review-due`: it prints `NON_GREEN=`, `BEGINNINGS=`,
   `EVERY_NON_GREEN=`, `EVERY_BEGINNINGS=` (each a number or `unmeasured`)
   and `DUE=yes|no`. On `DUE=no` nothing is dispatched or carried. On `DUE=yes` — **including when any of the four reads `unmeasured`**, since an
   unread count is not a `0` below its threshold — run
   `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve chief-engineer`, then
   dispatch the `chief-engineer` as the **escalation decider** for a **periodic review**
   (`${CLAUDE_PLUGIN_ROOT}/agents/chief-engineer.md` §Periodic review) with
   the `run-state:` path from the handoff header you hold and nothing else —
   no handoff, review file, packet id or counts; it picks its own result path
   in the run directory. `check-status` its one status line (status word
   `reviewed`) and route nothing on it — `route` has no token for a review —
   and record nothing yourself, since the review writes its own
   `record-review` record. On a second `check-status` refusal, carry on to the
   next packet, for the same reason. Carry both counts into the next report
   (shape A at the next landing, or shape B if the run stops first):
   `NON_GREEN=` and `BEGINNINGS=` as printed, with `unmeasured` rendered as the word `unmeasured` and never as `0`. What the review merged, routed and
   dropped reaches that report through `run-digest`'s `review` line, never from its status line or its result file.

## 4. Termination

- **Backlog complete** → before declaring done, run
  `${CLAUDE_PLUGIN_ROOT}/scripts/routing.sh resolve reviewer` (§3.4's rule;
  on an empty result its frontmatter applies), then dispatch
  **one broad whole-branch review** (the `reviewer`) over **this run's own
  integrated work — not everything the branch has accumulated since its
  base**, since a branch-vs-base diff re-presents earlier runs' already-reviewed commits. Bound the diff by the packet ids `runstate.sh
  run-digest .agents/run-state.yaml` prints (no `--since` — every packet this
  run began, landed or not) and their `[orch packet:<id>]` trailers: walk
  `git log <base>..HEAD --reverse` to the first commit whose trailer names one
  of those ids, and diff from **that commit's own parent** — `git diff
  <parent>..HEAD`, or that parent against the integration branch's `HEAD`.
  **Fall back to the branch-vs-base diff — `git diff <base>...HEAD`, or the
  integration branch vs its base — only when no commit on `<base>..HEAD`
  carries a trailer naming any id from that digest list** (the digest names
  no packet, or every packet ended failed, rolled-back, blocked or
  interrupted): such a run has no narrower boundary to offer. There is no
  handoff file: hand it the diff, `.agents/run-state.yaml`'s path, and any
  result path under the run directory (this review is not packet-scoped). It
  writes its findings through `write-result` to that path and returns one
  status line as usual.

  **You do not open that review file — "never open a result file" has no
  exception, not even here.** You have the reviewer's own status line:
  relay **that line**, verbatim, in the stop report, with the
  review file's path beside it so the operator can open what you did not.
  Never summarize findings you have not read, and never dispatch an agent to
  route them — the end-of-run routing step that once did was
  retired (ADR 0026 amendment 2026-09-22).

  **Record one finding per note that status line reports**, since the
  findings index, not the review file, is what the next run can see:
  ```
  runstate.sh add-finding .agents/run-state.yaml <id> '<summary>' --packets <packet-id[,id...]>
  ```
  The `<summary>` is **what that status line says about that note and
  nothing more** — never a finding you invent about a file you have not
  read. `--packets` is mandatory, naming the packet(s) the note is about, and
  expiry stays the positive-evidence rule (ADR 0024), with nothing of this
  step's own. The id is `[a-zA-Z0-9._-]`; `add-finding` refuses a duplicate,
  so suffix a number when the id is already in the index. Nothing here files
  a feature, appends a task, or writes into `gspec/`. **A review that
  reports no notes records nothing at all** — no call, no finding, and no figure changes.

  **Before declaring done, account for any branch a `discard-advance` left
  carrying a decider commit** (§3.5): check each of `git branch --list
  'orch/*'` for a `[orch decider:` trailer beyond `<base>`, merge each such
  branch into the integration branch now, and name each (branch, commit,
  one-line summary) in the stop report so the human sees what landed.

  **Also before declaring done, re-run the same capability-drift scan §1
  states** — the same `capability-drift | record-completion --drift
  --restore head` call, not a second reading of its rule — so a capability
  whose last covering task landed this run is named by this run, not the
  next one's preflight. Stage each `STAGE=` path it prints; if any was
  staged, land them in **one commit**, outside any packet, message `spec:
  reconcile capability record (end-of-run)`, with neither an `[orch packet:]`
  nor an `[orch decider:]` trailer. No `STAGE=` line means **no commit** and
  no flips — not a failure. The commit goes on the integration branch when
  §3.7 merged this run's packets into it, else on the run's own branch (no
  green `orch/*` branch this run), so a flip never reaches the integration branch ahead of the work it records. When the last line reads `failed=`
  above 0, or the commit fails, commit nothing: restore every `STAGE=` path with `git checkout HEAD -- <path>`, report it below, and never
  withhold `status: done` or otherwise halt.

  Carry each capability actually flipped (`COMPLETED=<slug>\t<capability
  text>` lines, not the `DRIFT=` listing) into the stop report's `▶ Next`
  section — the one section the tally does not count — as an unglyphed line
  naming the feature and the capability; flips restored rather than committed
  are stated as not committed. No ⚠️, since a capability flip is not a packet, and no new glyph, shape, or tally figure. **Carry every held feature
  there too**, one unglyphed line per `HELD=<slug>\t<reason>` line, naming the
  feature and its reason (a held feature is as §1 defines it — **neither a
  failure nor a flip**; naming it here spares the next run's preflight from
  being first). Each `CAPABILITIES=<slug>\tfailed` line goes there too,
  naming the feature. State the trailing `unjudgeable=<n>` count as §1 does, in the same section — these rows are never flipped, whatever the rest of the scan flips.
  `CAPABILITY_DRIFT=none` stays a silent no-op. A flip changes no tally
  figure, no packet count, and never the outcome recorded for `status` — the
  run's stop reason is unaffected either way.

  Once the review's verdict is read and every note it reports is recorded as
  a finding, set `status: done` (`runstate.sh set .agents/run-state.yaml status
  done`), then snapshot run-metrics (best-effort, non-critical): `metrics.sh
  collect || true`. Emit the **stop report** (`report-templates.md` shape B)
  from `runstate.sh run-digest .agents/run-state.yaml` with **no** `--since` —
  its `packet` lines name every packet the run began, with its outcome,
  whether or not this session was the one that ran it: what shipped in plain
  words, anything left undone, any decision still open (its `handoff-feature`
  lines, plus any un-merged decider-commit branch), the whole-branch review's
  own status line and its review file's path, the single recommended next
  action, and `branch <orch/task-id>` ready for review as the state line.

  **Its four digest-derived tally figures come from `runstate.sh run-tally
  .agents/run-state.yaml`, and you compute none of them:** `SHIPPED=`,
  `FAILED=`, `UNFINISHED=` and `DECISIONS=`, in the fixed tally order ✅, ⛔,
  ⚠️, 🔀, counted by the core from the same whole-run digest with the 🔀 dedup
  applied — render each as printed, never recounted from the `packet` or
  `decision` lines. ⬚ queued is not one of them: it stays `runstate.sh
  summary`'s `N pending`.

  **Naming a landed bundle in that report.** A bundle is ONE packet — one
  `packet` line in `run-digest`, one ✅ line, never one per member — but that
  line's `<title>` is only the cursor's `TEXT=` line (§3.3), so the one line
  must still name every member.

  First check cheaply, per `green` `packet` line, whether it bundled: look
  for a `BUNDLE=` line in its `<run-dir>/<id>/handoff.md` (a body line below
  runstate.sh's own header, not part of the header block). Without one it is
  a single-member packet — render it exactly as `run-digest` gives it, and
  nothing below applies. Only a `BUNDLE=<id,id,...>` line needs the rest.

  Confirm membership from the branch, not the `BUNDLE=` line alone — that
  line records the intent at §3.3; the commit's own trailers record what landed. **Search the packet's own feature branch and the integration branch
  together, never `<base>..HEAD` alone** — §3.7 has already merged each earlier bundle's commit into the integration branch. Find the commit whose
  trailers name this id, anchored to the **whole line** (§1's drift-scan
  shape, never a bare substring, so prose mentioning a trailer is never read
  as a landed member):
  `git log orch/<id> <base> -E --grep '^[[:space:]]*\[orch packet:<id>\][[:space:]]*$' --format=%H -1`
  (with `--all` when `orch/<id>` no longer exists, e.g. deleted after
  merging) — then read **every** `[orch packet:...]` trailer on that ONE
  commit, each on its own line, in commit order: the bundle's full landed
  membership, `<cursor>` first (§3.6 writes it first). Each member's title is
  the `TEXT=` line following its own `PACKET=<id>` line in the same
  `handoff.md`. Render the packet's ✅ line (or 🔁, when a `decision` line for
  this id reads `retry`) with every landed member's title, still as the one
  line `run-digest` gives you.

  **When no commit is found on either search** (the branch and `--all` both
  empty — it should not happen for a `green` packet, but must never be
  swallowed silently), render the members from the `BUNDLE=` line instead
  (the cursor alone when even that is absent), noting that the landing could
  not be confirmed from git; never render it silently as a single task.

  **A bundle that did not land** (`rolled-back`, `failed`, `blocked`,
  `interrupted`, `abandoned`) never committed, so no trailer records its
  membership: render it exactly as `run-digest` gives it, by its packet id and
  its own (cursor) title, like any other packet.

  **Lint the stop report before you emit it**, once fully rendered (bundles
  included), the same way §2 lints the kickoff: the digest you rendered from
  to `<RUN_DIR>/stop-digest.tsv` (`runstate.sh run-digest
  .agents/run-state.yaml > <RUN_DIR>/stop-digest.tsv`), the report to
  `<RUN_DIR>/stop-report.md`, `<RUN_DIR>` the value `begin-run` printed
  **written out literally**, never a variable — then
  `${CLAUDE_PLUGIN_ROOT}/scripts/report-lint.sh --shape B
  <RUN_DIR>/stop-report.md <RUN_DIR>/stop-digest.tsv`. Findings are corrected
  **at most once** and change nothing, as at §2 — the run's outcome and
  `status` are already settled above.

  **How to read the lint's result — here and at §2's kickoff.**
  `REPORT_LINT=clean` means *no mechanical rule was broken*, never that the
  report conforms to the contract. `REPORT_LINT=unjudged` is **not** clean:
  the check could not look, and its `REASON=` says why. The lint does not
  judge whether a consequence clause states a consequence rather than an
  argument, whether the kickoff's assumption is the one most likely to be
  wrong, whether a title is a good plain-English title rather than merely
  present, or prose quality generally — the reviewer is the gate for all of
  them.

  **Then `runstate.sh driver-mode exit` — immediately after every stop
  report, no exceptions.**
- **Blocked** → the `stop` action (§3.5) already handed this to
  `/gaffer:pause`, which verified the checkpoint, persisted the blocking
  question, set `status: blocked`, rendered the stop report, and ran
  `driver-mode exit` — nothing further to render here.

## Never

Commit/merge/**push to `main`/`master`** (or remote `main`), open a PR, run a
migration or schema change, install/upgrade dependencies, edit a
sensitive/hard-gate path, deploy, or rewrite history (`--amend`, interactive
rebase, force-push, `reset --hard`). **Merging to `main`, releasing, and
opening a PR are the human's hard gate** — the loop stops at "ready for the
human to release", integrated onto the non-`main` integration branch. Every
iteration is a green commit on a branch, so a crash or shutdown mid-loop
resumes cleanly from the last checkpoint. §3.7's merge/rebase/push onto
**non-`main`** branches is the loop's *sole* action beyond committing on a
feature branch; everything above still stops for the human.
