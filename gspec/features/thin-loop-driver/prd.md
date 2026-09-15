---
spec-version: v2
depends_on: [loop-measurement, retire-unused-loop-modes, retire-autonomy-levels]
---

# Feature: thin-loop-driver

## Overview

This is part 3 of the 2026-09-14 loop-cost redesign. Today the main session plays the Chief Engineer from the 40,081-byte `run-loop` instructions and may implement a packet itself; design-heavy packets may be implemented inline. In one consumer repo, main sessions ran 150–290 turns each, and in 14 of 95 packets the main session and the implementer edited the same file.

This feature keeps the main loop session's context small over 10–20 hour runs by moving detail into files and judgment into short-lived agents. The session running the loop enters driver mode: it passes file paths, reads one status line per agent, routes on the reviewer verdict and is blocked from editing. The operator keeps talking to it on the model and effort they chose. The driver stays in the main session, whose prompt cache lasts an hour against a subagent's five minutes. Relay's dispatched coordinator cost 1.84× inline because it re-read large state and polled; the driver does neither.

## Users & Use Cases

- **The operator** drives several projects at once from Claude desktop, often on Opus or Fable at high effort. They want long unattended runs that stay cheap, to ask and answer the driver's questions mid-run, and to return the same session to ad-hoc design work afterwards.
- **The plugin maintainer** wants the main session's role small and enforced by the guard, not only instructed.
- **A consumer repository** gets the same loop with less main-session cost.

## Scope

**In**
- the six capabilities below
- slimming the `run-loop` and `resume` instructions to the driver role
- the `loop-driver` agent and instructions

**Out**
- what the escalation decider decides, and its periodic review (`escalation-decider`)
- implementer context checkpoints and budget signals (a later redesign part)
- relay and parallel mode (retired by `retire-unused-loop-modes`)

**Deferred**
- nothing beyond the Deferred Decisions below

## Capabilities

- [ ] **P0**: A session running the loop is in driver mode
  - a session enters driver mode when `/gaffer:run-loop` or `/gaffer:resume` starts the loop in it, including a session launched with `claude --agent gaffer:loop-driver` (`model: inherit`), and leaves it when the loop renders its stop report, whether it stopped, paused or finished; after that the same session can edit again. Compaction does not end driver mode, and afterwards the session still follows the `loop-driver` instructions
  - in driver mode, the guard refuses Edit, Write, MultiEdit and NotebookEdit calls and the shell write forms it recognises (`sed -i`, `cat >`, `tee`, `cp` and similar) made from that session's main thread, unless the target is under `.agents/`, giving driver mode as the reason and a pause as the way out. Calls from its subagents, and git, gaffer's scripts and other commands without a recognised write form, are not refused
  - driver mode is keyed to one session: it never blocks another session, and a mark left by a session that crashed or closed mid-run blocks no session, that session reopened included
  - the kickoff states the session's model and effort (effort as unknown when it cannot be read) and never asks to change either

- [ ] **P0**: Agents take a handoff file and return one status line
  - when the loop begins a packet (as `loop-measurement` defines it), a script writes its handoff file holding the task, file hints and acceptance criteria, and each dispatch for that packet passes only that path, plus the review file's path on a fresh implementer attempt
  - every agent the loop dispatches returns exactly one status line (status, what changed, whether its result file needs reading, and that file's path) and writes everything else to its result file
  - the driver never opens a result file, which the escalation decider reads instead, and never polls: it waits for each dispatch to return and runs no repeated check while an agent works
  - handoff and result files are gitignored, so a pause stash and `resume`'s reconcile leave them in place. When `run-loop` or `resume` starts, it keeps the files of the run it drives and of the run before, and removes older ones

- [ ] **P0**: The reviewer verdict routes each packet mechanically
  - the reviewer returns exactly one verdict, on triggers that exclude each other: `pass`, the acceptance criteria are met and there is no blocking finding; `fix`, a failure its result file (the review file) describes precisely enough for another implementer to correct; `escalate`, anything else. When more than one could apply, or which applies is unclear, `escalate` wins
  - `pass` → the packet lands as a green commit and the loop advances; `fix`, or an escalation decider `retry`, → a fresh implementer attempt, meaning a new agent given the handoff and review files, whose work is reviewed again; `escalate`, or `fix` once the packet's attempts are used → the escalation decider, whose `reorder`, `append-task` or `hand-off-feature` makes the loop discard the packet's work to the last green checkpoint, keeping the decider's changes, and advance (a handed-off packet is not begun again this run), and whose `ask-operator` stops the loop on that question. The attempt count is set in `.agents/project-overrides.yaml` (default 1 when missing, invalid or 0) and counts attempts from either route since the packet's latest start
  - a packet in the design-heavy tier is implemented, and re-attempted on `fix` or `retry`, by a dispatched Opus agent that can edit (the architect or the UX designer, chosen when the packet is scoped), never by the driver
  - outcomes are recorded exactly as `loop-measurement` defines them: a fresh implementer attempt is a retry, and routing to the escalation decider is not an ending

- [ ] **P1**: Reports are thin and built from files
  - when a packet ends, the operator gets one line naming it by id and plain-English title with its outcome, plus one line per escalation decider decision since the last report, in place of ADR 0023's per-packet check-in, and ADR 0023 is amended to match
  - the kickoff, including on resume, and the stop report are assembled, without the driver opening result files, from handoff files, result files and `loop-measurement`'s outcome records, never from the driver's memory of the run
  - a stop report rendered after compaction, or by a session that resumed another session's run, still names every packet the run began with its outcome, or that it is paused, and each `hand-off-feature` question the run recorded

- [ ] **P1**: The operator can ask questions and request edits mid-run
  - the driver answers an operator question from handoff files, status lines and findings first, without reading source
  - a question those cannot answer goes to an agent that writes only its result file, whose status line carries the short answer and whose result file holds the rest; the driver passes the line and the file's path to the operator
  - an edit the operator asks for mid-run is made by a dispatched agent between packets and lands before the next packet begins, so no packet's commit or rollback includes it, and the run continues without a stop report
  - to edit by hand, in that session or outside it, the operator pauses first; once the stop report is rendered, the session edits directly

- [ ] **P1**: Long runs compact, and can pause on a schedule
  - the auto-compaction threshold can be set per repo, and a loop session where neither the repo nor the operator has set one uses gaffer's default, so long runs compact instead of growing. The kickoff states the threshold in effect, or that it cannot tell
  - with a periodic pause of N packets set in `.agents/project-overrides.yaml`, once N packets have ended since the loop last started or resumed, the loop pauses exactly as `/gaffer:pause` does, and the stop report names the setting as the reason
  - the periodic pause is off by default, and off when unset or 0, because it stops an unattended run until someone resumes it

## Dependencies

- `loop-measurement`: the packet start and outcome definitions this feature records against, and the spend report its success metrics use.
- `retire-unused-loop-modes`: a single sequential mode with no relay contract.
- `retire-autonomy-levels`: no autonomy-level branching for the driver to carry.
- `escalation-decider`: depends on this feature; it receives `escalate` routing and reads result files.

## Assumptions & Risks

- Assumes Claude Code lets a repo set the auto-compaction threshold (`autoCompactWindow` or `CLAUDE_CODE_AUTO_COMPACT_WINDOW`).
- A status line that grows past one line breaks the return contract; nothing refuses it, so review must catch it.
- The `loop-driver` instructions are followed, not enforced; only the edit block is enforced. It covers only the shell write forms the guard recognises: other shell writes are not refused, produce no edit event, and appear in metrics only as a command class.
- Answering many operator questions can still grow the driver's context; compaction is the backstop.
- The edit block assumes hooks carry an agent id only inside subagents; one arriving without it is refused as a main-thread call.

## Success Metrics

- **Main-session edits.** In that consumer repo, every loop run after release has 0 successful Edit, Write, MultiEdit or NotebookEdit calls from a driver session's main thread in driver mode with a target outside `.agents/`. A run with no event records, or with any such edit event that cannot show whether its target was under `.agents/`, reports unmeasured, never 0. Reference: about 174 main-session implementation edits in the 8 days before 2026-09-14 (metrics audit).
- **Main-session context.** In each loop run there in the 14 days after release, the largest context of one main-thread turn of a driver session in driver mode (its input, cache-write and cache-read tokens, each message counted once by id as `loop-measurement` counts it) is no more than the threshold that run's kickoff stated, plus 10%. A run lacking usage data or a stated threshold reports unmeasured. Reference: 395k tokens, the largest main-session context recorded before release.
- **Main-session cost per landed packet.** Main-session API-equivalent dollars for that repo in the `loop-measurement` spend report, including main sessions not running the loop, divided by packets recorded green there, is at most half as much over the 14 days after release as over the 14 days before, both using the same price table. A window with unpriced main-session tokens or unmeasured outcome coverage reports unmeasured. Reference: about $7.50 per packet ($645 over about 86 packets in one week).

## Implementation Context

> This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Tuning the default compaction threshold.** A starting value ships; tuning waits until the spend report shows main-session context size under driver mode.
