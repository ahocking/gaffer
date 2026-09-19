---
spec-version: v2
depends_on: [thin-loop-driver]
---

# Feature: loop-entry-routing

## Overview

The run entry point routes on the durable checkpoint's **existence**, not its
**status**. `skills/run-loop/SKILL.md`:133 sends the session to
`skills/resume/SKILL.md` whenever `.agents/run-state.yaml` is present, and that
skill's decision table (`:184–192`) enumerates three statuses — a clean pause, a
stop on a blocking question, and the mid-flight value a crashed session leaves
behind. The checkpoint documents a fourth (`templates/run-state.yaml`:38, the
completed run), nothing deletes the file when a run completes
(`skills/run-loop/SKILL.md`:505–506 sets that status and stops), and the branch
that handles it correctly sits directly below the redirect (`:137–155`: resolve
the next backlog through the adapter, write a new checkpoint, begin the run). So
a run opening after a completed one — the normal case, since that is how every
finished run leaves the disk — is sent to a skill with no branch for the state
it finds, and the fresh-run branch is unreachable by the condition as written.
Hit live on 2026-09-17 opening the `loop-prose-consistency` run: the session read
the completed status, declined the redirect by judgment, and built a new backlog
through the adapter instead.

Following the redirect is not a stall, and taking the fresh branch has its own
unstated hazard. A completed checkpoint carries no cursor and no pending packets,
so there is nothing to continue and nothing to reconcile, but the resume path
re-marks the finished run as in-flight (`skills/resume/SKILL.md`:256), re-claims
its driver, and keeps its run identity (`:201–202`, minted only when absent) —
the completed run's own record stops reading as complete. On the other side, the
fresh-run write **replaces** the whole file, and the findings index is in it: the
packet-close write states the consequence (`skills/run-loop/SKILL.md`:350–351, an
omitted entry is unlinked rather than edited out), the fresh-run write at
`:152–155` does not, and on 2026-09-17 the driver spliced ten entries across by
hand. Routed to ADR 0026 arm 2 rather than appended: the feature owning both
entry points is derived-done (six of six capabilities checked), the nearest
sibling on the same prose has no plan file and so offers no anchor, and no
feature whose plan still carries unchecked tasks has a capability covering the
loop's entry routing.

## Users & Use Cases

- **A driver opening a run after a completed one** — takes the first decision of
  the run against a test that cannot see the state it is in, and reaches the
  right branch only by deciding the instruction is wrong. Judgment that has to
  fire on the normal case is not a safeguard, it is an unrecorded correction.
- **A driver that followed the redirect** — arrives in a section whose every
  branch assumes work remains. Continuing from there costs more than a wasted
  step: a finished run is re-marked in-flight under its own identity, so the
  record of the run that completed is what pays.
- **A resuming session with a real checkpoint** — depends on the redirect still
  firing for a clean pause, a stop on a blocking question, and a crash. A
  correction that narrows too far starts a fresh backlog over unfinished work.
- **A future editor adding a lifecycle status** — needs one site stating which
  statuses route where. A condition that names none has nowhere to add the new
  value, which is how the fourth status came to be unhandled.

## Scope

**In**
- the run entry point's routing condition on the durable checkpoint: a test on
  the file's existence becomes a test on its status.
- the branch a completed checkpoint takes — the fresh-run path in that same
  section, with no redirect.
- what the routing does with a status it does not recognise.
- the findings index's carry-through on the write that replaces a completed
  run's checkpoint, and what must not cross with it.
- two regression cases in the sweep that owns these files: one over the routing
  condition, one over the carry-through clause.

**Out**
- the resume entry point.
- the checkpoint's lifecycle status values.
- how and when a run reaches the completed status, and that it leaves its
  checkpoint on disk.
- the mint-when-absent rule for a run's identity.
- the session-start advisory that notices a checkpoint at startup — it advises a
  human and routes nothing.
- telling a live second driver apart from a crashed session at the entry point.
- any mechanism change: no script behaviour, no new status, no new report shape.

**Deferred**
- Regression coverage for the unrecognised-status stop. The available pin — a
  token assertion that the routing instruction enumerates its recognised set —
  pins that the set is named, not that an unrecognised value stops, and the stop
  itself is a driver behaviour no prose sweep reaches. Deferred rather than
  taken, with the reviewer as the gate.

## Capabilities

- [x] **P0**: The run entry point routes on the checkpoint's lifecycle status, not on the file's existence
  - the redirect to the resume entry point is taken for exactly three statuses,
    each named in the condition: a run paused cleanly, a run stopped on a
    blocking question, and a run left mid-flight by a session that did not pause
    — the three that entry point's own decision table resolves
  - a checkpoint recording a completed run takes the fresh-run branch in that
    same section instead — resolve the next backlog through the adapter, write a
    new checkpoint, begin the run
  - the redirect set is stated positively rather than as everything but the
    completed status, so a value outside the set falls to the stop below rather
    than into a resume that has no branch for it
  - the resume entry point is unedited: the correction is to what reaches it,
    and a session that legitimately reaches it sees the same decision table it
    sees today

- [x] **P0**: A status the entry point does not recognise stops the run rather than taking either branch
  - a checkpoint whose status is absent, empty, or outside the documented set
    produces a stop naming the value read and the file it was read from, and the
    run neither redirects nor starts a fresh backlog over it
  - the stop writes nothing first: no status overwrite, no driver claim, no run
    directory — the checkpoint is not tracked by version control, so a wrong
    guess on a file whose state cannot be read is the least recoverable move
    available at this point in the run
  - the stop is followed immediately by discharging the session's driver-mode
    mark, since the mark is set before this decision is reached and a stop that
    leaves it set leaves the session unable to edit

- [ ] **P0**: A fresh run started over a completed checkpoint carries the findings index through, and nothing else
  - the instruction for the fresh-run write states that every findings index
    entry in the file being replaced is carried into the new content verbatim —
    the same consequence the packet-close write already states, at the write
    where the file being replaced belongs to a *different* run
  - nothing else crosses: cursor, pending packets, branch, last green
    checkpoint, note and the run's own identity all come from the new backlog,
    so the beginning run mints its own identity rather than inheriting the
    finished one's directory and records
  - the carry happens in the write itself, not as a repair afterwards — a
    checkpoint that exists for any interval without the index is an interval in
    which a crash loses it

- [ ] **P0**: The routing condition and the carry-through clause each have a case in the sweep that owns this surface, and neither can pass vacuously
  - the sweep that already asserts prose properties of both entry-point skills
    gains a case extracting the routing instruction by content anchor and
    asserting the extracted span is non-empty before scanning it, as its
    existing extractions do — a range matching nothing yields an empty span that
    satisfies every scan over it
  - the case asserts what the condition must name — the statuses that redirect
    and the completed status that does not — rather than the absence of a
    removed phrase, which passes forever from the moment the removal lands
  - reverting the condition to a test on the file's existence turns the sweep
    red, verified by making that reversion; the same mutation check is made for
    the case pinning the carry-through clause, by removing that clause
  - the sweep's existing cases over these two files keep passing unchanged, so
    this coverage is additive and nothing already pinned is loosened

## Dependencies

- `thin-loop-driver` — owns both entry-point skills, the driver-mode enter/exit
  discipline the stop obeys, and the run-identity mint-when-absent rule.
  Derived-done; no capability of it is re-opened.
- `run-state-cleanup` — owns the findings index shape carried through, and the
  rule that the index is hot while the bodies are cold. Complete; this feature
  changes where the carry-through is stated, never the index's shape.
- `loop-prose-consistency-gaps` — corrects other prose in the same section of
  the run entry point and adds cases to the same sweep. **Not blocking:** no
  capability of it is depended on; whichever lands second rebases.
- `stale-finding-expiry` — owns when an index entry may be dropped at a packet
  boundary. **Not blocking:** it changes what expires during a run, and this
  feature changes what survives a whole-file replacement between runs.

## Assumptions & Risks

- Assumption: nothing removes the checkpoint when a run completes, so the
  completed status is what the next run finds. Verified against the checkpoint
  the 2026-09-17 run left on disk.
- Assumption: the completed status is declared only once the backlog is
  complete, so that checkpoint has no cursor and no pending packets. A
  checkpoint carrying that status *with* a cursor disagrees with itself; the
  status is taken as the authority and the fresh-run branch is what it gets —
  accepted rather than made routable here.
- Risk: narrowing the condition too far is worse than the defect. A genuinely
  paused, blocked or crashed run sent to the fresh-run branch starts a new
  backlog over unfinished work, which is why the redirect set is named
  positively and the unrecognised case stops.
- Risk: the unrecognised-status stop ships with no case of its own — the
  available pin is declined for the reason in Scope/Deferred, leaving the
  reviewer as its only gate.
- Risk: the routing instruction and the carry-through clause sit in one section
  another filed feature is also correcting. Two changes to one span of prose is
  a merge conflict, not a contradiction, but only if both keep the other's
  clauses intact.
- Assumption: line references were taken at one commit and this repository's
  prose moves. Every site is located by content, never by line number.

## Success Metrics

- The loop's entry routing evaluates the checkpoint's status, and every value
  that checkpoint can carry reaches a stated branch — redirect, fresh run, or
  stop — checkable by reading the routing instruction against the documented
  status set, with zero values unaccounted for.
- A run opening after a completed one reaches its fresh backlog by the condition
  as written, with no driver override.
- After a fresh run begins over a completed checkpoint, the index it carries
  matches the one it replaced entry for entry, and no recorded body is left
  unreferenced.
- Reverting either pinned clause — the routing condition, or the carry-through —
  turns the sweep red.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- Whether the routing condition enumerates the statuses inline or calls the
  terminal-state reader the durable state's script already provides. Deferred
  because both satisfy the capability, and the second also surfaces the
  live-second-driver distinction this feature deliberately leaves out of scope.
- Whether the fresh-run write's carry-through is performed by the driver
  composing the new content around the index it read, or by the writer
  preserving the index across a replacement. Deferred because both satisfy the
  capability and the second is a change to the durable state's writer rather
  than to an instruction.
