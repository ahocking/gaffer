---
spec-version: v2
feature: stop-report-decision-liveness
---

# Plan: stop-report-decision-liveness

**The core lands first. The prose and the lint fixture follow it side by side.** T1 makes `run-tally`'s `DECISIONS` figure count an `ask-operator` question only while it is still awaiting an answer, and pins that rule with core sweep cases. T2 rewords the template so its tally sentence and body rule state T1's definition. T3 adds the resumed-run lint fixture, which needs T1's figure to be right. T2 and T3 both depend only on T1 and share no file.

**Liveness is computed inside `run-tally` alone, not shared through `run-digest`.** This settles the PRD's deferred decision. A digest `decision` line carries no timestamp. So sharing the answer through the digest would take either a new field on an existing line kind or a fifth line kind:
- the PRD freezes the four existing line kinds byte-for-byte;
- the parent plan already rejected a fifth kind, because every per-packet `run-digest --since` read would carry it.

`run-tally` already runs the digest over the whole run. It also reads the run's own `routing.jsonl` for each `ask-operator` record's `ts` and packet, and the outcomes logs for the answering records. The renderer is given the answer as a count: the header's 🔀 figure, which the body rule ties to the same definition. `cmd_run_digest`, `_rs_digest_outcome` and their output are left alone.

**Time comparison uses the existing parsed key, never the raw string.** `_rs_ts_key` already strips the fraction before `date` parses, then adds the milliseconds back as an integer. `sweep-open` and `_rs_digest_outcome` compare on this key for the same reason: `.` sorts before `Z`. An answer must have a strictly greater key than its question, so a tie keeps the question counting.

**File contention, and why all three tasks are `[P]`.**
- `scripts/runstate.sh` and `scripts/test-runstate.sh` are T1's alone.
- `templates/report-templates.md` is T2's alone.
- `scripts/test-report-conventions.sh` is T3's alone.

T1 has no deps. T2 and T3 each depend on T1 only, share no file, and sit together in the second wave. Every dep points strictly backwards.

**Reflexivity.** `scripts/runstate.sh` takes effect mid-run, so a run that lands T1 reports the corrected figure at its own stop report. `templates/report-templates.md` is read when a report is rendered. No task touches `hooks/hooks.json`, a settings file, or any agent's or skill's frontmatter, so no packet here owes a session boundary.

Every regression sweep must pass green after every task.

## Plan

- [ ] **T1** [P] **P0** In `scripts/runstate.sh`, make `cmd_run_tally` count an `ask-operator` decision only while it is still awaiting an answer. Change nothing else about the tally.

  The liveness rule:
  - it reads the question's `ts` from the run's `routing.jsonl`;
  - a record for the same packet in any session's outcomes log answers the question when it is a `start`, a `continue`, or an `abandoned` outcome, and its `_rs_ts_key` is strictly greater than the question's;
  - a `blocked` outcome never answers.

  What stays as it is:
  - `handoff-feature` lines and `hand-off-feature` decision lines keep today's count;
  - a decision line whose id already carries a `handoff-feature` line stays excluded;
  - `SHIPPED`, `FAILED` and `UNFINISHED` are unchanged;
  - `cmd_run_digest`, `_rs_digest_outcome` and the four digest line kinds are untouched.

  Update run-tally's entry in the header Subcommands list to state the rule. Write no condition as a pipe-fed `grep -q`.

  In `scripts/test-runstate.sh`, add cases in fresh runs with hand-written routing and outcome records at fixed timestamps:
  - a question answered by a later start, by a later continuation and by a later `abandoned` outcome each yields `DECISIONS=0`;
  - a question followed only by a `blocked` outcome yields `DECISIONS=1`;
  - an answer whose timestamp ties the question's yields `DECISIONS=1`;
  - a whole-second start that sorts after a sub-second question as a string, but parses earlier, yields `DECISIONS=1`;
  - two questions on one packet with a start between them yields `DECISIONS=1`.

  The existing fixture still asserts its `DECISIONS=2` hand-off dedup figure, its SHIPPED/FAILED/UNFINISHED figures and its pre-run-tally digest literal, all unchanged.
  - deps: —
  - covers: The DECISIONS figure counts an operator question only while it is still awaiting an answer · The liveness rule is pinned by core sweep cases
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [ ] **T2** [P] **P0** In `templates/report-templates.md`, rewrite shape B's paragraph on the core's 🔀 figure (the one opening "The core's 🔀 figure counts") — that paragraph is where the PRD's "tally sentence" definition lives — to define "still awaiting" as T1 counts it:
  - an `ask-operator` line counts until the same packet has a strictly later start, continuation or `abandoned` record;
  - a tie does not answer;
  - the pause's own `blocked` outcome does not answer.

  Then change the body rule bullet and the dedup worked example so each refers to that definition instead of restating it.

  Change nothing else:
  - add no backticked all-caps token inside the tally sentence's anchor range (`The tally counts \`packet\` lines by outcome` … `rather than guessing a number`);
  - keep every outcome named inside that range;
  - keep the worked examples' figures.

  The key-set and enum cases in `scripts/test-report-conventions.sh` must stay green unedited.
  - deps: T1
  - covers: The template's tally sentence and body rule state the core's definition
  - arch: —
  - files: templates/report-templates.md
- [ ] **T3** [P] **P1** In `scripts/test-report-conventions.sh`, add a resumed-run fixture: a synthetic run whose `ask-operator` question is answered by a later start record.

  Write its real `run-digest` output to a file, and assert:
  - the file carries the `decision` line for that question;
  - `run-tally` over the run prints `DECISIONS=0`;
  - a shape B report whose header 🔀 figure is built from the `DECISIONS=` value `run-tally` just printed (the bucket omitted at 0, never a literal), over a body with no decision blocks, yields no `decision-count` finding from `scripts/report-lint.sh` against that digest.

  Add a control that proves the liveness rule is what makes it clean. Drop the answering record from the same run, then assert:
  - `DECISIONS=1`;
  - the same body under a header built the same way from that printed figure yields a `decision-count` finding.
  - deps: T1
  - covers: An honest body on a resumed run lints clean
  - arch: —
  - files: scripts/test-report-conventions.sh
