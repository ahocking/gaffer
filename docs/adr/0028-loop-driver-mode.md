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

### "`route` appends one record per verdict" is now one per verdict plus at most one per run that is not

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
