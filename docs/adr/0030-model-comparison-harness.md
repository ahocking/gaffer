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
session has nobody to answer a permission prompt, so a step that reached one
would stall until its time limit. The bypass is confined to a disposable
directory: the session's working directory is its clone or view. The
guardrail is meant to keep applying inside it: `--plugin-dir` loads the
harness's `hooks/guard.sh`, and its hard deny is a `PreToolUse` hook's exit 2,
not a permission prompt. No bypass-mode session has yet been observed to
confirm that (see the list below).

A tool call denied in any of a replay's sessions makes the replay `invalid`.
That covers a guard denial, its ask tier included (nobody can answer an ask in
a headless session), and a permission-system denial. It is a harness fault:
the replay is rerun and left out of the pass rate, and it is never counted
against the varied model. `record` reads the denials from the sessions'
transcripts. Each session is started on a fresh `--session-id`, which its
`STEP` line names. Its transcript is `<projects>/*/<id>.jsonl`, and its
subagents' transcripts are `<projects>/*/<id>/subagents/agent-*.jsonl`, found as
`metrics.sh` finds them (`ORCH_METRICS_PROJECTS_DIR`, else
`~/.claude/projects`). A denied call is a transcript record carrying a top-level
`toolDenialKind`. Every kind counts except `interrupted` (a person's interrupt)
and `cancelled` (a response stopped by a safety classifier). A kind not yet seen
also counts. The count is stored as `denials`. When a `STEP` line names no
session, or a session has no transcript, the count is `null` (unmeasured, never
0), `denial_note` says why, and the outcome is decided without it.

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

A live probe (a bypass-mode `claude -p` session attempting a guard-denied and
an ask-tier write) was refused by the environment it was tried from. The first
live experiment must confirm that the steps run unprompted and that a denied
call is scored `invalid`. It should also confirm that the guard still hard-denies
in that mode, and read one bypass-mode replay's transcripts for the kind an
ask-tier decision records.

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
