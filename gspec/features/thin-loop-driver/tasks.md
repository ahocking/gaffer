---
spec-version: v2
feature: thin-loop-driver
---

# Plan: thin-loop-driver

The deterministic cores land first: the driver-mode mark, the guard rule, run directories, handoff and result writers, the router and the digest. Then come the agent contracts the driver routes on, then the driver and the loop prompts that call them, then the reports built from those files. Measurement comes last. `scripts/runstate.sh`, `hooks/guard.sh`, `skills/run-loop/SKILL.md` and every `test-*.sh` are serialization points, so no two tasks sharing one are `[P]`.

**Driver mode is a mark keyed by session, and the guard is its only enforcement.**
- The mark is `.agents/driver-mode/<session-id>`, written and removed only by `runstate.sh driver-mode` (T3).
- The guard refuses a write only when all three hold: the payload's `session_id` has a mark, the payload has no `agent_id`, and the target is outside `.agents/`.
- The secret floor still runs first. A payload with no `session_id` is judged exactly as it is today.
- A reopened session clears its own mark on SessionStart `startup|resume`. `compact` never clears it.
- T1 probes these payload facts before T5 and T6 rely on them. If the probe contradicts the PRD's assumption, stop there.

**New record formats live outside the outcomes log.** `_rs_open_packets` reads any record carrying `kind` as a start, so a new record there would reopen packets. Driver-mode enter and exit records go to `.agents/metrics/driver-mode/<session>.jsonl` (T3), and routing records go to `.agents/loop/<run_id>/routing.jsonl` (T9). The `record-start` and `record-outcome` shapes are unchanged:
- a fresh implementer attempt records no start;
- routing to the decider records nothing;
- `discard-advance` records `rolled-back`;
- a stop records `blocked`.

**A run spans sessions, so its identity lives in run-state.** `begin-run` mints `run_id` once and `resume` keeps it. Cleanup keeps the current run directory and the newest previous one. `.agents/loop/` and `.agents/driver-mode/` are ignored in both `.gitignore` files. An untracked file would be swept by the pause stash and discarded by `reconcile` as scratch.

**Result files are written through a script, so read-only agents stay read-only.** The reviewer, researcher and chief-engineer gain no Edit or Write tool. `runstate.sh write-result` refuses any path outside the current run directory. It writes the status line as the file's first line, so T11 can assemble reports without the driver opening a result file.

**There is no escalation decider yet, so the chief-engineer stands in for it, and this plan builds none of the decider's decision logic.** `route` maps `escalate` and an exhausted `fix` to `ACTION=decider`, and sweep cases pin how all five decider decisions are handled. Until `escalation-decider` ships:
- the driver dispatches `chief-engineer` with the packet's handoff and review paths;
- it decides with its existing judgment, not the decider's exclusive triggers or their precedence;
- it returns one of `retry`, `reorder`, `append-task`, `hand-off-feature` or `ask-operator` as its status, and the driver passes that token to `route`;
- it keeps its tools: an `append-task` line (ADR 0026 arm 1) is written by an architect it dispatches and committed on its own paths before the token returns, and a `hand-off-feature` is recorded as a question for the main context to run `/gspec-feature` on;
- it returns `retry` only while the packet has an attempt left, the rule `escalation-decider` states, and `route` refuses one past the limit rather than looping.

Packet work is committed only when it lands or at a pause checkpoint, so `discard-advance` discards uncommitted work back to the last green checkpoint, and a decider commit made on its own paths survives it.

`escalation-decider` replaces that section of `agents/chief-engineer.md` and the one dispatch line in `skills/run-loop/SKILL.md`, and must keep its own decision records outside `.agents/loop/`, which T7's cleanup removes.

**Acceptance criteria reach the handoff file through the adapter.** T2 widens ADR 0020's consumed contract to capability sub-bullets and amends ADR 0020 in the same task. `runstate.sh` still never reads `gspec/`.

**Compaction rests on a setting nobody here has verified.** T1 probes it, and T4 builds only what the probe found. On a miss, T4 still adds the lookup, which prints `unknown`, applies no default, and the kickoff states that it cannot tell. No setting is invented.

**Reflexivity.** Nothing writes a mark until T16 lands, so T5 is inert in the run that lands it. T6's `hooks.json` registration takes effect next session. Skills and agents are read at invocation, so the run landing T16 still runs the old loop. The first driver-mode run is the next `/gaffer:run-loop`.

**`templates/report-conventions-card.md` stays byte-identical across its three copies.** T18 edits only `report-templates.md`, `check-in.md` and `report-conventions.md`, and runs `test-report-conventions.sh`.

## Plan

- [x] **T1** [P] **P0** Probe in a real session, with a scratch hook that logs payloads, and record the results in a new ADR, `docs/adr/0028-loop-driver-mode.md`, before anything relies on them:
  - whether a main-thread PreToolUse payload carries `session_id` and no `agent_id`, both in a plain session and in one launched with `claude --agent` on a throwaway agent, and whether a subagent's payload carries `agent_id`;
  - whether `session_id` survives compaction, `/clear` and `claude --resume`, and which SessionStart `source` each one fires;
  - whether `autoCompactWindow` or `CLAUDE_CODE_AUTO_COMPACT_WINDOW` exists, its unit, which settings scopes read it, whether a plugin can supply a default without overriding a repo or operator value, and whether a running session can read the value in effect;
  - whether a session can read its own effort level.

  Never take an answer from docs. Record every result, including misses; stop only if the `session_id`/`agent_id` payload facts contradict the PRD.
  - deps: —
  - covers: A session running the loop is in driver mode · Long runs compact, and can pause on a schedule
  - arch: —
  - files: docs/adr/0028-loop-driver-mode.md
- [x] **T2** [P] **P0** Add `gspec-backlog.sh handoff <packet-id>`, which prints the task text, its file scope resolved exactly as `nodes` resolves it, each `covers:` capability with its PRD acceptance-criteria bullets verbatim, and the PRD and `arch.md` paths, and amend ADR 0020 to add acceptance-criteria bullets to the consumed contract. A `covers:` quote that matches no capability is reported, never guessed, and a non-gspec id prints `unknown`. `test-gspec-backlog.sh` cases cover all three plan layouts, a multi-bullet criterion, a ` · `-separated multi-capability `covers:`, an unmatched quote and a checked task.
  - deps: —
  - covers: Agents take a handoff file and return one status line
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh, docs/adr/0020-gspec-boundary-and-version-pin.md
- [x] **T3** [P] **P0** Add `runstate.sh driver-mode <enter|exit|status> [session-id]`, with the session defaulting to `CLAUDE_CODE_SESSION_ID`:
  - `enter --model <m> --effort <e|unknown> --threshold <n|unknown>` writes the mark `.agents/driver-mode/<session>` and appends an enter record to `.agents/metrics/driver-mode/<session>.jsonl`;
  - `exit` removes the mark and appends an exit record;
  - `status` prints `DRIVER_MODE=on|off`.

  Ignore `.agents/driver-mode/` in both `.gitignore` files. Cases cover a round trip, a repeated `exit`, another session reading `off`, valid append-only JSON, and `sweep-open --list` printing nothing after `enter`.
  - deps: —
  - covers: A session running the loop is in driver mode
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, .gitignore, templates/spec-driven-base/.gitignore
- [x] **T4** **P1** Add `runstate.sh compact-threshold`, which prints the auto-compaction threshold in effect and its source (repo, operator or gaffer's default), or `unknown`. Apply gaffer's default to a loop session, through the carrier T1 recorded, only where neither the repo nor the operator set one. Cases cover each source and the unknown case. If T1 found no per-repo setting, still add `compact-threshold` printing `unknown`, skip applying the default, and report the settings carrier as absent.
  - deps: T1, T3
  - covers: Long runs compact, and can pause on a schedule
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T5** [P] **P0** Make `hooks/guard.sh` refuse Edit, Write, MultiEdit and NotebookEdit calls, and the shell writes `BASH_WRITE_PATTERNS` recognises, when the payload's `session_id` has a driver-mode mark in a discovered config root, the payload carries no `agent_id`, and the target is outside `.agents/`. The refusal names driver mode as the reason and `/gaffer:pause` as the way out. It is checked after the secret floor and before the ask tier. A payload without `session_id` is judged as it is today. `test-guard.sh` cases:
  - each of the four tools and `sed -i`, `cat >`, `tee` and `cp` refused;
  - `.agents/` targets allowed, including a Windows-separated one;
  - the same payload with `agent_id` allowed;
  - another session's mark, and no mark, allowed;
  - `git commit` on a feature branch and a `runstate.sh write` heredoc allowed;
  - a secret path still refused as a secret.
  - deps: T1, T3
  - covers: A session running the loop is in driver mode
  - arch: —
  - files: hooks/guard.sh, scripts/test-guard.sh
- [x] **T6** **P0** Make `hooks/session-start.sh` clear its own session's driver-mode mark on `startup` and `resume`. Add `hooks/driver-mode-compact.sh`, registered in `hooks/hooks.json` on SessionStart `compact`. When its session has a mark, it prints a context-only note to `Read` `${CLAUDE_PLUGIN_ROOT}/agents/loop-driver.md` and continue as the driver; otherwise it prints nothing. It handles `clear` as T1 found: when `/clear` keeps the session id, the compact hook's matcher is `compact|clear`. `test-runstate.sh` cases cover a reopened session's mark cleared, a compacted session's mark kept, the `clear` behaviour T1 recorded, another session's mark untouched, valid JSON envelopes, and failing open with no session id.
  - deps: T1, T3
  - covers: A session running the loop is in driver mode
  - arch: —
  - files: hooks/session-start.sh, hooks/driver-mode-compact.sh, hooks/hooks.json, scripts/test-runstate.sh
- [x] **T7** **P0** Add `runstate.sh begin-run <run-state>`, which:
  - mints a sortable `run_id` into run-state only when it is absent;
  - creates `.agents/loop/<run_id>/`;
  - removes every other run directory except the newest previous one;
  - prints `RUN_ID=`, `RUN_DIR=` and one `REMOVED=` per removed directory.

  Add `run_id` to `templates/run-state.yaml`, and ignore `.agents/loop/` in both `.gitignore` files. Cases cover minting once, keeping the current and previous runs, a real YAML parse after the write, and run-directory files surviving `git stash --include-untracked` with `reconcile` still reading `clean`.
  - deps: T3
  - covers: Agents take a handoff file and return one status line
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, templates/run-state.yaml, .gitignore, templates/spec-driven-base/.gitignore
- [x] **T8** **P0** Add two writers to `runstate.sh`:
  - `handoff <run-state> <packet-id> --tier <tier> --agent <agent>` writes stdin atomically to `.agents/loop/<run_id>/<packet-id>/handoff.md`, headed by the packet id, title, tier and agent, and prints `HANDOFF=<path>`;
  - `write-result <run-state> <path> --status "<line>"` refuses any path outside the current run directory, collapses newlines in the status to spaces, and atomically writes the status line followed by stdin.

  Cases cover both writers, `..` and absolute-path refusals, and a rewrite replacing the file.
  - deps: T7
  - covers: Agents take a handoff file and return one status line
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T9** **P0** Add `runstate.sh route <run-state> <packet-id> <token> [--status "<line>"]`, which appends a routing record to `.agents/loop/<run_id>/routing.jsonl` and prints one action with `ATTEMPTS=` and `LIMIT=`:
  - `pass` → `land`;
  - `fix` → `attempt` while attempts remain, else `decider`; `retry` → `attempt` while attempts remain, since the PRD counts attempts from either route and `escalation-decider` returns `retry` only when one is left, and a `retry` past the limit is refused as `stop`, carrying a blocking question that names the over-limit `retry`, rather than looped;
  - `escalate` → `decider`; `reorder`, `append-task` and `hand-off-feature` → `discard-advance`; `ask-operator` → `stop`;
  - attempts count `fix` and `retry` records since the packet's latest `start` record, compared by parsed time, and a continuation does not reset the count;
  - the limit is `packet_attempts` in `.agents/project-overrides.yaml`, 1 when missing, invalid or 0;
  - `handoff` refuses a packet routed `hand-off-feature` in the current run.

  Add the commented key to both overrides files. Cases cover every token, an exhausted `fix`, a reset by a new start but not by a continuation, each limit fallback, the handed-off refusal, and the outcomes log left byte-unchanged.
  - deps: T8
  - covers: The reviewer verdict routes each packet mechanically
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, .agents/project-overrides.yaml, templates/spec-driven-base/.agents/project-overrides.yaml
- [x] **T10** **P1** Add `runstate.sh periodic-pause`, which prints `ENDED=`, `EVERY=` and `DUE=yes|no`. It counts terminal outcome records timestamped at or after the session's latest driver-mode `enter` record, so a swept interruption, which carries its start's time, does not count. `pause_every_packets` in `.agents/project-overrides.yaml` is off when missing, invalid or 0. Add the commented key to both overrides files. Cases cover off by default, off at 0, due at N, a restart after a new `enter`, and an excluded swept record.
  - deps: T3, T9
  - covers: Long runs compact, and can pause on a schedule
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, .agents/project-overrides.yaml, templates/spec-driven-base/.agents/project-overrides.yaml
- [x] **T11** **P1** Add `runstate.sh run-digest <run-state> [--since <ts>]`. It assembles its output from the run's handoff files, the first line of its result files, its routing records, the outcomes log and the driver-mode records, and prints nothing else:
  - one line per packet begun in the run, with its title and its latest outcome after its latest start or continuation, `paused` for a paused cursor, or `open`;
  - one line per decider decision since `--since`;
  - one line per `hand-off-feature` record, carrying its status line;
  - the model, effort and threshold stated at the latest `enter`.

  Cases cover a run spanning two sessions, a paused cursor, a `hand-off-feature` record, and result-file body text never appearing in the output.
  - deps: T3, T8, T9
  - covers: Reports are thin and built from files
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T12** [P] **P0** Add `templates/status-line.md`. It defines the one status line every loop-dispatched agent returns: status, what changed, whether its result file needs reading, and that file's path. The same line opens the result file written with `runstate.sh write-result`. It also states that a status line longer than one line breaks the contract and review must catch it.
  - deps: T8
  - covers: Agents take a handoff file and return one status line
  - arch: —
  - files: templates/status-line.md
- [x] **T13** [P] **P0** Replace the report section of `agents/reviewer.md` with the three verdicts and their exclusive triggers:
  - `pass`: the acceptance criteria are met and there is no blocking finding;
  - `fix`: a failure the review file describes precisely enough for another implementer to correct;
  - `escalate`: anything else, and whenever more than one could apply or which applies is unclear.

  The reviewer takes the handoff path as its whole brief. The verdict is returned in the status line. The review file is written through `runstate.sh write-result` as the reviewer's one permitted write, and no Edit or Write tool is added.
  - deps: T12
  - covers: The reviewer verdict routes each packet mechanically · Agents take a handoff file and return one status line
  - arch: —
  - files: agents/reviewer.md
- [x] **T14** [P] **P0** Update `agents/implementer.md`, `doc-writer.md`, `researcher.md`, `architect.md` and `ux-designer.md`:
  - each takes a handoff path as its whole brief, plus the review file's path on a fresh attempt;
  - each returns one status line per `templates/status-line.md` and writes everything else with `runstate.sh write-result`;
  - the architect and UX designer may implement, and re-attempt, a design-heavy packet within its handoff's file hints;
  - the researcher answers an operator question by writing only its result file, with the short answer in its status line.
  - deps: T12
  - covers: Agents take a handoff file and return one status line · The reviewer verdict routes each packet mechanically · The operator can ask questions and request edits mid-run
  - arch: —
  - files: agents/implementer.md, agents/doc-writer.md, agents/researcher.md, agents/architect.md, agents/ux-designer.md
- [x] **T15** [P] **P0** Add `agents/loop-driver.md` with `model: inherit`. It declares no `tools:` restriction, so a session launched with `claude --agent` keeps `Task`, `Bash` and `Read` for the loop and Edit and Write for after its stop report. Its instructions:
  - pass only paths, read one status line, never open a result file, and never poll while an agent works;
  - route every verdict through `runstate.sh route`, and until `escalation-decider` ships, answer `ACTION=decider` by dispatching `chief-engineer` with the handoff and review paths and passing its returned decision token, with its status line as `--status`, to `route`;
  - answer operator questions from handoff files, status lines and findings before dispatching the researcher;
  - have a mid-run edit the operator asks for made by a dispatched agent and committed between packets, before the next one begins, without a stop report;
  - send hand edits through a pause;
  - after compaction, keep following these instructions.

  In `agents/chief-engineer.md`, replace the loop-driving bullets with a stand-in escalation decider section, marked as interim until `escalation-decider` replaces it. With its tools unchanged, the stand-in:
  - reads only the handoff file, the review file and the findings naming the packet;
  - returns exactly one of `retry`, `reorder`, `append-task`, `hand-off-feature` or `ask-operator` in a status line per `templates/status-line.md`, with its reasoning written through `runstate.sh write-result`;
  - makes an `append-task` line by dispatching the architect under ADR 0026 arm 1, and commits only that edit's paths with an `[orch decider:<packet-id>]` trailer before returning, so discarding the packet's uncommitted work keeps it;
  - returns `retry` only while the packet has an attempt left;
  - records a `hand-off-feature` as a question for the main context, never running `/gspec-feature` itself;
  - returns `ask-operator` whenever it cannot settle on another decision.
  - deps: T9, T13, T14
  - covers: A session running the loop is in driver mode · Agents take a handoff file and return one status line · The reviewer verdict routes each packet mechanically · The operator can ask questions and request edits mid-run
  - arch: —
  - files: agents/loop-driver.md, agents/chief-engineer.md
- [x] **T16** **P0** Slim `skills/run-loop/SKILL.md` to the driver role, moving judgment into `agents/loop-driver.md`, so that:
  - it `Read`s that file, then enters driver mode with the session's model and effort before the kickoff and never asks to change them, then runs `begin-run`;
  - when it begins a packet, after the existing sweep, it pipes `gspec-backlog.sh handoff` (or, for a packet not from gspec, its task text from run-state) into `runstate.sh handoff`, choosing the architect or UX designer for a design-heavy packet at that point, and runs `record-start` only once the handoff is written; a refused handoff skips the packet with no record;
  - it dispatches with the handoff path only, and passes every returned verdict or decision to `route` with its status line as `--status`;
  - it routes on `route`'s action:
    - `land` commits green as today, with `[orch impl:delegated]`;
    - `attempt` dispatches a fresh agent with the handoff and review paths and records no start;
    - `decider` records nothing and dispatches the stand-in `chief-engineer` in one line that `escalation-decider` replaces, passing its decision token back to `route` with its status line as `--status`;
    - `discard-advance` discards uncommitted work back to the last green checkpoint (a landed packet or a pause commit), which keeps a decider commit made on its own paths, records `rolled-back` and advances;
    - `stop` records `blocked`;
  - no packet is implemented inline;
  - `driver-mode exit` runs immediately after every stop report.
  - deps: T2, T5, T6, T15
  - covers: A session running the loop is in driver mode · Agents take a handoff file and return one status line · The reviewer verdict routes each packet mechanically
  - arch: —
  - files: skills/run-loop/SKILL.md
- [x] **T17** **P0** Carry driver mode into `skills/resume/SKILL.md` and `skills/pause/SKILL.md`:
  - after its legacy-parallel check, `resume` enters driver mode and runs `begin-run`, keeping the run's `run_id`, then follows `run-loop`'s dispatch-and-route steps by `Read`;
  - every stop path in both skills runs `driver-mode exit` right after its stop report;
  - `pause` names the driver session, not the Chief Engineer, as the one running it.
  - deps: T16
  - covers: A session running the loop is in driver mode · The reviewer verdict routes each packet mechanically
  - arch: —
  - files: skills/resume/SKILL.md, skills/pause/SKILL.md
- [x] **T18** [P] **P1** Rework the report shapes in `templates/report-templates.md`, and add an amendment section to ADR 0023 recording the change:
  - shape A becomes one line per ended packet (id, plain-English title and outcome), plus one line per decider decision since the last report;
  - shapes B and C are assembled only from `runstate.sh run-digest`;
  - shape C states the model, the effort (or unknown) and the compaction threshold (or that it cannot tell), and never asks to change them;
  - shape B names a periodic pause's setting as its reason, and lists each `hand-off-feature` question.

  Note in `templates/check-in.md` and `templates/report-conventions.md` that loop agents return status lines, not check-ins. Leave the card and its two copies byte-identical, and run `test-report-conventions.sh`.
  - deps: T11, T12
  - covers: Reports are thin and built from files · A session running the loop is in driver mode · Long runs compact, and can pause on a schedule
  - arch: —
  - files: templates/report-templates.md, templates/check-in.md, templates/report-conventions.md, docs/adr/0023-report-conventions-delivered-not-referenced.md
- [x] **T19** **P1** In `skills/run-loop/SKILL.md`, `skills/resume/SKILL.md` and `skills/pause/SKILL.md`:
  - run `compact-threshold` and pass its value to `driver-mode enter`;
  - render every loop report only from `run-digest` output: the packet-ended line after each outcome, the kickoff (including on resume), and the stop report (including after compaction or in a session that resumed another's run);
  - at each packet boundary run `periodic-pause`, and on `DUE=yes` request a pause whose reason names `pause_every_packets` and hand to `/gaffer:pause`.
  - deps: T4, T10, T17, T18
  - covers: Reports are thin and built from files · Long runs compact, and can pause on a schedule
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, skills/pause/SKILL.md
- [x] **T20** [P] **P1** For the main-session edits success metric:
  - `hooks/metrics-log.sh` stamps Edit, Write, MultiEdit and NotebookEdit events with `agents_dir` (whether the target is under `.agents/`; the path is still never logged) and `driver_mode` (its session has a mark and the event has no `agent_id`);
  - `metrics.sh collect` reports a run's count of successful main-thread driver-mode edits outside `.agents/`, as `null` when the run has no events or any such event lacks `agents_dir`.

  `test-metrics.sh` cases cover a leak, an `.agents/` edit, a subagent edit, a pre-feature event and an event-less run. Success-metric instrumentation, not a PRD criterion
  - deps: T3
  - covers: A session running the loop is in driver mode
  - arch: —
  - files: hooks/metrics-log.sh, scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T21** **P1** For the main-session context success metric, make `metrics.sh collect` report the largest main-thread turn context inside driver-mode enter/exit windows. A turn's context is its input, cache-write and cache-read tokens, with each message counted once by id. Report it beside the threshold the `enter` record stated, as `null` when usage or a stated threshold is missing. Render it in `show`, describe it in `skills/metrics/SKILL.md`, and add cases for a turn under a threshold, over one, and with none stated. Success-metric instrumentation, not a PRD criterion
  - deps: T20
  - covers: Long runs compact, and can pause on a schedule
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh, skills/metrics/SKILL.md
- [ ] **T22** [P] **P1** For the cost-per-landed-packet success metric, add `spend.sh --project <folder>` so the agent-role breakdown reads one repo's main-session dollars, with cases. The green-packet denominator comes from `metrics.sh collect` over the same `--since`/`--until` window; if `collect` cannot count green outcomes and coverage across a multi-session window, report that rather than approximating. Success-metric instrumentation, not a PRD criterion
  - deps: —
  - covers: A session running the loop is in driver mode
  - arch: —
  - files: scripts/spend.sh, scripts/test-spend.sh
- [ ] **T23** [P] **P1** Make `migrate.sh` report a consumer `.gitignore` that lacks `.agents/loop/` or `.agents/driver-mode/`, and report any per-repo compaction entry T4's carrier needs, each as a finding to fix by hand in the same form as the existing pause and write-backup findings. `test-migrate.sh` cases cover each finding and a second run finding nothing, and `skills/migrate/SKILL.md` names them.
  - deps: T4, T7
  - covers: Agents take a handoff file and return one status line · A session running the loop is in driver mode · Long runs compact, and can pause on a schedule
  - arch: —
  - files: scripts/migrate.sh, scripts/test-migrate.sh, skills/migrate/SKILL.md
- [ ] **T24** **P1** Record in `CLAUDE.md`, `README.md` and the ADR T1 created, as one deliberate change to the repo's most contended file:
  - the driver-mode mark and its guard rule;
  - run directories and their cleanup;
  - the routing log;
  - script-written result files;
  - the chief-engineer as interim stand-in decider, and what `escalation-decider` replaces;
  - the widening of ADR 0020's consumed contract to acceptance criteria, which T2 amended ADR 0020 for.

  Repo-convention upkeep, not a PRD criterion
  - deps: T19, T21, T22, T23
  - covers: A session running the loop is in driver mode
  - arch: —
  - files: CLAUDE.md, README.md, docs/adr/0028-loop-driver-mode.md
