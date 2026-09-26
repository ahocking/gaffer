---
spec-version: v2
depends_on: [thin-loop-driver, handoff-verification-contract]
---

# Feature: implementer-continuation

## Overview

Nothing bounds how long an implementer dispatch runs. The harness's dispatch
carries no turn cap, so a packet that does not converge ends only when the
reviewer is finally reached — or never, when the session dies first. This
repository's own week of 2026-09-14 measured the tail: 60 of 242 implementer
runs went 150 turns or more and carried 74% of implementer cost, with single
packets reaching ~790k of context; the re-read per tool call grows from ~98k
under 100 calls to ~280k over 400; and 27 of 98 packets had no recorded
outcome, mostly the longest. The spec tool's own build driver measured the
same shape upstream (one uncapped run at 419 turns and 130M tokens), capped
its runs at 120 turns, and briefed each continuation with the partial work on
disk. That second half matters as much as the cap: today a `fix`/`retry`
re-dispatch tells the agent nothing about what the previous attempt left in
the tree, so a fresh attempt recreates files it could have read.

The cap here has to be cooperative — the same design as the ADR 0017 pause.
The authoritative mechanism is something the agent itself does at a safe
boundary because its handoff told it to. So every implementer handoff states
a budget and the stop rule at it, the agent returns `continue` as its status
when it stops there, the driver routes that token mechanically to a fresh
dispatch of the same packet without a review and without spending an attempt,
and every continuation or re-attempt is briefed with what is already on disk.

## Users & Use Cases

- **The implementer reading a handoff** — needs its budget, what to do when it
  reaches it, and — when it is continuing or re-attempting — which files the
  previous dispatch already touched, so it verifies them rather than
  recreating them.
- **The driver in driver mode** — reads one status line per dispatch and never
  opens a result file. It needs `continue` to route through the same
  mechanical call as every other token, with the cap enforced by the script
  rather than by its own memory.
- **The operator** — bound by a weekly token allowance, not wall clock. Wants
  the long tail bounded and every stop to leave a record.
- **The metrics reader** — needs each continuation to be a visible record with
  a distinct shape, so a later feature can tell a continued packet from a
  retried one.

## Scope

**In**
- A budget line in every implementer handoff — 120 tool calls, overridable
  per repository in `.agents/project-overrides.yaml`
  (`implementer_turn_budget`) — and the stop rule at the budget: a safe
  boundary, partial work left uncommitted, the result file states what is
  done and what remains, and the status line's first token is `continue`.
- `runstate.sh route` accepts `continue` and routes it to a continuation of
  the same packet, bounded by `packet_continuations` (3 per attempt) and
  refused as `stop` past it; both driver surfaces — `skills/run-loop/SKILL.md`
  §3.4–3.5 and the `## Routing` section of `agents/loop-driver.md` — read the
  implementer's status line before dispatching the reviewer and act on it.
- A partial-work block in the handoff of every continuation and every
  `fix`/`retry` re-dispatch, absent when there is no partial work.
- `templates/status-line.md` documents `continue`; `agents/implementer.md`
  states the budget and stop rule from the agent's side; the annotated
  reference copy of `project-overrides.yaml` under
  `templates/spec-driven-base/` carries both new keys.
- Cases in `scripts/test-runstate.sh` for each script change.

**Out**
- A hard turn cap or a coercive deny hook — not available on this dispatch,
  and deferred for the same reason ADR 0017 deferred it.
- Committing red work; the loop's commit stays green-only.
- How the reviewer judges, and its verdict vocabulary.
- Sizing packets on entry (`packet-bundling` owns bundling; a smaller first
  slice is a plan-side matter).
- Classifying or scoring the records this feature writes — that is
  `dispatch-progress-metrics`.
- Any parsing of `gspec/`; every gspec read stays in `scripts/gspec-backlog.sh`.

**Deferred**
- An adaptive budget (raise it when a continued packet still checks nothing —
  the upstream 120→240→360 ladder) until `dispatch-progress-metrics` can show
  whether continuations converge.
- An advisory hook in the shape of `hooks/pause-check.sh` naming the count
  against the budget. Injected context is untrusted data an agent may decline
  (ADR 0017), the prompt-stated budget is the authoritative mechanism, and it
  is built only if `dispatch-progress-metrics` shows the budget is not
  honoured.

## Capabilities

- [x] **P0**: Every implementer handoff states its budget and the stop rule
  - the handoff for an `implementer` dispatch carries one line stating the
    budget in tool calls: `implementer_turn_budget` from
    `.agents/project-overrides.yaml` when it is a positive integer, else 120;
    the line is present on the first dispatch, on every continuation and on
    every `fix`/`retry` re-dispatch, and absent from a handoff for any other
    `--agent`
  - the same line states what to do at the budget: stop at a safe boundary —
    never mid-edit — leave the partial work uncommitted in the working tree,
    write what is done and what remains to the result file, and return a
    status line whose first token is `continue`; `agents/implementer.md`
    states the same rule from its side, including that a `continue` is the
    correct outcome and not a failure to report as `blocked`
  - `scripts/test-runstate.sh` gains a case for the default, one for the
    override, one for a missing/invalid/zero override reading as 120, and one
    asserting a `doc-writer` handoff carries no budget line

- [x] **P0**: The driver routes `continue` to a continuation without a review or an attempt
  - `scripts/runstate.sh route` accepts `continue` as a ninth token, and
    both driver surfaces — `skills/run-loop/SKILL.md` §3.4 and the
    `## Routing` section of `agents/loop-driver.md` — read the implementer's
    status line before any reviewer dispatch: a first token of `continue` is
    passed to `route` with the line as `--status`; any other first token
    proceeds to the reviewer exactly as today; on both surfaces the
    twice-refused enumeration widens to the implementer's line, so a line
    `check-status` refuses twice is escalated as a blocking question naming
    the agent and the printed reason, never passed to the reviewer
  - `continue` within the cap prints `ACTION=continue`; in this order, the
    `continue` routing record is written by `route` first, then the driver
    records `record-start "$MEMBERS" --continue`, rewrites the packet's
    handoff file in place so the partial-work block (below) is present, and
    dispatches a fresh `implementer` with that same handoff path and no
    review path; the routing record is what distinguishes a continuation from
    a resume — a consumer joining the two logs reads it in preference to a
    start record at the same boundary; the reviewer is never dispatched on a
    `continue`, and no reviewer verdict is recorded for it
  - a continuation spends no attempt: `ATTEMPTS=` for a `continue` prints the
    packet's live attempt count and never increments it, and a `fix`/`retry`
    routed after a continuation counts against `packet_attempts` exactly as
    it would with no continuation between — the attempt window (since the
    packet's latest `start` record) is untouched
  - `templates/status-line.md` names `continue` as an implementer status the
    driver routes on, alongside the reviewer's and decider's tokens;
    `scripts/test-runstate.sh` gains cases for the in-cap route, the
    unchanged `ATTEMPTS=` across it, and a `fix` after a continuation
    counting one attempt

- [x] **P0**: Continuations are capped per attempt and every one leaves a record
  - one counted unit is a `continue` routing record for the packet since the
    later of its latest `start` record and its latest routing record whose
    action was `attempt`, against `packet_continuations` from
    `.agents/project-overrides.yaml` (positive integer, else 3)
  - past the cap the token routes as `stop`, printing `ACTION=stop` and a
    `question:` line naming the packet and the cap, never `attempt` and never
    looped
  - every `continue` writes a routing record carrying token, action and
    status line only — no path; an in-cap `continue` changes neither
    `run-digest`'s `decision`/`handoff-feature` lines nor `run-tally`'s
    `DECISIONS`, and the refused over-cap `continue` is counted by
    `DECISIONS` on the same still-awaiting rule as a retry past its limit, so
    the header figure equals the number of 🔀 blocks
  - `scripts/test-runstate.sh` gains cases for the refusal at the cap, the
    override and its default, the record's presence and shape, and
    `DECISIONS` before and after an in-cap and an over-cap `continue`

- [x] **P0**: A continuation or re-attempt is briefed with the partial work on disk
  - the partial-work set is the paths `git status --porcelain` on the main
    checkout reports that fall within the packet's scope — the union of its
    members' `allowed_files` — each marked existing or deleted; when the
    packet declares no scope, the set is bounded to the paths dirty since the
    run's `last_green_commit`, never the whole checkout
  - when the set is non-empty, the handoff for a continuation and for a
    `fix`/`retry` re-dispatch carries one block, under its own heading,
    listing that set and stating: read these files as they now stand, verify
    them, and continue — do not recreate them; the block is produced by
    `scripts/runstate.sh` when the handoff is rewritten in place, which the
    driver does before a continuation and before a `fix`/`retry`
    re-dispatch; the first dispatch of a packet never carries it
  - when the set is empty the handoff is byte-identical to one written with
    this mechanism absent — no empty section, no heading
  - the `REQUIRED` block's position and content are untouched (the six lines,
    the extension lines and the driver's two conditional lines unchanged in
    text and order), and the paths appear in the handoff only and in no
    metrics, routing or outcomes record; `scripts/test-runstate.sh` gains a
    case with a dirty scoped path, one with a dirty path outside the scope
    (block absent), one with a deleted scoped path, one with a clean tree,
    and one asserting the `REQUIRED` block is unchanged around the block

## Dependencies

- `thin-loop-driver` — the parent: `route`, `record-start`, `handoff`,
  result files and driver mode. Derived-done; nothing here re-opens a
  capability or edits a checked task.
- `handoff-verification-contract` — appends the `REQUIRED` block in
  `runstate.sh handoff`; the partial-work block is placed around it, never
  inside it.
- `packet-bundling` — shipped; a bundle continues as one packet, with one
  `record-start "$MEMBERS" --continue` call per continuation. Not blocking.
- `escalation-decider` — not built; the over-cap stop uses the existing
  `stop` path exactly as the over-limit `retry` does. Not blocking.
- `thin-loop-driver-gaps`, `loop-driver-run-gaps` — **not blocking, but same
  files**: `scripts/runstate.sh`, `scripts/test-runstate.sh`,
  `skills/run-loop/SKILL.md`. Not in flight at once.
- `dispatch-progress-metrics` — consumes the records this feature writes. It
  depends on this feature, not the reverse.

## Assumptions & Risks

- Assumption: the continuation is dispatched immediately, on the same
  checkout, with the partial work uncommitted between the `continue` and the
  fresh dispatch. A run that stops in that window is reconciled by the
  existing rules — the pause path's `git stash --include-untracked` and
  `reconcile`'s scratch discard on a green checkpoint — and the next session's
  `sweep-open` closes the packet as `interrupted`.
- Assumption: `record-start --continue` already exists for a resume
  continuing a packet; a continuation reuses it, and its routing record is
  what tells the two apart.
- Risk: the budget is cooperative, so an implementer can overshoot or ignore
  it. The detector is `dispatch-progress-metrics`' per-dispatch count, not a
  sweep.
- Risk: a `continue` on partial work that does not build would hand the
  reviewer a red tree if mis-routed. The route never sends `continue` to
  review; the reviewer sees only a dispatch whose well-formed line said
  something else.
- Risk: the partial-work block is prompt-enforced at the implementer. An agent
  that recreates a listed file is caught by the reviewer's diff, one cycle
  later.
- Risk: a budget line on every implementer handoff costs context on packets
  that never reach it; one line bounds the cost.

## Success Metrics

Baseline, this repository's week of 2026-09-14: 60 of 242 implementer runs at
150 turns or more, carrying 74% of implementer cost; 27 of 98 packets with no
recorded outcome. Measured by run-metrics on the next consumer run of ten or
more packets:

- No implementer dispatch exceeds its budget by more than 20 tool calls —
  countable from per-dispatch tool-call counts, against the baseline of 60 of
  242 runs at 150 turns or more.
- Packets with no recorded outcome fall to zero: every stop is a `continue`, a
  terminal outcome, or an `interrupted` from `sweep-open`.
- The share of implementer cost in dispatches over 150 turns falls from 74%.

Each is reported as unmeasured, never 0, when its source is incomplete: the
first and third when any dispatch lacks a tool-call count, the second when the
run's outcomes log is absent or partial.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Where the partial-work block sits relative to the `REQUIRED` block.**
  Before or after both satisfy the criteria; decided at plan time with the
  heading that delimits it.
- **Whether `continue` is honoured from the architect, UX designer or
  doc-writer on a packet they implement.** This PRD routes it from the
  implementer's line; the other agents' budgets have not been measured.
