---
spec-version: v2
---

# Feature: gspec-adapter-consistency

## Overview

Three internal-consistency defects in `scripts/gspec-backlog.sh` and its sweep
`scripts/test-gspec-backlog.sh`, found by review during `loop-measurement-t2`.
**None is a live behavioural defect today** — every duplicated literal is
byte-identical to its twin, and every assertion named below currently returns
the right answer. Each is a place where knowledge that has to stay in step is
duplicated with nothing tying the copies together, in the one file ADR 0020
designates as the single place this plugin reads `gspec/` at all. The cost is
decay: the copies agree now, and nothing would notice when they stop. One
feature because the three are the same shape in the same file, and closing any
one alone leaves the others.

**Defect 1 — the three plan-layout paths are enumerated twice.**
`_resolve_plan_path` (`:968-977`) holds one enumeration; `_task_history_probe`'s
git pathspec list (`:1102-1105`) hardcodes a second. The probe needs all three
candidates **whether or not they exist**, while the resolver `-f`-tests and
returns only the newest existing one — which is why the second copy was written.
ADR 0020 requires these paths be "resolved in exactly one place each", and names
why: gspec has moved these files twice (pre-2.0 `gspec/features/<slug>.plan.md`
→ 2.x `gspec/tasks/<slug>.md` → 3.x `gspec/features/<slug>/tasks.md`), and a
format change once broke seven files because nothing checked. Drift here
degrades to `unknown`, the safe direction — decay, not a latent wrong answer.

**Defect 2 — task-line knowledge stays duplicated, under a comment that
undercounts it.** `loop-measurement-t2` composed
`_TASK_LINE_PREFIX`/`_TASK_ID_CLASS`/`_TASK_LINE_SUFFIX` into `_TASK_LINE_RE`
(`:266-269`) and migrated `_task_lookup`, `_plan_task_line_count` and
`_task_history_probe` onto them. The full shape still has three copies, the id
class two, and the checked-marker test six — each enumerated in Scope — while
the comment at `:262-265` names two copies rather than three, and neither line
number it cites points at a pattern. **The sharp edge is the flip:**
`cmd_check_task` is the plugin's only write into `gspec/`, so a divergence there
is a write that misses — a task the loop believes it checked off and did not —
rather than a read that misses.

**Defect 3 — three sweep assertions pass for the wrong reason.** The empty-plan
case (`:1139`), the no-parseable-task-lines case (`:1149`) and the
slug-ambiguity **state** assertion (`:1175`) are satisfied incidentally:
`empty.md` and `noparse.md` are written after their root's last commit (`:1057`)
and so are untracked, and the collision fixture is not a git repository at all,
so `_task_history_probe` returns `UNAVAILABLE` and all three still read
`unknown` with their gate removed entirely. Their companion **reason**
assertions (`:1141`, `:1151`, `:1178`) do fail under mutation, and the behaviour
is genuinely covered by two newer cases from the same packet — **so nothing here
is untested.** What is wrong is that three assertions certify a gate they never
exercise: the vacuous-test family `test-runstate.sh` shipped when 21 cases
silently checked nothing for months.

## Users & Use Cases

- **The loop driver flipping a completed task's checkbox** — the one write into
  the specification tree, which must land on the same line every reader
  resolved.
- **A maintainer adding or reordering a specification layout** — must make that
  change in one place and have every caller follow.
- **A maintainer reading the sweep as evidence** — treats a green run as a
  statement about the gates, true only where each assertion exercises its own.

## Scope

**In**
- One enumeration of the three plan-layout candidate paths, with both callers
  derived from it.
- Every remaining copy of shared task-line knowledge migrated onto shared
  blocks, the flip included: the full shape (`:658`, `:731`, `:1204`), the id
  class (`:736`, `:1207`), the prefix itself (`:735`, `:1206`), and the checked-marker test
  `/^[[:space:]]*-[[:space:]]*\[[xX]\]/` at all six sites (`:428`, `:660`,
  `:733`, `:786`, `:996`, `:1209`) — `:428` included because its line type
  differs (a capability line) while its checkbox test does not.
- The three incidentally-passing sweep assertions made to exercise their own
  gates.
- Regression coverage proving no observable behaviour changed.

**Out**
- Any change to what the adapter reads, reports, or writes.
- New states, fields, subcommands, or output columns.
- `cmd_files_status`' narrower `**T[0-9]+**` id pattern, at all three of its
  occurrences in that function: it deliberately serves the fingerprint sidecar's
  key format, so deriving it from the shared blocks would *widen what it
  matches* — a behavioural change this feature forbids. Its checked-marker test
  is a different literal and is in scope above, and `_nodes_for`'s legacy-id test (`:738`).
- Anything in `scripts/runstate.sh` or `scripts/metrics.sh`.
- Migrating any file under `gspec/` itself.

**Deferred**
- Nothing beyond the Deferred Decisions below.

## Capabilities

- [ ] **P1**: The three plan-layout candidate paths are enumerated in exactly one place
  - a single source yields the three candidate paths for a slug, newest layout
    first, and both `_resolve_plan_path` (`:968`) and `_task_history_probe`'s git
    pathspec list (`:1102-1105`) derive from it — so adding, removing or
    reordering a layout is one edit
  - the two callers keep their different needs: the shared source yields
    candidates unconditionally, existence-testing stays the resolver's job, and
    **newest-shadows-older** resolution is unchanged — a slug present in two
    layouts is a half-finished migration, and the destination is the truth
  - every pathspec handed to git stays **root-relative** (`gspec/…`, never
    `$root/gspec/…`): `git -C "$root"` resolves it a second time against the same
    directory, which already produced a silent `unknown` for a relative root
    (`loop-measurement-t2` Minor)
  - with a slug in all three layouts, and one slug per layout, the resolver returns the newest
    and the probe finds history under each layout path — the observable form of
    the agreement, since the enumerator is internal and git treats multiple
    pathspecs as a union

- [ ] **P1**: Every task-line match in the adapter derives from the shared pattern blocks, the write included
  - no literal copy of the shared task-line knowledge — the full shape (`:658`,
    `:731`, `:1204`), the id class (`:736`, `:1207`) and the checked-marker test
    (its six sites) — remains outside the shared blocks, save the narrower id
    pattern named in Scope/Out; the marker test becomes one block of its own,
    which widens nothing, since all six copies are byte-identical and it carries
    no id shape
  - **all three migrate together** — partial migration is the documented
    `runstate-write-integrity` failure
  - the comment at `:262-265` is corrected or removed: with no copies left to
    count, its claim becomes structurally true, and it must not be left naming a
    number and two line numbers that point at nothing. The same stale
    cross-reference in `_plan_task_line_count`'s comment (`:1007-1015`) goes with
    it
  - a sweep case feeds one fixture holding both recognised task-line shapes
    (bold-closed id, and bold spanning id + description) to `plans`' count,
    `nodes`, `task-status` and `check-task`, asserting all four agree on the same
    line set — a count taken from a **different** pattern than the one it
    certifies lies about exactly what it is asked to certify

- [ ] **P1**: No assertion in the sweep certifies a gate it does not exercise
  - each fixture's git history contains a task line for the probed id, so the
    probe answers `FOUND`: committing the fixture is not sufficient, because the
    `NEVER` branch also yields `unknown` (`:1322-1325`) and the gate would still
    not bite. So `empty.md` and `noparse.md` are committed carrying
    `- [ ] **T1** …` and then emptied or replaced in a later commit, and the
    collision fixture's root becomes a git repository whose `phase-t2` plan
    carried a `**T1**` line before removal — coherent rather than contrived,
    since the ambiguity gate exists precisely to return `unknown` where the probe
    would otherwise say `gone`
  - the **state** assertions at `:1139`, `:1149` and `:1175` each fail when the
    gate they name is removed — verified by mutation at implementation time and
    recorded in the case's own comment, since "we checked once" is the only
    evidence a non-vacuous assertion can carry
  - expected output is unchanged by the fixture work: every one of these cases
    still asserts `unknown` with its existing reason string, and their companion
    reason assertions (`:1141`, `:1151`, `:1178`) keep passing for the reason they
    already pass for

- [ ] **P1**: No observable behaviour of the adapter changes
  - `task-status`'s state vocabulary (`finished` / `unchecked` / `unknown` /
    `gone`), its reason strings and its `FINISHED=` line are byte-identical — that
    line is fed verbatim to `runstate.sh findings --stale --finished`, so its
    format is a consumed contract
  - `check-task`'s exit codes are unchanged, notably **exit 4 = genuine drift**
    (report, do not halt) and `CHECKED=none` at exit 0 = skipped, not failed; the
    flip still changes one character on one line and preserves the plan file's
    mode and its trailing-newline handling
  - `nodes` and `plans` output is byte-identical, columns 4–5 included —
    `migrate.sh verify` counts parseable task lines from them to tell "nothing can
    parse this" from "everything here is done"
  - all three layouts stay readable with newest shadowing older, and the file
    stays runnable on **stock Git Bash** — asserted by a sweep run with `jq` and
    `python3` absent from `PATH`, `git` retained, since the history probe needs it

- [ ] **P1**: The behaviour-preservation claim is evidenced, not asserted
  - `nodes`, `plans`, `task-status` (across all four states) and `check-task`
    (flip, already-checked, drift, non-gspec id) are captured over the sweep's
    existing fixture set before the change and compared byte-for-byte after, with
    the comparison kept as a sweep case rather than a one-off transcript
  - the baseline is produced by the **pre-change** adapter — committed, or
    regenerated in-case from `git show <pre-change-rev>:scripts/gspec-backlog.sh`
    — and never refreshed from the current script: a refreshed golden still fails
    on later changes, so it would look healthy while evidencing nothing about
    this one
  - each of the three defects has at least one case that fails if its fix is
    reverted, so a later revert is caught by the sweep rather than by review
  - no case added here can pass vacuously — none is gated on a tool being present,
    and none is made green by a fixture state unrelated to what it names; a case
    is never re-run until green as a remedy

## Dependencies

- `loop-measurement` — its task `loop-measurement-t2` introduced the shared
  pattern blocks and `_task_history_probe`, which every capability here builds
  on. That task has landed, and nothing here re-opens it or waits on the rest of
  `loop-measurement`, so this feature carries no `depends_on`.
- `runstate-write-integrity` and `runstate-write-integrity-gaps` — precedent, not
  dependency: the shared-helper rule in capability 2 and the vacuous-assertion
  rule in capability 3 are the same findings on a different file.

## Assumptions & Risks

- Assumption: the duplicated literals are byte-identical today — diffed during
  review. If any is found to differ during implementation, that is a live defect
  and gets reported rather than silently normalised by the migration.
- **The main risk is a refactor that changes behaviour** — capability 4 states
  byte-identity as a requirement and capability 5 evidences it; a regression here
  would be silent in the same way the defects are.
- Risk: committing and then mutating the sweep's fixtures changes what
  `_task_history_probe` returns for them, so a case that was passing incidentally
  could legitimately change answer. Capability 3 requires expected output to stay
  unchanged, which makes such a change visible as a sweep failure rather than as
  a quiet edit to an expectation.
- Assumption: no caller outside `scripts/gspec-backlog.sh` parses `gspec/`, so
  identical adapter output means no consumer is affected.

## Success Metrics

- In `scripts/gspec-backlog.sh`, literal copies of the task-line shape go from
  three to zero, of the id class from two to zero, of the prefix from two to zero, and of the checked-marker test
  from six to one shared block; enumerations of the three layout paths go from
  two to one. All are countable by grep and pinned by the agreement cases in
  capabilities 1 and 2.
- Every state assertion named in capability 3 fails under removal of its own
  gate.
- The before/after comparison of `nodes`, `plans`, `task-status` and `check-task`
  over the existing fixtures is byte-identical, and `scripts/test-gspec-backlog.sh`
  is green with no expectation edited.

## Implementation Context

> This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- Whether the shared layout enumerator yields relative paths only, or a
  relative/absolute pair, and whether the resolver's existence test lives in the
  enumerator behind a flag. Both satisfy capability 1; the choice is a
  decomposition call.
- Whether `cmd_files_status`' narrower `**T[0-9]+**` id pattern, at its three
  occurrences in that function, should ever derive from the shared blocks.
  Deferred because doing so widens what it matches, and judging that needs a
  survey of the sidecar's real keys that this feature does not carry.
