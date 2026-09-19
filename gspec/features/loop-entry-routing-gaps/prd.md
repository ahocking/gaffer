---
spec-version: v2
depends_on: [loop-entry-routing]
---

# Feature: loop-entry-routing-gaps

## Overview

The parent feature's own whole-run review (2026-09-19, run
`20260919T192526-ba86`) left two Important findings behind. **A carry with no
source:** the fresh-run write in the run entry point (`skills/run-loop/SKILL.md`
§2, the paragraph beginning "When this write replaces a `done` checkpoint, carry
every `findings:` index entry into the new content verbatim") says what crosses
but not where it is read from. At that point the driver has read only the
checkpoint's status and holds none of the file. The one durable-state subcommand
named `findings` (`runstate.sh findings`) prints a tab-separated projection, not
the file's lines, and it strips the single-quoting that `runstate-write-integrity`
(ADR 0027) introduced — probed: a summary stored as `'x: y'` prints as bare
`x: y`. Re-emitting that projection as index lines reproduces the exact `": "`
corruption that feature closed, in the one file whose parse failure is
unrecoverable. The packet-close write uses the same "verbatim" word safely
because the driver there wrote the file it replaces; here the file belongs to a
different run. **A sweep that cannot see its own overrun:** the sweep that owns
this surface (`scripts/test-report-conventions.sh`) extracts the routing bullet
and the carry-through clause from that skill by a range between a content start
anchor and a content end anchor, and guards only that the span is non-empty.
Measured: changing one character on either end-anchor line makes the span run to
end of file — 864 lines — and every prose-pin assertion still passes on text from
outside the bullet. The comments beside both extractions name this risk and rely
on prose discipline (keep the anchor on one wrapped line); nothing mechanical
enforces it, and a rewrap by a future prose edit is the likeliest way it happens.

Split out rather than appended, under ADR 0026 arm 2: the parent is derived-done
— four of four capabilities checked — so an unchecked capability added to it
would make shipped work read as incomplete and block everything downstream
through the dependency rule. The first finding is live on the very next run in
this repository, since the run that found it ended `done`.

## Users & Use Cases

- **A driver opening a fresh run after a completed one** — the normal case,
  since that is how every finished run leaves the disk. Hit on 2026-09-19: the
  driver carried the index by reading the file with a line tool, correctly, by
  judgment rather than instruction. An instruction that names what to carry and
  not where from is satisfied equally by the right source and the corrupting one.
- **A resumed session reading the checkpoint that write produced** — a parse
  failure there is unrecoverable; the file is not version-controlled and the
  previous content was replaced by the write that broke it.
- **A future prose editor rewrapping the skill** — moves an end anchor across a
  line break, runs the sweep, and is told by a green bar that nothing changed.
- **A maintainer reading the sweep's green result as evidence** — takes a
  passing prose pin as proof the clause is still there and still says what it
  pinned. Under an overrun it proves only that the file is non-empty.

## Scope

**In**
- the source clause on the fresh-run write: which file, which block, copied
  line-for-line, and the explicit negation of the projection.
- one case in the sweep that owns this surface, pinning that clause.
- an end-anchor overrun refusal on both existing extractions in that sweep.

**Out**
- the parent's checked tasks and capabilities.
- the routing condition itself: which statuses redirect, which take the fresh
  branch, which stop.
- the Minor findings of the same review: a wrong stated reason in the stop
  clause, the legacy parallel-mode stop, stale line references in the parent
  PRD's Overview, and positive substring pins on negated phrases.
- anything under `hooks/`.
- the durable-state script's writer and its `findings` subcommand — unchanged;
  the projection stays a projection — a reader for one caller.
- any new status, report shape or mechanism.

**Deferred**
- nothing: both Important findings are taken in full, and the Minor findings
  are out rather than held.

## Capabilities

- [x] **P0**: The carried findings index is copied line-for-line from the on-disk findings block, and the projection is named as not a source
  - the clause names `.agents/run-state.yaml` as the file and its `findings:`
    block as the span, read from disk — a `Read` of the file or a line-range
    extraction of that block — and copied line-for-line into the new content,
    so the quoting the file carries is the quoting the new file carries — the
    span being the `findings:` key through its last indented entry and stopping
    at the next column-0 key, with an absent or empty block carrying nothing
  - the clause states that the `runstate.sh findings` output is not a source,
    and why: it is a projection that strips the single-quoting the durable-state
    writer applies, so re-emitting it as index lines re-opens the `": "`
    corruption that quoting exists to prevent
  - the carry still happens inside the one write, as the parent requires — the
    source clause changes where the index is read from, never when it lands
  - a case in the sweep that owns this surface asserts the clause names the file
    and negates the projection, extracted by content anchor with a non-empty
    guard and carrying an end-anchor overrun refusal — a negative assertion on
    the line after the clause, or a line-count ceiling — from the start; removing the
    source sentence turns the sweep red, verified by making that mutation

- [x] **P1**: Both sweep extractions of the run entry point refuse an end-anchor overrun
  - each of the two existing range extractions — the routing bullet and the
    carry-through clause — is followed by a negative assertion that fails when
    the extracted span contains the line that follows the bullet's true end, or
    exceeds a line-count ceiling well above the live span, so an end anchor that
    no longer matches turns the sweep red instead of vacuously green
  - mutating one character of either end-anchor line in a scratch copy of the
    checkout turns the sweep red, and restoring it turns the sweep green, verified
    by making both mutations
  - the sweep's existing cases over these extractions keep passing unchanged, so
    the refusal is additive and nothing already pinned is loosened

## Dependencies

- `loop-entry-routing` — the parent. Owns both the carry-through clause and the
  two extractions being hardened. Derived-done; nothing of it is re-opened and no
  checked task line is edited.
- `runstate-write-integrity` — owns the single-quoting the projection strips, and
  the reason the durable state's writer quotes every value. Complete; nothing of
  it changes.
- `loop-prose-consistency-gaps` — adds cases to the same sweep and corrects prose
  in the same section of the run entry point. **Not blocking:** no capability of
  it is depended on; whichever lands second rebases.

## Assumptions & Risks

- Assumption: the live spans are 28 lines (routing) and 12 lines (carry), so a
  ceiling of 60 lines is safe if the ceiling form is chosen — well above either
  span, well below the 864-line overrun.
- Risk: the negative anchor — the line after the bullet — is itself prose and
  can be rewrapped. Mitigated by pinning on a short distinctive phrase that fits
  on one wrapped line, the same discipline the existing needles follow.
- Risk: two features add cases to one sweep and correct prose in one section.
  Two changes to one span is a merge conflict, not a contradiction, but only if
  both keep the other's clauses and cases intact.
- Assumption: line references were taken at one commit and this repository's
  prose moves. Every site is located by content, never by line number.

## Success Metrics

- A fresh run started over a completed checkpoint produces a checkpoint whose
  findings block parses, and whose entries and quoting match the replaced file's
  block entry for entry.
- The sweep's green result is evidence again: a rewrapped end anchor can no
  longer produce a green run on text from outside the bullet.
- The sweep's passing count rises by the new cases and nothing already pinned
  loosens: every existing case over these two files passes unchanged.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- Whether the overrun refusal is a negative content assertion on the line that
  follows the bullet, or a line-count ceiling. Deferred because either satisfies
  the capability; an implementation call.
