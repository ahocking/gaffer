---
spec-version: v2
depends_on: [thin-loop-driver-gaps]
---

# Feature: driver-context-window-default

## Overview

Driver mode's success metric — the driver session's peak context measured against
the compaction threshold in effect — reads *unmeasured* on every run in every
repository that has not explicitly set a compaction window, which is the default
state. Two changes that were each individually correct produced it: one removed
the tool's invented default, leaving the threshold reader to report `unknown`
with a source naming nothing in effect; the other made both loop entry points
state no threshold and pass `unknown` onward whenever the reader names no value.
The measurement then nulls the threshold and forces the peak null with it, and
says so honestly. The diagnostics still report the windows and turns seen, so a
run is not invisible — only the comparison is.

This is an aggregate defect, not a bug in either change. The honest `unknown` is
strictly better than the invented constant it replaced, and nothing here
retracts it. What is missing is any default path to measuring the thing the
parent feature was built to measure, and any way for a reader who meets the
unmeasured line to tell *nobody has measured this here* from *this cannot be
measured*. Split out rather than appended, on the established precedent: both
parents are derived-done, so an unchecked capability added to either would make
shipped work read as incomplete forever and block everything downstream through
the dependency rule.

## Users & Use Cases

- **The operator reading a measurement summary** — meets the unmeasured line and
  has to decide whether to act. Today the line states the absence and not its
  cause, and the two readings call for opposite responses.
- **A driver session at kickoff** — states the session's facts before the first
  packet, where a wrong assumption costs one sentence rather than several
  packets. Saying nothing at all about compaction lets a reader assume the run is
  being measured against a window.
- **Whoever decides whether to close the gap** — needs the answer to a question
  that was deliberately left unrun, and cannot get it from the shipped code,
  which correctly declines to guess.
- **A later reader of the measurements** — compares runs, and must not read an
  unmeasured comparison as a passing one.

## Scope

**In**
- running the probe that was deferred: whether a plugin can supply a
  compaction-window default without overriding a value a repository or operator
  has set.
- recording that probe's answer as a result, including a negative answer.
- the unmeasured rendering of the driver-mode context measurement, and the
  instruction that relays it.
- the kickoff's session line where the reader names no value in effect.
- the regression case that pins the unmeasured rendering.

**Out**
- setting a compaction window in this repository's own settings. That is a
  one-line settings edit, not a feature: it makes one repository's
  metric real and says nothing about the default, which is what this feature is
  about.
- introducing any threshold value the tool did not read from a named source. The
  removed default is not restored, corrected, or recomputed.
- applying a plugin-supplied default, even if the probe admits one — see Deferred
  Decisions.
- changing which record either consumer selects, the measurement's null rules, or
  the shape of the kickoff or the enter record.
- re-opening, re-wording or re-checking any capability of either parent.

**Deferred**
- The three remaining unprobed items on the same list: precedence when both an
  environment variable and a settings key are set, the user and committed-project
  scopes, and whether a session can read the value in effect other than by
  reading settings files. Each is a separate question; this feature runs one
  probe.

## Capabilities

- [x] **P1**: The deferred probe is run, and its answer is recorded as a result
  - the probe answers exactly the question that was left unrun — whether a plugin
    can supply a compaction-window default without overriding a value a
    repository or operator has set — exercising both arms, since a default that
    only appears when nothing else is set is the entire claim
  - the answer is recorded in the decision record that deferred it
    (`docs/adr/0028-loop-driver-mode.md`), carrying the conditions it was taken
    under
  - a negative answer is recorded as the answer, not as a failure to answer: the
    threshold reader in `scripts/runstate.sh` keeps reporting `unknown`, and its
    header comment stops instructing a future reader to run a probe that has been
    run
  - no value enters the reader on the strength of this probe: a threshold is
    reportable only with a `SOURCE=` naming its provenance, and `unknown` remains
    a correct answer — inventing a number to close this gap would reproduce the
    defect its parents removed. The existing `compact-threshold` cases in
    `scripts/test-runstate.sh` pin every branch by exact
    `THRESHOLD=`/`SOURCE=`/`APPLIED=` triple, the no-default branch included, so
    no new case is owed here

- [x] **P1**: An unmeasured context metric says why, and what would make it real
  - the unmeasured rendering in `scripts/metrics.sh show` names the cause and the
    settings key that would supply a threshold — the key itself, not any one of
    the scopes that can carry it nor a precedence among them, both deferred — so
    the reader can separate *nobody has set one here* from *this cannot be
    measured* without reading the source
  - the reason reaches the human who meets it, not only the collected packet:
    `skills/metrics/SKILL.md` already instructs that line be relayed verbatim, and
    newly states that its remedy clause is relayed unparaphrased, never rewritten
    into an instruction to set a value
  - `driver_mode_context.threshold` stays null and forces `max_context` null with
    it, no rendering states what the setting's value should be, and the
    diagnostics beside it are unchanged
  - `scripts/test-metrics.sh` updates the existing exact-string case for that line
    and asserts the rendering names that key, and that no rendering of the line
    carries a numeric threshold while the collected threshold is null

- [x] **P2**: The kickoff distinguishes no threshold in effect from silence
  - both loop entry points state, in the same words, that no compaction threshold
    is in effect for the session when the reader names no value — where today
    they correctly state no number and therefore say nothing at all, which a
    reader takes for a measured run
  - what the parent removed stays removed: no number is stated, the kickoff shape
    gains no source slot, and the enter record gains no field. The line states the
    absence and the same settings key the capability above names, never a value,
    under the parent's `SOURCE`-not-`APPLIED` condition unchanged
  - the driver still passes `unknown` to the driver-mode enter call on that path,
    so the kickoff's wording and the measurement's null come from one reading of
    one reader. The one pin available — the no-threshold clause asserted present
    in both entry points, a technique `scripts/test-report-conventions.sh` already
    applies across a two-file pair — is declined to hold this feature to the cases
    above; the reviewer is the gate

## Dependencies

- `thin-loop-driver` — owns the driver-mode context metric this feature makes
  reachable, the kickoff shape, and the threshold reader. Derived-done; nothing
  here re-opens a capability or edits a checked task.
- `thin-loop-driver-gaps` — removed the invented default and made both consumers
  state no number, and named this probe in its own Out and Deferred lists. This
  feature takes that item up. Derived-done.
- `loop-measurement` — owns the measurement packet the context fields sit in.
  **Not blocking:** the shipped half is what is depended on, and its deferred
  tail shares no files with this feature.
- `loop-prose-consistency` — pins, in the regression sweep, where the removed
  source value may and may not appear across the two loop entry points and the
  report shapes. Any wording change here must leave that pin passing; not
  blocking in either direction.

## Assumptions & Risks

- Risk: the probe may return *no, a plugin cannot supply one safely*. That is a
  legitimate outcome, not a failed feature — in which case the metric stays
  opt-in and this feature's value is the second capability plus a recorded
  answer, rather than a measured metric. A feature whose probe can honestly
  return *don't build it* should say so rather than presuppose the fix.
- The operator was offered the one-line settings edit that would make this
  repository's own metric real, and it remains their call. Its absence from scope
  is deliberate, not an oversight.
- Risk: a probe result is a reading taken on one harness version, and in this
  area a model-conditional reading has already been mistaken for a harness-wide
  one once. A result recorded without its conditions repeats that.
- Assumption: the probe needs live sessions an unattended packet cannot produce —
  one with a plugin-supplied default and a repository value present, one with
  neither — so it is operator-assisted, as the original probe was. The packet
  hands the probe off to the operator and the capability stays unchecked until the
  answer is recorded: that is the intended state, not a stall.
- Assumption: the carrier the reader reads is the one already verified; this
  probe does not re-verify it, and a change there would invalidate the answer
  rather than the reader.
- Risk: the third capability adds prose to a line a parent capability
  deliberately emptied. Stating an absence is not stating a value, and the
  distinction has to survive in the wording or the change reads as a regression
  of the parent.

## Success Metrics

- The deferred probe has a recorded answer with its conditions, and no surface
  still instructs a reader to run it — checkable by reading the decision record
  against the reader's header comment.
- Zero renderings of the context metric report it unmeasured without naming the
  cause and the settings key that would supply a threshold — countable per run
  from the rendered line.
- Zero threshold values are reported without a `SOURCE=` naming their provenance.
- No kickoff states a compaction threshold, and none is silent about compaction
  while the reader names no value in effect — checkable per run against the same
  reader call the session already makes.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Whether a plugin-supplied default is ever applied rather than only
  reported.** It cannot be decided before the probe's answer exists, and a
  positive answer makes it a separate feature with its own scope: what supplies
  the value, what `SOURCE` names it, and what happens on the repositories that
  already set one.
- **Where a negative answer lives permanently.** The decision record holds the
  result either way; whether the reader's own header comment also carries a
  standing statement that the question is closed is a decomposition call, not a
  scope one.
