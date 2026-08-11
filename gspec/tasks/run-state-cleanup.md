---
spec-version: v1
feature: run-state-cleanup
---

# Plan: run-state-cleanup

Two run-state fields are removed and each is given the maintained home it should
have had. The deterministic cores land first (`gspec-backlog.sh`, `runstate.sh`,
`migrate.sh`), then the prompts that call them — the standing split in this repo,
and here it also keeps the contended files apart.

**The one ordering rule that cannot be got wrong:** at packet close the checkbox
flip happens *before* finding expiry is evaluated. Expiry requires positive
evidence of completion, and the checkbox is that evidence — so every task that
implements expiry sits downstream of T1, and T11 fixes the order inside the
packet-close sequence itself. Reversed, every gspec-sourced packet reads
`unknown` and expiry is permanently inert.

**`runstate.sh` calls no other script**, and never reads `gspec/`; the finished
set is supplied to it. That is a decision about `runstate.sh` specifically, not a
repo-wide rule — `migrate.sh` already calls the adapter through `$ADAPTER`, and
T17/T18 use that existing path rather than parsing `gspec/` themselves. The
safety property behind the decision is that an unsupplied set reads as `unknown`
for every entry, and `unknown` blocks expiry — so a caller that skips the wiring
expires nothing rather than expiring the wrong thing.

**Making `--packets` mandatory breaks the existing callers**, so the tasks that
repair them are part of this plan rather than a follow-up: the wire format has no
packet field today (T10), and the two `add-finding` call sites are inside the
sequences T11 and T13 already rewrite.

`allowed_files` for these tasks lives in `.agents/task-files.yaml`, fingerprinted.

## Plan

- [x] **T1** [P] **P0** Add `gspec-backlog.sh check-task` flipping one task's checkbox and never its text, name that write in ADR 0020's boundary section, and cover it in `test-gspec-backlog.sh`
  - deps: —
  - covers: The gspec task checkbox is the completion record, and the loop maintains it
- [x] **T2** **P1** Add a read-only adapter subcommand that, for a given set of packet ids, reports which name a still-unchecked gspec task and emits the finished set for `findings --stale` to consume, with a sweep case
  - deps: T1
  - covers: A drifted completion record is reported at preflight
- [x] **T3** [P] **P0** Make `add-finding` refuse without `--packets`, write the ids into the index entry, and name the four non-finding homes in its refusal, with `test-runstate.sh` cases
  - deps: —
  - covers: A finding is scoped to packets, and there is no run-wide finding
- [x] **T4** **P1** Write a finding body only when `add-finding` is passed `--body`, dropping the three-heading stub default, with a sweep case
  - deps: T3
  - covers: Finding bodies are opt-in
- [x] **T5** **P0** Add `runstate.sh drop-finding` removing index entry and body atomically, with sweep cases proving no orphan in either direction
  - deps: T3
  - covers: A finding is dropped at the packet boundary, and both halves go or neither
- [x] **T6** **P0** Add `findings --stale` taking the finished set as input rather than reading gspec, applying the finished/pending/unknown rule and the `ORCH_FINDINGS_INDEX_MAX_BYTES` threshold, with a sweep case pinning that an unsupplied set reads as `unknown` throughout and expires nothing
  - deps: T3
  - covers: A resolved finding is captured before it is dropped, by the session that resolved it
- [x] **T7** **P1** Give `reconstruct`'s `DONE=` note the clause that no run-state field is populated from it, with a `test-runstate.sh` assertion on the new clause
  - deps: —
  - covers: `reconstruct` keeps `DONE=`, and nothing is populated from it
- [x] **T8** [P] **P0** Remove `done:` from the `backlog` block in `templates/run-state.yaml`, leaving `cursor` and `pending` only
  - deps: —
  - covers: `backlog.done` is deleted, with no counter, tail, or replacement
- [x] **T9** **P0** Document in `templates/run-state.yaml` that `packets:` is required on write, bodies are opt-in, and schema stays 3 with a legacy `done:` ignored
  - deps: T8
  - covers: Neither change bumps the run-state schema, and there is no flag day
- [x] **T10** [P] **P0** Add the one-line stale-findings field to `templates/check-in.md`, emitted only when the index exceeds the threshold, and require packet ids on the `Findings:` line so the scheduler can record a lane's finding under the new `--packets` rule
  - deps: T6
  - covers: A resolved finding is captured before it is dropped, by the session that resolved it
- [x] **T11** **P0** Rewrite `run-loop` §3.3 packet close to drop the `done` append, flip the checkbox of a gspec-sourced packet in the packet commit (skipped, not failed, when the backlog is not gspec), then — after the run-state write, for the same reason `add-finding` is — apply the capture-then-drop test to that packet's findings, where filing a backlog task is the capture and a spent sign-off is not, dropping only the spent ones and passing packet ids to the `add-finding` site in that block
  - deps: T1, T5, T6
  - covers: The gspec task checkbox is the completion record, and the loop maintains it · A resolved finding is captured before it is dropped, by the session that resolved it
- [x] **T12** **P1** Make `run-loop` preflight report any `[orch packet:]` trailer naming a still-unchecked task, without flipping and without blocking
  - deps: T2, T11
  - covers: A drifted completion record is reported at preflight
- [x] **T13** **P0** Make the scheduler flip at green-lane merge and then apply the same capture-then-drop test to that lane's reported findings, updating the `parallel.md` P1.4 `add-finding` site to pass the lane's packet ids
  - deps: T11
  - covers: A finding is dropped at the packet boundary, and both halves go or neither
- [x] **T14** [P] **P0** Update the three `backlog.done` sites in `skills/resume/SKILL.md`, with orphan adoption removing from `pending` and flipping the checkbox of a gspec-sourced packet (skipped, not failed, when the backlog is not gspec)
  - deps: T1
  - covers: `backlog.done` is deleted, with no counter, tail, or replacement
- [x] **T15** [P] **P0** Remove the two `backlog.done` sites from `skills/pause/SKILL.md`, including the run-state heredoc
  - deps: —
  - covers: `backlog.done` is deleted, with no counter, tail, or replacement
- [x] **T16** [P] **P0** State in `templates/report-conventions.md` and both loop shapes that ✅ counts what this session landed, with the whole-backlog rule restated as forward-only
  - deps: —
  - covers: The tally's ✅ bucket is this session, everywhere
- [x] **T17** **P0** Add `backlog-done` detection to `scripts/migrate.sh` reporting unchecked tasks via the existing `$ADAPTER` before `apply` drops the block and `verify` asserts it gone, with `test-migrate.sh` cases
  - deps: T2
  - covers: Migration is detection plus interactive triage, and `apply` never deletes a finding
- [x] **T18** **P0** Add the `findings` detection and read-only `findings-audit` subcommand to `scripts/migrate.sh`, reading finished-ness via the existing `$ADAPTER`, with `test-migrate.sh` cases asserting `apply` deleted nothing and covering an `unknown` verdict
  - deps: T2, T17
  - covers: Migration is detection plus interactive triage, and `apply` never deletes a finding
- [ ] **T19** [P] **P0** Add the one-entry-at-a-time findings triage with its three outcomes to `skills/migrate/SKILL.md` §5
  - deps: T5, T18
  - covers: Migration is detection plus interactive triage, and `apply` never deletes a finding
- [x] **T20** **P0** Add a `test-runstate.sh` legacy fixture carrying `done:` and packet-less findings, plus a `done:`-free write asserted to parse, asserting a real parse after every mutating subcommand
  - deps: T4, T5, T6, T7
  - covers: Every changed behaviour has a case in its regression sweep
- [ ] **T21** **P1** Add the CLAUDE.md conventions bullets for both ADRs in one deliberate change — the checkbox as completion record, the session-scoped tally, and packet-scoped expiring findings — rather than letting earlier tasks each nudge the repo's most contended file. Repo-convention upkeep, not a PRD criterion
  - deps: T11, T13, T16, T19
  - covers: Neither change bumps the run-state schema, and there is no flag day
- [ ] **T22** **P0** Correct `skills/migrate/SKILL.md` where T17/T18 made it untrue: it promises the user that nothing is deleted by the script ever, but `apply` now drops the `backlog.done` block, and its relay list names only `MOVED=`/`STAMPED=`/`CONVERTED=`/`SKIP=`, so `DROPPED=`, `UNCHECKED=` and `UNRECOGNIZED_BACKLOG_DONE=` reach no human — the last two being exactly the ones needing a decision
  - deps: T18, T19
  - covers: Migration is detection plus interactive triage, and `apply` never deletes a finding
- [ ] **T23** **P1** Give `templates/check-in.md`'s `stale-findings:` field a producer: T10 added the field and T11 added the `findings --stale` scan, but §3.4 emits the check-in *before* that scan runs, so nothing can populate it and no session ever sees the backstop. Order the scan ahead of the check-in emission (or carry the count forward to it) in `skills/run-loop/SKILL.md` and the `parallel.md` scheduler
  - deps: T10, T11, T13
  - covers: A resolved finding is captured before it is dropped, by the session that resolved it
