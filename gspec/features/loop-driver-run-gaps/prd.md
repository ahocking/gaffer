---
spec-version: v2
depends_on: [thin-loop-driver-gaps, stop-report-decision-liveness]
---

# Feature: loop-driver-run-gaps

## Overview

Three gaps in the driver contract, observed by the operator driving run
`20260919T224810-6fc6` (2026-09-19/20) and approved for filing from that run's
stop report. Each is a place where the loop tells the driver to act "as
written" or "as printed" and the written thing cannot be followed. **Gap 1:**
the implementer returned an off-grammar status line on two of seven packets —
one free-form reply with no fields, no `result:` and no path; one with the
packet id as first field and no `result:` — and `templates/status-line.md`
says nothing mechanically refuses that, the reviewer is the gate. One cost a
full review cycle for a one-line reformat; the other was passed as
non-blocking. **Gap 2:** the packet-close write in `skills/run-loop/SKILL.md`
§3.6 names `status: running` and the `findings:` index as what must carry
through, and nothing else; a driver following it literally drops `run_id` and
the `driver_*` claim keys, after which `run-digest` refuses (no run id) and a
resume's `begin-run` would mint a new id, orphaning the run directory. §2's
fresh-run write deliberately omits `run_id`, which makes §3.6's silence read
as intended. Hit on packet 1, repaired by hand. **Gap 3:** `run-tally`'s
DECISIONS counts routing records; the end-of-run architect's ADR 0026 arm-2
proposal leaves none, so DECISIONS printed 0 while the stop report carried one
real decision block, and the driver had to render a 1 against a printed 0 —
breaking "render as printed" to keep "the tally indexes the sections".

Filed as one feature under ADR 0026 arm 2: every parent is derived-done, so an
unchecked capability added to any of them would make shipped work read as
incomplete and block everything downstream. The operator chose a mechanical
status-line check over a prompt-only fix.

## Users & Use Cases

- **The loop driver** — a session in driver mode holding only status lines.
  It routes on the first field, passes the line to `route` and `write-result`,
  writes run-state from what §3.6 tells it to carry, and renders the tally as
  the core prints it. Every gap above lands on it first.
- **The operator reading the stop report** — reads 🔀 as "waiting on me"; a
  proposal the header cannot count is a decision block the tally does not
  index.
- **A resuming session inheriting the run** — reads `run_id` back to find the
  run directory, its routing log and result files. A checkpoint that lost the
  id hands it a different run.
- **A dispatched agent that misformats its one line** — today learns that from
  a reviewer's `fix`, one full cycle later, or not at all.

## Scope

**In**
- a mechanical status-line grammar check on the driver's path, and the
  driver's re-dispatch rule on a refusal.
- the packet-close carry clause naming every key that must survive a
  whole-file write.
- a routing record for the end-of-run review, so the digest and tally see an
  arm-2 proposal.
- sweep cases in `scripts/test-runstate.sh` for each script change, and prose
  pins in `scripts/test-report-conventions.sh` for each skill clause.

**Out**
- changing the status-line grammar itself.
- changes to the dispatched agents' prompts (`agents/implementer.md` and its
  siblings) to re-teach the grammar.
- the DECISIONS aging rules — `stop-report-decision-liveness` owns them.
- the resume skill's writes — unaffected, since it keeps `run_id` through its
  own `begin-run` call.
- retrying a malformed status line more than once.
- legacy parallel-mode keys (`mode`, `packets`, `lanes`) in a pre-retirement
  run-state — a resumed one is `/gaffer:migrate`'s surface.

**Deferred**
- nothing beyond the Deferred Decisions below.

## Capabilities

- [x] **P0**: A malformed status line is refused before it reaches routing, and re-issued by the same agent once
  - a `runstate.sh` subcommand — a status-line check the driver runs on every
    returned line — accepts a line exactly when it is one line containing no
    backtick and no `$`, its first field (everything before the first ` · `)
    is one word, the segment between its second-to-last and last ` · ` is
    literally `result: needs-reading` or `result: no`, and its last field
    (everything after the last ` · `) is non-empty and whitespace-free; on
    failure it exits non-zero and prints one reason naming the rule that
    failed. A well-formed line whose `<what changed>` field itself contains
    ` · ` passes
  - `route --status` and `write-result --status` refuse a line the check
    refuses, printing the same reason, writing no routing record and no result
    file
  - the driver's routing step (`skills/run-loop/SKILL.md` §3 and the Routing
    section of `agents/loop-driver.md`) states the rule: on a refused line,
    re-dispatch the same agent once, passing the printed reason and nothing
    else. A second refusal of a line the driver does not route on proceeds to
    the reviewer dispatch exactly as today; a second refusal of a line the
    driver would have routed on (the reviewer's verdict, the decider's token)
    is escalated as a blocking question naming the agent and the printed
    reason, and the driver never substitutes a line of its own. The
    reviewer's content gate is unchanged
  - `scripts/test-runstate.sh` carries the two shapes the Overview names,
    each failing the check with its expected reason, plus the middle-field
    pass case

- [x] **P0**: A packet-close write carries the run identity and driver claim through
  - the close-out clause in `skills/run-loop/SKILL.md` §3.6 names, as an
    enumerated list, every column-0 key that must survive the whole-file
    `write` because the close does not itself produce it: `schema`, `run_id`,
    `branch`, every `driver_*` key present (`driver_host`, `driver_since`,
    `driver_heartbeat`, and `driver_pid` when the claim recorded one),
    `status: running`, `pending_questions`, and the `findings:` block — each
    copied from the on-disk `.agents/run-state.yaml` being replaced, the
    source rule `loop-entry-routing-gaps` set for the findings block.
    `updated_at` is the writer's own stamp; `last_green_commit`, `backlog`
    and `note` are the close's own output
  - after a write that follows the clause on a mid-run checkpoint,
    `run-digest` resolves without its no-run-id refusal, and `begin-run` on
    the same file prints the `RUN_ID=` it held before the write and mints
    nothing
  - the clause is pinned in `scripts/test-report-conventions.sh` beside the
    fresh-run clause's pin, asserting each named key appears in the extracted
    span

- [x] **P1**: An end-of-run arm-2 proposal is a counted decision
  - the termination step in `skills/run-loop/SKILL.md` §4 records the
    architect's routing outcome through the core: when the architect's status
    line reports an arm-2 proposal in its free-text clause — the driver
    judging it from the line it already relays; no new status token is
    introduced — the driver calls the routing subcommand with the token
    `hand-off-feature`, that status line as `--status`, and a fixed id naming
    the run's termination review rather than any packet; the printed `ACTION`
    is not acted on — the record is the whole purpose of the call — and no
    outcome is recorded for the termination id
  - `run-digest` then emits a `handoff-feature` line for that id carrying the
    architect's status line, `run-tally`'s DECISIONS includes it once — the
    existing dedup of a handed-off packet's own decision line unchanged — and
    the stop report's 🔀 section carries exactly that many blocks, the figure
    rendered as printed
  - an architect result that routes everything to arm 1, or finds nothing to
    route, records nothing and changes no figure; the digest's `packet` lines
    are unchanged, the termination id having no handoff file
  - pinned by a `run-tally` case in `scripts/test-runstate.sh` with a
    termination record, and by a `scripts/test-report-conventions.sh` fixture
    stop report whose header 🔀 is the printed DECISIONS and whose body
    carries one block for the proposal, yielding no `decision-count` finding
    from `scripts/report-lint.sh`

- [x] **P0**: Every change above has an owning sweep case, none vacuous, none silently skipped without `jq` or `python3`
  - every script change this feature makes has a case in
    `scripts/test-runstate.sh` asserting a literal, non-empty expectation,
    verified non-vacuous by making the mutation it exists to catch (reverting
    the fix) and observing the sweep turn red
  - every new case this feature adds to `scripts/test-runstate.sh` is mirrored
    in the block that runs with `jq` and `python3` absent from `PATH` and
    produces the same result there, except a YAML-parsing case, which skips
    loudly in both when no parser is present — both rules inherited by
    reference from the owning-sweep capability of `runstate-write-integrity-gaps`
  - every skill clause this feature adds or rewrites is pinned in
    `scripts/test-report-conventions.sh` by a content-anchored extraction with
    a non-empty guard and an end-anchor overrun refusal, the form
    `loop-entry-routing-gaps` requires of every extraction in that sweep

## Dependencies

- `thin-loop-driver-gaps` — the parent. Owns the status-line template, the
  routing and digest subcommands and the report lint. Derived-done; nothing
  of it is re-opened.
- `runstate-write-integrity-gaps` — owns the no-tools-mirror and loud-skip
  rules the owning-sweep capability inherits. Complete; nothing of it changes.
- `stop-report-decision-liveness` — owns the DECISIONS definition and its
  still-awaiting aging rules. Complete; extended here by one record kind.
- `loop-entry-routing-gaps` — owns the on-disk-source rule for the carried
  findings block and the overrun-refusal form for prose pins, both reused by
  reference. Complete; nothing of it changes.

## Assumptions & Risks

- Assumption: a single re-dispatch with the reason is enough — both observed
  failures were one-line reformats, and the reviewer, doc-writer and architect
  lines conformed on every packet of that run.
- Risk: the grammar check is stricter than the free-text middle fields allow —
  the template says the middle may contain ` · `. Pinned by the pass case.
- Risk: a termination record keyed to no packet confuses the open-packet sweep
  or the sweep fixtures. It must never be written to the outcomes log, whose
  readers treat any `kind`-bearing record as a packet start; the routing log
  is the only home.
- Assumption: the loop calls `claim-driver` without a pid, so three `driver_*`
  keys are on disk today.

## Success Metrics

- On the next run in this repository, a malformed status line costs one
  re-dispatch and zero reviewer cycles.
- A driver following §3.6 literally never has to repair `run_id` or the
  driver claim by hand, and no resume of such a run mints a second id.
- The stop report's printed DECISIONS equals its 🔀 block count without the
  driver overriding either.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- The status-line check's subcommand name, and whether it is a standalone
  subcommand that `route` and `write-result` call or is folded into both.
  Deferred because either satisfies the capability; a decomposition call.
- Whether `runstate.sh write` itself refuses content lacking a `run_id` line
  when the file it replaces carries one. Deferred because the refusal must
  still admit §2's deliberate omission over a `done` checkpoint; choosing the
  condition that separates that from a mid-run drop is the decision.
- The fixed id the termination record carries. Deferred because it only has
  to satisfy the packet-id charset, collide with no packet, and read as a
  title when rendered; a naming call.
