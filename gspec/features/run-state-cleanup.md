---
spec-version: v1
---

# Feature: run-state-cleanup

Remove the two unbudgeted stored fields from `.agents/run-state.yaml`, and give
each of them the maintained home it should have had. One feature because both
changes edit the same five skill files and the same migration script, and both
are drained in the same `/gaffer:migrate` pass.

**Completion (ADR 0025).** The loop reads `gspec/tasks/<slug>.md` and never
writes it — nothing in `skills/`, `agents/` or `templates/` flips a task
checkbox. Yet the adapter emits one node per **unchecked** task and `resume`
leans on that in prose. In practice the boxes are being flipped by hand,
inconsistently, sometimes in a separate `docs(spec): check off …` commit that
can be lost or reverted independently of the work it records. Meanwhile
`backlog.done` stores exactly the state those checkboxes derive — gitignored,
same-machine, with no reader — and because `runstate.sh write` replaces the
whole file, an agent re-emits the entire list from memory on every packet.
Measured: 95 entries, 16% of a 27,400-byte run-state, reproduced forever with
no checksum and nothing that would notice a dropped line.

**Findings (ADR 0024).** ADR 0022 gave findings a home and a creation path but
never said how a finding *ends*. Retention was implicit at forever, and the
unbounded growth 0022 removed from `note:` reappeared one directory over: a
14,777-byte index — 54% of the run-state, re-cached on every large turn — with
21 of 29 entries naming no packet at all. The summaries were good and the
carry-through discipline held; what failed is that nothing in the design could
tell a live entry from a dead one.

## Capabilities

- [ ] **P0**: The gspec task checkbox is the completion record, and the loop maintains it
  - at packet close, when the packet came from a gspec task, the checkbox flips `[ ]` → `[x]` **in the packet commit itself** — the work and the record that it happened land atomically, never in a follow-up commit
  - only the checkbox character ever changes; the task text is never rewritten (gspec's immutability floor blocks edits to checked lines, and a rewrite destroys the record of what was actually built) — and because this is the plugin's one write into `gspec/`, the boundary section of the spec-seam decision record (ADR 0020) names it explicitly rather than leaving it inferred
  - the driver flips it, not the implementer — the task file is outside the packet's `allowed_files`; under `--parallel` the scheduler flips when it merges a green lane back, so lanes sharing one feature's task file never contend
  - conditional, because gspec is optional: a packet from a run-state or explicit-argument backlog has no checkbox, and its absence is not a failure

- [ ] **P1**: A drifted completion record is reported at preflight
  - `run-loop` preflight, in a gspec repo, reports any `[orch packet:<id>]` trailer naming a task that is still unchecked
  - it reports, does not flip, and does not block the run — a task may be unchecked because the work was later reverted, so reconciling is a human decision
  - this is the runtime form of the migration check, so the cross-seam reliance is self-verifying rather than documented

- [ ] **P0**: `backlog.done` is deleted, with no counter, tail, or replacement
  - the `backlog` block carries `cursor` and `pending` only — no `landed:` integer, no bounded tail of recent ids, nothing else in its place, and nothing on the check-in path scanning commit trailers to substitute for it
  - the resume reconstruction step becomes "`pending` = the committed backlog minus `DONE`, in order" — the same computation without the intermediate storage, so no reader is left populating a field that no longer exists
  - orphan adoption on resume stops writing a completion list: it removes the packet from `pending` and, if the adopted commit did not already carry it, performs the checkbox flip
  - `pending` survives and is explicitly not the next thing removed by this reasoning — it carries the *chosen* order, which is a decision, not derivable state

- [ ] **P0**: The tally's ✅ bucket is this session, everywhere
  - the report conventions and both loop shapes state that ✅ counts what **this session** landed or shipped, countable from check-ins the rendering agent has already produced, with nothing read from disk
  - ⚠️ / 🔀 / ⬚ remain the forward state, drawn from `pending` and `pending_questions`
  - the "buckets must account for the whole backlog" rule is restated as applying to the **forward** buckets only — a growing backlog is not a fixed set to partition, and *2 landed, 25 to go* reads honestly

- [ ] **P1**: `reconstruct` keeps `DONE=`, and nothing is populated from it
  - `DONE=` still prints: a human rebuilding a lost run-state wants the identities, and it is the fallback where a repo's commits carry no trailers
  - its note gains one clause stating that no run-state field is populated from it any more — `DONE=` is informational only

- [ ] **P0**: A finding is scoped to packets, and there is no run-wide finding
  - `add-finding`'s usage text and its refusal message both state the definition: a finding is a constraint on a packet that has not executed yet, recorded because there is nowhere permanent to put it until that packet runs
  - `add-finding` refuses without `--packets`, and there is no `--run-wide` escape hatch — an entry that cannot expire is the thing being removed
  - the refusal names where the four non-findings go instead: a durable fact about the environment, tools, agents or standing policy → the repo's own committed files or agent memory; a question only the human can answer → `pending_questions:`; where this session stopped → `note:`; "this should be built/fixed" → the backlog

- [ ] **P0**: A finding is dropped at the packet boundary, and both halves go or neither
  - `drop-finding` removes the index entry **and** the body, atomically — the zero-orphan property must survive the introduction of a destructive path, and one command owning both halves is what preserves it
  - a lane never calls it (a lane's worktree has no run-state): the lane reports in its check-in and the scheduler drops
  - the drop joins the packet-close sequence bounded to that packet's findings — never an unattended judgment prune across the whole index — and always **after** the checkbox flip, never before: sequentially it runs after the packet commit that carries the flip, so the just-closed packet reads finished rather than unknown; under `--parallel` it runs after the scheduler has merged the green lane and flipped, because a lane cannot evaluate expiry at lane close at all — the flip it depends on has not happened yet
  - expiry requires positive evidence of completion — the gspec checkbox checked, or an `[orch packet:<id>]` trailer naming it. Absence from `pending` is **unknown**, not finished, and unknown blocks expiry

- [ ] **P0**: A resolved finding is captured before it is dropped, by the session that resolved it
  - a finding has exactly two terminal states — captured somewhere permanent and dropped, or dropped; no archive directory, tombstone, or archived status, and no extra machinery around the capture either: no promotion receipts, no `promoted_to:` field, no routing config, because where a resolved finding goes is the consuming repo's business
  - the capture is performed by the live session at the moment of resolution, which is the only one still holding the context that decides where it belongs
  - filing a backlog task *is* the capture (the knowledge is then committed and cross-machine); an owner-gate sign-off is not durable knowledge and expires with the packet it gated
  - `findings --stale` lists entries naming no unfinished packet, with the blocking reference where there is one, and surfaces as one line in the check-in when the index exceeds `ORCH_FINDINGS_INDEX_MAX_BYTES` (default 4096) — a backstop for the days discipline slipped, not the intended path

- [ ] **P1**: Finding bodies are opt-in
  - the index entry alone is the default; a body file is created only when `add-finding` is passed `--body`
  - the three-heading stub is no longer written by default — handed three empty headings an agent fills them, measured at 362-byte summaries against 6,789-byte bodies
  - bodies stay available and unchanged in shape for the cases with genuine evidence to preserve; most findings are fully carried by their summary

- [ ] **P0**: Neither change bumps the run-state schema, and there is no flag day
  - schema stays 3: every reader is a grep, so a file still carrying `done:` parses and the field is simply ignored
  - `packets:` becoming required is a write-side constraint only — an entry without it still parses, and reads as `LIVE=unknown`
  - new writes obey the new rules and `/gaffer:migrate` drains what predates them, so no existing run-state has to be migrated before the next run

- [ ] **P0**: Migration is detection plus interactive triage, and `apply` never deletes a finding
  - a read-only findings audit reports, per entry and without opening a body: whether it names packets, a three-state live/dead/unknown verdict, summary and body bytes, plus index and body totals for the run
  - `unknown` routes an entry to a human rather than to a rule — no `packets:` at all, or a named packet that is neither pending nor demonstrably finished. Finished-ness reads from the gspec checkbox or an `[orch packet:<id>]` trailer only, never the `done:` block, so the two drains in one pass are order-independent
  - before the `done:` block is dropped, detection reports any id in `done` whose gspec task is still unchecked; `apply` reports it and does not flip, because the work may have been reverted. `apply` drops the block and `verify` asserts it is gone
  - `apply` deletes no finding — it is non-interactive and runs against a clean tree, and the material includes the only copy of things nobody has decided about. The triage lives in the migrate skill, one entry at a time, with three outcomes: drop · capture then drop · keep and repair by adding the missing packet scope

- [ ] **P0**: Every changed behaviour has a case in its regression sweep
  - `test-runstate.sh` covers the `done:`-free write path, `add-finding` refusing without a packet scope, the opt-in body, `drop-finding` leaving no orphan in either direction, and the finished/pending/unknown expiry rule
  - `test-migrate.sh` covers both new detections, the unchecked-task report emitted before the block is dropped, the findings audit including an `unknown` verdict, and the assertion that `apply` deleted nothing
  - a legacy file still carrying `done:` and findings without a packet scope parses after every mutating subcommand — asserted as a real parse, not a grep
