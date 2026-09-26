---
spec-version: v2
depends_on: [runstate-write-integrity-gaps]
---

# Feature: runstate-set-shape-detection

## Overview

The parent's capability "`set` refuses any key it cannot address at column 0"
**stays checked**: its refusal is real and its sweep is green. This feature
closes two cases where that refusal misjudges a key's *shape*, plus four minor
gaps on the same surface, all found by the parent's own whole-branch review
(run `20260919T224810-6fc6`, 2026-09-19) and operator-approved on 2026-09-20 as
an ADR 0026 arm-2 follow-up; it never reopens the record. **Defect 1:** a
column-0 YAML comment between a header and its indented body is neither blank
nor indented, so the header is judged a column-0 scalar and `set backlog x`
replaces it at exit 0, stranding the children — the exact P0 corruption the
parent claimed closed. Reproduced; reachable only through a `write` carrying
such a comment, which no plugin writer emits today, so the sweep stayed green.
**Defect 2:** the detector cannot tell a mapping child from a line of a
`note: |-` body, so a note line starting `driver_host:` makes `claim-driver`
refuse a fresh run-state — a false refusal of a criterion the parent pinned.
Reproduced; loud, not corrupting, but the message steers the agent to a
whole-file `write`, and `trim-note` turns any long note into a block body, so
ordinary prose is the trigger and no sweep fixture carries one.

**Four minor gaps folded in:** the both-present shadow `cursor:` is written
silently by design (refusing it would break `set status`, since packet records
carry a nested `status:`) and nothing pins that; a key carrying a newline
appends a malformed column-0 line at exit 0; the record's one-decoder claim is
wider than the code, since three `project-overrides.yaml` digit tests still
strip a quote pair; and the reason-less sentinel case in `scripts/test-pause.sh`
passes on empty output (inferred, not reproduced).

## Users & Use Cases

- **An automated driver advancing state mid-run** — calls `set` between
  packets and must get either the write or a refusal, never a file that no
  longer parses.
- **A resuming or dispatched session reading state back** — `claim-driver` is
  its first write against a run-state it did not author; a false refusal there
  sends it to a whole-file rewrite of the loop's only durable state.
- **A human reconstructing after corruption** — the state is gitignored, so a
  header stranded at exit 0 is recovered by hand or not at all.

## Scope

**In**
- shape detection judged on YAML structure only: comment lines carry none, and
  a block scalar's body lines are the block's, not the mapping's.
- key charset validation before shape detection.
- the prose corrections (the parent PRD's Defect 1 paragraph and its success
  metric; `CLAUDE.md`).
- the emitted-advisory assertion on the reason-less sentinel case.
- an owning sweep case per hazard, in `scripts/test-runstate.sh` (mirrored in
  its no-tools block) and `scripts/test-pause.sh`, none vacuous, with the
  parent's loud-skip rule inherited.

**Out**
- YAML path addressing in `set`, in any form — still refused, per the parent's
  recorded decision.
- refusing the both-present shadow-cursor shape.
- changing run-state's schema.
- the pause sentinel gaining a parser.
- the three overrides-reader digit-strips themselves — digit tests on operator
  config, deliberately separate from the run-state decoder.

**Deferred**
- nothing: every review finding is taken in full.

## Capabilities

- [ ] **P0**: A column-0 comment between a header and its body never changes the header's judged shape
  - `backlog:` / `# a comment` / `  cursor: x` with `set backlog flat` is
    refused, asserting the four observables the owning-sweep-case capability
    defines — on the same shape the comment currently defeats
  - a comment line at any indentation, at any position outside a block-scalar
    body, is skipped exactly as a blank line is: it is never the line that
    decides a header's shape and never a nested-key match, so a file with
    comments judges every key identically to the same file with those lines
    removed

- [ ] **P0**: A block-scalar body is never read as nested keys
  - `claim-driver` against a fresh run-state whose `note: |-` body contains a
    line starting `driver_host:` exits zero and the file then carries all four
    `driver_*` keys at column 0, each readable back as the value written
  - the body lines the detector excludes from the nested scan are exactly the
    lines `set`'s replace path skips when it replaces that same block —
    asserted by one case run against both paths, since two hand-kept boundary
    rules drifting apart is the parent's original defect in a new place
  - a genuinely nested key is still refused: `cursor` under `backlog` is
    refused, asserting the four observables the owning-sweep-case capability
    defines, so the exclusion cannot be written as "stop scanning indented
    lines"

- [ ] **P1**: `set` refuses a key outside `[A-Za-z_][A-Za-z0-9_]*` before shape detection, writing nothing
  - a key carrying a newline, a space, a leading digit, or a `:` is refused,
    asserting the four observables the owning-sweep-case capability defines —
    the newline case being the reproduction that today writes a malformed column-0
    line at exit 0
  - the charset is the one the script's own column-0 boundary regex and the
    sweep's top-level key count already assume, so nothing a live caller writes
    today is newly refused: every key `claim-driver`, `heartbeat`, `begin-run`
    and the loop skills pass to `set` keeps working unchanged
  - the refusal is decided before any temp file exists, so a refused call
    leaves the target's directory as it found it

- [ ] **P1**: The record matches the code on the shadow artifact and on decoder unity
  - a file carrying both a nested `  cursor:` and a column-0 `cursor:` has one
    sweep case pinning today's behaviour: `set cursor` exits zero, rewrites the
    column-0 line only, and `runstate.sh cursor` still returns the nested value
  - the parent PRD's Defect 1 paragraph gains one sentence stating that the
    both-present shape is written silently by design and why refusing it would
    break `set status` — landing in free prose outside any checked block, so
    the immutability floor allows the edit
  - the one-decoder claim in `CLAUDE.md` and the parent PRD's success metric is
    scoped to every read path of run-state and the pause sentinel, and names
    the three `project-overrides.yaml` readers as digit tests kept deliberately
    separate, so a reader counting by inspection arrives at the same number
    the prose states

- [ ] **P1**: The reason-less sentinel case in `scripts/test-pause.sh` can fail
  - the case asserts the advisory was emitted — its fixed `PAUSE REQUESTED`
    prefix present in the hook's output — alongside the existing assertion that
    no `permissionDecision` is present, so a hook that exits before emitting
    turns the sweep red rather than passing on empty output
  - the existing pause cases keep passing unchanged, so the assertion is
    additive and nothing already pinned loosens

- [ ] **P0**: Every hazard above has an owning sweep case, none can pass vacuously, and every new case runs without `jq` or `python3`
  - each of the comment-between-header-and-body and block-body-with-key-shaped
    line shapes has a case in `scripts/test-runstate.sh` asserting a literal,
    non-empty expectation, and every refusal case this feature adds asserts all
    four observables — non-zero exit, checksum-identical file, no new column-0
    key, key named in the message — rather than any one of them
  - every new case this feature adds that parses YAML does so with a real parse
    and skips loudly — visibly reported and counted in the sweep summary — when
    no parser is present, exactly as the parent's sweep does; a case that can
    quietly return success re-opens the hazard the parent's loud-skip rule
    closed
  - every new case this feature adds to `test-runstate.sh` is mirrored in the
    block that runs with `jq` and `python3` absent from `PATH` and produces the
    same result there, since `runstate.sh` stays at the guard's dependency tier
    and must keep checkpointing on stock Git Bash
  - every new case this feature adds is verified non-vacuous by making the
    mutation it exists to catch (reverting the fix) and observing the sweep
    turn red

## Dependencies

- `runstate-write-integrity-gaps` — the parent. Supplies `_set_target_shape`,
  the fixture table, the "set: a target it CANNOT address" sweep block and its
  no-tools mirror. Derived-done; nothing here re-opens it, and both edits it
  receives are free prose outside every checked block.
- `runstate-write-integrity` — supplies the shared encoder and the loud-skip
  rule the sweep capability inherits. Complete; nothing of it changes.

## Assumptions & Risks

- Assumption: no plugin writer emits a column-0 comment inside a mapping today
  (verified for the shipped template).
- Assumption: no live caller passes `set` a key outside the charset, so the
  charset refusal breaks nothing that currently works.
- Risk: the detector's block-body exclusion and `set`'s replace-path skip are
  two boundary rules that must agree; pinned by a shared case, not a comment.
- Every agent-supplied value reaching this file is hostile input, and the file
  is gitignored — no corruption here is recoverable by `git restore`.

## Success Metrics

- The two reproductions change outcome: `set backlog flat` on the commented
  header goes from exit 0 and an unparseable file to a refusal; `claim-driver`
  on a fresh run-state with `driver_host:` in its note body goes from refused
  to claimed.
- A run-state assembled through `write` with comments in it, or with a long
  trimmed note, checkpoints through the loop's next `set` and `claim-driver`
  without a workaround through `write`.
- No prose claim in the repository about decoder unity is wider than what
  `runstate.sh` does, so counting by inspection and reading the record give
  the same answer.
- The sweeps' green results are evidence again: the one case known to pass on
  empty output no longer can, and no case this feature adds joins it.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- Whether `_set_target_shape` and `cmd_set`'s replace path share one awk
  function text for block-body tracking, or keep two implementations held
  equal by the shared case. Deferred because both satisfy the block-body
  capability and the choice is a decomposition call.
