---
spec-version: v2
depends_on: [thin-loop-driver, run-metrics, dispatch-progress-metrics]
---

# Feature: session-effort-reporting

## Overview

A dispatched agent runs at the session's reasoning effort. The newest model
defaults to a lower effort than its predecessor ran at, so a session started
without an effort setting silently ran the implementer (about 760 turns) and
the reviewer (about 350 turns) at that lower default over two days. The loop
kickoff records the session's effort as `unknown`, with the note that nothing
records it, although every transcript row now carries its effort. Run-metrics
shows effort per role in total but not per dispatch.

A per-agent effort override is not possible without new harness support. The
dispatch call accepts no effort. Every session control (the `--effort` flag,
`/effort`, the settings keys, `CLAUDE_CODE_EFFORT_LEVEL`) is session-wide.
Command hooks can read effort but not set it. The only hook that can set it
is an early-access, flag-gated, undocumented event that cannot tell which
agent is running. The only per-agent control is an agent definition's
`effort:` key, and the operator rejected coding effort into agent
definitions. Running each agent as its own session process was rejected
because it rebuilds the loop's dispatch path. So the session's effort is
every dispatched agent's effort. This feature makes that visible at kickoff
and measured per dispatch.

## Users & Use Cases

- **The operator** wants the kickoff to state the effort the whole run will
  use, read from the session rather than assumed. They also want a warning
  when an environment setting overrides it.
- **The maintainer reading run-metrics** wants to see the level each dispatch
  actually ran at, and to spot a run that ran at an unintended level.

## Scope

**In**
- reading the session's effort from the session's own transcript at
  driver-mode entry, in `run-loop` and `resume`.
- the kickoff's Session line stating that effort and that dispatched agents
  inherit it.
- a kickoff warning when `CLAUDE_CODE_EFFORT_LEVEL` is set.
- each dispatch's effort on its run-metrics per-dispatch row.
- amending the stale effort notes in `scripts/spend.sh`, `run-loop` and
  `resume`.
- regression cases in the sweeps that own each changed file.

**Out**
- a per-agent effort override, blocked until the harness offers a
  per-dispatch effort.
- an `effort:` key in any agent definition.
- setting or changing the session's effort. The kickoff states it and nothing
  sets it.
- unsetting, setting or otherwise managing `CLAUDE_CODE_EFFORT_LEVEL`. The
  kickoff reports it and nothing changes it.
- the model-comparison harness's per-replay effort and its `claude-opus-5-5`
  price entry. These are model-comparison-harness tasks: the harness runs each
  step as its own session, so it can pass effort per replay itself.

**Deferred**
- None beyond the Deferred Decisions below.

## Capabilities

- [ ] **P0**: Driver-mode entry records the session's effort read from its own transcript
  - `run-loop` and `resume` pass driver-mode entry the effort carried by the
    latest row of the session's own main-thread transcript that carries one.
    They no longer pass a hard-coded `unknown`, and a search of both
    SKILL.md files for "nothing records it automatically" finds nothing
  - the effort is read, never inferred from the model. It is `unknown` only
    when no main-thread row carries an effort (as on a model that takes none),
    or the session's transcript cannot be found or read. Driver-mode entry
    proceeds in every case
  - a sweep case in the sweep that owns the reader covers a row carrying an
    effort, no such row, a model that takes no effort, and an unreadable
    transcript, asserting the level in the first case and `unknown` in the
    other three

- [ ] **P0**: The kickoff's Session line states the session's effort and that dispatched agents inherit it
  - shape C's Session line says dispatched agents inherit that effort, as far
    as their model accepts one
  - a sweep case pins the line for a recorded level and for `unknown`

- [ ] **P0**: The kickoff warns when `CLAUDE_CODE_EFFORT_LEVEL` is set
  - when it is set to a non-empty value at `run-loop` or `resume` entry, the
    kickoff carries a ⚠️ line saying it is set and overrides the session
    effort for the driver and every dispatched agent this run. The run
    proceeds
  - when it is unset or empty, the kickoff carries no such line
  - a sweep case pins the line for set, empty and unset

- [ ] **P1**: Each dispatch's effort is on its run-metrics per-dispatch row
  - each `packets[].dispatches[]` row carries the effort read from that
    dispatch's own transcript rows: one level when every row carries the same
    one, or the set of distinct levels when it changed mid-dispatch
  - it is `null`, never a guessed level, when no transcript row resolves to
    the dispatch, the dispatch resolved to no `agent_id`, or any of its rows
    carries no effort. A partial read is unmeasured. A run collected before
    this feature has `null` on every row, and a dispatch on a model that
    takes no effort also reads `null`
  - `totals.by_effort` and every other existing field are unchanged
  - `scripts/test-metrics.sh` covers a single level, a level changed
    mid-dispatch, an unreadable effort (`null`), and a legacy run (`null`)

- [ ] **P1**: The `scripts/spend.sh` effort note is amended
  - the header note that dispatched-agent rows carry no `.effort` is amended
    with a dated observation that they now carry it and older rows do not
  - the earlier dated probe stays in the note

## Dependencies

- `thin-loop-driver`: owns driver-mode entry, the enter record and kickoff
  shape C.
- `run-metrics`: owns the collector and `totals.by_effort`.
- `dispatch-progress-metrics`: owns `packets[].dispatches[]` and how a
  dispatch resolves to its `agent_id` and transcript rows.
- `per-agent-model-routing`: related, not a dependency. A per-agent effort
  override would have extended it.

## Assumptions & Risks

- Assumption: every transcript row carries its effort, the main thread's and
  a dispatched agent's alike. Older rows do not.
- Assumption: with no `effort:` key in its definition, a dispatched agent
  inherits the session's effort, and `CLAUDE_CODE_EFFORT_LEVEL` overrides it.
- Risk: a model's live default effort can come from an organisation or server
  setting, so the session's effort must be read, never assumed from the model.
- Risk: if the environment check is skipped, an operator's
  `CLAUDE_CODE_EFFORT_LEVEL` silently changes every agent's effort with no ⚠️
  line. The per-dispatch effort still shows it after the run.

## Success Metrics

- A kickoff on a session whose transcript carries an effort names that level
  rather than `unknown`.
- In a run collected after this feature, every dispatch whose transcript rows
  all carry an effort has a non-null effort on its per-dispatch row.
- The sweep cases named in each capability pin the behaviour on every change.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **A per-agent effort override** — revisit when the harness offers a
  per-dispatch effort.
- **Where the session-effort reader lives and how it finds the session's
  transcript** — a core subcommand or part of driver-mode entry. The choice
  belongs to the architecture step.
- **How the set of levels is written when effort changed mid-dispatch** — its
  shape and order belong to the architecture step. The capability fixes only
  that every distinct level appears.
