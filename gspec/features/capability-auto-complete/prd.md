---
spec-version: v2
depends_on: [completion-record-drift-gaps]
---

# Feature: capability-auto-complete

## Overview

The loop flips each **task** checkbox inside the packet commit that lands it, but
never flips a feature's **capability** checkbox once the last task covering it
lands. The capability-drift scans that the parent (`completion-record-drift`)
added only report the gap, at preflight and at termination, and leave the flip
to the operator. So every finished feature ends with a manual chore:
`packet-bundling` needed five capabilities flipped by hand after its run
(`b47d5cd`). The operator's decision (2026-09-17): when a feature is complete, it
should be marked completed. This feature makes the loop record completion
itself, in the same commit as the work that completes it. Where drift already
exists, the loop reconciles it.

**This deliberately reverses the parent's "Out: flipping a capability checkbox,
automatically, ever."** The parent feared a silent wrong flip unblocking
everything behind a feature. The flip here uses the same mechanical rule a human
applies when reconciling drift: at least one covering task, every covering task
checked, and no unchecked task in the feature whose `covers:` quote is
unmatched. The loop then sees everything the drift report showed the human, and
in practice the operator flips on that report without gathering any further
evidence. What the rule cannot judge
is still reported and never flipped, because that is where human judgement adds
something.

## Users & Use Cases

- **The run that lands a feature's last covering task.** It checks the task
  today and leaves the capability half-recorded. With this feature, the feature
  reads complete from that commit onward.
- **A feature waiting behind it.** It is unblocked the moment its dependency is
  finished in fact, not when an operator next reads a kickoff.
- **The operator.** They stop reconciling records by hand, and are shown only
  the rows that need judgement: unmatched `covers:` quotes, and uncovered or
  unrecognized capabilities.
- **The next run's preflight.** It finds drift left by an older run, or by work
  landed outside the loop, and closes it rather than reporting it again.

## Scope

**In**
- A new adapter subcommand that flips a feature's finished capabilities. It is
  separate from the one-task flip.
- Running that subcommand inside the packet commit, and on the resume path that
  adopts an orphaned landed commit.
- Reconciling drift at the preflight and end-of-run scans, as a separate commit
  outside any packet, and naming each feature it holds back.
- Sweep cases for every flip and no-flip judgement.
- Updating the standing prose that assigns reconciliation to the human.

**Out**
- Unflipping a checked capability, for any reason.
- Flipping on the strength of acceptance-criteria text or counts.
- Changing how completion is derived, the verbatim `covers:` match, or the three
  unjudgeable classes.
- Blocking, halting or failing a run on drift or on a failed flip.
- A new report shape, glyph, tally figure or outcome state.
- Changing the one-task flip. It stays one id, one line.

**Deferred**
- Flipping in the dispatched-worktree context outside a loop packet. That
  context commits no gspec record today.

## Capabilities

- [x] **P0**: The adapter can mark a feature's finished capabilities complete
  - Given a feature slug, a new subcommand flips a capability's box only when
    at least one task covers it and every task covering it is checked. Each
    flipped capability is named in the output. The sweep case uses one
    fixture feature with two capabilities: one whose covering tasks are all
    checked, and one with an unchecked covering task. It asserts that the first
    is flipped and named, and that the second is untouched and absent.
  - The subcommand never flips an uncovered or unrecognized capability, and
    never unflips a checked one. A feature with any unchecked task whose
    `covers:` quote is unmatched flips **no** capability: a typo'd quote may be
    evidence against one that would otherwise flip, and flips are never undone.
    The sweep has one case per unjudgeable class, each asserting no box flipped;
    the unmatched case has capability A's matched tasks all checked plus an
    unchecked task with an unmatched quote, and asserts A still unchecked. A
    further case asserts a checked capability with an unchecked covering task
    stays checked.
  - Only the checkbox characters of the flipped lines change. The sweep asserts
    this by checksum: a PRD whose flipped lines are reverted is byte-identical to
    its original. A second run is a no-op. It names nothing, and the file is
    byte-identical to the file after the first run.
  - Exit behaviour mirrors the task flip:
    - where there is no gspec project, the call is skipped, not failed;
    - a malformed argument is a usage error;
    - a slug that does not resolve fails distinguishably from a skip.

    The fixtures are built in both layouts the adapter reads. The sweep has a
    case each for the non-gspec skip, the malformed argument and the
    unresolvable slug.

- [x] **P0**: A capability completes in the same commit as the task that completes it
  - When a packet lands, the loop runs the capability flip for the landed
    feature after the per-task flips, and stages the PRD into that one packet
    commit. A bundle is handled the same way, after every member's task flip.
  - The resume path that adopts an orphaned landed commit runs the same
    capability flip. Since that commit already exists, the flip lands as its own
    commit, in the same form as the reconciliation commits, so a crash between
    landing and recording leaves no drift.
  - A packet that completes no capability leaves its PRD out of the commit.
    Where a flip fails, the loop reports it through the existing packet line and
    the packet still lands. The task record is unaffected.

- [x] **P0**: Drift the loop finds is reconciled, not handed to the operator
  - The preflight scan flips each drifted capability. So does the scan at the
    end of the backlog-complete path. Each scan's flips land as one commit on the
    integration branch, staging only the PRDs it changed, outside any packet.
    That commit carries no packet trailer, so run metrics count no packet for
    it. It goes through the loop's own scripts and commit path, never a
    main-thread edit.
  - The kickoff states what preflight flipped, and the stop report states what
    the end-of-run scan flipped. Each flip names its feature and capability, and
    both use the existing line forms at each site.
  - Unjudgeable counts are still reported at both sites and are never flipped.
    A failed flip or commit is reported and never halts the run. Where there is
    no gspec directory, both sites stay a silent no-op.

- [x] **P0**: The drift detector itself stays read-only
  - The detector writes nothing. Its existing sweep case, which asserts every
    plan and PRD is byte-identical by checksum, keeps passing unchanged.
  - All capability writing lives in the new subcommand. The detector gains no
    write flag, mode or side effect, so a scan can still be run by anyone
    without touching the record.

- [x] **P1**: The standing wording says the loop reconciles the record
  - Three places currently say that reconciling a drifted capability record is
    the human's call:
    - the ADR 0025 bullet in `CLAUDE.md`;
    - ADR 0025 itself;
    - the `run-loop` and `resume` prose.

    Each now says the loop reconciles judgeable drift, and that it reports
    unjudgeable rows to the operator.
  - The parent's reasoning is kept as history, in the same way that superseded
    ADR revisions are kept: it is dated and marked as reversed, never deleted.
    Wherever that reasoning is kept, a pointer to this feature records the
    reversal and its justification.

- [ ] **P0**: A feature the loop cannot complete yet is still named
  - When the capability-completion subcommand holds a feature back, because an
    unchecked task's `covers:` quote matches no capability, the loop names that
    feature with the subcommand's reason: once in the kickoff, using the
    existing per-row alert line form, and once in the stop report's next-steps
    section on the backlog-complete path, as an unglyphed line. Before this
    feature the drift scan named these rows; the flip rule's hold-back made
    them silent.
  - Neither site flips, restores or commits anything for a held feature.
  - The `run-loop` prose, the `resume` prose and the ADR 0025 revision each
    describe a held feature the same way: named, never flipped, with the
    capability-completion subcommand's reason.

- [ ] **P0**: Follow-up correctness fixes from the end-of-run review
  - When no task handoff exists for the adopted packet (the file that names the
    landed feature), the `resume` adopt path skips capability completion, and
    the end-of-run scan reconciles.
  - The capability-completion subcommand handles a PRD file with no trailing
    newline, and a sweep case covers it.
  - The prose is corrected in three places: the land step (§3.6) and the
    `resume` adopt path describe staging the PRD in the same terms; the
    "CHECKED=none" parenthetical no longer says it means only the non-gspec
    case, since exit-4 drift prints it too; and the §3.6 failure restore states
    why it restores from the index rather than from HEAD.

## Dependencies

- `completion-record-drift-gaps` supplies the drift scan's final form and the
  completion derivation that the flip rule shares. It is derived-done, and
  nothing here re-opens it.
- `completion-record-drift` owns the two reporting sites, the three unjudgeable
  classes and the checksum case the read-only-detector capability keeps green.
  Its never-flip decision is reversed here, but its capabilities are not
  re-opened.
- `packet-bundling` defines the bundle commit that the same-commit capability
  stages into. It is derived-done.
- `run-state-cleanup` owns the one-task flip that the new subcommand sits beside
  and leaves unchanged.
- `gspec-adapter-consistency` is **not blocking, but file-overlapping**: it
  edits the same adapter and sweep. The two should not be in flight against the
  same files at once.

## Assumptions & Risks

- Assumption: `covers:` is the only evidence that links a task to a capability.
  The flip rule adds no second signal.
- Risk: a wrong `covers:` quote that still matches verbatim will flip the wrong
  capability silently. That is exactly as wrong as a human flipping on the same
  report, and the packet's review is the gate for plan text.
- Risk: the prose updates in the standing-wording capability are read at dispatch and no
  sweep can reach them. The reviewer is the only gate there.
- Accepted consequence: capability boxes can now change without an operator in
  the path. Unjudgeable rows remain the only reconciliation work left for the
  human.

## Success Metrics

- A feature's capabilities read complete in the commit that lands its last
  covering task. This is checkable per packet commit against its PRD.
- There are zero manual `spec:` capability-flip commits after this ships. This
  is countable in git history.
- Drift *detected* at every preflight after the first, before it reconciles
  anything, is `drift=0` apart from unjudgeable rows and work landed outside the
  loop. This is visible in each kickoff.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **The subcommand's name and output keys.** Every capability here is satisfied
  whatever they are, so this is a decomposition call.
- **Whether the preflight and end-of-run reconciliation commits share one
  message form, or name their site.** This is a report-volume detail that the
  first real reconciliation can settle.
