---
spec-version: v2
feature: loop-prose-consistency
---

# Plan: loop-prose-consistency

Five prose corrections, ordered by what a wrong statement costs while it stands. The
two output-contract comments go first: they are the only site a driver *branches on*
— it reads the block as the set of `SOURCE` values to handle, so a removed value buys
a dead branch every run. The stop report's section order is next, because every stop
report renders wrong until it lands and it is the one correction with a two-sided
authority to pin it against. Then the worked hand-off outcome (wrong glyph for the
commonest case in its shape), then the rotting count, then the continuation wording,
which costs a driver one misread on re-entry and is the only P2 here.

**Every site is located by content, never by line number** — the PRD makes this an
explicit assumption and this repository's prose moves. The anchors are: the
`runstate.sh compact-threshold` comment line itself; the `211 files and about 30,000
insertions` sentence in §4 Termination; shape B's `⬚ **Queued**` / `🔀 **Decisions**`
headings and the sentence ending `in that order`; shape A's `decision txn-t4
hand-off-feature` worked example; and each skill's `record-start <cursor> --continue`
clause.

**The emitter is settled and is not touched.** `cmd_compact_threshold` in
`scripts/runstate.sh` emits exactly `repo`, `operator` and `unknown`; its own usage
header already states that set verbatim, and `gaffer-default` was removed by the
parent feature's T6. Nothing here changes script behaviour, adds a field, adds a
report shape or adds an outcome state.

**Three rule-prose clauses deliberately name both `gaffer-default` and `unknown` and
must survive byte-unchanged** — one in each loop skill ("the enumerated set naming no
value in effect") and one in `templates/report-templates.md`'s shape C note
("neither is a value the harness enforces"). Naming both is what made the suppression
real across the interval between the two packets that landed it. Tidying any of them
is a regression, and T1's sweep case exists to make that tidy fail.

**Both sweep cases land in `scripts/test-report-conventions.sh`, and that is a
decision.** That file already owns `templates/report-templates.md` as `$SHAPES` and
`templates/report-conventions.md` as `$CONV`, and it already reaches outside its own
file set to bind a document to another file (`$DIGEST_SRC` for the outcome enum,
`$ADR23` for the amendment order) — which is exactly the shape both cases need. The
alternative, `scripts/test-runstate.sh`, owns the emitter's *behaviour*; what is
pinned here is agreement between documents and an emitter, which is this sweep's job.
Both cases follow the file's existing `sed -n '/anchor/,/anchor/p'` range-anchoring
with a non-empty guard, for the reason the comment above its `enum_blob` case already
gives: this repository has twice shipped assertions that passed while checking
nothing, and an assertion scoped to a whole file would pass for the wrong reason here
too.

**One thing the implementer should check rather than assume in T2.** The shape B notes
list already carries the `🔀` decision-block note *above* the `⬚ Queued` collapse
note, so after the reorder it may already read in section order with nothing moved.
The task's requirement is the end state — the notes describing sections read in the
corrected section order — not a move for its own sake. Shape B's first worked example
(the dedup one) states ordering only as counts and names `txn-t4` as `rolled-back`
already, so it needs no edit from T2 and is what T3 makes shape A agree with.

**Accepted consequence of the reorder, stated once here and in T2:** the decisions
section stops sitting immediately above `▶ Next`. The conventions document's fixed
tally order is chosen over that adjacency, deliberately, and the conventions document
is untouched — the shape is corrected to the authority, never the authority to the
shape.

**The parent feature's completed record is out of bounds for T4.**
`gspec/features/thin-loop-driver-gaps/` carries the superseded counts in checked task
lines and checked capability blocks; the immutability floor refuses edits there and is
right to. A hook rejection is the signal that the edit reached a completed record,
never a cue to bypass it. Its plan's free prose preamble also names a superseded
run-scope count, outside any checked block and so reachable — it is deliberately left
alone: it is that plan's record of its own reasoning, not an instruction anything
obeys, and the PRD's scope names only the loop-skill worked example.

**Three of the five tasks ship with no sweep case** — T3, T4 and T5. That is the PRD's
own recorded decision, not an omission: the only pin available for one of the three
expires the moment the string it asserts absent is removed, and the other two are
declined to hold this feature to two cases. For those three the reviewer is the only
gate, so each names the concrete read a reviewer performs instead.

**File contention, and why only two tasks are `[P]`.**
`skills/run-loop/SKILL.md` is touched by T1, T4 and T5; `skills/resume/SKILL.md` by T1
and T5; `templates/report-templates.md` by T2 and T3;
`scripts/test-report-conventions.sh` by T1 and T2. Only **T2** and **T4** hold file
sets disjoint from each other and from every other `[P]` task, so they alone carry the
marker. Everything else is sequential. A task carrying `deps: —` means it has no
logical prerequisite, not that it may run beside its neighbours.

**Reflexivity.** Nothing here takes effect mid-run. `skills/*/SKILL.md` is read at
dispatch and `templates/*.md` at render, so the run that lands these corrections is
still driving under the old prose; the first run under them is the next
`/gaffer:run-loop`. No script behaviour and no hook registration changes, so no
session boundary is needed and no `session_boundary` declaration is owed.

`scripts/test-report-conventions.sh` must pass green after every task.

## Plan

- [ ] **T1** **P1** Correct the two output-contract code-block comments — the `runstate.sh compact-threshold` line in `skills/run-loop/SKILL.md` and the identical line in `skills/resume/SKILL.md`, each found by that command and its `SOURCE=` enumeration rather than by line number — so each names `repo|operator|unknown`, the three values `cmd_compact_threshold` now emits, leaving the three rule-prose clauses that deliberately name both `gaffer-default` and `unknown` byte-unchanged in both skills and in `templates/report-templates.md`; `scripts/test-report-conventions.sh` gains a case asserting `gaffer-default` appears across those three files exactly three times, once per file and each inside its rule-prose clause, and never inside a `compact-threshold` output block, with the two skills' extracted `compact-threshold` blocks guarded non-empty so a moved or renamed anchor fails rather than silently checking nothing.
  - deps: —
  - covers: The output-contract comments reproduce the output the script emits
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, scripts/test-report-conventions.sh
- [ ] **T2** [P] **P1** Reorder stop report shape B in `templates/report-templates.md` to the tally order `templates/report-conventions.md` fixes — `🔀 Decisions` above `⬚ Queued` — in the shape's own rendered body, in the sentence that enumerates the order in the same breath as its table-of-contents claim, and in the five-packet worked example (shape B's dedup example states ordering only as counts and is not edited), so the ordered notes describing those sections read in the corrected order and the conventions document is untouched, accepting that the decisions section no longer sits immediately above `▶ Next`; `scripts/test-report-conventions.sh` gains a case deriving the expected glyph sequence from `$CONV`'s fixed tally line and asserting shape B's section headings appear in that sequence, so a shape internally consistent but diverged from the authority fails.
  - deps: —
  - covers: The stop report's section order matches its declared authority
  - arch: —
  - files: templates/report-templates.md, scripts/test-report-conventions.sh
- [ ] **T3** **P1** Correct shape A's worked hand-off in `templates/report-templates.md` so the handed-off packet carries `rolled-back` — the outcome a `hand-off-feature` actually records, since `runstate.sh route` maps that decision to `discard-advance` and `skills/run-loop/SKILL.md` §3.5 records a discard-advance as `rolled-back` — and therefore renders `⛔` per the shape's own outcome-to-glyph table, agreeing with shape B's dedup example which already reads `rolled-back`, while the glyph table, the two-lines-per-handed-off-packet rule and the routing stay unchanged; prose only, no sweep case, checkable by reading the example's outcome value through the shape's own table.
  - deps: —
  - covers: The worked hand-off shows the outcome a hand-off records
  - arch: —
  - files: templates/report-templates.md
- [ ] **T4** [P] **P1** Remove the run-scope count from `skills/run-loop/SKILL.md` §4 Termination — the clause stating how many files that run actually landed — while keeping the 211-files and ~30,000-insertions branch-vs-base figure, which its sentence already attributes to the moment it was measured, and keeping the branch-versus-base-against-run-scope contrast the sentence exists to make, editing nothing in `gspec/features/thin-loop-driver-gaps/` where the superseded counts sit in a completed record; prose only, no sweep case, checkable by reading the corrected sentence for any count of a run's own integrated work.
  - deps: —
  - covers: The worked example states no count that rots
  - arch: —
  - files: skills/run-loop/SKILL.md
- [ ] **T5** **P2** Word the continuation trigger as the situation in both entry points (the resume clause is in scope because the capability's third criterion requires both to read as the situation rather than a status list) — `skills/run-loop/SKILL.md` §3.3's `record-start <cursor> --continue` clause, narrowed today to a pause-interrupted packet, and `skills/resume/SKILL.md`'s, which lists `paused` **or** `blocked` — so each reads as *this session is about to continue the cursor packet*, the phrasing run-loop §3.2 already uses for the adjacent `--paused-cursor` sweep rule, admitting every status the shipped rule does without naming a list a later status could fall outside, and leaving the sweep rule itself unchanged in both files; prose only, no sweep case, checkable by reading each trigger clause for situation phrasing with no status list, then diffing the two.
  - deps: —
  - covers: One continuation rule, worded the same in both entry points
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md
