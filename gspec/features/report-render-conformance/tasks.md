---
spec-version: v2
feature: report-render-conformance
---

# Plan: report-render-conformance

**The two scripts land first, side by side. The prose follows, and each prose task calls what they shipped.** T1 adds the counted figures to the deterministic core. T2 adds the lint as a new script. The two share no file and need nothing from each other. T3 rewrites shape B's tally sentence to name T1's output, so it depends on T1. T4 and T5 are the rendering sites. They call both scripts, so they come after all three.

**The figures are a separate subcommand, `runstate.sh run-tally <run-state>`, not a fifth digest line kind.** This settles the PRD's first deferred decision, based on reading every `run-digest` caller:
- Shape A reads `run-digest --since` on every packet in `skills/run-loop/SKILL.md` §3, and has no tally.
- `skills/run-loop/SKILL.md` §4's whole-branch review reads the digest's packet ids.
- Shape B is read in `skills/run-loop/SKILL.md` §4, `skills/pause/SKILL.md` §4 and `skills/resume/SKILL.md` §3.
- Shape C is read in `skills/run-loop/SKILL.md` §2 and `skills/resume/SKILL.md` §4.
- `scripts/test-runstate.sh` asserts every digest line starts with one of the four kinds.

A fifth kind would ride into every per-packet read that has no use for it. A count printed next to `--since`-scoped `decision` lines would also be ambiguous: the dedup rule needs the whole run's decisions. `run-tally` pipes `cmd_run_digest` over the whole run (no `--since`) into one counting pass. It prints `SHIPPED=`, `FAILED=`, `UNFINISHED=` and `DECISIONS=` in the fixed tally order. It dies exactly where `run-digest` dies. `cmd_run_digest`, its output and the "no summary counts" comment are left alone, so the four existing line kinds cannot move.

**The lint is its own script, `scripts/report-lint.sh --shape <B|C> <report-file> <digest-file>`.** This settles the second deferred decision:
- It reads `templates/report-conventions.md`. `runstate.sh` reads no template.
- The PRD puts its cases in `scripts/test-report-conventions.sh`.
- A script that contains no run-state writer makes "a finding changes nothing" a structural property rather than a promise.

The caller passes the shape; the lint never infers it. That is how the lint classifies nothing.

Output is:
- `REPORT_LINT=clean`, or
- `REPORT_LINT=findings n=<k>` followed by one `FINDING=<rule>\t<line>\t<detail>` per finding, or
- `REPORT_LINT=unjudged` with a `REASON=`.

Exit status is 0 on every path, usage errors included.

**The lint runs at shapes B and C, never at shape A.** This settles the third deferred decision:
- Four of the six rules check the tally and the sections, and only B and C carry them.
- Linting needs the rendered report written to a file first, which puts its bytes in the driver's context twice. Doing that at every shape-A line would grow with packet count.
- One lint per stop report and one per kickoff is a bounded cost.

The report and the digest it was rendered from are written as literal paths under `.agents/loop/<run_id>/`. That directory is inside `.agents/`, so driver mode allows the write, and it is gitignored. A path given as an unexpanded variable would be refused. The lint runs before the report is emitted. The driver may correct the lines a finding names once, then emits. It never re-lints in a loop, and a finding changes nothing else.

**Every script task names its sweep case.** T1 names `scripts/test-runstate.sh`. T2 and T3 name `scripts/test-report-conventions.sh`. T4 and T5 are prose that is read at dispatch, which no sweep can reach, so each names the read a reviewer performs instead.

**File contention, and why all five tasks are `[P]`.**
- `scripts/runstate.sh` and `scripts/test-runstate.sh` are T1's alone.
- `scripts/report-lint.sh` and `README.md` are T2's alone.
- `templates/report-templates.md` is T3's alone.
- `scripts/test-report-conventions.sh` is edited by T2 and T3.
- `skills/run-loop/SKILL.md` and `agents/loop-driver.md` are T4's alone.
- `skills/pause/SKILL.md` and `skills/resume/SKILL.md` are T5's alone.

T1 and T2 have no deps and disjoint files. T3 depends on T1, so it sits in the next wave, and it shares its sweep with T2 across waves, never within one. T4 and T5 are each alone in their wave. Every dep points strictly backwards.

**`next-state-reporting-integrity` edits `scripts/runstate.sh` and `scripts/test-runstate.sh` too.** All its tasks are checked, so nothing is in flight against T1. T1's new code must still pass the pipe-fed `grep -q` guard that feature's T4 added to `scripts/test-runstate.sh`.

**Reflexivity.** `scripts/*.sh` take effect mid-run. `skills/*/SKILL.md` and `agents/loop-driver.md` are read when invoked or after compaction, so the run that lands T4 and T5 still renders under the old prose. The next `/gaffer:run-loop` is the first run to lint. No task touches `hooks/hooks.json`, a settings file, or any agent's or skill's frontmatter, so no packet here owes a session boundary.

Every regression sweep must pass green after every task.

## Plan

- [x] **T1** [P] **P0** Add `run-tally <run-state>` to `scripts/runstate.sh`, with the output contract and dedup rule stated above, and register it in the header Subcommands list and the dispatch table. Count only from `cmd_run_digest`'s own lines for the whole run:
  - ✅ one per `packet` line reading `green`;
  - ⚠️ aggregating `blocked`, `interrupted`, `abandoned`, `open` and `paused`;
  - ⛔ for `failed` and `rolled-back`;
  - 🔀 one per `handoff-feature` line, plus one per `decision` line whose token is `ask-operator` or `hand-off-feature`, except one whose id already carries a `handoff-feature` line.

  Emit no queued figure. Leave `cmd_run_digest`, its header comment and its output untouched. Write no condition as a pipe-fed `grep -q`, which the file's existing guard case would flag. Add cases to `scripts/test-runstate.sh`, built on the existing `run-digest` fixture:
  - a run carrying every outcome the digest can emit asserts each figure;
  - a handed-off packet plus an `ask-operator` question in one run asserts `DECISIONS=2`, not 3;
  - the fixture's four existing line kinds match their pre-change output byte-for-byte after sorting, captured before `scripts/runstate.sh` is edited and recorded as a literal in the case.
  - deps: —
  - covers: The tally's four digest-derived figures are computed by the deterministic core
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T2** [P] **P0** Create an executable `scripts/report-lint.sh` with the invocation, output contract and exit rule stated above.

  Derive both the glyph vocabulary and the section order from `templates/report-conventions.md`: the vocabulary from its glyph table, the order from its fixed-tally line, by the technique of the existing loop-prose-consistency section-order case. Neither is a frozen copy.

  Report one named finding for each of:
  - a glyph outside the vocabulary;
  - two glyphs on one line;
  - section headings out of the tally's order;
  - a header 🔀 figure unequal to the body's decision blocks plus any "N more" deferral;
  - a digest id whose first appearance carries no bold title. Take ids only from the digest's own lines, so a sha or branch name never fires.
  - a section written as "none", except the kickoff's `Will need you`.

  Treat the constructs each shape itself defines as conformant: the tally line, the kickoff's phase lines, its `▶ Session` and `▶ Autonomy` headings, a bare branch or sha in the state line, and `▶ Next`.

  Fail soft to `REPORT_LINT=unjudged` with a distinct `REASON=` for:
  - a missing or unreadable digest file (an empty digest is valid — a fresh run's kickoff has zero ids — and is judged, not refused);
  - an unreadable report;
  - an empty report.

  Write nothing anywhere. Add a `README.md` scripts-table row.

  In `scripts/test-report-conventions.sh`, add per rule a conforming fixture yielding no finding and a violating fixture yielding that finding by name. Add the shape-defined constructs as conforming fixtures. Add an all-violations fixture beside a synthetic run-state, outcomes log and plan file, asserting exit 0 and every one of those files byte-identical by checksum after the run. Add each fail-soft direction, asserting its output differs from `REPORT_LINT=clean`, and a conforming kickoff fixture with an empty digest asserting it is judged rather than `unjudged`.
  - deps: —
  - covers: A rendered report is checked against the digest it was rendered from · A finding changes nothing about the run
  - arch: —
  - files: scripts/report-lint.sh, scripts/test-report-conventions.sh, README.md
- [ ] **T3** [P] **P0** Rewrite shape B's tally sentence and its 🔀 dedup paragraph in `templates/report-templates.md`. Each digest-derived figure is read from `runstate.sh run-tally <run-state>`. The ✅/⛔/⚠️ outcome grouping and the 🔀 dedup rule are restated as what the core counts, not as arithmetic for the renderer.

  Change nothing else:
  - keep the fixed order;
  - keep the *unfinished* wording of the ⚠️ bucket;
  - keep the section headings;
  - keep the queued bucket's `runstate.sh summary` source;
  - keep the "three facts the digest does not carry" list, since `run-tally` is derived from the digest, not a new fact;
  - keep the worked examples' figures.

  Still name every outcome inside the existing enum-case anchor range (`The tally counts \`packet\` lines by outcome` … `rather than guessing a number`), or update that case's `sed` range in the same change so it never empties.

  Add a case to `scripts/test-report-conventions.sh` that runs `run-tally` over a minimal synthetic run and asserts, in both directions, that the set of figure keys it emits equals the set the shapes' tally sentence names. Guard it with a non-empty anchor check.
  - deps: T1
  - covers: The stop report consumes the digest-derived figures rather than deriving them
  - arch: —
  - files: templates/report-templates.md, scripts/test-report-conventions.sh
- [ ] **T4** [P] **P0** In `skills/run-loop/SKILL.md`, update §4's stop report and §2's kickoff, and add the one-sentence pointer below to `agents/loop-driver.md`.

  §4's stop report takes its four figures from `runstate.sh run-tally .agents/run-state.yaml` and computes none of them. Both §4's stop report and §2's kickoff are linted by the step that rendered them, as stated above:
  - write the digest and the report to literal paths under `.agents/loop/<run_id>/`;
  - run `scripts/report-lint.sh` with the matching `--shape` before emitting;
  - correct any lines a finding names at most once;
  - record, block, roll back, flip and halt nothing on a finding.

  Where §4 reads the result, state once:
  - a clean result means *no mechanical rule was broken*, never that the report conforms to the contract;
  - `unjudged` is not clean;
  - the lint does not judge whether a consequence clause states a consequence rather than an argument, whether the kickoff's assumption is the one most likely to be wrong, whether a title is a good plain-English title rather than merely present, or prose quality generally, and the reviewer is the gate for all of them.

  In `agents/loop-driver.md`'s report paragraph, add one sentence pointing at those two steps. Add no glyph, tally figure or shape slot. Prose only, no sweep case. A reviewer checks it by reading:
  - §2 and §4 against T1's and T2's output contracts;
  - the cannot-see statement against `templates/report-conventions.md`;
  - §3's shape-A step, to confirm it is unchanged.
  - deps: T1, T2, T3
  - covers: The stop report consumes the digest-derived figures rather than deriving them · A rendered report is checked against the digest it was rendered from · What the check cannot see is stated where its result is read
  - arch: —
  - files: skills/run-loop/SKILL.md, agents/loop-driver.md
- [ ] **T5** [P] **P0** In `skills/pause/SKILL.md` §4's stop report and `skills/resume/SKILL.md` §3's stop report and §4's kickoff, take the stop report's figures from `run-tally` and lint each report exactly as `skills/run-loop/SKILL.md` §4 and §2 do. At each site, state the reading of the result in one sentence — a clean result means *no mechanical rule was broken*, and `unjudged` is not clean — and point to run-loop's statement of the classes the lint cannot judge rather than restating that list, so only one wording of it exists. Leave every other line of those sections unchanged. Prose only, no sweep case. A reviewer checks it by reading the three sites against `skills/run-loop/SKILL.md` for one invocation, one reading of the result and no second copy of the cannot-see statement.
  - deps: T4
  - covers: The stop report consumes the digest-derived figures rather than deriving them · A rendered report is checked against the digest it was rendered from · What the check cannot see is stated where its result is read
  - arch: —
  - files: skills/pause/SKILL.md, skills/resume/SKILL.md
