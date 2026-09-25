---
spec-version: v2
feature: loop-prose-consistency-gaps
---

# Plan: loop-prose-consistency-gaps

Three tasks for four capabilities, ordered by what each defect costs while it stands.
**T1 is first and the only barrier:** it corrects the one site a driver *branches on* —
a clause keyed to a `SOURCE` value its reader can no longer emit — and it retires the
sweep case that names that correction as the error, so every other change to the sweep
would be written against a case about to go. T2 (the worked-example pin) and T3 (the
continuation trigger) follow as a `[P]` pair.

**Every site is located by content, never by line number** — the PRD states its line
references have drifted, and they have. The anchors:
- each loop skill's rule-prose sentence beginning "When `SOURCE` reads" and continuing
  "— the enumerated set naming no value in effect", directly under its
  `runstate.sh compact-threshold` output block;
- shape C's `▶ Session` note in `templates/report-templates.md`: "Whenever the
  reader's `SOURCE` named no" (the phrase wraps onto a second comment-prefixed line);
- the sweep's per-file `grep -c -- 'gaffer-default'` block, whose pass message reads
  "appears exactly once per file, in the three rule-prose clauses";
- the `shape B section order matches the conventions fixed tally order` section of
  `scripts/test-report-conventions.sh`, and its `BODY_B` extraction;
- shape B's five-packet worked example, from `#   ⏸️ **PAUSED**` to `#   ▶ **Next**`;
- run-loop §3.2's `--paused-cursor "$MEMBERS"` clause ("exactly when this session is
  about to continue it"), and §3.3's `record-start "$MEMBERS" --continue` clause.

**The emitter is settled and is not touched.** `cmd_compact_threshold` in
`scripts/runstate.sh` emits exactly `repo`, `operator` and `unknown`; the prose moves
to the code, never the reverse. No task changes script behaviour, a hook, or
`templates/report-conventions.md`, whose fixed tally order is read-only here and the
single authority both order assertions compare against.

**Capability 1 is one task, T1, deliberately.** Its two halves each fail alone — the
prose fixed with the count case kept is a red sweep; the case retired with the prose
kept is the same defect with its evidence removed — so no packet boundary may fall
between them. T1 adds no replacement case: the only candidate asserts a removed
string's absence, which the PRD rules out. The reviewer is the gate for the corrected
clauses, as the PRD's own risk entry accepts.

**Out of every task:**
- the two output-block enumerations and the four sweep assertions pinning them
  (`*gaffer-default*` inside the block, `SOURCE=repo|operator|unknown` present), which
  stay byte-unchanged;
- resume's continuation trigger;
- the parent feature's plan, whose preamble also calls the three clauses
  "must survive byte-unchanged" — that is the parent's record of its own reasoning,
  not an instruction anything follows;
- the deferred check-in hand-off clause: T1 has the shapes document open but keeps
  its diff to the three clauses, since its second failure mode is caught only by the
  reviewer.

**File contention.** T1 edits all four files in play; T2 edits only
`scripts/test-report-conventions.sh` and T3 only `skills/run-loop/SKILL.md`. Those
sets are disjoint and both depend only on the barrier, so they carry `[P]`.

**Reflexivity.** Nothing here lands as a hook or script behaviour change.
`skills/*/SKILL.md` is read at dispatch and `templates/*.md` at render, so the first
run under the corrected prose is the next `/gaffer:run-loop`. No `session_boundary`
is owed. `scripts/test-report-conventions.sh` must pass after every task.

## Plan

- [x] **T1** **P0** Correct the three source-branching clauses so each names only `unknown` as the case where the reader names no value in effect: the "When `SOURCE` reads" rule-prose sentence under the `runstate.sh compact-threshold` block in `skills/run-loop/SKILL.md` and in `skills/resume/SKILL.md` (corrected to the enumeration directly above it), and shape C's `▶ Session` note in `templates/report-templates.md` (corrected to the values the reader emits, there being no enumeration above it). Leave both output-block enumerations and the kickoff wording byte-unchanged. In the same change, retire the `grep -c -- 'gaffer-default'` occurrence-count case from `scripts/test-report-conventions.sh` and correct the section comment above it that calls those clauses deliberate and byte-frozen; leave the section's four output-block assertions unchanged. Add no case asserting the removed value's absence. Verify: the sweep passes with both halves applied, and goes red with the prose fixed and the count case restored.
  - deps: —
  - covers: The source-branching clauses name only values the reader can emit, and the sweep case defending them is retired in the same change · Every case this change touches in the sweep that owns this surface can fail
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, templates/report-templates.md, scripts/test-report-conventions.sh
- [x] **T2** [P] **P1** Extend the shape B section-order section of `scripts/test-report-conventions.sh` with a second extraction over shape B's five-packet worked example: range-anchored on its comment-prefixed `#   ⏸️ **PAUSED**` and `#   ▶ **Next**` lines, guarded non-empty before scanning, with a non-empty derived order. Assert the example's section headings appear in the order derived from `$CONV`'s fixed-tally line — never compared with shape B's own body — restricting the expected order to the sections the example renders, since the conventions omit zero buckets and the example has no `⛔` section. Leave the existing `BODY_B` extraction and assertion unchanged. Verify: moving only the example's `⬚ **Queued**` section back above its `🔀 **Decisions**` section in `templates/report-templates.md` turns the sweep red; restore it.
  - deps: T1
  - covers: The stop report shape's worked example is pinned to the order its shape is pinned to · Every case this change touches in the sweep that owns this surface can fail
  - arch: —
  - files: scripts/test-report-conventions.sh
- [ ] **T3** [P] **P1** State the continuation trigger in `skills/run-loop/SKILL.md` §3.2's `--paused-cursor "$MEMBERS"` sweep clause, worded as the situation the resume entry point's else branch already carries — a continuation is one whose start is still open; a fresh start is one whose prior attempt already closed with a recorded outcome — concretely enough to evaluate against the `sweep-open --list` output the driver already holds there, and naming no status list. Replace §3.3's tautological `record-start "$MEMBERS" --continue` condition with a reference to §3.2's decision. Leave the sweep mechanics and `skills/resume/SKILL.md` unchanged. Prose only, no sweep case (the PRD defers the agreement pin). Verify: §3.2 read alone yields a condition a reader can evaluate there, §3.3 refers to §3.2 rather than restating it, and the stated condition matches resume's else branch.
  - deps: T1
  - covers: The run entry point states its continuation trigger as a situation a reader can act on
  - arch: —
  - files: skills/run-loop/SKILL.md
