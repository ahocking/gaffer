---
spec-version: v2
feature: session-effort-reporting
---

# Plan: session-effort-reporting

**Readers first, prompts last.** The session-effort reader (T1), the kickoff template (T2), the per-dispatch collector field (T3) and the spend note (T4) touch separate files and depend on nothing, so they fan out. The `run-loop`/`resume` prompts (T5) land after the reader output and template lines they name. A prompt naming a subcommand that does not exist yet would make the driver improvise its effort. T5 edits `skills/run-loop/SKILL.md` and `skills/resume/SKILL.md`, which a live driver loads. The change takes effect at the next `/gaffer:run-loop` or `/gaffer:resume` entry, and a run in progress keeps the effort it already recorded.

**Two decisions the PRD defers to the architecture step, made here because there is no `arch.md`.**
1. **The reader is its own pure subcommand, `runstate.sh session-effort [session-id]`, modelled on `compact-threshold`.** `driver-mode enter` and its mark are unchanged. The driver passes the printed `EFFORT` to `--effort`. The subcommand finds the transcript by globbing `<projects dir>/*/<session-id>.jsonl`, the way `metrics.sh collect` already does. The projects dir comes from `ORCH_METRICS_PROJECTS_DIR`, defaulting to `~/.claude/projects`. It never rebuilds the escaped cwd. It never reads a `subagents/` file. It exits 0 in every case, so driver-mode entry always proceeds.
2. **A dispatch whose effort changed carries a JSON array of its distinct levels, in first-seen order by turn timestamp.** A dispatch with one level carries that level as a string.

**`null` means unmeasured, never a guess.** A transcript value is hostile input. A level is accepted only if it matches `[A-Za-z0-9_-]+`; a rejected level counts as the transcript not being readable, one of the PRD's `unknown` cases. Every `jq -r` value that a `read` consumes goes through `tr -d '\r'`.

## Plan

- [x] **T1** [P] **P0** Add `runstate.sh session-effort [session-id]`. The session id comes from the argument, else `$CLAUDE_CODE_SESSION_ID`, validated by `_rs_check_session_id`'s rule without exiting (that helper `die`s, so T1 applies its rule and reports `REASON=no-session` instead). The subcommand prints `EFFORT=<level|unknown>`, `REASON=<transcript|no-effort-row|no-transcript|ambiguous|unreadable|no-parser|no-session>` and `EFFORT_ENV=<set|unset>`, and always exits 0. `EFFORT` is the top-level `.effort` of the last row in the session's main-thread transcript that carries a non-null one. It is `unknown` when no row carries one, when zero or more than one `*/<session-id>.jsonl` matches, when the file cannot be read or parsed, when `jq` is absent, when a level fails the charset, or when there is no valid session id. `EFFORT_ENV` reads `set` only when `CLAUDE_CODE_EFFORT_LEVEL` is non-empty. `scripts/test-runstate.sh` gains fixture cases under `ORCH_METRICS_PROJECTS_DIR`: a row carrying `xhigh` read as `xhigh`; two levels where the later row wins; no row carrying an effort (user rows only) as `unknown`; assistant rows from a model with no `.effort` as `unknown`; a missing and an unreadable transcript as `unknown`; `jq` masked off `PATH` as `unknown`; a level containing a space as `unknown`; an invalid and an unset session id each reading `unknown` with `REASON=no-session`; two matching transcripts reading `unknown` with `REASON=ambiguous`; exit 0 for every case; and `EFFORT_ENV` for the variable set, set to empty, and unset
  - deps: —
  - covers: Driver-mode entry records the session's effort read from its own transcript · The kickoff warns when `CLAUDE_CODE_EFFORT_LEVEL` is set
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T2** [P] **P0** In shape C of `templates/report-templates.md`, change the `▶ **Session**` line to say that every dispatched agent inherits the session's effort, as far as its model accepts one. Update its rule comment and the worked example, and keep the words *effort unknown* for `unknown`. Add a `⚠️ **Effort override**` line after `⚠️ **Routing config**`. It says `CLAUDE_CODE_EFFORT_LEVEL` is set and overrides the session effort for the driver and every dispatched agent this run. Its rule comment says it is rendered only when `session-effort` printed `EFFORT_ENV=set`, asks nothing and never stops the run. `scripts/test-report-conventions.sh` gains cases for: the template's Session line carrying the inheritance wording; kickoffs with a recorded level (`effort xhigh`) and with `effort unknown` each linting `REPORT_LINT=clean` against an empty and a populated digest; a kickoff carrying the Effort override line linting clean; and the template carrying that line with its `EFFORT_ENV=set` condition
  - deps: —
  - covers: The kickoff's Session line states the session's effort and that dispatched agents inherit it · The kickoff warns when `CLAUDE_CODE_EFFORT_LEVEL` is set
  - arch: —
  - files: templates/report-templates.md, scripts/test-report-conventions.sh
- [x] **T3** [P] **P1** Make `metrics.sh collect` give each `packets[].dispatches[]` row an `effort`, taken from the `message.id`-deduplicated turns whose `aid` is the dispatch's resolved `agent_id`. It is the level as a string when every such turn carries the same one, and an array of the distinct levels in first-seen order when the level changed. It is `null` when the dispatch is unresolved, when no turn resolves to it, or when any of its turns has a null effort. Add `effort` to the existing pin's `del` list so the pin proves `totals.by_effort` and every other field unchanged. In one change, add a dated `session-effort-reporting` addendum to ADR 0019 v3.6 §1 (the field) and §4 (its null rules). `scripts/test-metrics.sh` gains cases for: a single level; a level changed mid-dispatch reading as an ordered array; one turn with no effort nulling the row; an unresolved dispatch reading null; and a legacy run with no `.effort` on any turn reading null on every row. The CRLF byte-identity case must still pass with effort values present
  - deps: —
  - covers: Each dispatch's effort is on its run-metrics per-dispatch row
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh, docs/adr/0019-run-metrics-observability.md
- [x] **T4** [P] **P1** First check a current `subagents/agent-*.jsonl` on this machine. Then amend the 2026-09-21 probe note in the `scripts/spend.sh` header: add a dated observation that dispatched-agent rows now carry a top-level `.effort` and older rows do not. Leave the earlier probe's text in place and change no code, so `scripts/test-spend.sh` still passes unchanged
  - deps: —
  - covers: The `scripts/spend.sh` effort note is amended
  - arch: —
  - files: scripts/spend.sh
- [x] **T5** **P0** In `skills/run-loop/SKILL.md` §2 and `skills/resume/SKILL.md` §0, run `runstate.sh session-effort` just before `driver-mode enter` and pass its `EFFORT` value exactly as printed to `--effort`. Replace the hard-coded `--effort unknown` and its "nothing records it automatically" paragraph with the rule: the effort is read, never inferred from the model, and the operator is never asked to change it. Tell both entry points to keep `EFFORT_ENV` for the kickoff and to render shape C's `⚠️ **Effort override**` line only when it reads `set`. Add a dated amendment to ADR 0028 Results §4 recording that the effort now comes from the session transcript rather than a hook-recorded PreToolUse value. `scripts/test-report-conventions.sh` gains cases that both SKILL.md files name `session-effort`, that neither contains "nothing records it automatically", and that neither passes a literal `--effort unknown`
  - deps: T1, T2
  - covers: Driver-mode entry records the session's effort read from its own transcript · The kickoff warns when `CLAUDE_CODE_EFFORT_LEVEL` is set
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, docs/adr/0028-loop-driver-mode.md, scripts/test-report-conventions.sh
