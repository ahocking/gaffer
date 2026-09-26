---
spec-version: v2
depends_on: [loop-prose-consistency-gaps, implementer-continuation]
---

# Feature: skill-prompt-trim

## Overview

The loop's three skills — `skills/run-loop/SKILL.md`, `skills/resume/SKILL.md`
and `skills/pause/SKILL.md` — load into the session driving the loop and stay in
its context for the whole run, re-cached on every turn. That is the one context
driver mode (ADR 0028) exists to keep small, and the skills now fill it: a
session resumed on 2026-09-22 carried resume, run-loop from §3.4 onward and
pause — about 120 KB of instructions before its first packet. The one-shot
skills (`migrate`, `metrics`, `new-project`, `review-change`) are smaller and
load once, but they ship to every install the same way.

The bulk is not rules. It is resume restating at full length what run-loop
states and then sending the reader to run-loop anyway; rationale, measurements
and task-id history written inline with the instruction they explain; the
`check-task` / `complete-capabilities` landing and scan decisions written out
at four sites; and stated values of settings whose state lives in a config file or a
script. This feature cuts those four and keeps every rule, the same move the
2026-09-22 `CLAUDE.md` trim made: rules stay where a session reads them,
evidence moves to the ADRs.

## Users & Use Cases

- **The operator running the loop** — pays for every instruction byte on every
  turn of the driving session. Wants the standing context smaller without the
  loop doing anything differently.
- **A maintainer editing a skill** — today changes one copy of a rule and
  leaves a second copy, in another skill or another section, saying something
  else. Needs each rule stated once and the landing decision in one place.
- **A consumer repository** — receives these prompts on install. A wrong cut
  changes loop behaviour everywhere at once, with no local signal.

## Scope

**In**
- `skills/resume/SKILL.md` reduced to what only resuming does, with references
  to run-loop for the rest.
- One adapter subcommand for the landing and scan decisions — `check-task`
  input at the two landing sites, `DRIFT=` slug input at the two scan sites —
  its sweep cases, and the four call sites switched to it.
- Rationale in the three loop skills relocated to ADRs or deleted, per
  capability 3.
- Stated setting and default values removed from every skill in scope.
- The same relocation and value removal in the four one-shot skills, last.

**Out**
- Any change to what the loop does at any site — what it stages, restores,
  reports, routes, records or dispatches. Capability 2 moves where the landing
  decision is written, never what it decides.
- The behaviour of `check-task`, `capability-drift` and `complete-capabilities`
  themselves: what each flips, prints and exits with.
- `agents/*.md` and `templates/`, except the two agent passages capability 7
  aligns with rules this feature's trim changed.
- Any edit to an existing line of an ADR; relocations append only.
- Checked task lines and capability blocks under `gspec/`.
- The gspec-installed preamble in `CLAUDE.md`.

**Deferred**
- Trimming `agents/*.md` and `templates/` — a separate question with its own
  readers.

## Capabilities

- [x] **P0**: The resume skill states only what is unique to resuming, and refers to run-loop for everything else
  - `skills/resume/SKILL.md` carries four things and no others at full length:
    loading the checkpoint, reconstructing state from git when run-state is
    missing or unusable, reconciling the working tree including the adopt path,
    and surfacing pending questions
  - each rule resume states today that run-loop also states — bundle-membership
    recovery, the sweep before start, the handoff checks, and the capability
    flip's shared rules (the staging test and held-feature handling) — is stated
    in run-loop only, and resume refers to it by run-loop section heading rather
    than by section number alone
  - the adopt path's own rules stay stated in resume: escalating on a
    `check-task` exit 1, restoring the PRD from `HEAD` at the path the handoff's
    `PRD=` line names, skipping the capability call when no member printed a feature slug and the handoff is missing, and the
    `adopt` reconciliation commit
  - resume passes capability 5's rule-by-rule review, where a rule counts as
    present if it appears in resume or in a run-loop section resume refers to;
    the cases in `scripts/test-report-conventions.sh` and
    `scripts/test-routing.sh` that read resume or run-loop keep passing, under
    capability 5's rule for a changed assertion

- [x] **P0**: The landing and scan decisions live in one adapter subcommand, and every site calls it
  - one `scripts/gspec-backlog.sh` subcommand serves two input shapes: at the
    two landing sites (run-loop §3.6 and resume's adopt path) it takes the
    packet's tasks, runs `check-task` for each member, then
    `complete-capabilities`; at the two scan sites (run-loop §1 preflight and §4
    end of run) it takes the `DRIFT=` slugs `capability-drift` printed and runs
    `complete-capabilities` once per slug, with no `check-task`; the `FEATURE=`
    fallback applies exactly where the prose applies it today
  - exit codes are read per command: `check-task` exit 0 with `CHECKED=none` is
    skipped, exit 4 is drift that is reported and never halts, and exit 1 is
    returned to the caller, which ends the bundle at §3.6 and escalates at
    adopt; `complete-capabilities` any non-zero exit is reported and its PRD
    restored, never a halt
  - the restore source is stated by the caller, never inferred: §3.6 restores
    from the index, and §1, §4 and adopt restore from `HEAD`; each of the four
    sites calls the subcommand and carries no copy of the exit-code table, and
    for each the files staged, restored and reported for a given input are the
    same as before the change
  - `scripts/test-gspec-backlog.sh` gains cases pinning each `check-task` branch
    and each `complete-capabilities` branch separately, each restore source and
    the `FEATURE=` fallback, and each case turns the sweep red when the branch
    it pins is reverted

- [x] **P0**: Rationale in the loop skills is relocated to an ADR or deleted, and each rule keeps at most a one-clause reason
  - in run-loop, resume and pause, a passage that explains why a rule exists
    moves to the ADR that owns the rule — or, where no ADR owns it, the closest
    related ADR; never a PRD, never left in place beyond the one-clause reason below — appended under a dated
    `Relocated from skills (<date>)` section; no existing ADR line is edited
  - a passage that is history with no rule attached — a task id, a
    "this is the bug that…" story, a measurement from the run that found a
    defect — is deleted, not relocated, since git and the plan files record it;
    a measurement that is the reason for a rule is rationale and is relocated
  - each rule left in these three skills carries at most one clause of reason
  - every `routing.sh resolve` beside a dispatch remains; the three skills pass
    capability 5's rule-by-rule review, and `scripts/test-report-conventions.sh`
    and `scripts/test-routing.sh` keep passing under capability 5's rule for a
    changed assertion

- [x] **P0**: No loop skill states the current value of a configurable setting or code default
  - run-loop, resume and pause name a setting by its key and name the file or
    script output that holds its value, and state no value for it: neither a key
    in `.agents/project-overrides.yaml`, an environment variable, a harness
    settings key, nor the fallback a script uses when one is unset
  - a closed set of tokens a script prints (a `DUE=`, `ACTION=` or
    `THRESHOLD=` value, a status token) is output grammar, not a setting, and
    stays where a rule branches on it
  - capability 5's rule-by-rule review counts a rule that depended on a removed
    value, with no pointer to where that value is read, as a lost rule

- [x] **P0**: The loop skills together meet the size gate
  - the combined bytes of run-loop, resume and pause are at or under the
    operator-accepted figure of 95957 bytes — the combined `wc -c` shipped
    after T13, with every rule kept — against a starting figure measured and
    recorded in a tracked file before the first trimming commit lands; the
    original target, half the starting figure (71912 bytes), stays on record
    there with its 24045-byte shortfall. The operator accepted the shipped
    figure on 2026-09-25, after two trim passes found no further room without
    cutting rules
  - every sweep passes at the commit that meets the figure; any sweep case whose
    assertion changed during this feature is named in its commit with the
    reason, and none is loosened to pass
  - a reviewer compares each of the three skills rule by rule against its
    version at the start of this feature and names every instruction,
    prohibition or trap that is gone with nowhere a session would read it; the
    finding count is zero, and the result is recorded in the same tracked file
    as the starting byte figure

- [x] **P1**: The one-shot skills get the same relocation and value removal, last
  - `skills/migrate/SKILL.md`, `skills/metrics/SKILL.md`,
    `skills/new-project/SKILL.md` and `skills/review-change/SKILL.md` meet
    capability 3's relocation and one-clause rule and capability 4's
    value rule, applied only after capabilities 1–5 have landed
  - `scripts/test-migrate.sh` and `scripts/test-routing.sh` keep passing,
    including the migrate skill's no-literal-pinned-version case and the
    `routing.sh resolve` case over review-change, under capability 5's rule for
    a changed assertion
  - the reviewer's rule-by-rule comparison of these four skills names zero lost
    instructions, prohibitions or traps, recorded in the same tracked file as
    capability 5's results

- [ ] **P1**: Agent prompts that restate a rule this trim changed agree with the trimmed skill
  - `agents/chief-engineer.md` gives the integration base the way run-loop §1
    **Branch** now does, with no `main`/`master` fallback arm (removed from
    run-loop by the operator's decision recorded in `docs/skill-prompt-trim.md`)
  - `agents/loop-driver.md`'s periodic-review section claims no more than it
    holds — the same rule as run-loop §3.8, not the same words — and states
    nothing that run-loop §3.8 no longer does
  - the sweep that extracts either passage keeps passing, under capability 5's
    rule for a changed assertion

## Dependencies

- `loop-prose-consistency-gaps` — **blocking**: edits run-loop and resume
  passages this feature trims; the prose is trimmed once, as it finally stands.
- `implementer-continuation` — **blocking**, same reason: adds `continue`
  routing to run-loop's dispatch and routing sections.
- `thin-loop-driver` — defines driver mode and the standing-context cost this
  feature reduces. Not blocking.
- `capability-auto-complete` — owns what `complete-capabilities` decides; capability
  2 wraps it and changes none of it. Not blocking.
- `per-agent-model-routing` — owns `routing.sh resolve` and the sweep pinning
  it beside each dispatch. Not blocking.
- `handoff-spec-inlining` — **not blocking, same files**: edits
  `scripts/gspec-backlog.sh` and `scripts/test-gspec-backlog.sh`; not in flight
  against them at the same time.

## Assumptions & Risks

- Risk: a rule lost in the cut changes loop behaviour in every consumer install
  and no sweep sees it. The reviewer's rule-by-rule comparison is the only
  detector for prose that no sweep extracts.
- Risk: a resumed session now needs a run-loop section it may not load. It
  already reads run-loop from §3.4 onward; the references name headings so a
  renumbering does not strand them.
- Risk: rationale and history are hard to tell apart at the margin. Relocating
  when unsure costs ADR bytes read by no session; deleting wrongly loses the
  reason.
- Assumption: sweeps that assert against skill text are
  `scripts/test-report-conventions.sh`, `scripts/test-routing.sh` and
  `scripts/test-migrate.sh`; other sweeps name skill paths only in comments or as
  guard fixture paths.
- Risk: ADRs grow. They are read on demand, never in a standing context.

## Success Metrics

- **Gate:** capability 5 — the loop skills at or under the operator-accepted
  figure (amended 2026-09-25 from half their recorded starting bytes), every
  sweep green, zero lost-rule findings.
- **Reported, never gating:** the driving session's `cc_shape` max and p90
  (ADR 0019) on the first loop run after the trim, against a baseline captured
  from a run before it, stated alongside ADR 0019's noted run-to-run variance
  and never offered as proof on its own.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **The landing subcommand's name and output keys.** Any name satisfies
  capability 2; the plan fixes it with the parser.
- **Which tracked file holds the starting byte count and the review results.** Any tracked location
  the reviewer can read satisfies capability 5, provided it is written before
  the first trimming commit; decided at plan time.
