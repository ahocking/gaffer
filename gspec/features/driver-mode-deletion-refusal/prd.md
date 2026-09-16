---
spec-version: v2
depends_on: [thin-loop-driver]
---

# Feature: driver-mode-deletion-refusal

## Overview

Driver mode refuses a main-thread write unless the guard can prove the target
lands under the repository's own `.agents/`. It recognises a set of shell write
forms and judges each one's target; a form it does not recognise is not judged.
Deletion is not in that set. Measured this session by executing the guard with a
driver-mode mark set and no agent id in the payload, `rm <file>`, `unlink
<file>`, `rmdir <dir>`, `shred <file>` and `git rm <file>` all succeed against a
target outside `.agents/`, while the recognised forms — redirections, `install`,
`ln -s`, `cp`, `mv`, `sed -i` — refuse the same target. The refusal itself works;
these five verbs never reach it.

This is a defect, not an accepted limit. Driver mode exists so the driving
session never mutates the repository itself, and deletion is a mutation — the
most destructive one. `thin-loop-driver`'s capability 1 carves out "other
commands without a recognised write form", wording written for neutral and
read-only commands rather than for deletion; it is a case that wording did not
anticipate, not one it weighed and accepted. `git rm` is the sharpest of the
five, because it is the one verb that deletes *tracked* files; it escapes for
the same reason as the other four, that no recognised write form matches it, so
the refusal is never reached.

## Users & Use Cases

- **The operator running long unattended loops.** A driving session that deletes
  a file is the failure driver mode exists to prevent, and it is worse than an
  errant edit: an edit shows in a diff against the last green checkpoint, a
  deletion of an untracked file leaves nothing to diff. The operator finds out
  hours in.
- **The plugin maintainer.** Needs the deletion verbs written into the
  recognised set with the same exemption and the same tie-breaker as the rest,
  so the boundary of driver mode is one rule rather than two.

## Scope

**In**
- `rm`, `unlink`, `rmdir`, `shred` and `git rm`, judged against the same
  `.agents/` exemption and the same conservative-refusal tie-breaker as the
  write forms the guard already recognises
- matching cases in the guard's regression sweep for every behaviour change

**Out**
- a general shell parser, and any write form other than these five verbs
- the refusal message wording, the pause route out, and how driver mode is
  marked
- the hard-deny and ask tiers, except to assert they are unchanged
- recursive and forced deletes (`rm -r`, `rm -f`), zero-truncation
  (`truncate -s 0`) and delete-executing `find`, in the short-flag spellings the
  hard-deny patterns match: already hard denials, so they are out of this
  feature's reach. Other spellings fall to this feature's refusal
- the four target-detection gaps owned by `guard-write-target-detection`. That
  feature fixes mis-extracted targets of forms the guard already recognises and
  states that widening the recognised set is separate work; this feature is that
  widening, for deletion only. The boundary is settled — neither side needs
  re-litigating

**Deferred**
- nothing

## Capabilities

- [ ] **P0**: The five deletion verbs are recognised write forms in driver mode
  - each of `rm`, `unlink`, `rmdir`, `shred` and `git rm` has its target paths
    extracted and judged after the hard-deny tier, exactly as an existing
    recognised write form is; on the main thread of a marked session, a target
    outside the repository's own `.agents/` refuses, giving driver mode as the
    reason and a pause as the way out
  - each of the five allows only when every target the extractor resolves lands
    under the repository's own `.agents/`, which is unchanged from today's
    behaviour for such a target
  - `git rm` is judged on the paths it names, with the subcommand word not
    treated as a target, so a tracked file outside the repository's own
    `.agents/` refuses and one under it allows
  - `scripts/test-guard.sh` gains, per verb, one case asserting a refusal for a
    target outside `.agents/` and one asserting an allowance for a target under
    it, with one of the `rm` refusal cases using a long-flag forced spelling
    (`rm --force`); every refusal case fails if the fix is reverted

- [ ] **P0**: A deletion is judged on every path it names, and refuses when it
      cannot resolve one
  - an invocation naming more than one path (`rm a b`) is judged on all of them:
    it refuses if any one lies outside the repository's own `.agents/`, and
    allows only when every one is under it
  - an argument that is an option rather than a path is not judged as a target,
    in the short, joined and long spellings, including an option that consumes
    its own argument; a `--` terminator makes every argument after it a path
  - a command whose targets cannot be resolved refuses rather than allows —
    no path found at all, a variable, a command substitution, a pattern the
    extractor cannot expand, or an unrecognised option that may have consumed
    the following argument
  - `scripts/test-guard.sh` gains a case deleting two paths where one is outside
    `.agents/` (refuses) and one where both are under it (allows), a case where
    an option's argument would read as a path outside `.agents/` while the
    positional target is under it (allows), and a case whose single target is a
    variable (refuses); each fails if the fix is reverted

- [ ] **P1**: Deletion refusal is keyed exactly as the existing write forms are
  - a call carrying an agent id — a subagent of the driving session — is not
    refused for any of the five verbs, however its target resolves
  - a call from a session carrying no driver-mode mark, a mark belonging to a
    different session, or a mark left behind by a session that crashed or closed
    mid-run is not refused, for any of the five verbs
  - `scripts/test-guard.sh` gains a case per verb asserting an allowance with an
    agent id present and a target outside `.agents/`, and one asserting an
    allowance with no mark set; each fails if the refusal is widened past the
    marked session's main thread

- [ ] **P1**: The hard-deny floor over destructive deletion is unchanged
  - recursive and forced deletes, zero-truncation and delete-executing `find`
    remain hard denials in the short-flag spellings the hard-deny patterns
    match, in driver mode and out of it, marked session or not; other spellings
    of the same intent fall to this feature's driver-mode refusal instead
  - the hard-deny tier is still judged before the driver-mode refusal, so none
    of these forms is downgraded to a driver-mode refusal, and none is offered
    the pause route out; the denial still names the rule it matched
  - recognising the five verbs opens no path by which a hard-denied form is
    allowed, a target under `.agents/` included
  - the existing `scripts/test-guard.sh` cases for these forms are retained
    unchanged, and one case per form is added asserting the denial holds with a
    driver-mode mark set and a target under `.agents/`; each fails if the tier
    ordering is inverted

## Dependencies

- `thin-loop-driver` — defines driver mode, the main-thread refusal, the
  `.agents/` exemption and the session keying these deletions are judged
  against. Blocking.
- `guard-write-target-detection` — **not blocking.** It edits the same
  sanitization and target-extraction path; whichever of the two lands second
  rebases onto the other.

## Assumptions & Risks

- Conservative refusal stays the tie-breaker: where extraction cannot prove
  every target lands under `.agents/`, the command refuses. Unresolvable
  targets, variables, command substitution and indirect execution keep refusing.
- The five verbs share the sanitization and target-extraction path with the
  existing recognised write forms, so a change made for deletion can alter their
  behaviour; the regression sweep is what detects that.
- Refusing a deletion the driver legitimately wanted is the safe direction, and
  the pause route out already covers it.
- Recognising a two-word verb makes the match fire on `<tool> rm` generally, so
  a `rm` subcommand belonging to another tool is refused rather than judged,
  even though it deletes no file. The safe direction, with the pause as the
  route out.
- Deleting by a form outside these five — an unrecognised verb, or deletion
  reached through a script or an interpreter — is still not refused. That
  remains an accepted limit of driver mode, narrower after this feature than
  before it.

## Success Metrics

- No main-thread deletion of a path outside the repository's own `.agents/` is
  allowed in a marked session, as capability 1 states it, and no case asserting
  that reports a pass whose result it could not read. The sweep is the
  measurement: the metrics pipeline records a command head and a path hash,
  never a path, so a field metric for shell deletion is not collectable.
- Every case in `scripts/test-guard.sh` that passed before this feature still
  passes after it.

## Implementation Context

> This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.
