---
spec-version: v2
feature: driver-context-window-default
---

# Plan: driver-context-window-default

The probe goes out first because it is the only work here whose completion depends
on someone outside the run: T1 writes the procedure and hands it to the operator,
and T5 records the answer whenever it arrives. Everything between them proceeds
while that answer is outstanding — the capability staying unchecked in the interval
is the intended state, not a stall, and no other task waits on the probe's result.
The reader-facing defect lands next (T2, T3), because every run rendered today
carries the unexplained unmeasured line; the kickoff's silence (T4) is the same
defect one surface upstream and costs a reader one wrong assumption per run rather
than per report. The standing instruction (T6) lands last, when the facts it states
all exist.

**Nothing here restores, corrects or recomputes a threshold value.** Every task
below states an *absence* and names the settings key that would end it; none states
a number. That distinction is the whole feature — the parent removed an invented
`200000` precisely because ADR 0028 result 3 records `1m tokens` as the default *on
Opus 5 (1M)*, model-conditional rather than harness-wide — so a task that closes its
gap by naming a plausible value has reintroduced the defect while appearing to fix
it. It is called out as the mutation on T2 and T4 for that reason.

**The probe's answer may be *no*, and T5 is written to land either way.** A negative
answer is the answer: the reader keeps printing `THRESHOLD=unknown` / `SOURCE=unknown`,
no branch is added, and the only code change is that its header comment stops telling
a future reader to run a probe that has been run. T5 therefore owes **no new sweep
case** — the existing `compact-threshold` block in `scripts/test-runstate.sh:3151`
already pins every branch by exact `THRESHOLD=`/`SOURCE=`/`APPLIED=` triple, including
the no-value branch, and re-running it unchanged is the assertion that the probe
changed no behaviour. **T5 strips only the plugin-default probe references.** The same header
comment documents the operator-over-repo precedence as UNVERIFIED and names two other
unprobed scopes; those remain deferred, and deleting them alongside would claim three
answers this feature did not buy.

**`gaffer-default` must still appear exactly once in each of the three files T4
touches.** `scripts/test-report-conventions.sh:271` counts it per file and
`:253`/`:257` assert it is absent from each skill's `compact-threshold` output block.
The new no-threshold clause therefore states the absence *without* restating the
enumerated `SOURCE` set — the condition is already written one paragraph above it in
both skills. That sweep is the only mechanical pin T4 has; the PRD declines a
two-file identical-clause pin of its own and names the reviewer as the gate, so do
not add one.

**Two prose surfaces have no sweep and must not grow one.** T1 and T6 are a decision
record and a standing instruction; their detector is a careful read, and each names
the concrete check below instead. Per this repository's rule the evidence stays in
`CLAUDE.md` and the ADR — no task adds it to an agent or skill prompt.

**Shared-file note, computed from every unchecked task's `files:` line in the four
other open plans.** Only T2 (`scripts/metrics.sh`, `scripts/test-metrics.sh`) is
touched by no other open plan and can land beside anything. The rest must stay
**sequential** with open work: `skills/metrics/SKILL.md` (T3) is claimed by
`loop-measurement`'s unchecked T15; `skills/run-loop/SKILL.md` (T4) by
`handoff-verification-contract`, `escalation-decider` and `loop-driver-run-gaps`;
`templates/report-templates.md` (T4) by `escalation-decider`; `scripts/runstate.sh`
(T5) by all three of those; `docs/adr/0028-loop-driver-mode.md` (T1, T5) by
`escalation-decider` and `loop-driver-run-gaps`; `CLAUDE.md` (T6) by all three. A
`[P]` marker here is judged within this plan only; the list above governs landing
beside another plan's open work. **This plan does not touch
`scripts/test-runstate.sh` at all**, which is the file those features contend on
hardest — T5's change is comment-only by design.

**Reflexivity.** `scripts/metrics.sh` is invoked per call, so T2 is live in the run
that lands it; `scripts/runstate.sh` likewise, though T5 changes no executable line.
`skills/*/SKILL.md` and `templates/*.md` are read at dispatch or at render, so the
run landing T3 or T4 is still driving under the old prose and the first kickoff under
T4 is the next `/gaffer:run-loop`. `CLAUDE.md` is standing instruction loaded at
session start, so T6 reaches the harness next session. The ADR is inert. No hook
registration changes here, so nothing needs a session boundary beyond that.

## Plan

- [x] **T1** **P1** Add a dated, open-probe section to `docs/adr/0028-loop-driver-mode.md` stating the one question result 3 left unrun — whether a plugin can supply a compaction-window default without overriding a value a repository or operator has set — enumerating the carrier(s) to try, **both** arms it must exercise (a plugin default with a repository or operator `autoCompactWindow` present, and a plugin default with neither set, since a default that only appears when nothing else is set is the entire claim), what reading counts as each answer, and the conditions every reading must be recorded under (harness version, model, and which settings scopes were populated — a model-conditional reading has already been mistaken for a harness-wide one here once); hand the section to the operator as a blocking question, since the probe needs live sessions an unattended packet cannot produce, and leave the existing result-3 text and its not-probed list unrevised. Prose only, no sweep case; checkable by reading the new section against result 3's not-probed list and confirming it answers exactly one item of it and presupposes neither answer.
  - deps: —
  - covers: The deferred probe is run, and its answer is recorded as a result
  - arch: —
  - files: docs/adr/0028-loop-driver-mode.md
- [x] **T2** **P1** Make the null-threshold branch of `scripts/metrics.sh show` (`:1808`) name the cause and the settings key `autoCompactWindow` that would supply a threshold — the key alone, naming no scope that can carry it and no precedence among them, both deferred — so a reader separates *nobody has set one here* from *this cannot be measured* without reading the source, leaving `driver_mode_context.threshold` null and `max_context` null with it, the two diagnostics counts on the line unchanged, and the threshold-present and no-usage-data branches byte-unchanged; `scripts/test-metrics.sh` updates its exact-string case at `:2086` to the new line and adds assertions that the rendering names that key and that the line carries no number other than the two diagnostics counts — ruling out a remedy clause that closes the gap by suggesting a value, which would reinstate in prose the invented default the parent deleted from the reader.
  - deps: —
  - covers: An unmeasured context metric says why, and what would make it real
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T3** [P] **P1** State in `skills/metrics/SKILL.md`'s main-session-context paragraph that the unmeasured line's remedy clause is relayed unparaphrased along with the rest of the line — never rewritten into an instruction to set a value, which is the operator's call and not this report's to open — extending the verbatim-relay rule already written there rather than adding a second rule beside it, and changing nothing about the two fields' null semantics or either consumer's record selection. Prose only, no sweep case; checkable by reading the relay sentence against the string `show` now renders and confirming an agent following it emits the remedy clause and no recommendation.
  - deps: T2
  - covers: An unmeasured context metric says why, and what would make it real
  - arch: —
  - files: skills/metrics/SKILL.md
- [x] **T4** **P2** Give `skills/run-loop/SKILL.md` §2 and `skills/resume/SKILL.md` one identical instruction for the no-value-in-effect path — state, in the same words, that no compaction threshold is in effect for the session and name the same settings key `autoCompactWindow`, where today both correctly state no number and therefore say nothing at all, which a reader takes for a measured run — keeping the parent's `SOURCE`-not-`APPLIED` condition and the `--threshold unknown` argument to `driver-mode enter` unchanged, so the wording and the measurement's null come from one reading of one reader; update `templates/report-templates.md` shape C's `▶ Session` annotation (`:341`) from omitting the element entirely to stating the absence in those same words, adding no `SOURCE` slot to the line and no field to the `enter` record. `scripts/test-report-conventions.sh` must pass unchanged — its per-file `gaffer-default` count of exactly one and its two output-block assertions rule out the obvious wrong fix, a clause that restates the enumerated `SOURCE` set beside the new wording; also checkable by reading the two instructions and the shape's annotation together, all three stating the absence and none stating a number.
  - deps: T2
  - covers: The kickoff distinguishes no threshold in effect from silence
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, templates/report-templates.md
- [x] **T5** **P1** Record the operator's probe answer in `docs/adr/0028-loop-driver-mode.md` beneath T1's section, dated and marked as an amendment with the conditions it was taken under and nothing above it revised, recording a negative answer as the answer rather than a failure to answer; then strip from `cmd_compact_threshold`'s two header-comment blocks in `scripts/runstate.sh` (`:238`, `:2163`) every reference to the plugin-default probe as outstanding — each clause instructing a future reader to probe whether a plugin default can coexist with a repository or operator value, leaving the UNVERIFIED operator-over-repo precedence note and the two still-deferred scopes stated as they are. No executable line changes and no new sweep case is owed: re-run `scripts/test-runstate.sh`'s `compact-threshold` block (`:3151`) unchanged — its exact `THRESHOLD=`/`SOURCE=`/`APPLIED=` triples, the no-value branch included, are what rules out the wrong implementation this task invites, a positive answer being closed by adding a value or a source branch to the reader when a threshold stays reportable only with a `SOURCE=` naming its provenance — and confirm the no-tools sweep still passes with `jq` and `python3` absent from `PATH`.
  - deps: T1
  - covers: The deferred probe is run, and its answer is recorded as a result
  - arch: —
  - files: docs/adr/0028-loop-driver-mode.md, scripts/runstate.sh
- [ ] **T6** [P] **P1** Amend the ADR 0028 bullet in `CLAUDE.md` where the harness reads it as standing instruction, stating the probe's recorded answer and that this repository measures driver-mode context only where `autoCompactWindow` is set, that the unmeasured rendering now names that key and the kickoff now states the absence, and that the remaining three items of result 3's not-probed list are still open — keeping the evidence here and adding none of it to an agent or skill prompt, and leaving the existing statement that the removed default was model-conditional intact rather than rewritten. Prose only, no sweep case; checkable by reading the amended bullet against the ADR amendment and the reader's header comment and confirming the three name one answer and no value.
  - deps: T2, T4, T5
  - covers: The deferred probe is run, and its answer is recorded as a result · An unmeasured context metric says why, and what would make it real
  - arch: —
  - files: CLAUDE.md
