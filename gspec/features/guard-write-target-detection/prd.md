---
spec-version: v2
depends_on: [thin-loop-driver]
---

# Feature: guard-write-target-detection

## Overview

Driver mode refuses a main-thread write unless the guard can prove the target
lands under the repository's own `.agents/`. For a shell command that proof
depends entirely on the guard finding the command's write targets: it sanitizes
the command and extracts a target per recognised write form. A target the
sanitizer never sees is a write the guard never judges.

Four defects in that extraction were found reviewing the shipped work (run-state
finding `driver-mode-shell-write-limits`). The two **P0** capabilities below let
a main-thread write escape driver mode entirely, which is the one thing driver
mode exists to stop; the two **P1** ones refuse a legitimate write — wrong, but
in the safe direction. This feature fixes
the four and fixes nothing else: it is not a general shell parser, and where
detection stops is stated rather than widened.

## Users & Use Cases

- **The operator running long unattended loops.** A missed write means the
  driving session edits during a run, which driver mode exists to prevent; a
  wrong refusal stalls the run on a shell whose path spellings are unrecognised.
  Either way the operator finds out hours in.
- **The plugin maintainer.** Needs the boundary of target detection written down,
  so the next review distinguishes a defect from an accepted limit instead of
  re-litigating the same four cases.

## Scope

**In**
- the four capabilities below, all in the guard's shell-write target extraction
- matching cases in the guard's regression sweep for every behaviour change

**Out**
- a general shell parser. Detection covers the write forms the guard recognises
  (redirections, `tee`, the copy/move/link/sync family, `dd of=`, in-place
  stream editing); widening the recognised set is separate work
- the refusal message, the pause route out, and how driver mode is marked
- the hard-deny and ask tiers, and the per-repo guard pattern files

**Deferred**
- nothing

## Capabilities

- [ ] **P0**: A `<<` operator inside a quoted argument does not start heredoc tracking
  - a `<<` sequence appearing inside a single- or double-quoted region is not
    treated as a heredoc start; the line is scanned as ordinary command text and
    every write target in it is extracted and judged
  - a genuine heredoc — the `<<` itself outside any quoted region, whether or not
    the marker is quoted (`<<'A'`) — still has its body dropped through to its
    terminator line, and any redirection on the heredoc's own command line
    (`cat <<EOF > path`) is still extracted and judged
  - a line with an unbalanced quote after sanitization, or a heredoc whose
    terminator never appears before the command ends, refuses the whole command
  - `scripts/test-guard.sh` gains a case where a `<<` sits inside a quoted
    argument on a multi-line command whose later line writes outside `.agents/`,
    asserting a refusal; the case fails if the fix is reverted

- [ ] **P0**: Every heredoc a command line starts is tracked, not only the first
  - a line starting two or more heredocs (`cmd <<A <<B`) drops all of their
    bodies, each ending at its own terminator, in marker order, including the
    quoted (`<<'A'`) and tab-stripping (`<<-A`) spellings, and resumes scanning
    only after the last terminator
  - no heredoc body is scanned as command text: a write form written inside a
    body yields no target and does not by itself cause a refusal
  - no command text is dropped as a body: a write target on a command line after
    the last heredoc terminator is still extracted and judged
  - `scripts/test-guard.sh` gains one case per direction — a two-heredoc command
    whose body text contains a write form that must not refuse, and one whose
    post-terminator line writes outside `.agents/` and must refuse; both fail if
    the fix is reverted

- [ ] **P1**: In-place stream-editing targets exclude script arguments
  - an argument consumed by an expression or script-file option (`-e`, `-f`, and
    their long forms) is not treated as a write target; the remaining positional
    arguments are
  - the joined spellings (`-eSCRIPT`, `--expression=SCRIPT`) are handled, and a
    `--` terminator makes every argument after it positional
  - an in-place suffix argument (`-i.bak`, or an empty suffix passed separately)
    yields the same positional targets, and a command where an option the
    extractor does not recognise consumes an argument, or where no positional
    argument remains, refuses
  - `scripts/test-guard.sh` gains a case where the script text contains a path
    outside `.agents/` while the file argument is under it (must not refuse) and
    one where the file argument is outside it (must refuse); both fail if the fix
    is reverted

- [ ] **P1**: A config root is matched in every path spelling the platform produces
  - each discovered config root is compared in the POSIX spelling and in the
    drive-letter spellings the shell can produce for it, so an absolute target
    under the repository's own `.agents/` is recognised whichever spelling the
    command used
  - drive-letter comparison is case-insensitive and separator-insensitive, so
    `C:\repo\.agents\x`, `C:/repo/.agents/x` and `/c/repo/.agents/x` all match a
    root at `/c/repo`; matching outside that family stays exact
  - when no alternate spelling can be produced, the target is judged by the POSIX
    spelling alone and refuses when it does not match — the fallback never allows
    anything the current behaviour refuses
  - `scripts/test-guard.sh` gains a case asserting a drive-letter target under a
    fixture root's `.agents/` is allowed while a sibling path outside `.agents/`
    and a same-named directory under a different root both refuse; where the
    platform cannot produce the spelling the case is skipped with a counted
    notice, never passed silently, and it fails if the fix is reverted

## Dependencies

- `thin-loop-driver` — defines driver mode, the main-thread refusal, and the
  `.agents/` exemption these targets are judged against. Blocking.

## Assumptions & Risks

- Conservative refusal stays the tie-breaker: where detection cannot prove a
  target lands under `.agents/`, it refuses. Unresolvable targets, variables,
  command substitution, and indirect execution keep refusing.
- Detection covers only the recognised write forms; an unrecognised form is not
  refused, produces no edit event, and appears in metrics only as a command
  class. This is an accepted limit of driver mode, not a gap this feature closes.
- The drive-letter fix assumes the shell provides a working path-translation
  helper; where it does not, behaviour is unchanged and stays safe-side.
- Sanitization order is shared by all recognised forms, so a change made for one
  gap can alter another's behaviour — the sweep is what detects that.

## Success Metrics

- Every case in `scripts/test-guard.sh` that passed before this feature still
  passes after it.

## Implementation Context

> This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.
