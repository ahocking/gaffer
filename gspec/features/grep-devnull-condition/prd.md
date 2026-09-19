---
spec-version: v2
depends_on: [next-state-reporting-integrity]
---

# Feature: grep-devnull-condition

## Overview

The crash-recovery path answers *is this dirty tree safe to discard, or does it
hold something a reviewer produced*, and it answers by asking whether any path
in the tree's status listing matches a reviewed-output pattern. That check —
`_dirty_has_reviewed_output()` in `scripts/runstate.sh` (~:3208–3246) — ends in
`| grep -E "$combined" >/dev/null`, and its exit status is the `elif` condition
in `_reconcile_tree` (~:3283), reached only from `cmd_reconcile`, which
`/gaffer:resume` runs. A pipe-fed `grep -q` stops at its first match, so on a
large dirty tree it exits while `git status`, `tr` and `sed` are still writing;
under the file-wide `pipefail` setting the pipeline reports the signal, the
function reads **false**, and reconcile picks **discard** over **escalate** for
precisely the mixed tree — loop scratch plus reviewed output such as
`.gspec/memory/pending/…` — the function exists to protect. The discard is a
stash, so the loss is recoverable; that is what bounds the harm to a
recoverable stash rather than data loss. The `-q` half reproduces on every
grep tested: 20/20 misfires (rc 141) on BSD grep, ugrep, and GNU grep 3.8 and
3.11. The `>/dev/null` form that replaced it was **inferred** to short-circuit
the same way under GNU grep, and that inference was **refuted by measurement
on 2026-09-19** (T1's review): 0/20 misfires on GNU grep 3.8 and 3.11 against
a 414 KB listing, with the pre-change check escalating 20/20 — GNU grep stops
scanning on a null stdout but drains a non-seekable stdin before it exits, so
the writer never takes SIGPIPE; only `-q` skips that drain. The redirect form
is therefore inert on every grep in the toolchain, and it is still replaced:
its correctness rests on an implementation courtesy no grep documents as a
contract, and a redirect is one keystroke from `-q`. The comment inside the
function (~:3232–3238) reasons "drop `-q`, redirect stdout" as the fix; it
must be rewritten, not deleted, to state what was measured, or the next reader
restores a pipe-fed grep on its authority.

This is the one shape of the same reader-closes-the-pipe hazard that
`next-state-reporting-integrity` closed elsewhere, and both of the guards that
feature added deliberately do not match it — its own end-of-run review found
this instance. It is a new feature rather than a task on that parent because
the parent's plan is fully checked, and appending to a checked plan reopens a
derived-done feature. It is not a capability on `runstate-write-integrity-gaps`
either: that feature's hazards are key addressing and value decoding, and the
guard widening here spans both sweeps and the adapter, which its scope
excludes. The slug names the scope — a pipe-fed grep with a `/dev/null` stdout
used as a condition: the one live instance plus the detector that missed it.

## Users & Use Cases

- **The operator resuming after a crash on a Linux host** — their tree holds
  reviewed output alongside loop scratch, and the recovery path decides on
  their behalf whether that output is kept or stashed. They are not asked.
- **The resumed session obeying reconcile's decision** — reads one `DECISION=`
  and acts on it, with no second source to check it against. A wrong answer
  here is executed, not noticed.
- **CI running under GNU grep** — the flavour the redirect form was assumed to
  misfire on; measurement showed it does not, so the sweep case pins the
  corrected form and is sharp against the `-q` shape rather than showing the
  fix undo an observed GNU grep failure.
- **A maintainer reading the guards' KNOWN BOUNDARY comments** — needs them to
  describe what the guards still miss, not a shape the guards now catch.

## Scope

**In**
- The reviewed-output check in `scripts/runstate.sh` reads its entire input
  before deciding, expressed with no reader that can close the pipe before its
  writers finish, with the function's never-fails contract and its true/false
  return semantics unchanged, and the stale in-function comment rewritten.
- The guard shape `PIPE_GREP_Q_RE`, a verbatim copy in `scripts/test-runstate.sh`
  and `scripts/test-gspec-backlog.sh`, widens in **both** copies, kept
  byte-identical, to flag (a) a pipe-fed grep whose stdout is redirected to
  `/dev/null` and (b) a `q`-bearing grep option placed after the pattern, which
  GNU option permutation turns into the same behaviour; each guard gains one self-proof
  injection per new shape.
- The fix lands before or with the widened detector, so neither sweep is ever
  red on a known instance.
- A reconcile case in `scripts/test-runstate.sh`: a dirty fixture holding one
  reviewed-output path plus enough untracked leaf files that the producer runs
  well past any pipe buffer, asserting `escalate` over a repeat loop.

**Out**
- What reconcile decides when the check is correct: the same `DECISION=`
  vocabulary, no new state.
- `scripts/metrics.sh`, `scripts/migrate.sh`, and every hook body.
- Anything under `gspec/`.
- The parent's checked tasks and both guards' checked task **lines** — only the
  files those tasks produced change.

**Deferred**
- Surveying the same `/dev/null` shape across the plugin's remaining scripts
  and hooks. The one live instance and the two guards are this scope; a wider
  survey is its own.

## Capabilities

- [ ] **P0**: Reconcile's reviewed-output check reads its whole input before deciding
  - `_dirty_has_reviewed_output` in `scripts/runstate.sh` holds no pipeline
    whose reader can exit before its writers finish, so a dirty tree holding
    loop scratch plus at least one reviewed-output path yields `escalate` on
    every run, at any size of tree, under GNU grep as under BSD grep or ugrep
  - the function still never fails its caller: a tree with no reviewed-output
    path reads false as it does today, a tree that cannot be listed reads as it
    does today, and `_reconcile_tree`'s `elif` and its surrounding branches
    are otherwise unchanged
  - the in-function comment is rewritten to state why `-q` is correct again
    in the corrected form, what was measured about the `>/dev/null` form it
    replaced (no misfire on GNU grep 3.8 or 3.11; only the pipe-fed `-q` form
    misfires) and why it is replaced anyway, and that the whole listing is
    held deliberately — so a later reader neither restores the redirect nor
    "optimises" the corrected form back into a pipe-fed grep

- [ ] **P1**: Both source guards flag a stdout-to-`/dev/null` or `q`-after-pattern grep condition as they flag `-q`
  - `PIPE_GREP_Q_RE` in `scripts/test-runstate.sh` and
    `scripts/test-gspec-backlog.sh` is byte-identical across the two files
    after the change, and matches each of `>/dev/null`, `> /dev/null`,
    `1>/dev/null` and `&>/dev/null` on a pipe-fed grep, and a pipe-fed grep
    with a `q`-bearing option placed after its pattern — while a bare
    `2>/dev/null` alone is **not** matched, since stderr to null does not
    short-circuit
  - each guard carries one self-proof injection per new shape, each shown to
    turn the guard red when planted anywhere in the file it scans and recorded
    in the case's comment, alongside the existing `-q` injection
  - each guard's KNOWN BOUNDARY comment no longer names a shape the guard now
    catches, and states the boundaries that remain — a construct inside a
    trailing comment, a pipeline split across a `\`-continuation, and any
    shape excluded by the Deferred Decision below

- [ ] **P1**: A reconcile sweep case pins the corrected reviewed-output check against the reader-closes-the-pipe misfire
  - the fixture is a dirty tree with one reviewed-output path and enough
    untracked leaf files that the status listing exceeds any pipe buffer by a
    wide margin, and the case asserts `escalate` **by name** over a repeat
    loop — an assertion that the decision merely differs from `discard` passes
    on several wrong answers
  - the case is run against the pre-change code under GNU grep and its result
    recorded — measured 2026-09-19 on GNU grep 3.8 and 3.11: the pre-change
    `>/dev/null` form did **not** misfire (0/20, `escalate` 20/20 on a 414 KB
    listing) while the pipe-fed `-q` form misfired 20/20 (rc 141) — and its
    comment records that observation, the hosts it was made on, that the case
    is sharp against the `-q` shape, and that a green run on any host
    certifies only that the here-string form holds, never that the redirect
    form failed — a probe that cannot reproduce a failure eliminates nothing,
    in either direction

## Dependencies

- `next-state-reporting-integrity` — the parent: it named the mechanism, closed
  every `-q`-shaped instance in these two files and added the two guards this
  feature widens. Derived-done; nothing here re-opens a capability or edits a
  checked task line of it.
- `runstate-write-integrity-gaps` — **not blocking, but same file**: it is the
  next feature to edit `scripts/runstate.sh`. Landing this first means it does
  not edit around a known-wrong condition.
- `gspec-adapter-consistency` — **not blocking, but file-overlapping**: it adds
  cases to `scripts/test-gspec-backlog.sh`, where one copy of the widened guard
  lives. No logical dependency in either direction; the two should not be in
  flight against the same file at once.

## Assumptions & Risks

- If the corrected form holds the whole status listing in memory, that is an
  accepted consequence: the shell handles multi-megabyte strings and the
  comparison is a single grep, so this is acceptable — and the comment must say
  so.
- Risk: the reconcile path runs only on resume, so the first live exercise of
  the fix is the next crash recovery, not the packet that lands it. The sweep
  case stands in for that exercise.
- Risk: the widened guard is still a text scan. It bounds accidental
  reintroduction of the named shapes, not a deliberate rewrite into an
  unrecognised one; the reviewer remains the gate there.
- Assumption: a GNU grep host is reachable at implementation time — CI or a
  local GNU grep — for the pre-change observation the sweep case requires;
  without one the case's comment must say the result was not observed.
  Resolved 2026-09-19: observed in Linux containers during T1's review, and
  the result was negative for the redirect form (see P1).

## Success Metrics

- Reconcile on a mixed tree holding reviewed output returns `escalate` on every
  invocation under GNU grep — checkable by repeated invocation against a
  fixture whose status listing exceeds any pipe buffer by a wide margin.
- Both guards flag every planted instance of every named shape and zero
  instances on the real files — checkable by running the two sweeps.
- No reviewed-output path is ever swept into a discard stash by the recovery
  path — checkable per recovery against the stash contents.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Whether the widened guard should also match a pipe-fed grep whose stdout is
  redirected to a path other than `/dev/null`.** A redirect to a regular file
  does not short-circuit, so the likely answer is no; it is decided at plan
  time alongside the regex itself.
- **Whether the corrected check is a captured value tested from a here-string
  or an emptiness test folded into the writer** — an implementation call,
  deferred exactly as the parent deferred it.
