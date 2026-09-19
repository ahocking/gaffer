---
spec-version: v2
feature: loop-entry-routing-gaps
---

# Plan: loop-entry-routing-gaps

**The source clause lands first, carrying its own overrun refusal; the second extraction is hardened after.** T1 is live on the very next `/gaffer:run-loop` in this repository — the run that found it ended `done`, so the next fresh-run write replaces a completed checkpoint and an instruction that names what to carry but not where from is satisfied equally by the corrupting source. T2 is a sweep-only hardening of a risk that fires when prose is next rewrapped. Ordering follows that: P0 before P1, and the refusal mechanism is introduced by T1 because its own capability requires the new case to carry one from the start, which leaves T2 applying an existing helper rather than inventing one.

**Deferred decision, resolved.** The overrun refusal is a **line-count ceiling of 60 lines**, applied identically to both extractions through one shared helper in the sweep, not a negative content assertion on the line after the bullet. The PRD allows either, and the ceiling is chosen because the failure it must catch is an end anchor matching nothing, which runs the span to end of file — 864 lines against live spans of 28 and 12 — and because the alternative anchors the guard on prose that the same rewrap can move, which is the exact failure being guarded against. The PRD's own assumption already sizes 60 as safe.

**File contention.** T1 writes `skills/run-loop/SKILL.md` §2 and `scripts/test-report-conventions.sh`; T2 writes the same sweep, including the helper T1 adds. T2 therefore depends on T1 and neither is `[P]`. The ceiling is applied to exactly the two run-entry-point extractions, `_extract_fresh_run_write` and `_extract_entry_routing`, and to no other range in this sweep — the other `sed`-range extractions it carries stay guarded as they are. No task touches `scripts/runstate.sh` — the `findings` subcommand and the durable-state writer are unchanged, and the projection stays a projection. No task touches `hooks/`, `skills/resume/SKILL.md`, `templates/run-state.yaml`, `.github/workflows/ci.yml` or CLAUDE.md. No new sweep is added, so the CI step list and the sweep list stay unchanged.

**Reflexivity.** Skill prompts are read at dispatch, so the source clause takes effect on the next `/gaffer:run-loop`, not in the run that lands it. The sweep is a script and takes effect the moment it is next run, including inside the run that edits it. No frontmatter, `hooks.json` or settings file is touched, so no packet needs a session boundary.

**The parent is not re-opened.** `loop-entry-routing` is derived-done. No checked task line and no capability checkbox of it is edited; both tasks here add to prose and cases that feature authored, and every existing assertion over them keeps passing unchanged.

**Sibling prose.** `loop-prose-consistency-gaps` adds cases to this same sweep and corrects prose in this same §2 section. Not blocking; whichever feature lands second rebases and keeps the other's clauses and cases intact. Locate every site by content, never by line number.

Every regression sweep must pass after every task, and `claude plugin validate .` must stay clean.

## Plan

- [ ] **T1** **P0** In `skills/run-loop/SKILL.md` §2's fresh-run write, add the source clause naming `.agents/run-state.yaml`'s `findings:` block as what is copied line-for-line and the `runstate.sh findings` projection as not a source, and pin it in `scripts/test-report-conventions.sh` with new assertions over the existing carry-through extraction plus a line-count ceiling on that extraction.

  The clause, written into the existing carry-through paragraph **before its closing sentence** — the one ending "inheriting the finished run's directory and records", which is the extraction's end anchor, so a clause appended after it would fall outside `_extract_fresh_run_write`'s span and pin nothing:
  - names the file `.agents/run-state.yaml` and its `findings:` block as the span, read **from disk** — a `Read` of the file, or a line-range extraction of that block — and **copied line-for-line** into the new content, so the quoting the file carries is the quoting the new file carries;
  - defines the span as the `findings:` key through its last indented entry, stopping at the next column-0 key, with an absent or empty block carrying nothing;
  - states that `runstate.sh findings` output is **not a source**, and why: it is a projection that strips the single-quoting the durable-state writer applies (ADR 0027), so re-emitting it as index lines re-opens the `": "` corruption that quoting exists to prevent, in the one file whose parse failure is unrecoverable;
  - leaves the parent's timing untouched — the carry still happens inside the one `runstate.sh write`. This clause changes where the index is read from, never when it lands.

  The sweep work:
  - add one helper that fails a span exceeding 60 lines, and apply it to `_extract_fresh_run_write` immediately after its existing non-empty guard;
  - add assertions over that span that it names `.agents/run-state.yaml`, names the block being copied line-for-line, and names `runstate.sh findings` in the refusal. Every needle sits on **one wrapped line** of the paragraph — `has` is a plain substring match, so a phrase broken by a wrap matches nothing and fails a clause that is present. Strengthening the general weakness of pinning a negated phrase with a positive substring match is out of scope; pin a phrase distinctive to the refusal sentence.

  Verify by temporarily removing the source sentence and confirming the sweep goes red, then restore it. Leave the parent's existing cases over this span unchanged.
  - deps: —
  - covers: The carried findings index is copied line-for-line from the on-disk findings block, and the projection is named as not a source
  - arch: —
  - files: skills/run-loop/SKILL.md, scripts/test-report-conventions.sh

- [ ] **T2** **P1** In `scripts/test-report-conventions.sh`, apply T1's line-count ceiling to `_extract_entry_routing` as well, and verify both extractions now refuse an end-anchor overrun by mutating each end anchor in a scratch copy of the skill.

  - place the ceiling immediately after the routing bullet's existing non-empty guard, so both extractions are guarded the same way by the same helper, and update the comment block beside each to say what the ceiling catches that the non-empty guard cannot — a span that swallows the rest of the file and passes every prose pin on text from outside the bullet;
  - leave both `sed` ranges and every existing assertion unchanged: the refusal is additive, and nothing already pinned is loosened.

  Verify both mutation checks, using one mechanism for both. The sweep resolves its root from its own location and reads the skill only from there, so a scratch copy of the skill alone cannot be exercised: copy the whole checkout into the scratch directory and run *that* copy's `scripts/test-report-conventions.sh`, whose root then resolves to the copy — the real checkout is never mutated. In the copy, change one character of `_extract_entry_routing`'s end anchor line in `skills/run-loop/SKILL.md`, run the copy's sweep, and confirm it goes red on the ceiling rather than passing vacuously; restore and confirm green. Repeat, in the same copy, for `_extract_fresh_run_write`'s end anchor line. Confirm the real sweep's passing count rises by the new cases and that every case over these two files passes unchanged.
  - deps: T1
  - covers: Both sweep extractions of the run entry point refuse an end-anchor overrun
  - arch: —
  - files: scripts/test-report-conventions.sh
