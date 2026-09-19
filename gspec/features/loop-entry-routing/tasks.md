---
spec-version: v2
feature: loop-entry-routing
---

# Plan: loop-entry-routing

**The routing condition and its stop land first. The carry-through clause lands second. Each ships with its own sweep case in the same packet.** T1 rewrites the redirect bullet in `skills/run-loop/SKILL.md` §2 into a test on the checkpoint's status, adds the unrecognised-status stop, and adds the sweep case that pins the condition. T2 adds the findings carry-through to §2's fresh-run write and adds the sweep case that pins it. A sweep case landing in a separate, later packet would sit there with nothing to assert. Pairing each case with the prose it checks means every packet can verify itself with the mutation check its capability requires.

**Deferred decisions, resolved.**
- The condition enumerates the statuses inline, read with `runstate.sh get .agents/run-state.yaml status`. It does not call `runstate.sh outcome`, because `outcome` also distinguishes a live second driver from a crashed one, and that is out of scope.
- The carry-through is done by the driver composing the new content around the index it read. It is not done by `runstate.sh write` preserving the index, because Scope rules out any mechanism change.

**File contention.** Both tasks write `skills/run-loop/SKILL.md` §2 and `scripts/test-report-conventions.sh`, so T2 depends on T1 and neither is `[P]`. No task touches `skills/resume/SKILL.md`, `templates/run-state.yaml`, `scripts/runstate.sh`, `.github/workflows/ci.yml` or CLAUDE.md. No new sweep is added, so the CI step list and the sweep list stay unchanged.

**Reflexivity.** Skill prompts are read at dispatch. The driver of an in-flight run keeps the `run-loop` text it loaded at start, so the new routing takes effect on the next `/gaffer:run-loop`. No frontmatter, `hooks.json` or settings file is touched, so no packet needs a session boundary.

**Sibling prose.** `loop-prose-consistency-gaps` edits the same §2 section and adds cases to the same sweep. Whichever feature lands second rebases and keeps the other's clauses intact. Locate every site by content, never by line number.

Every regression sweep must pass green after every task, and `claude plugin validate .` must stay clean.

## Plan

- [x] **T1** **P0** In `skills/run-loop/SKILL.md` §2, replace the "If `.agents/run-state.yaml` exists, you are resuming" redirect with a three-way routing on its status, and add the sweep case that pins the condition to `scripts/test-report-conventions.sh`.

  The routing instruction:
  - reads the status with `runstate.sh get .agents/run-state.yaml status`, and never parses the file by eye;
  - redirects to `skills/resume/SKILL.md` for exactly `paused`, `blocked` and `running`, each named in the condition and each glossed as that entry point's decision table resolves it;
  - sends `done` (backlog complete) to the fresh-run bullet directly below it, with no redirect. A `done` checkpoint that still carries a cursor or pending packets follows the status, so it also takes the fresh-run branch;
  - states the redirect set positively. It never says "anything but `done`";
  - covers every other value, including an absent or empty status: stop with a report naming the value read and `.agents/run-state.yaml`. Before stopping, write nothing: no `set`, no `write`, no `begin-run`, no `claim-driver`, and no kickoff/lint files, since no run directory exists yet. Run `runstate.sh driver-mode exit` immediately after that stop report, because §2 entered driver mode before this decision.

  Leave `skills/resume/SKILL.md` unedited.

  The sweep case:
  - extracts the routing bullet by its own content anchor, with the same non-empty guard the existing extractions use (not by reusing `_extract_ct_block`, which matches a different, fenced span);
  - asserts the extracted span is non-empty before scanning it;
  - asserts the span names `paused`, `blocked` and `running` as the redirect set, and names `done` as taking the fresh-run branch. It adds no assertion for the unrecognised-status stop: the PRD defers that coverage, with the reviewer as the gate.

  Write no condition as a pipe-fed `grep -q`. Verify by temporarily reverting the condition to an existence test and confirming the sweep goes red, then restore it. Leave every existing case in the sweep unchanged.
  - deps: —
  - covers: The run entry point routes on the checkpoint's lifecycle status, not on the file's existence · A status the entry point does not recognise stops the run rather than taking either branch · The routing condition and the carry-through clause each have a case in the sweep that owns this surface, and neither can pass vacuously
  - arch: —
  - files: skills/run-loop/SKILL.md, scripts/test-report-conventions.sh
- [ ] **T2** **P0** In `skills/run-loop/SKILL.md` §2's fresh-run write, state the carry-through: when it replaces a `done` checkpoint, carry every `findings:` index entry into the new content verbatim, and carry nothing else. Add the sweep case that pins this clause to `scripts/test-report-conventions.sh`.

  The clause:
  - carries the index within the one `runstate.sh write` itself, never as a follow-up `add-finding` or repair. It names the consequence the packet-close write already states: `write` REPLACES the file, so an omitted entry is unlinked, not edited out;
  - builds cursor, pending, branch, `last_green_commit` and `note` from the new backlog;
  - writes no `run_id` line, so the following `begin-run` mints a new run id rather than inheriting the finished run's directory and records.

  The sweep case:
  - extracts the fresh-run write instruction by a content anchor and asserts the span is non-empty;
  - asserts the span names the `findings:` carry-through as verbatim, and names `run_id` as not carried.

  Verify by temporarily removing the clause and confirming the sweep goes red, then restore it. Leave T1's case and every earlier case unchanged.
  - deps: T1
  - covers: A fresh run started over a completed checkpoint carries the findings index through, and nothing else · The routing condition and the carry-through clause each have a case in the sweep that owns this surface, and neither can pass vacuously
  - arch: —
  - files: skills/run-loop/SKILL.md, scripts/test-report-conventions.sh
