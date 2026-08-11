---
spec-version: v1
---

# Feature: runstate-write-integrity

`scripts/runstate.sh` is the single writer of `.agents/run-state.yaml` — the
loop's ONLY state that survives a session (ADR 0005). The file is gitignored
(ADR 0009, `.gitignore:25`), so a corrupted run-state has no `git restore`:
recovery is manual reconstruction from whatever context is left. Two of its
write paths can destroy that file and both have fired live, and the sweep that
is supposed to catch them can pass without running. One feature because defects
1 and 2 are the same hazard in the same two functions and share one encoding
helper and one guarded rename, and defect 3 is the check that would have caught
both — the parse assertions capability 4 requires are vacuous until it lands.

**Defect 1 — `set` writes an unquoted scalar.** `cmd_set` substitutes the value
straight into `sed -E "s|^${key}:.*|${key}: ${val}|"` and quotes nothing, so any
value containing `: ` opens a sibling mapping key and the file stops parsing. It
fired live at a packet close whose note read `… blocked on the commit: the
harness denied it` → `yaml.scanner.ScannerError: mapping values are not allowed
here`. `set` is the only write path that takes an arbitrary agent-supplied value
as an argument, and `: ` is the single likeliest sequence in a note about code.
The mechanism carries two more hazards of its own: the `|` delimiter breaks on a
value containing `|`, and sed replacement text expands `&` to the whole match.
ADR 0022 hardened `add-finding` against exactly this class — single-quoted scalar
with `'` doubled, interpolated via `awk ENVIRON` and never `awk -v` (because `-v`
expands `\n` in the *value*, which re-opened a newline injection one line after a
`tr` collapse closed it) — and `cmd_set`, two hundred lines above it in the same
file, never got it. The hardening went to the function whose bug had just been
found, not to the class of writes sharing the hazard.

**Defect 2 — `write` replaces the file with whatever reaches stdin, and validates
nothing.** `cmd_write` is `cat > "$tmp"` followed by `mv -f`. A failed transform
upstream in the pipe silently truncates run-state to a stub; it fired live when
an `awk` aborted on a missing `strftime` and left a **26-byte** file. The atomic
rename did precisely its job — it committed the stub atomically.

**Defect 3 — the sweep's parse assertions are conditional on the host and pass
silently when they cannot run.** `yamlok()` (`scripts/test-runstate.sh:583`) uses
`python3 -c 'import yaml'` when available and otherwise `return 0` ("no parser
available -> do not fail the sweep on this host"). PyYAML is not in the standard
library, so on a stock python3 all six hostile-input cases — `colon`, `hash`,
`quote`, `backslash`, `dashlead`, `brace` — pass **without testing anything**,
while the sweep still reports green. `CLAUDE.md:485` states flatly that the sweep
"asserts a real YAML *parse* after each mutating subcommand": true on CI and on
the author's machine, not universally. Same shape as the two defects above — a
check that looks like it is running and is not.

**The dependency tier is the design constraint, not a compromise.** Validation
must run **everywhere `runstate.sh` runs**, which means POSIX shell alone.
`jq` would not help even if it were required — jq is a JSON processor and
run-state is YAML, and there is no `yq` anywhere in the plugin. `runstate.sh` is
deliberately in the top tier: it has **zero** jq invocations today (its three
mentions of jq are comments), and `add-finding`'s quoting is a single `sed`
substitution *specifically* so it keeps working on stock Git Bash, which ships
neither jq nor a real python3 — the same constraint `hooks/guard.sh` is built
around. Only `metrics.sh collect` hard-requires jq, and metrics is non-critical
and called `|| true`. Demoting the durable-state writer to that tier would mean
the loop either cannot checkpoint or checkpoints unvalidated on Windows. So
`write` gets a **structural check, not a parse**.

## Capabilities

- [ ] **P0**: `set` cannot corrupt run-state, whatever the value contains
  - the value is written as a single-quoted YAML scalar with `'` doubled and newlines collapsed rather than rejected (the caller is an agent mid-loop) — the encoding `cmd_add_finding` already applies, and both call **one shared helper**, so a future hardening of one cannot leave the other behind, which is exactly how this defect was created
  - the value never reaches `sed` replacement text or `awk -v`: replacement text expands `&` to the whole match and `\1` to a group, `-v` expands `\n` in the value, and the present `s|…|…|` delimiter breaks on a `|`. Interpolation is `awk ENVIRON`, POSIX shell only
  - **every** value is quoted — there is no plain-scalar allowlist, and reintroducing one as an optimisation is a regression. An allowlist was built and removed on 2026-08-11: approximating YAML's plain-scalar grammar with negative rules produced two distinct classes of silent wrongness, each found only by someone thinking of the next counterexample. Unparseable output — 273 fuzzed values ending in `:` wrote a broken run-state with `rc=0`, invisible to the key-count check below because they add exactly one key. And wrong-typed round-trips — `no` returned `False`, `00` returned `0`, `0755` returned `493`, parsing cleanly while violating the round-trip criterion above. **Neither class was reachable from any caller of the day** — `status` is only ever `running`/`paused`/`done`/`blocked`, SHAs are hex, timestamps end in `Z`, PIDs have no leading zero — and that is the point rather than a mitigation: the allowlist is a claim about every *future* value, it was wrong twice within one afternoon, and each rule was only ever added after someone thought of the next counterexample. A single-quoted scalar is correct for every string by construction; the allowlist bought only that `status: running` stayed visually bare
  - compatibility is the **reader's** job, not the writer's: every reader in `runstate.sh` that surfaces a value (`status`, `cursor`, `pause-status`, …) strips the encoding symmetrically, so callers see the bare value and no existing reader, grep, skill instruction or fixture changes. Measured before the decision: no production code greps run-state values at all — `skills/`, `scripts/`, `hooks/` and `templates/` are clean; only sweep assertions do
  - no output self-check is required, and one was deliberately **dropped** on 2026-08-11 rather than built. The plan carried a task to verify the top-level key count before the rename and refuse a value that injected a sibling key; once every value is quoted, a value cannot inject a key at all — verified by writing a value containing a literal newline and `injected: yes`, which collapses and quotes into one scalar and adds no key. A check whose failure mode cannot occur is the same kind of construct as the allowlist it would have been guarding, so it is not in this feature. The residual key-side hazard (`cmd_set` guards with a regex and matches with a literal, so the two can disagree) is recorded as a finding, unreachable while every key is an internal `[a-z_]` literal and no caller supplies one
  - `set` is also safe against the **target's** existing shape, not only the value: it replaces one column-0 line, so writing a key whose current value is a multi-line block scalar rewrites the header and orphans the indented body, and the file stops parsing entirely. Reproduced 2026-08-11: `trim-note` re-emits `note:` as `|-` by design, after which `set <file> note <one line>` leaves the old body stranded below the new value. The key-count check above does **not** catch it — no top-level key is added. `set` either handles a block-scalar target correctly or refuses it, and never silently strands a body. This path is undocumented but not unreachable: nothing in `skills/` names a command for "overwrite `note:`", and an agent reaching for `set` is what produced the reproduction — the same ambiguity that made a lane's `status` write hazardous until `parallel.md` was made to name `write` explicitly

- [ ] **P0**: `write` refuses structurally invalid input and leaves the existing file byte-untouched
  - refuses empty or whitespace-only input, input carrying no `schema:` key, and any column-0 line that is not a well-formed `key:` line, a comment, or a document marker — the 26-byte stub fails the first two
  - on refusal: nonzero exit, a message naming the check that failed, the temp file removed, and the target file **byte-identical** — asserted by checksum, because "the good file still exists afterwards" is the whole point of the capability
  - the bound is stated honestly in the refusal message and in the script: this catches **truncation and gross malformation**, not every corruption. A document that is well-formed but wrong — a stale `cursor`, or a `: `-injected sibling key that is itself valid YAML — passes the check, and is out of this feature's reach
  - a run-state that does not yet exist is still created: the check runs on the input, never on the target, so first-write and `resume`'s rebuild are unaffected

- [ ] **P0**: The integrity checks run on every host `runstate.sh` runs on, in POSIX shell alone
  - no jq, python3, yq or any other external dependency enters `runstate.sh` — it stays at the same dependency tier as `hooks/guard.sh`, which is what lets the loop checkpoint at all on stock Git Bash
  - nothing in the write path is gated on `command -v` or any other host-conditional: a check that disables itself when a tool is missing is defect 3 in a different file
  - the sweep exercises the encoding and the `write` check with a `PATH` from which `jq` and `python3` are absent, asserting identical behaviour — so a dependency added later fails a test rather than degrading silently on the hosts nobody runs the sweep on

- [ ] **P0**: Every hazard has a regression case, asserted rather than grepped
  - `set` is exercised with a value containing `: `, an embedded `'`, a newline, a leading `-`, a `#`, flow and anchor characters (`{`, `[`, `&`, `*`), a `|`, and a trailing space — each asserting a real YAML parse, a round-trip read-back equal to the input, and an unchanged top-level key count: the three assertions the hostile-summary loop already makes for `add-finding` (`scripts/test-runstate.sh:599–604`)
  - the `set` fixtures carry keys both before and after the key being written, so an injected sibling is detectable rather than landing harmlessly at the end of the file
  - `write` is exercised with the 26-byte truncation, empty stdin, whitespace-only stdin, and a schema-less document — each asserting a nonzero exit and a target checksum identical to its pre-call value
  - one case asserts `set` and `add-finding` produce the **same** encoding for the same hostile value, pinning the anti-drift property mechanically rather than by comment

- [ ] **P1**: The sweep's parse assertion never silently no-ops
  - `yamlok` is either unconditional or **loudly skipped** — visibly reported and counted, never `return 0` standing in for a pass — in all three copies: `scripts/test-runstate.sh:583`, `scripts/test-migrate.sh:31`, and the second parser-gated helper at `scripts/test-migrate.sh:42`. The precedent is already in this repo: `scripts/test-report-conventions.sh:71-72` records a FAIL reading "not asserting vacuously" rather than passing when no parser is present
  - a skip is visible in the sweep's summary line, so a green run on a parser-less host is distinguishable from a green run that actually parsed
  - the overstated claim is corrected everywhere it appears: `CLAUDE.md:485`, and the in-sweep comments repeating it at `scripts/test-runstate.sh:582`, `:771`, `:810` and `scripts/test-migrate.sh:294-295`. The same claim in the **unchecked** criterion at `gspec/features/run-state-cleanup.md:96` needs no edit — it becomes true when this capability lands
  - `test-runstate.sh:267` already invokes python3 unconditionally, so a host with no python3 at all fails the sweep regardless: the conditional buys silence only in the case where it does damage — python3 present, PyYAML absent

- [ ] **P1**: The sweep is deterministic, so a green run means the same thing every time
  - `scripts/test-runstate.sh`'s case "trim-note handles the multi-line shape" fails intermittently — observed once in a 20-run probe on 2026-08-11 (Darwin 25.5), with a different `trim-note` assertion failing on different runs. `runstate.sh trim-note` is **deterministic in isolation** on that exact fixture (12/12 `TRIMMED=yes`), so the nondeterminism is in the sweep's environment, not the function under test
  - the cause is identified and fixed, or the case is made deterministic; a case that usually passes is not a regression test, because the run that matters is the one where it lied
  - this belongs with the two defects above for the same reason capability 5 does: all three are ways the verification reports success without having verified. A vacuous assertion and a flaky one are the same failure wearing different clothes — and a flaky case is worse in one respect, because the standard response is to re-run until green
  - no case in any sweep is re-run-until-green as a remedy; a retry loop added to hide this would itself be the defect

## Deferred Decisions

- Whether agent-supplied values composed *into* `write` input (a nested packet
  note, `pending_questions:`) get the same encoding. Deferred because their
  composer is a prompt, not a function, so there is no single call site to
  harden; the structural check does not reach them and the capability above says
  so rather than implying coverage it does not have.
- Whether `write` should require invariants beyond `schema:` (`status:`, `mode:`).
  Deferred because `resume` reconstruction and several existing sweep fixtures
  legitimately write partial documents, so widening the invariant set needs a
  survey of real writes that this feature does not carry.
