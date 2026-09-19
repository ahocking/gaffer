---
spec-version: v2
feature: answered-question-expiry
---

# Plan: answered-question-expiry

**The core lands first, in two steps on the same file. The prose and the lint fixture follow.** T1 moves the parent's liveness rule into one shared helper and uses it to make `run-tally` count a retry-past-limit stop. T2 adds the prune subcommand on top of that helper. T3 updates the template's 🔀 definition to match T1's figure. T4 changes the three skills so they stamp `asked_at` and name T2's subcommand. T5 pins the second-stop lint fixture against T2's prune.

**This plan settles the PRD's deferred decision: one shared helper, not `_rs_tally_live_questions` called as it is today.** Today `_rs_tally_live_questions` reads its questions from `routing.jsonl`. The prune reads its questions from run-state's `pending_questions` entries, which are (`packet`, `asked_at`) pairs, so it cannot call a routing-file reader. T1 therefore splits off the answering half as one helper: it takes (packet, ts) question pairs and the outcomes dir, and returns the unanswered ones. It keeps the parent's exact rule: a start, continuation or `abandoned` record, a strictly greater `_rs_ts_key`, and a tie or a `blocked` record never answers. `_rs_tally_live_questions` feeds it from `routing.jsonl`, and T2's subcommand feeds it from run-state. The rule then exists once in code.

**How the retry-past-limit count works.** A digest `decision` line for `retry` does not say whether the retry was routed `attempt` or `stop`, and the four line kinds are frozen. So the retry-past-limit count comes from `routing.jsonl`'s `action` field, never from the digest. The helper's routing reader emits a live question for `token: retry` with `action: stop`, alongside `ask-operator`.

**Where pause gets `asked_at` (operator decision, 2026-09-18).** `route` does not print the record's `ts`. Pause reads the cursor's latest `routing.jsonl` record routed `stop` directly; `route` is not changed to print `TS=`.

**File contention and `[P]`.**
- `scripts/runstate.sh` and `scripts/test-runstate.sh` belong to T1 and T2 only, so T2 depends on T1.
- `templates/report-templates.md` is T3's alone.
- `skills/pause/SKILL.md`, `skills/resume/SKILL.md`, `skills/run-loop/SKILL.md` and `templates/run-state.yaml` are T4's alone.
- `scripts/test-report-conventions.sh` is T5's alone.

The waves are T1 → {T2, T3} → {T4, T5}. Every dep points strictly backwards, and no two tasks in one wave share a file.

**Reflexivity.** `scripts/runstate.sh` takes effect mid-run. Templates and skills are read at render time or dispatch time. No task touches `hooks/hooks.json`, a settings file, or any frontmatter, so no packet here needs a session boundary.

Every regression sweep must pass green after every task.

## Plan

- [x] **T1** [P] **P0** In `scripts/runstate.sh`, split the parent's liveness rule out of `_rs_tally_live_questions` into one helper, and make `run-tally` also count a still-awaiting retry-past-limit stop.

  The helper:
  - takes (packet, ts, tag) question entries and the outcomes dir, and prints the unanswered ones with their tag echoed (T2 passes a fixed tag);
  - an answer is a start, `continue` or `abandoned` record for the same packet whose `_rs_ts_key` is strictly greater than the question's;
  - a tie or a `blocked` record never answers.

  `_rs_tally_live_questions` feeds the helper from `routing.jsonl`. It takes `ask-operator` records as today, plus records whose `token` is `retry` and `action` is `stop`. The routing reader tags each live line with its token, so the `ask-operator` count (and its hand-off exclusion) and the retry-past-limit count read separate tallies; the retry-past-limit count is not hand-off-excluded, since it is a distinct question. `cmd_run_tally` counts each live retry-past-limit stop as one 🔀. Leave these unchanged:
  - `SHIPPED`, `FAILED` and `UNFINISHED`;
  - the hand-off dedup and the existing `ask-operator` count;
  - `cmd_run_digest` and its four line kinds, byte-identical.

  Update run-tally's entry in the header Subcommands list. Write no condition as a pipe-fed `grep -q`.

  In `scripts/test-runstate.sh`, add cases with hand-written routing and outcome records at fixed timestamps:
  - a `retry` routed `stop` with no later answer yields `DECISIONS=1`;
  - the same stop with a later start yields `DECISIONS=0`;
  - a `retry` routed `attempt` yields `DECISIONS=0`;
  - one packet with both a live `ask-operator` and a live retry-past-limit stop yields `DECISIONS=2`.

  Every existing run-tally case, including the parent's liveness cases and the `DECISIONS=2` hand-off dedup fixture, still asserts its figures unchanged.
  - deps: —
  - covers: `run-tally` counts a retry-past-limit stop as a decision · The prune and the new count are pinned by core sweep cases
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [ ] **T2** [P] **P0** In `scripts/runstate.sh`, add a subcommand (for example `prune-questions <run-state>`) that keeps only the `pending_questions` entries T1's helper reports as unanswered, plus those with no `packet:` or no `asked_at`.

  What it drops and keeps:
  - it parses the block-entry shape `templates/run-state.yaml` documents; a list in any other shape is kept unchanged;
  - it feeds the helper each entry's `packet` and `asked_at`, with quotes stripped symmetrically as `cmd_get` does;
  - it keeps every entry that has no `packet:` or no `asked_at`, which fails toward over-reporting;
  - when one packet has stopped twice, it drops the answered first question and keeps the live second one.

  How it writes:
  - it writes through `cmd_write`, carrying every other key, including `findings:`, through byte-identical;
  - when nothing is dropped, it does not write at all.

  Add it to the header Subcommands list.

  In `scripts/test-runstate.sh`, add:
  - one case per answering kind (start, continuation, `abandoned`), each dropping the entry;
  - cases that keep an unanswered entry, a tied entry, an entry with no `packet:`, and an entry with no `asked_at`;
  - the case where one packet stops twice;
  - a case asserting `findings:` is byte-identical after a prune;
  - a no-drop case asserting the file is unchanged.

  Every case must assert a real YAML parse afterwards.
  - deps: T1
  - covers: A core subcommand prunes answered entries from `pending_questions` · The prune and the new count are pinned by core sweep cases
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [ ] **T3** [P] **P0** In `templates/report-templates.md`, extend shape B's paragraph that opens "The core's 🔀 figure counts" so it names the retry-past-limit stop as a counted decision, aged by the same still-awaiting definition as an `ask-operator` line.

  Change nothing else:
  - add no backticked all-caps token inside the tally sentence's anchor range;
  - keep every outcome named in that range;
  - keep the worked examples' figures.

  The key-set and enum cases in `scripts/test-report-conventions.sh` must stay green unedited.
  - deps: T1
  - covers: `run-tally` counts a retry-past-limit stop as a decision
  - arch: —
  - files: templates/report-templates.md
- [ ] **T4** [P] **P0** Add `asked_at` to the `pending_questions` entry shape in `templates/run-state.yaml`, and change the skill prose at the three list sites.

  In `skills/pause/SKILL.md`, the persist step:
  - runs T2's subcommand first, before the list is written;
  - takes the existing entries it carries through from `pending_questions` as they stand in the pruned run-state on disk, never from an earlier read, with their `asked_at` unchanged;
  - stamps the entry the `stop` action handed over with the quoted `ts` of the cursor's latest `routing.jsonl` record routed `stop`. It writes no `asked_at` on any other new entry (for example a `hand-off-feature` question or one carried by a plain pause), so T2 keeps that entry;
  - shows `pending_questions` in the block-entry shape in its heredoc placeholder.

  In `skills/resume/SKILL.md`, the entry runs T2's subcommand before `pending_questions` is read or rendered.

  In `skills/run-loop/SKILL.md`, the "carrying every existing entry through" sentence names T2's subcommand.

  Each site names the subcommand rather than restating the rule.
  - deps: T2
  - covers: Each `pending_questions` entry records when it was asked · The prune runs wherever the list is re-persisted
  - arch: —
  - files: templates/run-state.yaml, skills/pause/SKILL.md, skills/resume/SKILL.md, skills/run-loop/SKILL.md
- [ ] **T5** [P] **P1** In `scripts/test-report-conventions.sh`, add a fixture for a run that stops, resumes, answers the first question with a later start and stops a second time.

  Run T2's subcommand over its run-state, then assert against its real `run-digest` output:
  - a shape B body rendered with one decision block per surviving `pending_questions` entry;
  - under a header whose 🔀 figure is built from the `DECISIONS=` value `run-tally` prints;
  - yields no `decision-count` finding from `scripts/report-lint.sh`.

  Add a control that skips the prune and renders the body from the unpruned list. It must yield a `decision-count` finding.
  - deps: T2
  - covers: A report after a second stop lints clean
  - arch: —
  - files: scripts/test-report-conventions.sh
