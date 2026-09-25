# ADR 0028 — Loop driver mode: what the harness actually carries (probe results)

- Status: Accepted (probe record; the design decisions it feeds land with `thin-loop-driver` T3–T24)
- Date: 2026-09-15
- Amended (2026-09-20): **a status line's shape is refused by `runstate.sh check-status`
  before `route` or `write-result` touches disk, and the routing log carries one record
  per run that is not a verdict** (`loop-driver-run-gaps` T1–T5). See
  [Amendment (2026-09-20)](#amendment-2026-09-20--a-status-line-is-refused-by-a-subcommand-and-one-routing-record-is-not-a-verdict)
  below; the 2026-09-16 amendment above it is unchanged.
- Amended (2026-09-21): **the interim decider paragraph of the 2026-09-16 amendment is
  superseded in place** — `escalation-decider` shipped, and "The interim decider, and
  what `escalation-decider` replaces" now states what replaced it, with the original
  text kept marked beneath it.
- Open probe (2026-09-21): **one item of result 3's not-probed list — whether a plugin
  can supply a compaction-window default without overriding a repository or operator
  value — has a written procedure and is handed to the operator as a blocking question**
  (`driver-context-window-default` T1). See
  [Open probe (2026-09-21)](#open-probe-2026-09-21--can-a-plugin-supply-a-compaction-window-default-without-overriding-a-repository-or-operator-value)
  at the end; result 3 and its list are unrevised, and the answer lands beneath that
  section when the operator returns it (T5).
- Amended (2026-09-21): **the open probe is answered — no.** A `settings.json` at the
  plugin root is inert on Claude Code 2.1.278 (Opus 5); the hook-written carrier was not
  tried, by the operator's decision (`driver-context-window-default` T5). See
  [Amendment (2026-09-21)](#amendment-2026-09-21--the-plugin-default-probe-answered-no)
  at the end; nothing above it, the open-probe section included, is revised.
- Amended (2026-09-22): **the one routing record per run that is not a verdict is
  retired** — `run-loop` §4 no longer dispatches an architect at termination and writes
  no `end-of-run-review` record, so the 2026-09-20 amendment's "`route` appends one
  record per verdict" section is marked retired in place. `scripts/runstate.sh` is
  unchanged; the reasoning is
  [ADR 0026](0026-post-completion-findings-route-by-scope.md)'s 2026-09-22 amendment.
- Deciders: user (tech lead), orchestration plugin
- Relates to: `gspec/features/thin-loop-driver/prd.md` and its plan T1;
  [ADR 0017](0017-graceful-cooperative-pause.md) (the earlier payload probe that established
  `agent_id` inside subagents); [ADR 0019](0019-run-metrics-observability.md) (metrics
  attribute roles by `agent_type`, which this probe shows is not a main-thread test).

## Context

Driver mode rests on four harness facts nobody had checked, and the plan forbids taking
them from documentation:

1. Can a hook tell a session's main thread from its subagents, including in a session
   launched with `claude --agent`?
2. Does `session_id` survive compaction, `/clear` and `claude --resume`, and which
   SessionStart `source` does each fire?
3. Does a per-repo auto-compaction threshold exist, in what unit, and can a running
   session read the value in effect?
4. Can a session read its own effort level?

## Method

A scratch hook (`scratch/log-payload.sh`, gitignored, now removed) was registered in
`.claude/settings.local.json` on `PreToolUse` (matcher `.*`) and `SessionStart`
(`startup|resume|clear|compact`). It appended each raw payload as one line and printed
nothing. Four fresh sessions were run by the operator with effort set to `high`:

- **A** plain: a Bash call, `/compact`, a Bash call, `/clear`, a prompt.
- **B** `claude --resume` of A's post-clear session, a prompt.
- **C** `claude --agent probe-agent` (a throwaway `model: inherit` user agent): a Bash
  call, then a dispatched general-purpose subagent running Bash.
- **D** `/context` three times: plain; with `CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000`
  (plus a Bash `echo` of it); with `"autoCompactWindow": 100000` in
  `.claude/settings.local.json`.

19 payloads were logged. Session transcripts supplied the `/context` output and the
command results. The raw log stays local and uncommitted.

## Results

### 1. Main thread vs subagent: the discriminator is `agent_id`, and only `agent_id`

- A plain session's main-thread PreToolUse payload carries `session_id` and **no**
  `agent_id` and no `agent_type` (A, D).
- A session launched with `claude --agent probe-agent` carries **`agent_type:
  "probe-agent"` on its main thread, still with no `agent_id`**. The Bash call and the
  `Agent` dispatch both show it, and so does its `SessionStart startup` payload (C).
- A dispatched subagent's calls carry `agent_id` and `agent_type` (C: general-purpose,
  including its `SubagentHandback` call).
- Harness-spawned agents the operator never dispatched, with no transcript on disk, also
  carry `agent_id`. One in A had no `agent_type`, and two in C had `agent_type:
  "probe-agent"`, inherited from the launch. The guard treats them as subagents, which
  the PRD allows.

**The PRD assumption holds** ("hooks carry an agent id only inside subagents"), so the plan
continues. **`agent_type` is NOT a main-thread test.** Anything that treats "has
`agent_type`" as "is a subagent" misreads a `--agent` main thread: the guard (T5), the
metrics main-thread counts (T20, T21), and the existing role attribution in
`metrics-log.sh`, which will file a `claude --agent gaffer:loop-driver` main thread under
the role `loop-driver`.

### 2. Session identity: compaction and resume keep it; `/clear` does not

- `/compact` fires `SessionStart source=compact` with the **same** `session_id`, and
  carries `model`.
- `/clear` fires `SessionStart source=clear` with a **new** `session_id`. The payload
  names no previous id and carries no `model`.
- `claude --resume` fires `SessionStart source=resume` with the resumed session's **own**
  id (B; this planning session's own resume showed the same). It also carries
  `context_tokens`, `prompt_cache_likely_expired`, `seconds_since_last_response` and
  `estimated_cache_write_usd`, and no `model`.

**Consequences.**
- A driver-mode mark keyed by `session_id` survives compaction, which the PRD requires.
- A reopened session can clear its own mark on `resume`, as T6 plans.
- `/clear` mid-run ends driver mode for the new session with no stop report and orphans
  the old mark. The orphan is inert, because it is keyed to an id nothing will use again
  unless that session is resumed, in which case `resume` clears it. The PRD does not
  require surviving `/clear`, and the `clear` payload offers nothing to link the two
  sessions, so T6 registers its compact hook on **`compact` only** and does not guess.

### 3. Auto-compaction threshold: exists per repo, in tokens

- The default on Opus 5 (1M) read `Auto-compact window: 1m tokens`.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000` read `100k tokens` (`59.2k/100k`), and a Bash
  call in that session printed `100000`, so the variable is visible to tools.
- `"autoCompactWindow": 100000` in `.claude/settings.local.json` read `100k tokens`. That
  is a **per-repo setting**, and the unit is **tokens**.
- The `Autocompact buffer` stayed 33k in absolute terms either way.

**Not probed, and left to T4 to probe before relying on it:**
- precedence when both the variable and a settings key are set;
- the user and committed-project (`.claude/settings.json`) scopes;
- whether a **plugin** can supply a default without overriding a repo or operator value;
- whether a session can read a settings-file value in effect other than by reading the
  settings files. No hook payload carries the window.

The PRD's "the auto-compaction threshold can be set per repo" is achievable. "gaffer's
default" has no verified carrier yet.

### 4. Effort: readable from PreToolUse payloads, not SessionStart

- Every PreToolUse payload, main thread and subagent alike, carries `effort: {"level":
  "high"}`.
- SessionStart payloads carry no effort.
- `model` appears on SessionStart `startup` and `compact` only, and on no PreToolUse
  payload.
- PostToolUse was not registered in this probe, so whether it carries `effort` is
  unverified.

The model cannot read a hook payload itself, so the kickoff's effort must come from a
value a PreToolUse hook records for the session. With one, "effort unknown" is the
fallback, not the norm.

**Amendment (2026-09-24, `session-effort-reporting`) — the effort comes from the
session's transcript, not from a hook.** No PreToolUse hook ever recorded
`effort.level`, and none is added: until this change `run-loop` §2 and `resume` §0
passed `--effort unknown` unless the operator had stated a level. They now run `runstate.sh session-effort` just
before `driver-mode enter` and pass its `EFFORT` to `--effort` exactly as printed.
That reader takes the top-level `.effort` of the last row carrying one in the session's
own main-thread transcript (`<projects dir>/*/<session-id>.jsonl`, never a `subagents/`
file). The level is read, never inferred from the model. It is `unknown` when no
main-thread row carries one — as on a model that takes no effort — or when the
transcript cannot be found, parsed or trusted. The reader always exits 0, so entry
proceeds either way. The same call prints `EFFORT_ENV`, `set` only when
`CLAUDE_CODE_EFFORT_LEVEL` is non-empty; the kickoff renders shape C's `⚠️ **Effort
override**` line on `set` alone. The PreToolUse finding above stands as a record of
what the payloads carry; it is no longer the source of the recorded effort, and the
"Consequences for the plan" bullet for T3/T16 below describes the design as first
planned, not as built.

## Consequences for the plan

- **T3/T16:** `driver-mode enter --effort` reads a hook-recorded PreToolUse `effort.level`
  for the session, and falls back to `unknown` only when none has been recorded. `--model`
  comes from SessionStart `startup`/`compact` or the transcript.
- **T5:** refuse only when `agent_id` is absent. Never branch on `agent_type`.
- **T6:** the compact hook matches `compact` only (result 2).
- **T4:** the per-repo carrier is verified (`autoCompactWindow`, tokens). Probe precedence
  and a non-overriding plugin default first, and report `unknown` rather than invent one.
- **T20/T21:** main-thread means no `agent_id`. A `--agent` main thread must not be counted
  as a subagent role.

## Amendment (2026-09-16) — the mechanism these results produced

`thin-loop-driver` T3–T23 have landed, so the decisions this probe fed now exist as
code. This section records their **shape**, so the mechanism is readable from the ADR
that justified it rather than only from the plan file that scheduled it. Nothing above
is revised — the probe results stand as recorded, including the misses.

### The mark, and the guard rule it feeds

Driver mode is a **file**: `.agents/driver-mode/<session-id>` in a discovered config
root, written and removed only by `runstate.sh driver-mode <enter|exit|status>`. Its
**content is irrelevant** — existence alone means "this session is the loop driver."
That is deliberate: the guard checks it on every mutating tool call, and a file test is
both cheap and impossible to get subtly wrong. `enter` also appends an enter record
(model, effort, threshold) to `.agents/metrics/driver-mode/<session>.jsonl` and `exit`
an exit record. **Those records live outside the outcomes log on purpose:**
`_rs_open_packets` treats any record carrying `kind` as a packet start, so writing them
there would reopen packets that never existed.

The guard refuses a write only when **all three** hold: the payload's `session_id` has a
mark, the payload carries **no `agent_id`**, and the target is outside `.agents/`.
Result 1 above is the whole reason the second test is `agent_id` and never `agent_type`
— a `claude --agent gaffer:loop-driver` main thread carries `agent_type` with no
`agent_id`, and must still be refused. Four details are load-bearing:

- The `session_id` becomes a **path component**, so it is validated first (`[A-Za-z0-9._-]`,
  and never `.` or `..`); anything else is treated as **no mark** and the call is judged
  exactly as it is today. The guard never stats an attacker-chosen path.
- The check sits **after the secret floor and before the ask tier**, and it refuses via
  `deny()` — so `bypass-ask-tier: true` does not skip it, and a secret path is still
  refused *as a secret* rather than as a driver-mode write.
- For shell writes it is **conservative by construction**: a command it cannot judge
  safely (a target it cannot resolve, an unexpanded `$VAR`) is refused rather than
  allowed. Wrong-and-refused costs a pause; wrong-and-allowed is the leak the feature
  exists to stop.
- The refusal **names driver mode as the reason and `/gaffer:pause` as the way out**. A
  hard deny with no stated exit is how an agent starts improvising around the guard.
- **"Outside `.agents/`" means where the write PHYSICALLY lands, never what the path is
  called** (hardened 2026-09-16, `thin-loop-driver-gaps-b1`). The name test is lexical and
  a symlink is exactly what lies about a name, in three shapes: a symlinked ancestor, an
  existing symlink *leaf* (`.agents/x -> ../src/util.ts`), and a symlinked *directory*
  under `.agents/` (`.agents/d -> ../src`). So `_driver_mode_path_ok` resolves first —
  following a symlink leaf with a bounded plain-`readlink` hop loop, never `readlink -f`,
  which stock Git Bash does not reliably provide — and judges on the result, in the
  relative path form as well as the absolute one. The lexical `<root>/.agents/` test
  survives **only** as the resolution-failure fallback, and not even then for a symlink
  leaf, which is refused as unverifiable. Do not reintroduce it as a fast path: it is
  self-reachable escalation, because `ln -s ../src/util.ts .agents/link.txt` is itself a
  permitted write (at judgement time that path is not yet a link).

`hooks/session-start.sh` clears a session's own mark on `startup|resume`;
`hooks/driver-mode-compact.sh` fires on `compact` only (Result 2) and reminds the
compacted session to re-`Read` `agents/loop-driver.md`. A mark left by a session that
crashed is **inert** — it is keyed to an id nothing will use again, and reopening that
session clears it.

### Run directories, the routing log, and script-written result files

`runstate.sh begin-run` mints a sortable `run_id` into run-state **only when absent**, so
a resume keeps it and a run spans sessions, and creates `.agents/loop/<run_id>/`.
Cleanup keeps the current run's directory and the **single newest other one**, and only
removes directories matching the minted `YYYYMMDDTHHMMSS-<hex>` shape — anything else
under `.agents/loop/` is operator scratch this command does not own. Both `.gitignore`
files ignore `.agents/loop/` and `.agents/driver-mode/`: untracked is **not** enough,
because `git stash --include-untracked` (the pause path) would sweep the run's own files
and `reconcile` would read them on the green checkpoint as scratch to discard.

`runstate.sh route` appends one record per verdict to
`.agents/loop/<run_id>/routing.jsonl` — again a **new** log rather than the outcomes
one, for the `kind` reason above — and prints one action: `pass` → `land`; `fix` →
`attempt` while attempts remain, else `decider`; `retry` → `attempt` while attempts
remain, and **past the limit it is refused as `stop`** carrying a blocking question that
names the over-limit `retry`, never looped; `escalate` → `decider`; `reorder`,
`append-task` and `hand-off-feature` → `discard-advance`; `ask-operator` → `stop`.
Attempts count `fix` and `retry` since the packet's latest `start` record — a
*continuation* deliberately does not reset the count — against `packet_attempts` in
`.agents/project-overrides.yaml`, which is 1 when missing, invalid or 0. A record is
written even for `stop` and `decider`, which is what lets `run-digest` see every decision
and lets `handoff` refuse a packet already routed `hand-off-feature` in this run.

> **Amended 2026-09-22 (`implementer-continuation`), not rewritten.** The tokens this
> paragraph enumerates are no longer the whole set: `route` takes a ninth, `continue`,
> the implementer's own, which routes to a continuation of the same packet. See the
> 2026-09-22 amendment at the end of this ADR.

`runstate.sh write-result` is **the one write a read-only-tooled agent gets**. It refuses
any path resolving outside the current run directory (lexically, before touching disk)
and writes the status line as the file's first line, followed by stdin. That is what let
the reviewer, researcher and chief-engineer take on result files while gaining **no**
`Edit` or `Write` tool — read-only still means read-only — and what lets the driver
assemble a report from first lines without ever opening a result body.

### The interim decider, and what `escalation-decider` replaces

**Superseded in place (2026-09-21).** `escalation-decider` shipped (`8d8bb3e` the
decision log, `251795b`/`62be31b`/`e996163` the contract in `agents/chief-engineer.md`,
`23bffc2`/`7763178` the two driver surfaces). What follows is the arrangement as it now
stands; the two paragraphs this section carried on 2026-09-16 are kept, marked, at the
end of it, as the record of what was true on that date.

`route` still maps `escalate` and an exhausted `fix` to `ACTION=decider`, and the driver
still passes the returned token straight back to `route`. What changed is who answers.
The `chief-engineer`, in its loop role, **is** the escalation decider, under a contract
that is its own two sections — §Escalation decider and §Periodic review — rather than
its general judgment. It is dispatched with the handoff path, the review path and the
`ATTEMPTS=`/`LIMIT=` the same `route` call printed, and nothing else; it reads that
packet's files, the findings naming the packet, and what its triggers test, and no other
packet's files. The five triggers each exclude the others, and when more than one fits
the first of `ask-operator` → `hand-off-feature` → `append-task` → `reorder` → `retry`
wins; the only judgment call is `ask-operator`'s catch-all. Its authority is a closed
list of `runstate.sh` calls plus an `architect` it dispatches, because it holds no
`Edit`/`Write`: `reorder-pending` for a `reorder`, that architect appending one unchecked
task (committed on its own path with the `[orch decider:<packet-id>]` trailer, as before,
so `discard-advance` keeps it) then `reorder-pending` for an `append-task`, and
`amend-handoff` — its one write into a handoff file — for a `retry`, which `route` still
refuses past the attempt limit rather than trusting the decider. Each of those three
lands an `add-finding` naming the packet and a `record-decision` before the status line
returns; `ask-operator` and `hand-off-feature` record a decision and change nothing else
on disk.

The decision records live where the 2026-09-16 text required: **outside
`.agents/loop/`**, in a third log, `.agents/metrics/decisions/<session>.jsonl`, written
only by `record-decision` and `record-review`. It is outside the run directory because
`begin-run`'s prune would remove it two runs later, and outside the outcomes log for the
same reason the mark's enter/exit records are: `_rs_open_packets` reads any record
carrying `packet` and a non-empty `kind` as a packet boundary, and these carry
`kind: decision` / `kind: review`. Every record is stamped with `run_id`, since the log is
session-keyed and a session outlives a run. `run-digest` reads it for its `review` line
and for one `decision` line per review routing, and reports a packet's own decision once
— from the `routing.jsonl` record the driver wrote — treating the decider's record as the
audit copy.

The same agent also runs a **periodic review** of the findings index, dispatched by the
driver between packets and never while one is open, when `runstate.sh review-due` prints
`DUE=yes` (2 non-green endings or 10 beginnings since the last `record-review`, or either
count `unmeasured`). It merges duplicates only through the lossless `merge-findings`,
routes findings that propose work through the two arms and drops them as the capture,
and drops anything else only on `findings --stale --finished` evidence — the terms are
[ADR 0024](0024-findings-are-packet-scoped-and-expire.md)'s amendment of the same date.
Its `record-review` is its last write and the record that resets `review-due`'s count; a
review cut short leaves none and runs again at the next boundary.

> **As written 2026-09-16, superseded above.** There is no escalation decider yet, so
> `agents/chief-engineer.md` carries an interim stand-in section and `route` maps
> `escalate` and an exhausted `fix` to `ACTION=decider`. The stand-in decides with its
> existing judgment — **not** the decider's exclusive triggers or their precedence, which
> this feature deliberately did not build — and returns one of `retry`, `reorder`,
> `append-task`, `hand-off-feature` or `ask-operator` as its status, which the driver
> passes straight back to `route`. It returns `retry` only while an attempt remains;
> `route` refuses one past the limit rather than trusting that. An `append-task` line
> (ADR 0026 arm 1) is written by an architect it dispatches and committed on its own
> paths with an `[orch decider:<packet-id>]` trailer *before* the token returns, so the
> `discard-advance` that follows keeps it. When `escalation-decider` ships it replaces
> **that section of `agents/chief-engineer.md` and the one dispatch line in
> `skills/run-loop/SKILL.md`** — and it must keep its own decision records **outside
> `.agents/loop/`**, which `begin-run`'s cleanup removes.

### One contract widened elsewhere

A handoff file has to say what "done" means for its task, which for a capability-level
PRD lives one level below the checkbox. ADR 0020's consumed contract therefore widens by
exactly one thing — a capability's indented acceptance-criteria sub-bullets — read only
by `gspec-backlog.sh handoff`. That decision, and why completion is still derived from
the checkbox alone, is recorded where it belongs, in
[ADR 0020](0020-gspec-boundary-and-version-pin.md) D2's own amendment.

## Amendment (2026-09-20) — a status line is refused by a subcommand, and one routing record is not a verdict

`loop-driver-run-gaps` T1–T5 landed (`d724c0b`, `1bf43eb`, `1d79001`, `f9249c0`,
`ee8b869`). Two statements in the 2026-09-16 amendment above are now incomplete. This
section amends them; it does not rewrite them, and the text above stands as the record
of what shipped on that date.

### "writes the status line as the file's first line" described a write nothing checked

"Run directories, the routing log, and script-written result files" says `write-result`
"writes the status line as the file's first line, followed by stdin" and that the driver
assembles a report "from first lines without ever opening a result body". Both were true,
and both rested on a status line whose one-line grammar (`templates/status-line.md`) was
prompt-enforced only: nothing refused an off-grammar line, so a multi-line or field-less
reply was written as the first line of a result file, or routed on, and only the reviewer
caught it — as a `fix`, one packet later.

**Now `runstate.sh check-status --status '<line>'` is the one mechanical reading of that
grammar.** It accepts a line exactly when it is one line (a CR counts as a break)
containing no backtick and no `$`, its first field (everything before the first ` · `)
is one word, the field between its second-to-last and last ` · ` is literally
`result: needs-reading` or `result: no`, and its last field (everything after the last
` · `) is non-empty and whitespace-free. Otherwise it exits non-zero and prints **one
reason naming the rule that failed** — never a generic "malformed status line", because
the driver's only move on a refusal is to hand that reason back. The boundaries come
from the first and last separator and never from a field count: the two middle fields
are free text and may carry their own ` · `, which the template explicitly permits, so a
four-way split would refuse a well-formed line.

`route --status` and `write-result --status` run the same check **first, before either
touches disk** — before the routing record is appended, before the run directory is
created, before the result file is written — and refuse with the byte-identical reason
(one `die` path, no per-caller prefix). A refused line therefore leaves `routing.jsonl`
byte-unchanged and creates no result file; the "one write a read-only-tooled agent
gets" is now a write that can be refused on its content's shape as well as its path.

The driver's rule is stated on both of its surfaces (`skills/run-loop/SKILL.md` §3 step 4
and the Routing section of `agents/loop-driver.md`): run the check on **every** returned
line, including one nothing routes on; on a refusal re-dispatch the same agent **once**,
passing the printed reason and nothing else; on a second refusal, a line the driver does
not route on proceeds to the reviewer dispatch as before, and a line the driver would
have routed on (the reviewer's verdict, the decider's token) is escalated as a blocking
question naming the agent and the reason. The driver never substitutes a line of its
own. The check reads shape, never truth — a well-formed line that is wrong is still the
reviewer's `fix`, and that content gate is unchanged.

> **Amended 2026-09-22 (`implementer-continuation`), not rewritten.** "A line the driver
> does not route on proceeds to the reviewer dispatch as before" no longer covers the
> implementer's own line: the driver now routes on its first token, so a twice-refused
> implementer line is escalated rather than passed to the reviewer. See the 2026-09-22
> amendment at the end of this ADR.

### "`route` appends one record per verdict" is now one per verdict plus at most one per run that is not

> **Retired 2026-09-22 (`chore/retire-adr0026-routing`), not rewritten.** The end-of-run
> architect dispatch this section's record exists for is deleted, so `run-loop` §4 writes
> **no** `end-of-run-review` record and the routing log is back to one record per verdict,
> each keyed to a packet id (plus the `continue` records the 2026-09-22
> `implementer-continuation` amendment adds). `scripts/runstate.sh` is unchanged — the id
> was never special-cased there — and the driver instead records one finding per note the
> whole-branch review's status line reports. See
> [ADR 0026](0026-post-completion-findings-route-by-scope.md)'s 2026-09-22 amendment. The
> text below stands as the record of what shipped on 2026-09-20.

The same section fixes the routing log's shape as "one record per verdict", each keyed
to a packet id. That is still every record the packet loop writes. **At termination,
`run-loop` §4 now writes one more**, under the fixed id `end-of-run-review`: when the
end-of-run architect's status line reports an ADR 0026 arm-2 proposal in its free-text
clause — judged by the driver from the line it already relays, with no new status token
— the driver calls `route <run-state> end-of-run-review hand-off-feature --status
'<that line>'`. The id names the run's termination review and is not a packet: it fits
the packet-id charset, reads as a title in the stop report, and cannot collide with a
packet because every gspec-sourced id is `<slug>-t<n>`. The call prints
`ACTION=discard-advance`, and that action is **not acted on** — there is no packet to
discard and no cursor to advance at termination; the record is the whole purpose of the
call.

**No outcome is recorded for the id, and the record may never go to the outcomes log.**
The id has no handoff file and no start record, `record-outcome` is never called for
it, and it earns no `packet` line in the digest. Every record in the outcomes log is
packet lifecycle to its readers, and this is not a packet; it lives in `routing.jsonl`,
kept out of the outcomes log for the same reason the mark's enter/exit records are
(those go to `.agents/metrics/driver-mode/<session>.jsonl`, as the 2026-09-16 amendment
above states). Ordering is load-bearing: the
record must land **before the stop report reads `run-tally`**, which is what counts it
— recorded after that read, the report printed `DECISIONS=0` beside a rendered decision
block, the defect T5 closed. `run-digest` then emits one `handoff-feature` line for the
id carrying the architect's status line; `run-tally`'s `DECISIONS` includes it once, the
existing dedup of a handed-off packet's own decision line unchanged. An architect that
routed everything to arm 1, or found nothing to route, records nothing and changes no
figure. ADR 0026 carries the matching revision from the arm-2 side; the operator gate it
states is untouched — the record counts the proposal, and nobody in the run files it.

### One consequence for `begin-run`'s "only when absent"

`begin-run` minting `run_id` only when absent is what lets a run span sessions, and it
is also what makes a packet-close `write` that drops the key silently expensive: nothing
fails at the write, `run-digest` refuses for the rest of the run, and the next
`begin-run` mints a second id and a second run directory, orphaning this run's handoff
files, result files and routing log. `run-loop` §3.6 therefore enumerates the keys a
close must carry through the whole-file write (`loop-driver-run-gaps` T4): `schema`,
`run_id`, `branch`, every `driver_*` key present, `status: running`,
`pending_questions` and the `findings:` block, each copied from the on-disk file being
replaced. That is a loop-prose decision rather than one of this ADR's, and is recorded
here only because the minting rule above is why it matters.

## Open probe (2026-09-21) — can a plugin supply a compaction-window default without overriding a repository or operator value?

Result 3 lists four things it did not probe. This section takes up **exactly one** of
them — the third, *whether a plugin can supply a default without overriding a repo or
operator value* — and leaves the other three (precedence between the variable and a
settings key; the user and committed-project scopes; reading the value in effect other
than from the settings files) exactly as open as result 3 left them. It is a
**procedure and a blocking question for the operator, not a result**: the probe needs
live sessions in which a person reads `/context`, which an unattended packet cannot
produce — the same was true of the four sessions in Method. The answer lands beneath
this section as a dated amendment (`driver-context-window-default` T5) and revises
nothing above it; result 3's text and its not-probed list stand as written.

### The question, stated so that a negative reads as an answer

Does any carrier a plugin can ship cause the harness to use the plugin's value as the
auto-compact window **only when** no repository or operator scope carries
`autoCompactWindow`, and to defer to that value whenever one does? The second half is
not optional: a "default" that wins over a repository value is an override, and a
carrier that is inert both ways is not a carrier. Either is *no*, and *no* is recorded
as the answer — `runstate.sh compact-threshold` keeps printing `THRESHOLD=unknown` /
`SOURCE=unknown`, no value enters it, and its header comment stops naming this probe as
outstanding. Nothing in this section presupposes that a plugin carrier exists or that
it does not.

### Carriers to try

What follows was read against Claude Code **2.1.278** as installed here — the strings
its own binary carries, not the documentation — and is a prediction of what each
carrier will do, which the probe turns into a reading. A later version may differ,
which is why the version is a recorded condition below.

1. **A `settings.json` at the plugin root.** The only *file-shaped* carrier that could
   carry the harness's own key (a plugin manifest's `userConfig` surface is namespaced
   under the plugin name, so it cannot). 2.1.278's own list of what it recognises as plugin content at a root is
   `.claude-plugin/`, `commands/`, `skills/`, `agents/`, `hooks/`, `themes/`,
   `output-styles/`, `monitors/`, `workflows/`, `SKILL.md`, `.mcp.json` and
   `.lsp.json`, and the settings scopes it names internally are `userSettings`,
   `projectSettings`, `localSettings`, `policySettings` and `flagSettings` — no plugin
   settings scope among them. So the expected reading is *inert in both arms*; that
   expectation is not the answer, the reading is. Try it first, because if it works it
   is the only carrier whose value the harness would attribute itself.
2. **A `SessionStart` hook that writes the key.** The plugin's `hooks/hooks.json` can
   register a `startup` hook that inserts `"autoCompactWindow": <n>` into
   `.claude/settings.local.json` when no scope carries the key. This is a *mechanism*
   rather than a carrier: it "does not override" only by checking first; it turns a
   plugin default into an entry the reader reports as `SOURCE=operator`, misattributing
   provenance; and it writes a settings file, which `compact-threshold` is built never
   to do. Try it only if carrier 1 reads inert in arm B, and record a *yes* through it
   as "yes, by writing the operator's file" — which the PRD's deferred decision then
   weighs as a separate feature, not as this probe closing the gap. **Its arm B is
   taken in two consecutive fresh sessions**, because the carrier is not in place until
   its own startup hook has run inside the session being measured, and a settings
   value is what the harness reads at its *next* session start (the assumption
   `compact-threshold`'s header states): the first session is the one whose hook
   writes the key, the second starts with the key already on disk. Both readings are
   recorded. A value present only in the second is a distinct reading — "yes, from the
   next session onward, by writing the operator's file" — still the separate-feature
   case above, never carrier 1's yes; the control value in *both* sessions is inert →
   no. Its arm A needs one session: the hook checks first, so 100k persists.

**Not a carrier: `CLAUDE_CODE_AUTO_COMPACT_WINDOW`.** A hook is a child process, so
nothing it exports reaches the session that spawned it; a plugin cannot set the
variable for a session, and probe D already read it as the *operator's* carrier. Every
session below runs with it **unset**, so each reading is about the settings files and
not the variable — and so that this probe does not quietly answer the precedence item
it is not asking.

### Values, chosen so the number says whose value won

Three distinct numbers, none equal to any model's own default: the repository/operator
`autoCompactWindow` at **100000** (the value probe D used), the plugin default at
**150000**, and the model's own reading from a plain session as the **control**.
Distinctness is the whole attribution: `/context`'s `Auto-compact window:` line labels
its source only as one of five — `(from settings)`, `(from
CLAUDE_CODE_AUTO_COMPACT_WINDOW)`, `(default for this model)`, `(default for an
unrecognized model)` or `auto` — and it never names *which* settings scope, so only the
number can say which value is in effect. The control on a recognised model is expected
to carry `(default for this model)`; result 3's `1m tokens` on Opus 5 (1M) is that
case, not the unrecognized-model one.

### The two arms, and what each reading means

Each session is fresh (`claude` from the repository root, never `--resume`), with the
plugin enabled and the carrier under test in place; run `/context` once and copy the
`Auto-compact window:` line verbatim.

- **Arm A — plugin default with a repository or operator value present.**
  `"autoCompactWindow": 100000` in `.claude/settings.local.json` (the scope result 3
  verified), plugin carrier at 150000. Reads `100k tokens (from settings)` → the plugin
  does not override. Reads `150k` → it overrides → **no** for this carrier, and arm B
  need not run for it.
- **Arm B — plugin default with neither set.** No scope carries the key (user,
  project and local files checked, no managed settings present), the variable unset,
  plugin carrier at 150000. Reads `150k tokens (from settings)` → the plugin's value is
  in effect when nothing else is. Reads what the control read → the carrier is inert
  → **no** for this carrier (for carrier 2, only when both of its consecutive
  sessions read the control value — see the two-session rule under carrier 2).
- **Control — plugin disabled, nothing set.** The model's own reading (result 3 saw
  `1m tokens` on Opus 5 (1M)). Recorded so arm B's "unchanged" is a comparison with
  something measured under the same conditions, never with result 3's line.

**Yes** requires both: arm A shows 100k *and* arm B shows 150k, for the same carrier,
in the same harness version, on the same model. Any other combination is **no** for
that carrier, and no for every carrier is the answer *no*. In each session also run
`runstate.sh compact-threshold` and record its triple: it is expected to read
`THRESHOLD=100000` / `SOURCE=operator` in arm A and `unknown` in arm B *whatever
`/context` says*, because the reader reads no plugin carrier by design — a *yes* would
make changing that a separate decision (the PRD's deferred one), never a reader change
made on the strength of this probe.

### Conditions every reading is recorded under

Each reading — both arms and the control — carries all of the following, and one
missing any of them is re-taken rather than recorded:

- the **harness version** (`claude --version`; 2.1.278 when this section was written)
  — the plugin-content list and scope names above are this version's, and a carrier's
  fate may differ on another;
- the **model** the session ran on, from `/context`'s header or the `SessionStart
  startup` payload's `model`. Result 3's `1m tokens` was taken on Opus 5 (1M) and was
  then treated as harness-wide: it became an invented `200000` default in the reader,
  which `thin-loop-driver-gaps` T6 removed. A plugin value that appears on one model
  and not another is a *no*, not a yes with a caveat;
- **which of the five settings scopes carried `autoCompactWindow`** (user
  `~/.claude/settings.json`, project `.claude/settings.json`, local
  `.claude/settings.local.json`, managed/policy, flag) and with what value, plus that
  the environment variable was unset;
- the **carrier tried** and the plugin's **enabled state and where it was enabled** —
  this repository's committed `.claude/settings.json` sets
  `"gaffer@gaffer-marketplace": false` today, so a probe session must enable it
  explicitly and say in which scope;
- the **`/context` line verbatim**, parenthetical source label included, and the
  **`compact-threshold` triple** from the same session.

### Blocking question for the operator

The sessions are the operator's to run: arms A and B and the control against carrier
1, then carrier 2 only if carrier 1 reads inert in arm B, each reading returned with
its conditions. T5 records them beneath this section, dated, as an amendment — a
negative as the answer, never as a failure to answer. Until then the capability stays
unchecked, which is its intended state and not a stall.

## Amendment (2026-09-21) — the plugin-default probe, answered: no

The operator ran the procedure above on 2026-09-21 and returned three readings. This
section records them and the answer they give. It revises nothing above it: result 3,
its not-probed list, and the open-probe section (its predictions included) stand as
written, and where a reading contradicts a prediction that is stated here rather than
corrected there.

### Conditions shared by all three readings

- **Harness:** `2.1.278 (Claude Code)`.
- **Model:** Opus 5, in all three sessions.
- **Sessions:** each a fresh `claude` from the repository root, never `--resume`.
- **Environment variable:** `CLAUDE_CODE_AUTO_COMPACT_WINDOW` unset.
- **Settings scopes:** no managed/policy settings; user `~/.claude/settings.json` and
  committed-project `.claude/settings.json` carry no `autoCompactWindow`; local
  `.claude/settings.local.json` carries it only in arm A, as stated there.
- **Plugin enabled state:** the committed `.claude/settings.json` sets
  `"gaffer@gaffer-marketplace": false`, so "enabled" below means launched with
  `--plugin-dir .` — a command-line flag, not any of the five settings scopes. The
  plugin root is therefore the repository root.
- **Carrier tried:** carrier 1 only — a `settings.json` at the plugin root containing
  `{"autoCompactWindow": 150000}`.

The test files were removed afterwards: no root `settings.json`, and no
`autoCompactWindow` in `.claude/settings.local.json`.

### The readings

1. **Control** — plugin disabled (no `--plugin-dir`), no scope carrying the key.
   `/context`: `Auto-compact window: 1m tokens`.
   `compact-threshold`: `THRESHOLD=unknown` / `SOURCE=unknown` / `APPLIED=no`.
2. **Arm B, carrier 1** — plugin enabled, plugin-root `settings.json` at 150000, no
   other scope carrying the key.
   `/context`: `Auto-compact window: 1m tokens`.
   `compact-threshold`: `THRESHOLD=unknown` / `SOURCE=unknown` / `APPLIED=no`.
3. **Arm A, carrier 1** — plugin enabled, plugin-root `settings.json` at 150000 kept,
   `"autoCompactWindow": 100000` in `.claude/settings.local.json`.
   `/context`: `Auto-compact window: 100k tokens`.
   `compact-threshold`: `THRESHOLD=100000` / `SOURCE=operator` / `APPLIED=no`.

### The answer: no

**Carrier 1 is inert.** Arm B read the control's value, `1m tokens`, and not the
plugin's 150k — the "reads what the control read" case, which the section above names
**no** for this carrier. Arm A read 100k, so the plugin value did not override the
operator's; for a carrier already inert in arm B that half is moot, since a carrier
that does nothing in either arm is not a carrier. On 2.1.278 a root `settings.json` is
read in neither role: not as project settings (those live under `.claude/`), and not as
plugin settings (the version has no plugin settings scope, as the carrier-1 prediction
expected from the binary's own scope list).

**Carrier 2 (a `SessionStart` hook writing the key) was not tried — the operator's
decision, not a failed attempt.** The section above already classes any *yes* through
it as "yes, by writing the operator's file", which the PRD's deferred decision weighs as
a separate feature rather than as this probe closing the gap; so no reading through it
could have changed this answer. It is recorded as **not tried**. With the only carrier
that could have closed the gap inert, the answer to the question this probe asked —
can a plugin supply a compaction-window default without overriding a repository or
operator value — is **no**, on 2.1.278, on Opus 5.

This is the answer, not a failure to answer. It changes no code:
`runstate.sh compact-threshold` reads no plugin carrier, keeps printing
`THRESHOLD=unknown` / `SOURCE=unknown` when neither a repository nor an operator value
is set, and no value enters it on the strength of this probe. Both `compact-threshold`
triples above are what the section predicted "whatever `/context` says". Its header
comments no longer name this probe as outstanding; they still name the operator-over-
repo precedence as documented and unverified, and the user and committed-project scopes
as unprobed — the three result-3 items this probe did not take up are as open as before.

### Where a reading contradicts a prediction above

**No source label appeared on any `/context` line** — not `(from settings)` in arm A,
not `(default for this model)` in the control. The claim above that the line labels its
source as one of five parentheticals does not hold on 2.1.278 as observed; attribution
here rests on the distinct numbers alone (100k, 150k, and the control's 1m), which the
section's choice of values already allowed for. A later version that does print the
label should not be read as contradicting these readings.

### Limits of this answer

- **One harness version, one model.** Taken on 2.1.278 and Opus 5 only; a later version
  that adds a plugin settings scope, or a different model, is not covered, and a reader
  change on the strength of such a version is a new decision, not this record.
- **Plugin activation was inferred from the launch, not independently observed.** The
  readings record `--plugin-dir .` as the enabling condition; they do not record a
  separate check (for example `/plugin` output) that the plugin was loaded in the arm
  sessions. The carrier-1 result agrees with the binary's own scope list, so the answer
  does not rest on activation alone, but a re-take that wants to rule this out should
  record that check.

## Amendment (2026-09-22) — `route` has a ninth token, and the implementer's line is read before the reviewer

`implementer-continuation` T1–T7 landed (`55942e1`, `961d834`, `8e60268`, `120e348`,
`7a969a4`, `397b2cd`, `fd75a10`). Two statements in the amendments above are now
incomplete: the 2026-09-16 section's enumeration of the tokens `route` maps, and the
2026-09-20 section's rule for a line `check-status` refuses twice. This section amends
both — each is marked in place above — and rewrites neither; that text stands as the
record of what shipped on those dates.

### The ninth token is `continue`, and it spends no attempt and reaches no reviewer

Nothing bounded how long an implementer dispatch ran. The cap is cooperative, in the
shape [ADR 0017](0017-graceful-cooperative-pause.md) gave the pause: the authoritative
stop is something the agent does at a safe boundary because its handoff told it to.
`runstate.sh handoff` therefore writes one budget line for `--agent implementer` and for
no other agent, stating the budget in tool calls (`implementer_turn_budget` in
`.agents/project-overrides.yaml`) and the rule at it — stop at a safe boundary and never
mid-edit, leave the partial work uncommitted, write what is done and what remains to the
result file, and return a status line whose first token is `continue`.

`route` accepts `continue` as its ninth token and maps it to `ACTION=continue`. Two
properties of that arm are load-bearing:

- **A continuation spends no attempt.** `ATTEMPTS=` prints the packet's live attempt
  count and is never incremented, and the attempt pool counts `fix`/`retry` tokens only,
  so a `continue` record never enters it. Otherwise three stops at the turn budget would
  exhaust a packet's attempts without a single review having happened.
- **No reviewer is dispatched and no verdict is recorded for it.** A continuation is the
  same dispatch carried on, not an attempt that ended; there is nothing yet to judge, and
  the tree it would be judged on is deliberately red.

Continuations are capped **per attempt**: the count is the packet's `continue` routing
records since the later of its latest `start` record and its latest routing record whose
action was `attempt`, against `packet_continuations` in `.agents/project-overrides.yaml`.
So each fresh attempt gets a fresh allowance, and the two windows stay apart — a
`kind: continue` record never moves the attempt boundary, and an `attempt` resets only
the continuation count. Past the cap, `continue` refuses as `ACTION=stop` with a
`question:` line naming the packet and the cap, its record carrying action `stop`; it is
never routed as `attempt` and never looped, for the reason an over-limit `retry` is not.
Every `continue` record carries the same fields as any other routing record — timestamp,
packet, token, action and status line — and no path.

### The driver reads the implementer's line before any reviewer dispatch

The 2026-09-16 arrangement had the driver dispatch the reviewer on every implementer
return. Both driver surfaces (`skills/run-loop/SKILL.md` §3 steps 4–5 and the `Routing`
section of `agents/loop-driver.md`) now read and `check-status` the implementer's line
**first** and branch on its first token: `continue` goes straight to `route` with that
line as `--status`, and any other first token proceeds to the reviewer exactly as before.

On `ACTION=continue` the driver does three things, in this order: `record-start
"$MEMBERS" --continue`, then `refresh-handoff` for the packet, then dispatch a fresh
`implementer` with that same handoff path and **no review path**. `route`'s own record is
already on disk — it was written when the call printed `ACTION=continue` — and it is what
distinguishes a continuation from a resume for a reader joining the two logs. The order
of those three is the point: dispatching before `refresh-handoff` briefs the
continuation without the partial work the refresh exists to carry on from.

### The twice-refused rule now names the implementer's line

Because the driver routes on that line, it is a line the driver *would have routed on* in
the 2026-09-20 rule's sense. The enumeration there — the reviewer's verdict, the
decider's token — widens on both surfaces to include the implementer's own line: a line
`check-status` refuses twice is escalated as a blocking question naming the agent and the
printed reason, and is **never passed to the reviewer**. The single re-dispatch on the
first refusal, and the rule that the driver never substitutes a line of its own, are
unchanged.

### What counts the refusal, and what counts nothing

An in-cap `continue` moves no reported figure: it changes neither `run-digest`'s
`decision`/`handoff-feature` lines nor `run-tally`'s `DECISIONS`. A `continue` refused
past its cap is a question still awaiting an operator, so `run-tally` counts it in
`DECISIONS` on the same still-live rule as a `retry` past its attempt limit — which is
what keeps the header figure equal to the number of 🔀 blocks in the report.

### The handoff is rewritten in place, by splicing

`runstate.sh refresh-handoff <run-state> <packet-id>` replaces, inserts or removes **one**
marked `## Partial work on disk` block in that packet's `handoff.md` and leaves every
other byte alone. It is run by the driver before a continuation and before **every**
`fix`/`retry` re-dispatch, and never by `handoff` itself, so a packet's first dispatch
never carries the block however dirty the tree is.

It splices rather than regenerates for the reason `amend-handoff` does, plus one this
feature adds: a continuation can follow a decider `retry`, and rebuilding the file
through `handoff` would silently drop that `amend-handoff` block — the retry instruction
the re-dispatch exists to carry. The set is the paths `git status --porcelain` on the
main checkout reports that fall within the packet's scope, read from the `FILES=`/
`BUNDLE_FILES=` lines of its own `handoff.md` — this script's own output, never `gspec/`
— each marked existing or deleted. With no scope the set is bounded to the paths dirty
since run-state's `last_green_commit`, never the whole checkout. An empty set leaves the
file byte-identical to one written without the mechanism, and the listed paths are
written into the handoff only: no routing, outcomes or metrics record names them.
Where the block and the budget line sit relative to the `REQUIRED` block, and why, is
recorded in [ADR 0029](0029-handoff-verification-contract.md)'s amendment of the same
date.

## Relocated from skills (2026-09-25) — the pause skill's driver-mode reasons

Moved out of `skills/pause/SKILL.md` by `skill-prompt-trim`. The skill keeps each
rule with at most a one-clause reason; the fuller wording is recorded here.

- **Why the loop-driver, not the Chief Engineer, runs the pause** (the pause
  skill's preamble):

  > the Chief Engineer is only ever dispatched, per packet, as the interim
  > escalation-decider stand-in.

- **Why the driver may make the pause's work-in-progress commit** (pause step 1):

  > (this is the driver's soft-gate commit — `git commit` is not a write the
  > guard's driver-mode edit block refuses)

- **Why the cursor's handoff exists when the `stop` action reaches the pause**
  (pause step 3):

  > already exists whenever the `stop` action reaches here (it always follows a
  > dispatched packet)

- **Why the stop report reads the whole-run digest** (pause step 4):

  > its `packet` lines name every packet the run began, with its outcome,
  > whichever session ran each one, so this report reads the same right after
  > landing or after a compaction

- **Where the tally figures are counted** (pause step 4):

  > counted by the core from the same whole-run digest with the 🔀 dedup already
  > applied

- **Why a pause exits driver mode** (pause step 4):

  > driver mode ends whenever the loop renders its stop report, whether it
  > stopped, paused, or finished (ADR 0028), and a pause is exactly that: a stop.

## Relocated from skills (2026-09-25) — the resume skill's driver-mode reason

Moved out of `skills/resume/SKILL.md`'s `mode: parallel` stop by `skill-prompt-trim`.
The skill keeps "it is idempotent, and `/gaffer:run-loop` enters driver mode before
redirecting here". It used to read:

> This check runs first, but this session can still reach it already marked —
> `/gaffer:run-loop` §2 enters driver mode before its own redirect to this skill, so
> this stop path may run with a mark already set. `driver-mode exit` is idempotent
> (a no-op if there is no mark), so calling it here is always safe regardless of
> which caller reached this skill.
