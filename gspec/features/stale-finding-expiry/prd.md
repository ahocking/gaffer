---
spec-version: v2
depends_on: [run-state-cleanup]
---

# Feature: stale-finding-expiry

## Overview

The loop has exactly one path that drops a finding from the run-state index, and
that path can only drop findings belonging to the packet it just landed. The
detector feeding it is already wider: at every packet close the loop resolves
completion for **all** findings' packets and asks the index which entries are
stale. The drop rule then discards all but one slice of that answer. An entry
whose packets every one finished in an *earlier* run is therefore structurally
undroppable — no future landing can ever name it, however many packets land, so
it survives for the life of the state file while the same close that could
expire it reports it as stale.

Measured in this repository at the close of the run that landed the preceding
feature: the packet-close sequence returns two stale entries, one scoped to six
consecutive packets of a completed feature and one scoped to nine, every packet
of both checked — alongside an index of 5,647 bytes against a 4,096-byte
threshold and an over-threshold flag reading yes. So the loop reports its own
index as over budget on every packet close while holding entries it cannot act
on. That cost is not paid once: the run-state is read by every packet and sits
in the standing context, so an entry that cannot expire is re-cached per
dispatch for the rest of the backlog — the precise cost the findings design
exists to bound. The expected shape is one clause: drop every stale entry the
detector reports, rather than only one naming the landed packet. The detector,
the evidence rule, and the index format are all unchanged.

## Users & Use Cases

- **A driver closing a packet** — already holds the full stale list, already
  paid for computing it, and is then instructed to act on one line of it. Every
  other line it must read and discard.
- **A driver in a later run inheriting an index** — sees entries whose work
  finished before this session began. Under the current rule it has no action
  available; under the corrected one its inherited entries are ordinary work.
- **The operator reading a report line that names a stale count** — needs the
  count to mean *discipline slipped this run*, not *a residue no run can clear*.
- **Any dispatched agent reading the run-state** — never reads a finding's body
  and often does not need the entry at all, but pays for the index on every
  dispatch.

## Scope

**In**
- The drop rule at the packet-close boundary: the clause selecting which stale
  entries are dropped.
- The capture-before-drop judgement applying unchanged to an entry inherited
  from an earlier run.
- A regression case that fails if the drop rule is narrowed back.

**Out**
- Any periodic or cadence-driven review of the index. That belongs to
  `escalation-decider`, which owns a review agent and a firing rule; a second
  cadence here would collide with it.
- Merging, deduplicating or rewriting entries, and any cap on a summary's
  length — both are that same feature's scope.
- The detector: how completion is resolved, what counts as finished, and the
  three-state live/dead/unknown verdict are all unchanged.
- The index format, the threshold default, the body-or-no-body distinction, and
  the command that performs a drop.
- Draining the two entries live today. It is a consequence of the corrected
  rule — the first packet close after it lands removes them — not work of its
  own.
- The over-threshold signal becoming actionable again at the moment it is
  reported. It is a consequence of the corrected rule — the close that reports
  the signal can now clear it — not work of its own.

**Deferred**
- Whether a run that closes no packet at all should get an expiry opportunity.
  The corrected rule fires at a packet boundary; a run that lands nothing still
  cannot expire anything, and closing that is a cadence question, which is out
  of scope above.
- An entry whose named packet reads unknown forever — rolled back, abandoned, or
  re-decomposed under a regenerated plan — never yields positive evidence, so the
  detector never reports it stale and no close can expire it. Closing that is a
  detector question, not this feature's.

## Capabilities

- [ ] **P0**: Every stale entry the detector reports is droppable at the packet boundary
  - the drop step acts on each stale entry the close's own detector call
    returns, with no filter selecting only entries naming the just-landed
    packet — so an entry whose packets all finished in an earlier run is dropped
    by the first close after this lands, exactly like one finished this run
  - the detector is not touched: it already resolves completion across all
    findings' packets rather than the landed one, and the correction is to the
    consumer of its answer, not to the answer
  - the sequence's position is unchanged — still after the packet commit that
    carries the completion flip, so the just-closed packet reads finished rather
    than unknown, and still bounded to entries the detector named stale, never
    an unattended prune across the whole index
  - an entry naming at least one unfinished packet is still never dropped, and
    an entry whose named packet is neither pending nor demonstrably finished
    still reads unknown, which still blocks expiry

- [ ] **P0**: Capture precedes drop at full strength for an entry inherited from an earlier run
  - expiry still demands positive evidence of completion — the specification
    checkbox checked, or a packet trailer naming it — and absence from the
    pending list still reads unknown rather than finished, for an inherited
    entry exactly as for a fresh one
  - the driver judges from the entry's summary whether the finding is durable
    knowledge needing capture, or a spent sign-off needing none, and files a
    backlog task as the capture where it is durable; this is the same judgement
    at the same moment, not a weaker one for older entries
  - no extra operator interrupt, no confirmation step, and no distinction
    between an entry with a body and one without — an entry is dropped by its
    summary and its packet scope, which is what the index is for

- [ ] **P0**: The corrected rule has a case in `scripts/test-runstate.sh` that cannot pass vacuously
  - a script-level case pins the half the drop rule depends on: an index entry
    whose every named packet is supplied as finished, and which names nothing
    landed in the current close, is reported stale — asserted on the entry's own
    line, not merely on the stale count
  - a case pins the drop clause itself wherever the packet-close sequence is
    stated — `skills/run-loop/SKILL.md` and any further site stating that
    sequence — anchored to the packet-close section so a matching phrase
    elsewhere in a file cannot satisfy it, asserting at each site that the
    selection is over every stale entry and that no clause narrows it to the
    landed packet
  - that case is proved non-vacuous by running the same assertion against a copy
    of the file carrying the narrowed wording and requiring it to fail — a
    pure absence assertion expires the moment the old phrasing is reworded and
    then passes forever while checking nothing
  - the drop command's existing zero-orphan property is re-asserted for a
    cross-run entry: index line and body both go, or neither, when the entry
    being dropped was written by a session other than the one dropping it

## Dependencies

- `run-state-cleanup` — owns the index, the drop command, the stale detector,
  the threshold signal, and the capture-before-drop evidence rule. Derived-done;
  this feature corrects one consumer of its detector and re-opens no capability
  of it.
- `thin-loop-driver` — owns the packet-close sequence the corrected clause lives
  in, and the report line the stale count is rendered into. Derived-done; the
  sequence's shape and position are unchanged.
- `escalation-decider` — owns the periodic index review that Scope/Out leaves to
  it; not built, not blocking, and not a substitute for a drop at a boundary that
  has already computed the answer.

## Assumptions & Risks

- Assumption: the detector's finished/pending/unknown verdict is correct for a
  packet completed in an earlier run. It reads the checkbox or the commit
  trailer, neither of which is session-scoped, so it is; this feature would
  otherwise be widening a drop rule over an answer it cannot trust.
- Risk: widening the rule widens what a wrong capture judgement costs. A durable
  finding dropped without capture is unrecoverable — the state file is
  gitignored — and the inherited entries are exactly the ones whose context the
  dropping session lacks. The evidence rule is unchanged precisely because it,
  not the drop's breadth, is what guards that.
- Risk: the volume of drops at a single close rises sharply the first time this
  runs against an aged index. That is the backlog being paid down in one step,
  and it is the same judgement repeated, but it is the close most likely to be
  rushed.
- Assumption: every site stating the packet-close sequence carries the same drop
  clause. A second copy would need the same correction, which is why the sweep
  case above asserts the clause's form at every such site rather than at one — a
  diverged copy fails the sweep instead of shipping half the correction.

## Success Metrics

- Every stale entry is droppable by construction: for every stale entry, some
  packet close can expire it — checkable by reading the drop clause against the
  detector call that feeds it.
- The two entries measured stale in this repository are gone after the first
  packet close following the change, with no entry naming an unfinished packet
  removed alongside them.
- An over-threshold reading caused by stale entries is clearable within one
  packet close by following the sequence, so a run reporting it twice for the
  same stale entries indicates
  slipped discipline rather than a structural residue.
- The sweep fails when the drop rule is reverted to the packet-naming form,
  demonstrated by the mutated-copy assertion rather than asserted in prose.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.
