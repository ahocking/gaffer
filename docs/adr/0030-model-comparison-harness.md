# ADR 0030 — The model-comparison harness replays landed packets in clones, as its own driver, with one fixed and blinded reviewer

- Status: Accepted
- Date: 2026-09-24
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0028](0028-loop-driver-mode.md) (the `run-loop` §3 sequence,
  `route`, `check-status`, `refresh-handoff` and the routing log that a replay
  walks); [ADR 0029](0029-handoff-verification-contract.md) (the verification
  block a rebuilt handoff carries, and the handoff that names the required
  sweeps); [ADR 0019](0019-run-metrics-observability.md) (the collector, the
  routing stamp and the spend tooling a replay's cost and routing check read);
  [ADR 0017](0017-graceful-cooperative-pause.md) (the pause sentinel `run`
  honours between replays).
- Feature: `gspec/features/model-comparison-harness/prd.md` and its plan. This
  ADR is T18; the mechanism it records landed in T1–T17, T19 and T20.

## Context

`per-agent-model-routing` made `model_routing` in
`.agents/project-overrides.yaml` the repository's routing policy, and left open
which values belong in it. The only evidence was one confounded run, which could
not separate a model effect from a missing test sweep (PRD, Overview).

The harness produces that evidence. It replays packets that already landed, each
from its parent commit. One role's model is varied through `model_routing`, and
one reviewer model stays fixed as the blinded judge. Every replay is recorded,
each packet's final diffs are ranked side by side, and a report proposes a
`model_routing` value that the operator applies by hand, or does not. The PRD
leaves two decisions open, the estimate rule and the results location. The plan
settled both, together with the isolation and driver decisions below. This ADR
records all of them as built in `scripts/compare.sh`, pinned by
`scripts/test-compare.sh`, and driven from the operator's session by
`skills/compare-models/SKILL.md`.

## Decision

### 1. Isolation is a clone, not a worktree

`routing.sh`, `runstate.sh`, the pause sentinel and `hooks/metrics-log.sh` all
find their config root through `git rev-parse --git-common-dir`
(`scripts/routing.sh:90`, `scripts/runstate.sh:2460`,
`hooks/metrics-log.sh:50`). From a linked worktree that resolves to the main
checkout. A worktree replay would therefore read and write the main checkout's
`.agents/` and its routing configuration. That breaks the isolation criterion,
and it breaks "set through `model_routing` in the replay's configuration".

A `git clone --shared` resolves to itself. `prepare` clones the source
repository at the packet's replay start into an opaque directory
`<scratch>/<16 hex>`, where `<scratch>` is the scratch root
(`ORCH_COMPARE_SCRATCH`) and must lie outside the source's working tree. The clone gets one
opaque branch, `replay-<16 hex>`. Every other local branch and the `origin`
remote are deleted, so nothing the clone does can reach the source. The replay
start is the first parent of the packet's earliest `[orch packet:<id>]`
commit. `prepare` then sets `model_routing` in the clone's own
`.agents/project-overrides.yaml`, and `routing.sh --root <clone> resolve` must
print the configured models, or `prepare` refuses. The main checkout's tree,
`.agents/` and refs are unchanged by construction. The one exception is the
experiment's store (§6).

### 2. The harness is its own driver, and every agent step is a headless session in the clone

An agent dispatched from the operator's own session would be stamped by
`hooks/metrics-log.sh`, and the stamp would carry the operator checkout's
routing. The hook resolves its root from the session's working directory
(`hooks/metrics-log.sh:50-54`). It stamps `routing_resolved` from
`routing.sh --root <that root> resolve` (`hooks/metrics-log.sh:189-212`). The
collector counts a dispatch whose passed model differs from that stamp in
`audit.dispatches_with_model_override`. So a replay's model, passed from the
operator's session, would read as an override of the main checkout's routing,
and the replay would fail its own routing check. The PRD also requires the
varied model to be set through `model_routing`, and never passed per dispatch.
There is a second reason. The reviewer cannot run in a checkout whose
`.agents/project-overrides.yaml` names the subject model (§4).

So `compare.sh replay` drives the replay itself. Every agent step is a separate
non-interactive session, time-limited by `ORCH_COMPARE_STEP_TIMEOUT`, with stdin
from `/dev/null` (`run_session` in `scripts/compare.sh`). Its working directory is the
work clone for the varied role, or a review view for the reviewer. The session
dispatches the step's agent once, with the model that
`routing.sh --root <dir> resolve <agent>` prints. `ORCH_COMPARE_CLAUDE` names
the executable, so the sweep runs every step through a stub and needs no live
agent.

Every session is launched with `--plugin-dir <harness checkout>`, and every
script is invoked from the harness checkout with `--root <clone>`. The clone
supplies only the working tree and the `.agents/` configuration. In this
repository, a clone at a parent commit carries older copies of `agents/`,
`hooks/` and `scripts/`, or none. Its committed `.claude/settings.json` also
disables the plugin. A session that is not pinned to the harness checkout would
run the old loop, or no loop at all.

Every session `run_session` starts (each replay step, each review view and each
`rank` session) runs with `--permission-mode bypassPermissions`. A headless
`-p` session has nobody to answer a permission prompt. A call that reaches one
is refused, as a real `claude -p` session's refused edit shows (the evidence
paragraph below), or the step stalls until its time limit. Either way the
replay measures the harness, not the model.

A working directory is not a confinement: a bypass-mode session can write
anywhere its user can. So `run_session` also gives each session `--settings`
(`confine_settings` in `scripts/compare.sh`) with two parts, each bound to that
session's clone or view, resolved physically (the root below):

- **Claude Code's OS-level Bash sandbox**, on, with filesystem writes allowed
  only in the root and in the session's own temp directory, the two paths its
  `allowWrite` names. `failIfUnavailable`
  makes a session whose sandbox cannot start exit instead of running
  unsandboxed, so its step reads as a crash. `allowUnsandboxedCommands: false`
  removes the retry outside the sandbox, which the bypass mode would otherwise
  approve. The sandbox is meant to confine a shell write however it is made (a
  script, an interpreter's own file calls, `git -C`). It covers `Bash` alone.
- **A harness-owned `PreToolUse` hook**, `scripts/compare-confine.sh <root>
  <tmp>`, on `Edit`, `MultiEdit`, `Write`, `NotebookEdit` and `Bash`. It is the
  only confinement of the file tools, and a first line for the shell writes it
  recognises. It refuses a write whose target does not physically resolve
  inside the root or the session's temp directory, following symlinks and refusing a file with a second hard
  link. It also refuses, failing closed, a target it cannot resolve (a
  variable, a `..` segment, a construct that can hide a write). Inside the
  root, it refuses the paths Claude Code loads configuration and code from:
  `.claude` and its settings files, its `skills`, `agents`, `commands`, `hooks`
  and `workflows` trees, and `.mcp.json`. It is not registered in
  `hooks/hooks.json`, so the live loop never runs it. `disableAllHooks: false`
  in the same settings is meant to outrank a replayed repository's own.

**One write boundary for both halves.** The hook and the sandbox allow the same
two places, so a write is allowed by both or refused by both. A write only one
of them allowed would be a false result either way: an ordinary scratch file
the sandbox allows would be scored as a denial if the hook refused it. So
`run_session` makes each session its own temp directory before launch
(`session_tmp`): a fresh `mktemp -d` directly under `/tmp`, taken physically,
mode 0700, outside the clone or view, the source checkout and the harness's main
checkout. If it cannot be made there, the session is not started, and the step
reads as a crash. The session gets it as `TMPDIR` and `CLAUDE_CODE_TMPDIR`, the
sandbox gets it as the second `allowWrite` entry, and the hook gets it as its
second argument: all the same string. It is removed when the session ends. Any
other temp directory is outside both halves: another session's, a bare `/tmp`
path, or Claude Code's shared `/tmp/claude-<uid>`. A temp directory the hook is
given but cannot use makes it refuse every write, the root's included.

It is `/tmp`, not `$TMPDIR`, and `CLAUDE_CODE_TMPDIR` as well as `TMPDIR`,
because of how Claude Code 2.1.281 places a sandboxed command's temp directory.
That was read from its installed binary on 2026-09-24, and the live probe
(below) observed it on 2026-09-25. The directory is `${CLAUDE_CODE_TMPDIR:-/tmp}/claude-<uid>`, so without
`CLAUDE_CODE_TMPDIR` it would be one directory shared by every session of the
user, which the sandbox allows and the hook refused. When that path is longer
than 44 bytes, Claude Code falls back to the shared `/tmp/claude-<uid>`, and
a macOS `$TMPDIR` path is already that long. The sandbox runtime's own
environment also sets `TMPDIR` from `CLAUDE_CODE_TMPDIR`. Both places lie inside
the session's temp directory.

`--plugin-dir` also loads the harness's `hooks/guard.sh`, whose hard deny is a
`PreToolUse` hook's exit 2, not a permission prompt. A refusal by the hook or
the guard is a denied call like any other, so the replay is scored `invalid`
(below). A write the sandbox blocks fails inside its command instead, and its
transcript records no denied call (observed by the live probe below), so it
does not make the replay `invalid`.

**The residual risk.** A live probe on 2026-09-25 (Claude Code 2.1.281, below)
confirmed four of the five things this paragraph left unconfirmed, in
bypass-mode `claude -p` sessions. A hook's exit 2 is honoured in that mode. The
sandbox starts and confines there: a `python3` write outside the clone, which
the hook does not see, failed with `Operation not permitted`.
`disableAllHooks: false` outranks project settings: with `disableAllHooks: true`
in the clone's `.claude/settings.json`, the confinement hook and the guard both
still refused. A sandboxed command's `$TMPDIR` lies inside the session's temp
directory: it read `<tmp>/claude-<uid>`, and a write there was not denied. The
fifth is confirmed in part. After a `Bash` call ran `cd` out of the clone,
Claude Code reset the shell to the clone, so the next relative write landed
inside it. Whether the hook's payload `cwd` follows a `cd` between directories
inside the root is still unobserved; the sandbox would bound a misplaced
relative write there, and it keeps Claude Code's configuration paths from
`Bash` either way. Four gaps are known and left open:

- MCP tools are confined by nothing the harness adds. A session loaded
  through `--plugin-dir` has the harness's `.mcp.json` servers (`git`,
  `filesystem`, `github`), and only their own scopes limit them.
- Network access is not restricted.
- The sandbox's write list can be widened by entries already in a replayed
  repository's committed `.claude/settings.json` or in the operator's own
  user settings. The hook stops a session from writing those files, but it
  cannot undo entries that are already there. This comes from Claude Code's
  settings documentation, not from an observed run.
- **The harness's own steps are not sandboxed** (T26 leaves this open). A
  session can plant a git setting (`core.fsmonitor`, `core.hooksPath`, a
  filter or diff driver) or a symlink inside its own clone. The harness's own
  unsandboxed steps later act on that clone (`land_tree`'s git commands, the
  review file `replay` copies from a view into the work clone), and they
  would run the setting or write through the link.

A tool call denied in any of a replay's sessions makes the replay `invalid`.
That covers a guard denial, its ask tier included (nobody can answer an ask in
a headless session), and a permission-system denial. It is a harness fault:
the replay is left out of the pass rate, and it is never counted against the
varied model. Its rerun question leans against a rerun, since the same rule
would deny the same call again until the harness configuration changes (below). `record` reads the denials from the sessions'
transcripts. Each session is started on a fresh `--session-id`, which its
`STEP` line names. Its transcript is `<projects>/*/<id>.jsonl`, and its
subagents' transcripts are `<projects>/*/<id>/subagents/agent-*.jsonl`, found as
`metrics.sh` finds them (`ORCH_METRICS_PROJECTS_DIR`, else
`~/.claude/projects`). Each transcript is parsed as JSON. A denied call is a
tool-result record (a `user` record whose `message.content` holds a
`tool_result`) carrying a top-level string `toolDenialKind`. The field is read
only there, never as text anywhere on a line. Every kind counts except
`interrupted` (a person's interrupt) and `cancelled` (a response stopped by a
safety classifier). A kind not yet seen also counts. The count is stored as
`denials`, the kinds as `denial_kinds`, and the tools the denied calls asked
for as `denial_tools`: each denial's `tool_use_id` joined to the `tool_use` item
of the assistant record that made the call, in the same transcript, whose name
is taken (`unrecorded` when the transcript holds no such call; the count never
depends on it). The count is `null` (unmeasured,
never 0) when a `STEP` line names no session, a session id is malformed, a
session has no transcript, or a transcript is not in the recognised form (a
line that is not JSON, tool results none of which is in that form, or a
`toolDenialKind` anywhere else). `denial_note` then says why, and the outcome is
decided without it. So a Claude Code format change reads as unmeasured, not as
a silent 0. `rank` reads its one session's transcript the same way. It refuses
to record a ranking whose session had a call denied, or whose denials are
unmeasured.

**The reason reaches the operator.** `record` stores an `invalid` replay's
cause as one token, `invalid_cause`: `routing`, `crashed`, `timed-out`, `error`,
`fixed-role-refused` or `denial`. `rank-prepare`'s `UNRANKABLE` line carries that
cause (`cause=`), and for a denial the denied kinds (`kinds=`) and tools
(`tools=`). `report` adds one line per model whose latest records hold a
denial-invalid replay: the count, the kinds and the tools denied. A kind is the
transcript's category (a guard hook's deny reads `permission-rule`), so the tool
is what tells the operator which call the configuration refused. Neither names
the specific guard rule: the guard's own message in the tool result is not
parsed. That line sits beside the cells and changes no figure, since
the cells already leave invalid replays out. `/gaffer:compare-models` step 6
names the cause in each rerun question. For a denial it leans against a rerun,
naming the kinds and tools: the same rule would deny the rerun too, until the harness
configuration changes. Any other cause keeps the lean toward a rerun, with one
exception.

**Precedence: a denial counted under an earlier cause still blocks a rerun.**
`record` tests the causes in order: routing, then a crash or timeout, then a
fixed role refused, then a denial. A replay that failed its routing check and
also had a call denied stores `routing` as its cause, and the denial is in its
`denials` count alone. That denial would stop a rerun just the same. So when an
invalid replay's cause is an earlier one but its record counts `denials` above
0, the `UNRANKABLE` line adds `denials=<n>` with the kinds and tools. `report`
gives such replays their own per-model line, naming the causes, kinds and tools
and saying a rerun would meet the same denial; like the denial line, it changes
no figure. Step 6 applies the denial lean to them too. A count of 0, or `null`
(unmeasured), adds nothing: an unmeasured count is never read as a denial.

**A consumer experiment.** A source repository whose configuration keeps the
guard's ask tier on (no `bypass-ask-tier`) will see every ask-tier hit scored as
a denial-invalid replay.

This detection was read from real transcripts, not from a live replay. The
evidence was the machine's own `~/.claude/projects` on Claude Code 2.1.202 to
2.1.281, read on 2026-09-24. There, every tool_result a `PreToolUse` hook
denied carried `toolDenialKind: "permission-rule"` (1,054 records), with no
counter-example. The other kinds seen were `user-rejected` (among them a real
`claude -p` session's refused edit), `automode-blocked`, `automode-unavailable`,
`interrupted` and `cancelled`. No transcript on the machine came from a
bypass-mode session. Five cases were not observed:

- a guard hard deny inside a bypass-mode session;
- a guard ask-tier decision inside a bypass-mode `claude -p` session, and the
  kind it records;
- any denial inside a `-p` session's subagent transcript;
- the transcript a `-p` session writes under a given `--session-id`;
- a denial reported on a `-p` session's stdout.

**The live probe (2026-09-25).** A first attempt, a bypass-mode `claude -p`
session attempting a guard-denied and an ask-tier write, was refused by the
environment it was tried from. The probe that ran used `compare.sh`'s own
`run_session`, `confine_settings`, `session_tmp` and `rd_session_denials` on
Claude Code 2.1.281. It started two sessions, each in a `git clone --shared` of
this repository with `bypass-ask-tier` turned off; the second also had
`disableAllHooks: true` in the clone's `.claude/settings.json`. Both ran to the
end unprompted. Every refusal the probe expected happened, and nothing was
written outside a clone or its temp directory. It observed three of the five
cases above. A guard hard deny (a `.env` write) records `permission-rule`, as
the confinement hook's refusal does. A guard ask-tier decision is refused, not
approved, and records `user-rejected`. Each session's transcript was where
`rd_session_denials` looks for its `--session-id`, and it counted all five
denials, so a replay that meets any of them is scored `invalid`. A denial inside
a subagent transcript and a denial reported on stdout remain unobserved; the
probe dispatched no subagent. The first live experiment should read one
replay's subagent transcripts for a denial.

### 3. A replay copies `run-loop` §3's sequence, so the two are amended together

`replay` walks the `run-loop` §3 attempt, fix and review path in the order that
section fixes. It uses the loop's own `runstate.sh` subcommands: `record-start`,
`check-status` with its one re-dispatch, `route`, and `refresh-handoff` before a
continuation or a re-attempt. `packet_attempts` in the clone's configuration
bounds the attempts through `route`. The PRD scopes replays as "the loop's path
as it stands, minus the escalation decider". `ACTION=decider` and `ACTION=stop`
therefore end the replay, and the decider is never dispatched.
`ACTION=land` commits only the packet's diff, as one commit on the opaque
branch. It runs no `check-task`, no `complete-capabilities` and no roadmap edit,
and it takes the routing change back out.

The sequence is a copy, not a call. `run-loop` §3 is prose that a driver
session follows, and no script exists for `compare.sh` to invoke. A change to
`run-loop` §3's order, to the subcommands it calls, or to the routing
vocabulary it reads must therefore be made in `compare.sh replay` and
`scripts/test-compare.sh` in the same change. If it is not, replays measure a
loop that no longer runs. `scripts/compare.sh:281` and the replayable-role set
at `scripts/compare.sh:936` name the section they copy.

### 4. The reviewer reviews a blinded view, with named channels redacted

`review-view` builds, for every review, a second opaque clone at the replay
start (`review-<16 hex>`, no remote). It holds the work clone's current diff,
taken through a temp index and a temp object directory, so the work clone is
only read. Each channel through which a model could be identified is handled:

- **Routing configuration.** The view's `model_routing` is reduced to the one
  `reviewer` entry, so the replay's routing change is not in the diff under
  review. The packet's own edits elsewhere in `project-overrides.yaml` are kept.
- **Metrics, run directory and run-state.** Everything under `.agents/metrics/`
  and `.agents/loop/`, and both run-state files, stays as the start holds it.
- **Commits.** The view's commits are made by `git commit-tree`, so no hook or
  template runs, with a fixed author, committer, date and neutral message. They
  carry no trailer and no `Co-Authored-By`.
- **Branch and path names.** These are opaque hex, redrawn when one contains a
  model identifier. A scratch root whose path names a model is refused.
- **Handoff and result file.** The view gets copies in which every word
  containing an identifier of the settings' models is replaced by `[model]`,
  matched case-insensitively and together with a directly following version
  number (`scripts/compare.sh:2544`). The header's paths are pointed at the
  view's own.
- **Routing-check metrics.** `routing-check` collects each view's metrics only
  after that view's review session has ended, and writes them beside the
  replay's record in the store, never inside a view.

`rank-prepare` builds the ranking clone the same way. It writes letter-labelled
diffs in an order drawn fresh for each packet. It appends the label-to-model map
to the store's `labels.jsonl` and writes it nowhere in the clone. `rank` records
the ranking before it reads the map's models.

The change under review is carried as it is. A diff whose own content names a
model is not redacted, because redacting it would change the work being judged.
The PRD also records that blinding cannot close a model's style of writing, nor
a reviewer model's preference for its own diffs when it is also a subject.

### 5. Effort is one setting for every session, and `CLAUDE_CODE_EFFORT_LEVEL` is removed

A headless session given no effort runs at its model's own default, and that
default differs between models, so an arm left unset is not comparable. The
settings file therefore requires an `effort:` key. `settings` refuses the key
when it is absent or outside `EFFORT_LEVELS`, the set stated once in the
script, and it feeds the experiment id. Every session the harness starts
receives `--effort` with that value: each varied-role step, each review and each
ranking.

`CLAUDE_CODE_EFFORT_LEVEL` overrides the session effort
(`templates/report-templates.md:410`), and it outranks `--effort` (plan T19;
`scripts/compare.sh` `replay` usage). Left in the operator's environment, it
would carry into every child session, and one experiment could run
at a level its settings do not name. The launcher unsets it before starting each
session (`run_session` in `scripts/compare.sh`). The fixed effort is also checked
afterwards. `routing-check`, and the model-and-effort check `rank` runs, fail
when the collected `totals.by_effort` names any level other than the setting. A
model that takes no effort names none, and passes.

### 6. The store is `.agents/metrics/comparisons/`, outside `.agents/loop/`

The results are kept in `.agents/metrics/comparisons/` in the main checkout of
the repository the harness runs from (`scripts/compare.sh:1614`;
`ORCH_COMPARE_STORE` overrides it). The location is outside `.agents/loop/`
because `begin-run` prunes `.agents/loop/` to the current run plus one
(`cmd_begin_run` in `scripts/runstate.sh`). A store there would lose an experiment's
records to the next loop run, and a stopped experiment could not resume. All of
`.agents/metrics/` is already gitignored as bookkeeping in both `.gitignore`
files.

The store's files are:

- Per experiment: `selection.json`, `approvals.jsonl`, the per-packet handoff
  cache, the per-replay step, routing, sweep and metrics files, and the run logs.
- Shared across experiments: `records.jsonl`, `labels.jsonl` and
  `rankings.jsonl`.

The shared files are append-only, and each record embeds the settings that
produced it. An experiment's id is a digest of its normalized settings. The
same settings therefore resume the same experiment, and changed settings start
a new one beside it. For one experiment, packet and model, the last record wins.
A rerun of an `invalid` replay appends a new record, and the old record is never
rewritten.

### 7. The estimate holds tokens constant and prices them per model

This settles the PRD's first deferred decision. A packet's forecast is its
original recorded `packets[].tokens`, read from the source repository's stored
`run-metrics.json`. It is identical for every model. `estimate` prices it at each
model's rates in the price table and prints the table's date. Recorded tokens do
not split cache writes by lifetime, so dollars are given as a range: every cache
write priced at the 5-minute rate, and every cache write priced at the 1-hour
rate. Fix rounds are not modelled. The original cost already includes the
original run's rounds, and forecasting a different number of rounds per model
would assume the answer the experiment exists to measure. A packet whose
original cost is unmeasured is named as excluded and never counted as 0. A model
with no complete price entry reads as unpriced, and its dollars read unmeasured.

### 8. Spend is approved through a single-use token bound to one replay set

Each `estimate` issues an `APPROVAL=` token. Before printing it, `estimate`
appends one `pending` line to the experiment's `approvals.jsonl`. The line binds
the token to exactly the replay set printed, as a digest of that set. `run`
refuses a token that is missing, spent or superseded, where the newest pending
estimate supersedes every earlier one. It also refuses a token whose stored set
no longer matches its digest. A valid token is consumed under a lock before any
replay starts, so it is single-use even when the run stops early.
`estimate --remaining` covers only replays with no stored record, which is how a
resumed experiment states its remaining spend and asks again.
`run --rerun <replay>` is admitted only for a replay whose latest record is
`invalid`, and only under a token whose set holds that packet and model. The
skill passes a token to `run` only after the operator's own go-ahead to the
estimate shown in the same session.

### 9. The required sweeps are every `scripts/test-*.sh` path the handoff names

`sweeps` treats every `scripts/test-<name>.sh` path that the replay's handoff
names as a required sweep (`scripts/compare.sh:3457`). It reads them from the
experiment's handoff cache: the bytes every model's replay of that packet was
first given. It never reads the work clone's handoff, into which a continuation
or a fix round may have spliced a partial-work block. A glob such as
`scripts/test-*.sh` names no sweep. Each sweep runs with a timeout in a fresh
clone of the final diff, and the work clone is only read. A required sweep that
the final diff does not hold fails as `not-run`. A handoff that names no sweep
reads `none-required`. A replay that was never swept records `sweeps` as null,
which means not run and never a pass.

### 10. The proposal is computed by a fixed rule, never written by a model

Two renders of the same stored results must match byte for byte (PRD, P1), and
only a deterministic rule can give that. `report` reads only the store, starts
no session and prints no timestamp. Its proposal (`scripts/compare.sh:4823`)
picks one model for the varied role. The model with the highest pass rate over
both classes wins. On a tie the lowest mean rank decides, then the lowest mean
dollars. Each later figure decides only among the models tied on every figure
before it. A class favours a model by the same rule applied inside that class.
When the prose and code classes favour different models, the report says so and
states what a per-tier split would change against the single value.

No change is proposed, and the reason is named, in any of these cases:

- A model has an unmeasured cell.
- The rule reaches a figure that is unmeasured for a tied model.
- The models tie on all three figures.

Ranks from different ranking sets are never averaged. Cells are never pooled
across different varied roles, reviewer models or source repositories. The
proposal is text. Nothing in the harness writes routing configuration outside
its own clones.

## Consequences

- `run-loop` §3 now has a second reader. An edit to that section's sequence is
  not complete until `compare.sh replay` and its sweep cases match it (§3).
- A replay measures the loop as it stands today, not as it stood when the packet
  first landed. The original outcome is context, not a baseline (PRD,
  Assumptions).
- The harness changes nothing the live loop runs. A field it needs that
  `runstate.sh`, `routing.sh`, `metrics.sh` or `spend.sh` does not produce is a
  finding for the feature that owns it, not a local patch (plan preamble).
- Every agent step is a full headless session, so an experiment runs for hours.
  The skill runs `run` and each `rank` in the background. `run` honours the
  pause sentinel only between replays.
- Adding another role, model or repository is a change of settings. Its records
  sit beside the earlier ones, and the report keeps each group apart.
