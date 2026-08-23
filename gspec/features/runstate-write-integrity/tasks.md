---
spec-version: v2
feature: runstate-write-integrity
---

# Plan: runstate-write-integrity

Three write paths in `scripts/runstate.sh` can destroy the loop's only durable
state, and the sweep that should have caught them can pass without running. The
vacuous check is fixed **first**.

**The one ordering rule that cannot be got wrong:** T1 lands before any change to
`runstate.sh`. `test-runstate.sh`'s `yamlok` returns 0 when PyYAML is absent, so
every "asserts a real YAML parse" case is currently a coin flip on the host — and
those cases are the *only* thing guarding a refactor of the encoding. Reversed,
T4–T7 and T10 would be verified by assertions that cannot fail, which is precisely
how defect 1 reached production. T1 is **P1 by product priority and a prerequisite
for the P0 work**; that inversion is deliberate, not an ordering slip. This binds
T7 as much as the rest, which is not obvious: T7's own new cases are checksum-based
and survive a parser-less host, but they cover only the *refusal* paths — its
unchanged-behaviour half rests on `test-runstate.sh:820` and `:836`, both of which
assert through `yamlok`.

**The POSIX-only dependency tier is a constraint on every task, not a task.** No
`jq`, `python3`, `yq` or any other external tool enters `runstate.sh`, and nothing
in the write path is gated on `command -v` — a check that disables itself when a
tool is missing is the defect T1 fixes, in a different file. Only the third
criterion of that capability is executable work, so it is one task (T8): a sweep
case with a scrubbed `PATH`. T8 must come after T1 so the scrub is scoped around
the `runstate.sh` invocations only — wrapped around the sweep's own parser helper
it would trip T1's loud skip and fail the run for the wrong reason.

**Regression cases ride with the behaviour that needs them**, so the dedicated
regression capability has no task of its own: there is no compiler here, the sweep
is the build, and a behaviour task without its cases is not verifiable at all. The
one exception is T8, whose subject is host-independence rather than a behaviour —
it has nothing to ride on.

**No skill or prompt changes are in this plan, and that is a property being
bought, not an omission.** Every value is quoted on write and stripped
symmetrically on read, so callers see byte-identical values; if a task finds
itself editing `skills/`, the decode is wrong. Note this rests entirely on the
reader — see the T4/T5 note below.

**T3 is an investigation, not a known fix**, and it is ordered early on purpose:
until the sweep is deterministic, a green run on any later task means less than it
should. It carries **no dependency edge** — it must never block P0 work if the
cause takes a while to find.

**The "ruled out" note this preamble used to carry was WRONG, and the way it was
wrong is the lesson.** It recorded SIGPIPE under `pipefail` as eliminated because
the exact piped shape was run 120 times in **isolation** with zero failures. But
isolation never reproduces this flake at all — 0 in 3,000 sequential calls and 0
in 12,000 at concurrency were separately established. A probe run where the
phenomenon does not occur **cannot eliminate any cause**; absence of the failure
there is evidence about the setup, not about the hypothesis. That false
elimination was then propagated into two task briefs as "do not re-derive it",
which could have blocked the answer. SIGPIPE was the cause.

**T10 is a third defect of the same family, found while planning**, and it is now
the only remaining `set` hazard: it is about the *target's* existing shape rather
than the value, so quoting the value cannot address it. Ordered after T4 because
it shares its function and fixtures.

**T6 was dropped on 2026-08-11, not deferred.** It would have made `cmd_set`
verify its own top-level key count before the rename and refuse a value that
injected a sibling key. Once T4 quoted every value, that failure mode became
unreachable by construction — verified by writing a value containing a literal
newline and `injected: yes`, which collapses and quotes into a single scalar and
adds no key. Keeping a check whose failure cannot occur is the same construct as
the allowlist it would have guarded. The residual key-side hazard (`cmd_set`
guards with a regex and matches with a literal, so they can disagree) is a filed
finding, unreachable while every key is an internal literal.

**T4 and T5 are NOT separable, and splitting them here was a planning error**
(corrected 2026-08-11, mid-execution). Once T4 dropped the plain-scalar allowlist
and began quoting every value, the writer stopped preserving the bare form, so
the reader's symmetric strip became the only thing preserving compatibility.
Landing T4 alone leaves `cmd_get` returning `'running'` **with quote characters**,
which breaks the `case` match at `hooks/session-start.sh:36-51`: a crashed run
falls through to the `paused|*` arm and the human is told the run "was paused
cleanly" — the wrong recovery instruction, silently. They are executed as one
packet. Both files are still `scripts/runstate.sh` + `scripts/test-runstate.sh`,
so no scope widens; only the packet boundary moved.

T4, T5, T7 and T10 all write `scripts/runstate.sh` and `scripts/test-runstate.sh`, so
they serialize and none is marked `[P]`. The `CLAUDE.md` correction is isolated
into one late task rather than letting each earlier task nudge the repo's most
contended file.

**`.agents/task-files.yaml` carries no entries for this feature yet**, so every
packet here resolves to empty scope and `packet-graph.sh` serializes it — safe, and
it means T2's `[P]` currently buys nothing. Add fingerprinted entries when this
feature is scheduled, if the parallelism is wanted; the dependency chain limits the
real gain to T1 and T2, so it may not be worth it. Do not describe the sidecar as
populated until it is.

## Plan

- [x] **T1** **P1** Make `test-runstate.sh`'s `yamlok` record a counted, reported FAIL reading "not asserting vacuously" instead of `return 0` when no YAML parser is present — the shape `test-report-conventions.sh:71-72` already uses — surface the skip in the sweep's summary line, and correct the in-sweep comments at `:582`, `:771` and `:810` that state the parse is unconditional
  - deps: —
  - covers: The sweep's parse assertion never silently no-ops
- [x] **T2** [P] **P1** Apply that same loud-skip shape to both parser-gated helpers in `test-migrate.sh` — `yamlok` at `:31`, and `yaml_cursor` at `:42` whose `return 0` yields an empty *value* a caller then compares as a pass — and correct the comment at `:294-295`
  - deps: T1
  - covers: The sweep's parse assertion never silently no-ops
- [x] **T3** **P1** Identify why `test-runstate.sh`'s case `trim-note handles the multi-line shape` fails roughly 1 run in 20 while `runstate.sh trim-note` is deterministic on that exact fixture in isolation, then either fix the cause or make the case deterministic and record which it was — a retry or re-run-until-green remedy is out of bounds, the SIGPIPE-under-`pipefail` lead is already ruled out (see the preamble), and the remedy is confirmed over the same 40-consecutive-run probe shape that ruled it out — for a 1-in-20 flake, "it passed" is not evidence
  - deps: —
  - covers: The sweep is deterministic, so a green run means the same thing every time
- [x] **T4** **P0** Extract `cmd_add_finding`'s single-quoted encoding (newline collapse, `'` doubled, `awk ENVIRON` interpolation) into one shared POSIX-shell helper both it and `cmd_set` call, and rewrite `cmd_set`'s replace and insert branches to interpolate through it instead of `sed` replacement text — retiring the `|` delimiter, `&` and `\1` hazards — quoting **every** value with no plain-scalar allowlist (one was built and removed the same day; see the capability for what it cost), with the hostile-value cases (`: `, a trailing `:`, an embedded `'`, a newline, a leading `-`, `#`, `{`/`[`/`&`/`*`, `|`, a backslash, a trailing space) each asserting a real parse and a round-trip read-back through a real YAML load rather than a mirror decoder, plus the case pinning that `set` and `add-finding` encode the same hostile value identically
  - deps: T1
  - covers: `set` cannot corrupt run-state, whatever the value contains · Every hazard has a regression case, asserted rather than grepped
- [x] **T5** **P0** Strip the encoding symmetrically in every `runstate.sh` reader that surfaces a value — `cmd_get`, `cmd_cursor`, and `trim-note`'s first-line unwrap, which today strips a leading quote but not a doubled `''` — with a case asserting a value such as `running` is returned byte-identical through the reader, so no existing grep, fixture or skill instruction changes. Note the file itself is no longer byte-identical — since T4 dropped the plain-scalar allowlist, `status` is stored as `'running'` and the reader is now the *only* thing preserving compatibility, which raises this task from tidy-up to load-bearing
  - deps: T4
  - covers: `set` cannot corrupt run-state, whatever the value contains
- [x] **T7** **P0** Make `cmd_write` refuse empty, whitespace-only, `schema:`-less, and column-0-malformed input with a nonzero exit, the temp file removed, and a message naming the failed check and stating its bound honestly — truncation and gross malformation, not a well-formed-but-wrong document — checking the input and never the target so a first write still creates the file, and — before replacing an EXISTING run-state — copying it to `.agents/run-state-prev.yaml` as the last known good, since a transform that dies between lines yields a structurally perfect document the checks cannot catch (`schema: 3` + `status: running` is exactly the 26 bytes the live incident left). With cases asserting a target checksum identical to its pre-call value for the 26-byte stub, empty stdin, whitespace-only stdin, a schema-less document, and a `schema:`-carrying document with a malformed column-0 line, plus the backup being written on replace, absent on first create, and gitignored in both `.gitignore` files
  - deps: T1
  - covers: `write` refuses structurally invalid input and leaves the existing file byte-untouched · Every hazard has a regression case, asserted rather than grepped
- [x] **T8** **P0** Add a sweep case exercising the `set` encoding and the `write` check with `jq` and `python3` absent from `PATH`, scoped so the scrub wraps only the `runstate.sh` invocations and not the sweep's own parser helpers, asserting behaviour identical to a full-`PATH` run
  - deps: T4, T7
  - covers: The integrity checks run on every host `runstate.sh` runs on, in POSIX shell alone
- [x] **T10** **P0** Make `cmd_set` safe against a **block-scalar target**: writing a key whose current value is a multi-line block scalar (`|-`, `|`, `>`) today replaces only the column-0 header and strands the indented body, and the file stops parsing. Handle it correctly or refuse it, never silently strand a body, with a case reproducing the live sequence — `trim-note` re-emits `note:` as `|-`, then `set <file> note <one line>` — asserting a real parse afterwards, since the key-count check cannot see this
  - deps: T4
  - covers: `set` cannot corrupt run-state, whatever the value contains · Every hazard has a regression case, asserted rather than grepped
- [x] **T9** **P1** Correct `CLAUDE.md:485`, which states flatly that the sweep asserts a real YAML parse after each mutating subcommand, and record in the same bullet that one shared encoder now serves `set` and `add-finding` and that `write` validates structurally — one deliberate change to the repo's most contended file rather than seven tasks each nudging it. The two records beyond the correction are repo-convention upkeep, not a PRD criterion
  - deps: T1, T2, T4, T7, T10
  - covers: The sweep's parse assertion never silently no-ops
