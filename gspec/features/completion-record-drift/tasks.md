---
spec-version: v2
feature: completion-record-drift
---

# Plan: completion-record-drift

The detector lands first and alone, because everything else in this plan either
tests it or calls it. Then the two sweep tasks that hold it honest, then the two
reporting sites in plan order: preflight before termination, since both are prose
in `skills/run-loop/SKILL.md` and the termination site's whole content is *the
same command §1 already runs*.

**The detector is a NEW read-only subcommand, `capability-drift`, not an extension
of an existing one.** The report is per **capability** across **every** resolvable
feature, and no existing subcommand has that cardinality: `features` and `plans`
are one row per feature and per plan, with column-index-stable TSV contracts
`migrate.sh` and the loop already parse positionally (the `deferred` column is
documented as appended LAST for exactly that reason), `next` answers about one
feature, `handoff`/`check-task`/`task-status` about one packet. Hanging a
per-capability answer off any of them means either a second row shape inside one
command's output or a flag that changes what its columns mean — both are how a
parsed contract breaks silently. A subcommand also makes P1's "one implementation"
structural rather than a promise: the two reporting sites run the same string.

**Nothing new is parsed, and that is the acceptance test for the diff.** The scan
is a join over things the adapter already computes: `_prd_paths`/`_plan_paths` and
`_resolve_prd_path`/`_resolve_plan_path` decide the scanned set, `_feature_done`'s
capability pattern enumerates capability lines with their checkbox state,
`_TASK_LINE_RE` enumerates task lines with theirs, `_split_covers` splits the
`covers:` value, and `_prd_capability` decides — verbatim, unguessed — whether a
quote is a capability. A fourth copy of any of those patterns is a defect here, not
a shortcut: this file's own history is the argument (`_plan_task_line_count` and
`_task_lookup` disagreeing).

**Output contract, fixed here so all five tasks agree on it.** Line-oriented, the
adapter's house style, exit 0 on every path:

```
DRIFT=<slug>\t<capability text>
UNJUDGEABLE=<class>\t<slug>\t<detail>        class: unmatched-quote |
                                             uncovered-capability |
                                             unrecognized-capability
CAPABILITY_DRIFT=ok|attention drift=<n> unjudgeable=<n>
```

with `CAPABILITY_DRIFT=none` plus an explanatory `NOTE=` line and exit 0 when there
is no `gspec/` — the same `<KEY>=none` plus an explanatory line shape `check-task`
(`CHECKED=none`/`REASON=`) and `files-status` (`FILES=none`/`NOTE=`) already use.
The two counts are separate fields on purpose: a single zero that could mean either
*nothing drifted* or *nothing could be judged* is the failure this whole feature
exists to close.

**The judgement is asked only of an UNCHECKED capability.** A checked box is the
reconciled state — the question the scan asks, *should this box be checked?*, is
already answered there, so a checked capability is neither drift nor unjudgeable
and emits no line. This follows the criteria's own reasoning rather than narrowing
them: the drift condition is stated over an unchecked box, and the two per-capability
unjudgeable classes exist to keep a capability the scan cannot judge from reading as
either answer. `unmatched-quote` is the exception and stays per **task**, because a
quote matching nothing is evidence about the task, not about any one capability.

**Report volume stays as the PRD deferred it.** Every `DRIFT=` line names feature
and capability, per capability, never a count alone. The unjudgeable side is
reported to the human as a **figure** with the classes named, not as one line per
capability — a plan whose task lines predate `covers:` yields one unjudgeable per
capability, and a kickoff is not the place for that list; the command's own output
carries it for whoever wants it. Whether such a feature should collapse to one line
is the PRD's second deferred decision and is not settled here: the command's
line-level output is per capability so either shape stays derivable, and the
human-facing volume question is what stays open.

**DETECT, NEVER FLIP.** The adapter's write surface stays exactly one task-checkbox
flip in `cmd_check_task`. `capability-drift` opens no file for writing, and T3 pins
that mechanically rather than by review, because an auto-flip is the silent failure
a reviewer reading for intent does not catch.

**Neither reporting site adds a shape, a glyph or a tally figure, and no template
is edited.** The precedent is the trailer-versus-task drift scan this one sits
beside: §1 tells the driver to say it in the kickoff, and
`templates/report-templates.md` carries no slot for it. In the kickoff a ⚠️ line is
already an uncounted line (shape C's header tallies packets and phases only, and
`⚠️ Assuming` sits under it). In the stop report it must NOT become a
`⚠️ Unfinished` line: that section's glyph is tallied per **packet**, and a drift
finding is not a packet — so it lands in `▶ Next`, which the shapes file names as
the one section the tally does not count, and which is where "flip this box and the
feature behind it unblocks" honestly belongs.

**Two things here are prose only, and the reviewer is their gate.** P0-3's second
criterion (the rule holds at any entry point that states a preflight drift scan)
and the whole of P1 are statements in a file the loop reads at dispatch; the
adapter's sweep cannot reach them, and a case asserting a string is present in a
prose file is the wrong answer — it pins the wording, not the rule. T4 and T5 each
name the concrete read a reviewer performs instead.

**`skills/resume/SKILL.md` is deliberately untouched.** Resume's §1 preflight states
`check` and `interlock` only, not the trailer-versus-task drift scan, so it is not an
entry point that states a preflight drift scan; its `same as /gaffer:run-loop §1` line
restates those two checks inline rather than importing §1's bullets. The PRD defers a
scan there, and a resumed run still reaches the termination site T5 adds.

**File contention, and why only two tasks are `[P]`.**
`scripts/gspec-backlog.sh` is touched by T1 alone; `scripts/test-gspec-backlog.sh`
by T1, T2 and T3; `skills/run-loop/SKILL.md` by T4 and T5. Only **T2** (sweep) and
**T4** (skill) hold file sets disjoint from each other and from every other `[P]`
task, so they alone carry the marker. A task carrying `deps: T1` is not thereby
barred from `[P]` — T1 is earlier in the plan order — but T3 collides with T2 and
T5 with T4, so neither takes it.

**`gspec-adapter-consistency` must not be in flight against this.** It refactors
this adapter's shared task-line pattern blocks and adds cases to this same sweep.
There is no logical dependency in either direction, and no ordering is implied —
but T1, T2 and T3 edit exactly those two files.

**Reflexivity.** `scripts/gspec-backlog.sh` takes effect mid-run, in the run that
edits it, so T2–T5 can call the detector T1 landed. `skills/run-loop/SKILL.md` is
read at dispatch, so the run that lands T4 and T5 is still driving under the old
prose: the first run under either reporting site is the next `/gaffer:run-loop`.
No hook registration changes, so no session boundary is owed.

`scripts/test-gspec-backlog.sh` must pass green after every task.

## Plan

- [x] **T1** **P0** Add a read-only `capability-drift` subcommand to `scripts/gspec-backlog.sh` that walks every feature whose PRD **and** plan both resolve (a feature with no plan is out of scope, not unjudgeable), joins each unchecked capability to the `covers:` quotes of that plan's task lines, and prints one `DRIFT=` line naming feature and capability for each capability whose covering tasks are **all checked**, one `UNJUDGEABLE=` line naming its class, the feature, and the offending quote or capability — classed `unmatched-quote` / `uncovered-capability` / `unrecognized-capability` — for each quote matching no capability, each unchecked capability no task covers, and each unchecked capability line the verbatim matcher declines, and a trailing `CAPABILITY_DRIFT=` summary carrying the drift and unjudgeable counts as separate named fields — built entirely from `_prd_paths`/`_plan_paths`, `_resolve_prd_path`/`_resolve_plan_path`, `_feature_done`'s capability pattern (extracting that pattern to a shared constant without changing `_feature_done`'s result for any PRD), `_TASK_LINE_RE`, `_split_covers` and `_prd_capability` with no new parser and no fourth copy of an existing pattern, opening no file for writing, and exiting 0 on every path including `CAPABILITY_DRIFT=none` where there is no `gspec/`; `scripts/test-gspec-backlog.sh` gains the fixture feature carrying two capabilities — one whose covering tasks are all checked, one with an unchecked covering task — asserting the first named present and the second absent by name in the flat layout (`mk_prd`/`mk_plan`), plus the no-`gspec/` exit-0 case — T2 carries the same fixture in the feature-folder layout.
  - deps: —
  - covers: The drift test is per capability, across every feature with a resolvable PRD and plan · Anything the test cannot judge is reported as unjudgeable, never as drift · Every judgement has a case in `scripts/test-gspec-backlog.sh`, and none passes vacuously
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
- [x] **T2** [P] **P0** Add the three unjudgeable cases to `scripts/test-gspec-backlog.sh` — a task whose `covers:` quote matches no capability, a capability no task covers, and a legacy `**P0 — text**` capability line appended to a builder-written PRD which `_feature_done` counts and `_prd_capability` declines — each asserting **both** halves, the expected `UNJUDGEABLE=` line present with its class and feature name *and* that feature absent from every `DRIFT=` line, since either half alone passes for the wrong reason, and each built with `mk_prd`/`mk_plan` and `mk_prd_v2`/`mk_plan_v2` so a detector that reads only the feature-folder layout fails rather than passing on the newer one alone; additionally run T1's two-capability drift fixture in the feature-folder layout (`mk_prd_v2`/`mk_plan_v2`), so every case in this feature is exercised in both layouts the sweep already builds for.
  - deps: T1
  - covers: Every judgement has a case in `scripts/test-gspec-backlog.sh`, and none passes vacuously · Anything the test cannot judge is reported as unjudgeable, never as drift
  - arch: —
  - files: scripts/test-gspec-backlog.sh
- [x] **T3** **P0** Pin detect-never-flip in `scripts/test-gspec-backlog.sh` with a case that builds a drifted fixture in both layouts, takes a `cksum` manifest of every PRD and plan file under its `gspec/` before running `capability-drift`, and asserts the manifest is byte-identical afterwards, so the constraint is held mechanically rather than by a reviewer reading for intent — and assert alongside it that the run still reported the drift it was given, so the case cannot pass by the detector doing nothing at all.
  - deps: T1
  - covers: Every judgement has a case in `scripts/test-gspec-backlog.sh`, and none passes vacuously
  - arch: —
  - files: scripts/test-gspec-backlog.sh
- [ ] **T4** [P] **P0** Add a preflight bullet to `skills/run-loop/SKILL.md` §1, beside the existing `Drifted completion record` trailer-versus-task bullet and found by that bullet's content rather than by line number, instructing the driver to run `${CLAUDE_PLUGIN_ROOT}/scripts/gspec-backlog.sh capability-drift`, name each `DRIFT=` line's feature and capability in the kickoff as a ⚠️ line and state the unjudgeable count separately as a figure with its classes named, flip nothing, halt nothing and never treat any exit as a stop — on the same authority as the scan beside it, skipped in silence with no `gspec/` directory, and worded over any entry point that states a preflight drift scan rather than this one alone; prose only, no sweep case, checkable by reading the bullet for a flip, a halt or a stop condition, for a rule written to a single site, and for whether `skills/resume/SKILL.md`'s `same as /gaffer:run-loop §1` parity claim is still accurate once the bullet is added.
  - deps: T1
  - covers: Preflight reports drift on every run, and blocks none
  - arch: —
  - files: skills/run-loop/SKILL.md
- [ ] **T5** **P1** Add the second reporting site to `skills/run-loop/SKILL.md` §4's backlog-complete path, after the decider-branch accounting and before the stop report is rendered, running the **same** `gspec-backlog.sh capability-drift` invocation §1 states and naming it as the same one rather than restating the rule, so a capability whose last covering task landed in this run is named by this run; each `DRIFT=` line is carried into the stop report's `▶ Next` section — the one section the tally does not count — so no tally figure, packet count or outcome changes, nothing is flipped and a drifted record never alters why the run stopped; prose only, no sweep case, checkable by reading the two sites for one command and one rule and confirming no ⚠️/⛔/✅ tally bucket gains a non-packet line.
  - deps: T4
  - covers: The run that drifts the record reports it before it stops
  - arch: —
  - files: skills/run-loop/SKILL.md
