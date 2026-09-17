---
spec-version: v2
feature: completion-record-drift-gaps
---

# Plan: completion-record-drift-gaps

The two corrections that change what the detector answers land first, each
followed by the sweep case that holds it honest: the inverting test before the
completion skip, because the skip decides *which* features reach the test and a
test that can invert should be sound before fewer inputs reach it. The two
remaining capabilities touch neither answer — one is prose at a reporting site,
one is a reading of two patterns — and sit last, in priority order.

**Nothing here changes the output contract.** The shapes are fixed by
`gspec/features/completion-record-drift/tasks.md` and stay exactly as they are:
`DRIFT=<slug>\t<capability text>`, `UNJUDGEABLE=<class>\t<slug>\t<detail>` over
the same three classes under the same names, and
`CAPABILITY_DRIFT=ok|attention drift=<n> unjudgeable=<n>` with its two separate
counts. No task adds a line kind, a class, a field, an exit code, a report
shape, a glyph or a tally figure. The completion skip removes *rows*; it never
renames or re-classes one.

**The inverting construct is REMOVED, not probed.** The test at issue is
`_capability_drift_for`'s `! printf '%s\n' "$bits" | grep -qx '0'` — a reader
that exits on its first match while its writer is still writing, evaluated under
the `set -euo pipefail` at the top of the same file, which reports the writer's
signal exit in place of the reader's success; the leading negation then turns
that into a `DRIFT=` line for a capability that has an unchecked covering task.
This is the same family as the `trim-note` flake, and its lesson binds here: a
probe that does not reproduce the phenomenon cannot eliminate a cause, so no
task is allowed to close this by failing to reproduce it. The defect is rare by
construction and a green sweep is weak evidence either way — the detector for
the change is a reading of the construct. **Which construct replaces it is left
open** (the PRD's second deferred decision: here-string, a pattern test over the
joined values, or an accumulator carried through the enumeration — all three
remove it). The invariant T1 owes is the one stated: no pipeline in that test
whose reader may exit before its writer, and every judgement the test makes
correctly today unchanged.

**The completion skip reuses the derivation, and is justified by the property
alone.** It belongs in `cmd_capability_drift`'s own walk — `_feature_done` on
the **resolved** PRD (the same `prdabs` `_capability_drift_for` is handed, so a
feature present in two layouts is judged on the file actually scanned), skipped
before the per-feature scan is called. Not a second test of completeness: this
adapter's own history is the argument for never writing a fourth copy of a
pattern, and completion is derived in exactly one place. The justification is
that a checked box is the reconciled state and the scan's question — *should
this box be checked* — is answered for every capability there; **never** the
number of rows it happens to remove in any one repository. No drift finding is
lost, because the drift condition is reachable only from an unchecked
capability, and a feature with an unchecked capability does not read as
complete. A PRD with no recognized capability line reads as **not** complete
(zero checkboxes is not completion) and is still scanned — which is what stops
the skip being read as *skip features whose plan carries shorthand `covers:`
labels*.

**The anchoring divergence is closed by DOCUMENTATION, and that choice is made
here.** `_CAPABILITY_LINE_RE` admits leading whitespace; `_prd_capability`'s awk
anchors at `^-`. The PRD allows either close and requires the alignment, if
taken, to widen the stricter pattern and be judged against both its callers. It
fails that test: `_prd_capability` does not merely *recognize* a capability
line, it extracts the sub-bullet block beneath it by an indentation rule — the
block ends at the first line that is neither blank nor indented — and that rule
is what `cmd_handoff` uses to tell a packet what "done" means. Widen the anchor
and an indented capability's block boundary becomes the surrounding list's
indentation, so handoff would reproduce sibling bullets as acceptance criteria.
A wrong criteria block is worse than a declined quote, so the divergence stands
and is recorded at both sites. **No pattern changes, so the PRD's fourth
criterion owes no sweep case** — but its second criterion states a behaviour the
sweep *can* reach (an indented capability line yields `uncovered-capability`
plus one `unmatched-quote` per covering task, never drift), and a comment making
a behaviour claim that nothing checks is how the claim drifts. T6 pins that
claim with one fixture. That is not a pattern change and is not the case
criterion four describes.

**DETECT, NEVER FLIP, unchanged.** The adapter's write surface stays the single
task-checkbox flip in `cmd_check_task`. Nothing here opens a file for writing,
and the parent's checksum case — a `cksum` manifest of every PRD and plan file
taken before `capability-drift` and compared byte-identical after, in both
layouts — must stay green after every task. It is the mechanical gate on the
last success metric and no task may weaken or re-scope it.

**T5 is prose only and the reviewer is its gate.** `skills/run-loop/SKILL.md` is
read at dispatch; the adapter's sweep cannot reach it, and a case asserting a
string is present in a prose file pins the wording rather than the rule. T5
names the concrete read a reviewer performs instead of any such assertion.

**File contention, and why only three tasks are `[P]`.**
`scripts/gspec-backlog.sh` is touched by T1, T3 and T6;
`scripts/test-gspec-backlog.sh` by T2, T4 and T6; `skills/run-loop/SKILL.md` by
T5 alone. **T2** (sweep), **T3** (script) and **T5** (skill) hold file sets
disjoint from each other and from every other `[P]` task, so they alone carry
the marker. T4 collides with T2, and T6 collides with both T2 and T3, so neither
takes it. T2 carrying `deps: T1` is no bar — T1 is earlier in the plan order.

**`gspec-adapter-consistency` must not be in flight against this.** It refactors
this adapter's shared pattern blocks and adds cases to this same sweep. There is
no logical dependency in either direction and no ordering is implied — but T1,
T2, T3, T4 and T6 edit exactly those two files, and T6 edits the pattern blocks
that refactor moves.

**Reflexivity.** `scripts/gspec-backlog.sh` takes effect mid-run, in the run
that edits it, so every later task can call what T1 and T3 landed.
`skills/run-loop/SKILL.md` is read at dispatch, so the run that lands T5 is
still driving under the old prose: the first run under the corrected
termination site is the next `/gaffer:run-loop`. No hook registration changes,
so no session boundary is owed.

`scripts/test-gspec-backlog.sh` must pass green after every task.

## Plan

- [x] **T1** **P0** Replace `_capability_drift_for`'s all-covering-tasks-checked test in `scripts/gspec-backlog.sh` — today the negated pipeline `! printf '%s\n' "$bits" | grep -qx '0'` — with a construct carrying no pipeline whose reader may exit before its writer has finished, so that under the `set -euo pipefail` earlier in the same file a writer's signal exit can never be reported in place of the reader's success and negated into a `DRIFT=` line for a capability that has an unchecked covering task, removing the construct rather than probing it (a probe that does not reproduce the failure eliminates nothing), and scanning the rest of the function and `cmd_capability_drift` for any second reader-closes-early pipeline in the same direction; every other judgement is unchanged — for every input the test judges correctly today the same three unjudgeable classes, the same per-capability `DRIFT=` lines and the same `CAPABILITY_DRIFT=` counted summary, still opening no file for writing and still exiting 0 on every path.
  - deps: —
  - covers: The drift test cannot invert into a report of drift it did not find
  - arch: —
  - files: scripts/gspec-backlog.sh
- [ ] **T2** [P] **P0** Add a case to `scripts/test-gspec-backlog.sh`, in both layouts the sweep already builds (`mk_prd`/`mk_plan` and `mk_prd_v2`/`mk_plan_v2`), over a fixture feature carrying one capability covered by **both** a checked and an unchecked task and a second capability whose covering tasks are all checked, asserting the first absent by name from every `DRIFT=` line **and** the second present in the same run, so the case cannot pass by the detector reporting nothing at all, and asserting the run's `CAPABILITY_DRIFT=` summary counts one drift and no unjudgeable row for either capability.
  - deps: T1
  - covers: The drift test cannot invert into a report of drift it did not find
  - arch: —
  - files: scripts/test-gspec-backlog.sh
- [ ] **T3** [P] **P1** Skip a feature that reads as complete in `cmd_capability_drift`'s walk in `scripts/gspec-backlog.sh`, by calling the existing `_feature_done` on the **resolved** PRD path the scan would otherwise hand `_capability_drift_for` — no second test of completeness and no fourth copy of the capability pattern — so a feature with at least one recognized capability line and every one of them checked emits no `DRIFT=` line and no `UNJUDGEABLE=` line of any class and raises neither summary count, while every other feature is scanned exactly as before with its `unmatched-quote` rows intact, including one with an unchecked capability and one whose PRD offers no recognized capability line at all (which the derivation reads as **not** complete, absence of evidence never being completion); plan-side resolution, the no-plan out-of-scope rule and the no-`gspec/` path are untouched, and the skip's justification carried in the code comment is that property alone, never a count of rows removed in any repository.
  - deps: T1
  - covers: A feature that reads as complete contributes nothing to the scan
  - arch: —
  - files: scripts/gspec-backlog.sh
- [ ] **T4** **P1** Add the completion-skip cases to `scripts/test-gspec-backlog.sh` in both layouts the sweep already builds: a fully-checked feature whose plan carries an unmatchable `covers:` quote yields no line of any kind and does not raise the summary's `unjudgeable` count, and the **same** fixture yields that `unmatched-quote` row again in each of two variations — one capability unchecked, and capability lines rewritten into a form the derivation does not recognize at all — so the skip is pinned to the derivation rather than to the shorthand `covers:` labels that motivated it, with each case asserting both the expected row's presence or absence by class and feature name and the summary count that goes with it.
  - deps: T3
  - covers: A feature that reads as complete contributes nothing to the scan
  - arch: —
  - files: scripts/test-gspec-backlog.sh
- [ ] **T5** [P] **P1** State the line form at the termination reporting site in `skills/run-loop/SKILL.md` §4 — the backlog-complete path that re-runs the same `capability-drift` invocation §1 states — so that each `DRIFT=` line is carried into the stop report's `▶ Next` section as an **unglyphed** line, explicitly not reusing ⚠️ (the conventions reserve that glyph for a tally-counted section carrying one line per packet, and a drift finding is not a packet) and introducing no new glyph, while §1's preflight ⚠️ line is left exactly as it stands so the two sites differ by explicit statement rather than by one of them saying nothing, and nothing else at either site moves: no tally figure, packet count or recorded outcome, and no template gains a slot, glyph or shape; prose only, no sweep case, checkable by reading the two sites against `templates/report-conventions.md` and shape B in `templates/report-templates.md` for whether the stop report's glyph vocabulary gains anything, whether `▶ Next` is still the one section the tally does not count, and whether each site now names its own line form.
  - deps: —
  - covers: The termination reporting site states a line form that does not collide
  - arch: —
  - files: skills/run-loop/SKILL.md
- [ ] **T6** **P2** Record the anchoring divergence between `_CAPABILITY_LINE_RE` (which admits leading whitespace) and `_prd_capability`'s `^-`-anchored matcher at **both** pattern sites in `scripts/gspec-backlog.sh`, each comment naming the other pattern, the indented-line behaviour and the safe direction — an indented but otherwise canonical capability line is enumerated by the pattern completion derivation reads and declined by the verbatim quote matcher, so it yields `uncovered-capability` plus one `unmatched-quote` per covering task and never a `DRIFT=` line — and naming why the divergence stands rather than being aligned: widening the stricter pattern would move the indentation-based block boundary `_prd_capability` uses to extract a capability's acceptance criteria, which `cmd_handoff` reads to tell a packet what done means, so a widening judged against that second caller trades a declined quote for a wrong criteria block; neither pattern changes, and add one case to `scripts/test-gspec-backlog.sh` over an indented capability line asserting exactly that behaviour in both variations — covering tasks all checked, and one unchecked — namely `uncovered-capability` plus one `unmatched-quote` per covering task and no `DRIFT=` line either way, the PRD's exception branch being unreachable while the anchors diverge.
  - deps: T1
  - covers: The two capability-line patterns' anchoring divergence is resolved or recorded
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
