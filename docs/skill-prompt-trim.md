# skill-prompt-trim — ledger

The tracked record for the `skill-prompt-trim` feature
(`gspec/features/skill-prompt-trim/prd.md`). It holds the starting figures the
size gate is measured against, the reported `cc_shape` baseline, and the
results later tasks record. Every figure below was measured before any skill
was edited.

## Preconditions

Every task in `gspec/features/loop-prose-consistency-gaps/tasks.md` (3 of 3)
and `gspec/features/implementer-continuation/tasks.md` (8 of 8) was checked at
the baseline commit.

## Baseline

- **Baseline commit:** `48de82d11040cbee0374a0601a30f7faaff59ead`
  (`git rev-parse HEAD` at measurement, 2026-09-25).

Each byte count is `wc -c` of the file at the baseline commit; to reproduce
one, run `git show 48de82d11040cbee0374a0601a30f7faaff59ead:<path> | wc -c`.

### Loop skills (gated)

- `skills/run-loop/SKILL.md`: 83774 bytes
- `skills/resume/SKILL.md`: 42632 bytes
- `skills/pause/SKILL.md`: 17418 bytes
- **Total:** 143824 bytes
- **Gate figure** (half the total, rounded down): **71912 bytes**. The three
  loop skills together meet the size gate when their combined `wc -c` is at or
  under this figure.
- **After T13** (measured 2026-09-25, working tree at T13's landing, before
  T9): `skills/run-loop/SKILL.md` 62971, `skills/resume/SKILL.md` 19608,
  `skills/pause/SKILL.md` 13378 — **combined 95957 bytes**, down from 107095
  as T8 left them. **The gate figure is not met: the shortfall is 24045
  bytes.** No rule was cut to close it; the remaining text is rules, the
  passages the sweeps extract, and the step, command and token wording the
  skills carry. The operator later amended the gate to this shipped figure;
  see **Size gate result (T9)**.

### One-shot skills (reported, not gated)

- `skills/migrate/SKILL.md`: 29622 bytes
- `skills/metrics/SKILL.md`: 22028 bytes
- `skills/new-project/SKILL.md`: 9373 bytes
- `skills/review-change/SKILL.md`: 6512 bytes

## `cc_shape` (reported, never gating)

The driving session's `cc_shape` (ADR 0019 v3.4 §1) is the `main` role in
`by_agent_role`, read through `scripts/metrics.sh`. Per the PRD it is reported
against ADR 0019's noted run-to-run variance and is never offered as proof on
its own.

### Before the trim — the `loop-prose-consistency-gaps` run

Run `20260925T182537-3f4b`, driving session
`67b3c5ad-a97f-4212-8c60-12dc9c1cd37a`. That run went on to start this
feature's packets, so the window ends at the `loop-prose-consistency-gaps-t3`
`green` outcome (`2026-09-25T18:41:30.720Z` in the session's outcomes log).

Two windows are recorded, because they give materially different figures. The
session's first turn (`2026-09-25T18:21:52Z`, 73888 cache-creation tokens, the
full load of its standing context) happened before the run id's start time.

- **Run window** (`18:25:37Z` to `18:41:31Z`, the run id's start to the t3
  outcome): `main` p90 **1429**, max **2161** (28 turns, median 721, no turn
  over 50k).
  Command: `scripts/metrics.sh collect --session 67b3c5ad-a97f-4212-8c60-12dc9c1cd37a --since 2026-09-25T18:25:37Z --until 2026-09-25T18:41:31Z --out <file>`
- **Session window** (from before the session's first turn to the t3
  outcome): `main` p90 **3600**, max **73888** (43 turns, median 912, one turn
  over 50k).
  Command: `scripts/metrics.sh collect --session 67b3c5ad-a97f-4212-8c60-12dc9c1cd37a --since 2026-09-25T18:00:00Z --until 2026-09-25T18:41:31Z --out <file>`

**Run-to-run variance noted in ADR 0019** (v3.4 §1): across four untouched
same-regime sessions, coordinator cache-creation per packet spans **1.76x**,
and across all sessions **9x**. A change removing about 150k of context is
20–30%, inside that noise. `cc_shape` was added because its `max`/`p90`
separate by an order of magnitude between regimes (session `max` from 24,190 to
239,851 in that ADR's table) while the median stays flat. ADR 0019 gives no
separate variance figure for `cc_shape` itself.

### After the trim

- **After-trim `cc_shape` (`main` p90 / max):** *to be filled on the first
  loop run after this feature lands.* Measure it over the same window type as
  the baseline figure it is compared with.

## Size gate result (T9)

Measured at `e96576e` (T13's `develop` merge, the last loop-skill edit) with
`wc -c skills/run-loop/SKILL.md skills/resume/SKILL.md skills/pause/SKILL.md`:

- `skills/run-loop/SKILL.md`: 62971 bytes (baseline 83774)
- `skills/resume/SKILL.md`: 19608 bytes (baseline 42632)
- `skills/pause/SKILL.md`: 13378 bytes (baseline 17418)
- **Total:** 95957 bytes (baseline 143824; 47867 bytes removed, 33.3%)
- **Original gate figure:** 71912 bytes (half the baseline). The total is 24045
  bytes over it. No rule was cut to close that gap, and T9 cuts none. The three
  skills stand as T13 left them.
- **Gate closed at the amended figure, by operator decision.** On 2026-09-25,
  answering the second size-gate escalation on T9, the operator amended the
  PRD's size-gate criterion to the figure shipped after T13, **95957 bytes**,
  with every rule kept, because two trim passes (T3–T8, then T13) found no
  further room without cutting rules. The total meets the amended figure. The
  original 71912-byte target and the 24045-byte shortfall stay on record here
  and in the PRD criterion.

### Sweeps at that commit

Every `scripts/test-*.sh` was run once, and each exited 0:

- `test-compare.sh`: 1142 passed, 0 failed
- `test-gspec-backlog.sh`: 875 passed, 0 failed
- `test-guard.sh`: 311 passed, 0 failed
- `test-metrics.sh`: all 570 checks passed
- `test-migrate.sh`: 336 passed, 0 failed
- `test-pause.sh`: 34 passed, 0 failed
- `test-report-conventions.sh`: 640 passed, 0 failed
- `test-routing.sh`: 149 passed, 0 failed
- `test-runstate.sh`: 1735 passed, 0 failed
- `test-spend.sh`: all 192 checks passed

## Changed sweep assertions

**Reconciled by T9 against `git diff 48de82d..HEAD -- scripts/` at `e96576e`.** The diff
touches three files:
- `scripts/gspec-backlog.sh`: 291 added, 1 removed. The removed line is the
  dispatcher's usage string, extended with `record-completion`. That is
  implementation, not a sweep.
- `scripts/test-gspec-backlog.sh`: 231 added, 0 removed.
- `scripts/test-report-conventions.sh`: 606 added, 0 removed (T4 120, T5 158, T6 60,
  T7 89, T8 123, T13 56).

No line in any `scripts/test-*.sh` was deleted, so no assertion was removed or
loosened. Each sweep commit's hunks are one block appended after the previous
task's section, with one exception: T5's first two hunks (3 and 5 lines) insert a
comment and an `if` into the session-effort loop. That is the one changed assertion
group, named under T5 below. Every other sweep is unchanged since the baseline.

- **T1 (the ledger):** no sweep changed.
- **T2 (`record-completion` added):** no existing assertion changed.
  `test-gspec-backlog.sh` gains one appended block of cases, one per branch of the
  new subcommand: each `check-task` exit code, each `complete-capabilities` outcome,
  each restore source, the `--feature` fallback, both skips, the scan form, and the
  `--restore` refusal.
- **T3 (pause trimmed):** no sweep changed.
- **T4 (record-completion at the four sites):** no existing assertion changed.
  No sweep pinned the prose the four sites gave up. `test-report-conventions.sh`
  gains one section: each site calls `record-completion` with its own restore
  source, keeps its own staging, commit, restore and report rules, and carries
  no copy of the exit-code table.
- **T5 (resume restructured):** one existing assertion group changed, to follow a
  moved rule. In the session-effort loop (`for se_skill in run-loop resume`), the
  three prose pins — *the effort is read, never inferred from the model*, *never ask
  the operator to change the effort*, and *printed `EFFORT_ENV=set`* — are now read,
  for resume, from `skills/run-loop/SKILL.md`, because resume no longer restates
  them: it refers to run-loop's `## 2. Enter driver mode`, their one statement. Not
  loosened: the three phrases are still pinned, now where the rule is stated, and a
  new pin requires resume to name that heading as where they live. The fenced-block
  checks over resume (the `SOURCE` enum, the `session-effort` → `driver-mode enter`
  order, `--effort <EFFORT, exactly as printed>`, no literal unknown effort) are
  unchanged, because resume keeps the block. The T4 adopt-span anchors and needles
  are unchanged. `test-report-conventions.sh` gains one section: run-loop carries the
  moved rules (membership recovery in §3's **Form this packet's members** step,
  before `group` is read; a recovered bundle's non-cursor `HANDOFF=unknown` in the
  **Write the handoff** step; a resumed session's first-packet continuation rule in
  the sweep), resume carries no copy of them, resume names no run-loop line number or
  bare section number, every heading and §3 step title resume names exists in
  run-loop, and resume keeps its own four things and the `routing.sh resolve` beside
  its dispatch.
- **T6 (run-loop, top through `## 2. Enter driver mode`):** no existing assertion
  changed. Every passage the sweep extracts from this range — the packet-template
  `Read`, the compact-threshold block, §2's entry-routing bullet and fresh-run
  carry-through clause, §1's drifted-capability site — keeps its anchors and needles
  as they were. `test-report-conventions.sh` gains one section: §1's Branch bullet
  names `integration_branch` and `.agents/project-overrides.yaml` and points at
  `templates/task-packet.yaml` for the absent-key fallback; the range states no
  default value; and for each of the nine reasons this task moved, run-loop keeps its
  one clause, carries no copy of the moved wording, and the owning ADR's run-loop
  relocation section (ADR 0005, 0022, 0023, 0025, 0028) holds it.
- **T7 (run-loop §3 steps 1–5, `## 3. Loop` through **Act on `route`'s action**):**
  no existing assertion changed. Every passage the sweep extracts from this range —
  the `check-status` refusal clause, the implementer-line branch, the attempt-refresh
  and `ACTION=continue` arms, and T5's membership-recovery, first-packet and
  recovered-`HANDOFF=unknown` spans — keeps its anchors and needles as they were; the
  refusal clause, the branch and both arms are byte-identical, so the two surfaces
  those sections compare still read the same. `test-report-conventions.sh` gains one
  section: the Branch step names `integration_branch` and
  `.agents/project-overrides.yaml` and points at §1's **Branch** bullet for the
  fallback; the Form step reads the cap from `runstate.sh bundle-cap`'s `CAP=`, named
  by `bundle_max_tasks` and its file; the range states no default value, carries no
  task-id history and no "as today" outside the two pinned phrases; each of its five
  dispatches keeps its `routing.sh resolve`; and for each of the fourteen reasons this
  task moved, run-loop keeps its one clause, carries no copy of the moved wording, and
  the owning ADR's run-loop relocation section (ADR 0005, 0020, 0023, 0028, 0029)
  holds it.
  One rule removal, deliberate (operator decision, 2026-09-25): the Branch step's
  integration-base fallback at the baseline — `integration_branch`, else `develop`,
  else `main`/`master` — loses its `main`/`master` arm, and is not restored. That arm
  contradicted §1's **Branch** bullet ("Never run on `main`/`master`"; the base is
  the **non-`main`** branch). The remaining fallback is the one
  `templates/task-packet.yaml`'s header comment states, which §1 points at.
  `agents/chief-engineer.md` still states the `main`/`master` arm; aligning it is
  outside this task's files.
- **T8 (run-loop §3 step 6 **Land** to the end of the file):** no existing assertion
  changed. Every passage the sweep extracts from this range — §3.6's packet-close
  carry-through clause, the `rc_land` and `rc_s4` record-completion spans, the
  `## 4. Termination` heading with its whole-branch review needles and retired-arm
  absences, and §4's relay-and-record clause — keeps its anchors and needles as they
  were; the `rc_land` end anchor ("reads exactly as it does today: nothing staged,
  nothing to report") and the relay clause's "retired (ADR 0026 amendment 2026-09-22)"
  are kept verbatim for that reason, though both read as history. The §3.8 periodic
  review paragraph is trimmed to one clause per reason like the rest of the range; its
  pointer now says `agents/loop-driver.md` §The periodic review "carries the same
  rule", not the same words. Known mirror-wording gap: `agents/loop-driver.md` still
  says it states that paragraph "in the same words", which is no longer literally true.
  That file is out of scope under the PRD's Out and Deferred (`agents/*.md`), so the gap
  is left for the deferred `agents/*.md` trim. No sweep pins that mirror; the only
  same-words pin in `test-report-conventions.sh` covers the status-line refusal clause.
  `test-report-conventions.sh` gains one section: the
  Advance step names `pause_every_packets` and `.agents/project-overrides.yaml` and
  reads the value through `periodic-pause`'s `EVERY=`; the range states no default
  value and no measurement, carries no task-id history and no "today" outside the
  `rc_land` anchor, holds both later headings, and keeps `routing.sh resolve` beside
  its two dispatches; and for each of the twenty-nine reasons this task moved,
  run-loop keeps its one clause, carries no copy of the moved wording, and the owning
  ADR's run-loop relocation section (ADR 0005, 0017, 0020, 0022, 0023, 0024, 0025,
  0026) holds it. The periodic-review paragraph is also read on its own: it keeps
  `resolve chief-engineer`, the `unmeasured`-is-due arm, "record nothing yourself", the
  second-refusal carry-on, `unmeasured` never rendered as `0`, the `run-digest` route
  for the review's counts and the same-rule pointer, and claims no identical wording.
  ADR 0017 is the closest ADR for the periodic pause, which no ADR owns; ADR 0024 owns
  the periodic review (its 2026-09-21 amendment). The fallback `periodic-pause` applies
  to an unset key was a value, and is removed rather than relocated.
- **T13 (further trim of run-loop, resume and pause):** no existing assertion
  changed. Every passage the sweeps extract from the three skills keeps its anchors
  and needles; where a reworded sentence would have split an anchor or a needle
  across a line wrap, the wrap was moved so the phrase sits on one line. The
  status-line refusal clause and the implementer-line branch and continue arm, which
  `agents/loop-driver.md` mirrors, are untouched. Nothing was relocated to an ADR
  (reasons were shortened in place, never moved), so no ADR gains a relocation
  section. `test-report-conventions.sh` gains one section: for each rule T13 now
  states once, the one statement is present and the site that restated it points
  at it instead — run-loop's lint-finding consequences (stated at §2's kickoff lint;
  §4's stop-report lint points there), the Land step's removal of every member from
  `pending` (stated in the Land step; the `hand-off-feature` arm points at it), the
  held-feature definition (stated in §1; §4's end-of-run scan points there), the
  model-resolution rule (stated once in step 4; no other dispatch site outside the
  attempt and continue arms restates it), and pause's lint reading (pause carries no
  copy of the consequences and points at run-loop's `## 4. Termination`).
- **T9 (gate closed, rule review):** no sweep changed. T9 edits only this ledger.
- **T10 (migrate trimmed):** no existing assertion changed. `scripts/test-migrate.sh`'s
  only reads of `skills/migrate/SKILL.md` — the runbook pointer, the no-literal-pinned-
  version case and the `gspec-backlog.sh pin` read — are unchanged and pass, because
  the skill keeps all three. `test-migrate.sh` gains one appended section: for each of
  the thirty-four reasons this task moved, the skill keeps its one clause, carries no
  copy of the moved wording, and the owning ADR's migrate relocation section (ADR
  0004, 0020, 0023, 0024, 0025, 0028) holds it; the skill states no default value, no
  task id and no retired feature's slug; and seventeen of its prohibitions and traps,
  most of them beside a moved reason, keep their wording. The skill measures 24294 bytes with `wc -c` after T10 (29622 at the
  baseline). One task id ("T4's per-repo setting") and two retired-feature slugs
  were history and are deleted, not relocated. The skill stated no setting value
  at the baseline, so capability 4 removed nothing from it.
- **T11 (metrics, new-project and review-change trimmed):** no existing assertion
  changed. `scripts/test-routing.sh`'s existing reads of these skills — the
  dispatching-set membership of `skills/review-change/SKILL.md` and the file-level
  `routing.sh resolve` literal over every dispatching file — are unchanged and pass,
  because every "delegate to" phrase and every `routing.sh resolve` in the three skills
  is kept. `test-routing.sh` gains one appended section: for each of the twenty-five
  moves (nine metrics reasons to ADR 0019; ten report-reason rows to ADR 0023, four
  from metrics, two from new-project and four from review-change, each skill's copy of
  the shared conventions reasons counted separately; six new-project reasons to ADR
  0020), the skill keeps its one clause, carries no
  copy of the moved wording, and the named relocation section holds it; none of the
  three states a setting's value, a script's fallback, a task id or a fix-history
  story; twenty-four rules beside a moved reason keep their wording; and every
  dispatch keeps `routing.sh resolve <agent>` in its own `##` section (one in
  metrics, one in new-project, three in review-change), with a fixture proving a
  resolve in another section does not cover a dispatch. Deleted as history, not
  relocated: five task ids and a revision note in metrics, the metrics "v3.3 already
  had to fix once" story, the metrics note on packets before loop-measurement T4, and
  new-project's note that the `--parallel` skill which populated
  `.agents/task-files.yaml` was retired. Capability 4 removed from metrics the
  `metrics:` example block's values (`enabled`, `otel`, `retain_runs`), the
  enablement chain's "default on", the `ORCH_METRICS=off` value, `spend`'s default
  window length and the "default source" label on the transcript token source; each
  setting is now named by its key and file, or by the script output that shows it.
  New-project and review-change stated no setting value. The skills measure, with
  `wc -c` after T11: metrics 20369 (22028 at the baseline), new-project 8448 (9373),
  review-change 6104 (6512).

## Loop-skill rule review

Every instruction, prohibition and trap in the three skills at the baseline commit
(`git show 48de82d11040cbee0374a0601a30f7faaff59ead:skills/<name>/SKILL.md`), each
beside where a session reads it at `e96576e` (T13's `develop` merge, the last
loop-skill edit). A reason, a history note or a description of what a script does is
not a rule and is not listed; where a rule's reason moved, it moved under T3 and
T6–T8, and T13 shortened reasons in place. "Same" means the same skill, same
section. A rule marked **record-completion** is now applied by
`scripts/gspec-backlog.sh record-completion` (capability 2, T2), and the site reads
its result from the printed line named; T9 checked each such claim against the
subcommand's source (`cmd_record_completion`, `_recc_capabilities`), not its header.
Where T13 left one statement of a rule and a pointer at the other site, the entry
names both.

### `skills/pause/SKILL.md`

Preamble:
- P1 End with a clean tree at a green commit, run-state enough to reconstruct; never pause mid-edit. → same.
- P2 The loop-driver session runs pause, not the Chief Engineer. → same.
- P3 Never cross a hard gate to pause (migration, `main` commit, dependency change, sensitive path). → same.
- P4 A request may arrive through the `request-pause` sentinel; the steps are the same however triggered; clear the sentinel once durable. → same.
- P5 `Read` `report-conventions.md` and `report-templates.md` before step 4, while the checkpoint work is in flight; naming a path is not reading it. → same.

§1 Reach a safe checkpoint:
- P6 Inspect the single checkout on its `orch/<task-id>` branch; take the options in order of preference. → same.
- P7 Already green and committed: that commit is the checkpoint. → same.
- P8 Green, in-policy uncommitted work: commit it on the branch (`git commit` is not refused by the driver-mode block). → same.
- P9 Verify green build and tests before that commit yourself; the hook cannot. → same.
- P10 Put `[orch packet:<cursor>]` on its own line as the write-ahead trailer. → same.
- P11 Record no outcome for that commit; the start stays open; a later session continues it with `record-start <cursor> --continue`. → same.
- P12 Scratch that is not a safe checkpoint: `git stash push --include-untracked -m "orch pause scratch: <task-id>"`; never `reset --hard`/`clean -f`. → same.
- P13 Record the stash ref in the check-in. → same, and §4 **State**.
- P14 Escalate to the human before stashing if there is any doubt it is disposable loop scratch. → same.

§2 Verify the checkpoint:
- P15 Clean tree and `HEAD` equal to the chosen SHA before writing state; on failure stop, report, then `driver-mode exit`; never write a run-state that lies. → same.

§3 Persist run-state:
- P16 Write from the template; `status` `paused`, or `blocked` on an unanswered blocking question; `branch`; `last_green_commit`; `cursor`/`pending`. → same.
- P17 Run `prune-questions` first (skip only when the file is absent); carry existing entries from the pruned file on disk, `asked_at` unchanged. → same.
- P18 The question `stop` handed over gets `asked_at` = the `ts` of the cursor's latest `stop` routing record, verbatim and quoted. → same.
- P19 Any other new entry gets no `asked_at` line. → same.
- P20 A `blocked` status from `stop` is a terminal outcome: this step persists the question and records the outcome; `stop` wrote no run-state. → same.
- P21 The question's `packet:` already names the bundle (its first member's id); the outcome must cover every member. → same.
- P22 Membership recovery: the cursor's handoff `BUNDLE=` (absent → cursor alone), `task-status` dropping `finished`/`gone` but never the cursor, never re-deriving `group`; no handoff → cursor alone. → same, and run-loop §3 **Form this packet's members**, which pause names.
- P23 `record-outcome "$MEMBERS" blocked`, one call, before writing the file. → same.
- P24 Route what was learned: backlog vs finding (`add-finding … --packets`, mandatory) vs `note:`. → same (table).
- P25 No findings in `note:`; no `resolved_questions:` list. → same.
- P26 Write atomically through `runstate.sh write` with the heredoc shape. → same.
- P27 `write` first, `add-finding` second; carry every existing finding through verbatim. → same.
- P28 Verify the checkpoint before the write; commit run-state only on the feature branch or leave it staged, never on `main`. → same.
- P29 Clear the pause sentinel (sweeps per-lane sentinels too). → same.

§3b Snapshot run-metrics:
- P30 `metrics.sh collect || true` only after steps 1–3; never let it affect the pause; ignore an error or absent `jq`; optional one-line `metrics.sh show`. → same.

§4 Stop report:
- P31 Shape B from `run-digest` with no `--since`; do not re-open the repo to embellish. → same.
- P32 Opening sentence: why it stopped and what is at risk; a periodic pause names its setting. The baseline's worked value (`pause_every_packets: 5`) is removed; the key `pause_every_packets` in `.agents/project-overrides.yaml` and the count from `runstate.sh periodic-pause`'s `EVERY=` are named. → same.
- P33 **Shipped**: green `packet` lines in plain words, never a packet-id list. → same.
- P34 **Not done**: the other outcomes; the paused cursor named with the word *paused* under ⚠️ Unfinished, never folded in. → same.
- P35 **Decisions for you**: every blocking question as an answerable choice (two options, consequences, lean, default). → same.
- P36 **Recommended next**; **State** with branch, SHA, clean tree, `/gaffer:resume`, stash ref. → same.
- P37 Tally figures from `run-tally`, none computed; ⬚ from `runstate.sh summary`. → same, rendered as run-loop `## 4. Termination` states, which pause names.
- P38 Lint: `stop-digest.tsv`, `stop-report.md`, literal `<RUN_DIR>`, `report-lint.sh --shape B`; correct at most once, never re-lint; a finding changes nothing; `clean` is not conformance; `unjudged` is not clean. → same (the parenthesis after "act on its result as that section states"), and run-loop `## 4. Termination` **How to read the lint's result** for what the lint cannot judge, within the `## 4. Termination` section pause names.
- P39 An automated caller also gets the wire check-in. → same.
- P40 `driver-mode exit` immediately after the stop report. → same.
- P41 Stop cleanly; do not start the next packet. → same.

### `skills/resume/SKILL.md`

Preamble, report contract, flags:
- R1 Run-state is the only trustworthy memory; read it first. → same.
- R2 This session is the loop-driver in the one sequential mode. → same.
- R3 `Read` both report templates once, before surfacing anything; not per packet. → same.
- R4 `--relay`/`--inline` accepted without error; one ⚠️ line per flag in the kickoff. → same, the line's form in run-loop `## Flags this loop no longer has`, which resume names.
- R5 `--parallel` alone never triggers the parallel stop. → same.

Parallel run-state:
- R6 Check `mode: parallel` first, read-only; run no packet, write nothing. → same.
- R7 Read `runstate.sh lanes`; shape B with the four bullets (lanes, merged status, merged none, what to clear). → same.
- R8 `driver-mode exit` after that report. → same.

§0 Enter driver mode:
- R9 Run `compact-threshold`, `session-effort`, `driver-mode enter` right after the parallel check. → same (block kept).
- R10 Pass `EFFORT` exactly as printed; read, never inferred; never replace `unknown`. → run-loop `## 2. Enter driver mode`, which resume names.
- R11 `⚠️ **Effort override**` only when `EFFORT_ENV=set`. → run-loop `## 2. Enter driver mode`; resume keeps `EFFORT_ENV` for the kickoff.
- R12 `SOURCE` `repo`/`operator` → pass and state `THRESHOLD`; `unknown` → `--threshold unknown` and the fixed wording, never a number. → run-loop `## 2. Enter driver mode`.
- R13 Never ask the operator to change the effort or threshold. → same (one clause) and run-loop `## 2. Enter driver mode`.
- R14 `enter` refuses → stop with a stop report; never resume unmarked. → same.
- R15 `Read` `agents/loop-driver.md`. → same.
- R16 `begin-run` only once §1 has the checkpoint. → same.

Concurrency:
- R17 File-editing agents one at a time unless scopes are disjoint; read-only agents fan out; never a worktree for a loop packet. → run-loop `## 3. Loop` **Branch** step, which resume names; resume runs `## 3. Loop` for every packet, and each packet after the first reaches **Branch** through the **Advance** step's "pull the next packet and repeat". `agents/loop-driver.md` does not state it (checked by grep at `e96576e`).

§1 Load the checkpoint:
- R18 gspec `check` + `interlock`; `CHECK=fail` or `INTERLOCK=busy` stops, then `driver-mode exit`. → same (the exit) and run-loop `## 1. Preflight` gspec bullet.
- R19 `routing.sh validate` and `table` once, kept for the kickoff; `validate` never stops; never read `model_routing`. → run-loop `## 1. Preflight` model-routing bullet.
- R20 Resume runs neither drift scan; adopt reconciles the orphan case; the rest is left to the end-of-run scan. → same.
- R21 `prune-questions` first when the file exists. → same.
- R22 Take `status`, `branch`, `last_green_commit`, `cursor`/`pending`, `pending_questions`. → same.
- R23 Read the findings index only; open a body only when its summary bears on the packet, and say which and why. → same.
- R24 Missing file: switch to the `orch/*` branch; `runstate.sh reconstruct .`; verify `TIP` green yourself, red → escalate with a stop report and `driver-mode exit`; rebuild the backlog through the adapter only, `pending` = backlog minus `DONE`, no `backlog.done`; `pending_questions` empty and flagged in the first check-in; write with `status: running`. → same (steps 1–6).
- R25 Reconstruction impossible → say so, stop, `driver-mode exit`. → same.
- R26 Read `status` first: `paused`/`blocked` expect a clean tree; `running` is a crash, do not trust the tree. → same.
- R27 Keep that reading for the sweep's first-packet decision. → same, and run-loop §3 **Form this packet's members**.

§2 Re-establish the working tree:
- R28 `begin-run` now; it keeps `run_id`; keep `RUN_DIR=`. → same.
- R29 `git switch orch/<task-id>`, then `reconcile … .`; never eyeball it. → same.
- R30 `clean` → continue. → same.
- R31 `discard` → `git stash --include-untracked`, note the ref; escalate before stashing on any doubt; record no outcome. → same.
- R32 `adopt`: re-verify build and tests on the commit yourself. → same.
- R33 Read every trailer with the anchored, deduplicated `MEMBERS` read. → same (code block).
- R34 Inline pre-convention trailers read empty and escalate; never loosen the anchor. → same.
- R35 First id not the cursor → escalate. → same.
- R36 Set `last_green_commit`; remove every member from `pending`; no `done` list. → same.
- R37 Flip each member's task if the commit lacks it, in trailer order. → **record-completion** `--tasks "$MEMBERS"` (`check-task` per member in the given order; `CHECKED=already` is idempotent); resume §2.
- R38 `CHECKED=none` is skipped, not failed. → **record-completion** (no `STAGE=`; all-`none` prints `RECORD_COMPLETION=skipped`).
- R39 `check-task` exit 4: note by name, never halt. → same (`TASK_DRIFT=` bullet).
- R40 `check-task` exit 1: escalate naming the member. → same (`HALT=` bullet).
- R41 One `complete-capabilities` call; slug from a `CHECKED=<feature>#T<n>` line, else the handoff's `FEATURE=`. → **record-completion** (first `#T<n>` slug, else `--feature`); resume passes `--feature` from the cursor's handoff.
- R42 Skip the call only when every member read `CHECKED=none` at exit 0; one exit-4 member keeps it. → **record-completion** (exit 4 clears the all-`none` flag).
- R43 No slug and no handoff → no call, restore or commit for capabilities; say so in the kickoff; the end-of-run scan reconciles. → same ("No slug and no handoff"), and run-loop `## 4. Termination`.
- R44 Stage the PRD only when `completed=` is above 0, never on `FILE=` presence. → **record-completion** (`STAGE=` for the PRD only when `n > 0`); resume stages every `STAGE=`.
- R45 Held feature: nothing flipped, restored or committed; neither failure nor flip; named in the kickoff with its reason. → same (`HELD=` bullet, naming it with its reason), and run-loop `## 1. Preflight` **Drifted capability checkboxes**, which resume names as the statement of what a held feature is (stages nothing, leaves nothing to restore, neither a failure nor a flip).
- R46 Capability-call failure: report by name, never escalate, change nothing decided; restore the PRD from `HEAD` at the `PRD=` path. → same (`CAPABILITIES=…failed` bullet); the restore is **record-completion** `--restore head` (`RESTORED=`).
- R47 Commit task and capability flips together, or the capability flip alone; no commit when nothing flipped. → same (stage every `STAGE=`, commit only when `git diff --cached --quiet` exits 1).
- R48 Message `spec: reconcile capability record (adopt)`; never an amend of the orphan; no `[orch packet:]` trailer. → same.
- R49 A failure in the call or commit is never escalated or halting and never changes the `green` attestation. → same.
- R50 `record-outcome "$MEMBERS" green`, one call. → same.
- R51 `cursor` = first remaining `pending` entry, never assuming a prefix; write atomically. → same, and run-loop §3 **Land** (the cursor-advance rule), which resume names.
- R52 Redo no member. → same.
- R53 `escalate` → stop, ask, `driver-mode exit`; discard no commit or unreviewed output. → same.
- R54 `status: running`; `claim-driver`; heartbeat at each boundary; clear the pause sentinel. → same, and run-loop §3 **Advance**.
- R55 After a crash, `metrics.sh collect || true`, ignoring errors. → same.

§3 Pending questions:
- R56 A blocking question on the cursor halts it; present and wait. → same.
- R57 Stop report from `run-digest` with no `--since`; each question an answerable choice with a lean, naming the packet by its plain-English title. → same.
- R58 Non-blocking questions are surfaced and do not halt unrelated packets. → same.
- R59 Tally from `run-tally`, none computed. → same, and run-loop `## 4. Termination`.
- R60 Lint the stop report on literal `<RUN_DIR>` paths, at most once; `clean`/`unjudged` reading. → same (paths), and run-loop `## 4. Termination` (lint paragraph, **How to read the lint's result**).
- R61 When that report is the whole session, `driver-mode exit` after it. → same.

§4 Continue from the cursor:
- R62 Kickoff: shape C, `### Resuming`, from `run-digest` with no `--since`; one ⚠️ **Picked up** line. → same.
- R63 Session, Routing config, Routing and Effort override lines, each only when its source printed. → run-loop `## 2. Enter driver mode` (kickoff paragraph), which resume names.
- R64 State what is left, expected decisions, where it stops; one line on reconciling; the relay-flag lines. → same.
- R65 Lint the kickoff: `kickoff-digest.tsv`, `kickoff.md`, literal `<RUN_DIR>` never a variable, `--shape C`, at most once, findings change nothing. → same (paths and literal rule), and run-loop `## 2. Enter driver mode` (lint paragraph) with `## 4. Termination` **How to read the lint's result**.
- R66 Form the cursor's membership before anything else; `$MEMBERS` does not survive a crash or pause. → run-loop §3 **Form this packet's members**.
- R67 Handoff exists → recover it, never re-run `group`; `tier:`/`agent:` from its header; no `BUNDLE=` → cursor alone. → run-loop §3 **Form this packet's members**.
- R68 Mechanical refusals only: `task-status` drops `finished`/`gone`, never the cursor; `hand-off-feature` is caught at `HANDOFF=refused`. → run-loop §3 **Form this packet's members**.
- R69 No handoff → `bundle-cap`, `group`, tier walk, design-heavy truncation, `HANDOFF=unknown` alone. → run-loop §3 **Form this packet's members**.
- R70 Sweep: `--list`, `task-status` for the gone set, `--gone`; `--paused-cursor "$MEMBERS"` when continuing; a resumed first packet is a continuation on `paused`/`blocked` and fresh on `running`; skip `task-status`/`--gone` when `--list` is empty; capture `$SWEEP`. → run-loop §3 **Form this packet's members** (its first-packet exception names `/gaffer:resume`).
- R71 Carry `$SWEEP` into the first shape-A report. → run-loop §3 **Form this packet's members**.
- R72 Write the handoff for `$MEMBERS`; `tier`/`--agent` already decided. → run-loop §3 **Write the handoff, then start**.
- R73 `HANDOFF=unknown`: only the cursor when formed by `group`; a recovered non-cursor member truncates like a refusal; an unresolved cursor pipes run-state's task text or is skipped with no record. → run-loop §3 **Write the handoff, then start**.
- R74 `HANDOFF=refused`: the cursor is skipped with no record; a later member truncates and re-runs; never pipe a refused body. → run-loop §3 **Write the handoff, then start**.
- R75 `runstate.sh handoff` takes the cursor alone, never `$MEMBERS`. → run-loop §3 **Write the handoff, then start**.
- R76 Capture `SINCE` first; `record-start "$MEMBERS" --continue` or fresh as the sweep decided; one call. → run-loop §3 **Write the handoff, then start**.
- R77 Follow run-loop for dispatch, routing, landing, integration, advance and termination. → same (intro and §4: `## 3. Loop` from the Form step through `## 4. Termination`).
- R78 `routing.sh resolve <agent>` before each dispatch; non-empty → `model`, empty → omit. → same, and run-loop §3 **Dispatch, then route**.
- R79 The driver owns routine commits and non-`main` merge/rebase/push; hard gates stop for the human. → run-loop `## Never`, which resume names, and §3 **Integrate**.
- R80 Keep run-state current; `driver-mode exit` after run-loop's stop report. → same.

### `skills/run-loop/SKILL.md`

Preamble, flags, report contract:
- L1 `Read` `agents/loop-driver.md` once, first; never per packet. → same.
- L2 One sequential mode; no packet implemented inline; honor the guard, the branches and the checkpoint. → same.
- L3 `--relay`/`--inline`/`--parallel` accepted without error; one fixed ⚠️ line per flag. → same.
- L4 `Read` both report templates once, before the kickoff. → same.

`## 1. Preflight`:
- L5 No stop in §1 needs `driver-mode exit`. → same.
- L6 gspec `check`/`interlock`: `CHECK=fail` stops (remedy named), never read the backlog anyway; `INTERLOCK=busy` stops; no-ops without gspec. → same.
- L7 Drifted completion record: scan every ref with the whole-line anchor; empty → skip; `task-status`; `unchecked` said in the kickoff; never flip, never block. → same.
- L8 Drifted capabilities are reconciled by the loop itself, never a main-thread edit. → same (the `capability-drift | record-completion --drift --restore head` call).
- L9 One `complete-capabilities` call per distinct slug. → **record-completion** `--drift` (one call per distinct `DRIFT=` slug, first-seen order).
- L10 Stage only on `completed=` above 0, never `FILE=` presence. → **record-completion** (`STAGE=`); same stages each `STAGE=`.
- L11 Staged → one commit on the integration branch outside any packet, `spec: reconcile capability record (preflight)`, no packet or decider trailer, through the loop's own path. → same.
- L12 Nothing flipped → no commit, not a failure. → same.
- L13 Off the integration branch → commit nothing, state flips as not committed with the reason, restore with `git checkout HEAD --`, leave the checkout as found. → same.
- L14 `complete-capabilities` exits: 0 for a flip, a hold or a skip; 1 and 4 are failures. → **record-completion** (`CAPABILITIES=<slug>\tfailed` on any non-zero; `HELD=` for a hold); same reads `failed=`.
- L15 A failure or failed commit is reported, restores every touched PRD with the `HEAD` form, and never halts. → same; the failed call's own restore is **record-completion** `--restore head`.
- L16 One ⚠️ line per capability flipped, from `COMPLETED=`, naming feature and capability. → same.
- L17 One ⚠️ line per held feature with its reason; nothing flipped, restored or committed; neither failure nor flip. → same (`HELD=` lines).
- L18 A capability failure gets a ⚠️ line naming the feature. → same (`CAPABILITIES=…failed`).
- L19 `unjudgeable=` as one figure naming the classes present; never flipped; silent only when fully clean. → same.
- L20 No exit is a stop; the rule holds at every entry point's scan; no `gspec/` reads `none`, silent. → same.
- L21 Branch: never `main`/`master`; `orch/<task-id>` branches in the single checkout; the base is the non-`main` `integration_branch`. The baseline's value `(default develop, else main/master)` is removed: the key `integration_branch` in `.agents/project-overrides.yaml`, and the fallback in `templates/task-packet.yaml`'s header comment (which reads `default develop`). → same. The `main`/`master` arm is removed by operator decision, not restored; see T7 above.
- L22 `routing.sh validate`/`table` once before driver mode; the only source of the routing lines; `validate` never stops; never read `model_routing`. → same.

`## 2. Enter driver mode`:
- L23 Enter driver mode right after preflight with the three-call block. → same.
- L24 Effort: exactly as printed, read never inferred, `EFFORT_ENV=set` gates the override line. → same.
- L25 Threshold: pass on `repo`/`operator`; `unknown` gets `--threshold unknown` and the fixed wording, never a number. → same.
- L26 Never ask the operator to change effort or threshold. → same.
- L27 `enter` refuses → stop; never run unmarked. → same.
- L28 `Read` `templates/task-packet.yaml` once; its two REQUIRED rules; never per packet. → same.
- L29 Existing run-state: route on `runstate.sh get … status`, never by eye. → same.
- L30 `paused`/`blocked`/`running` → `Read` resume and follow it. → same.
- L31 `done`, with or without a cursor → the fresh-run branch. → same.
- L32 Any other or absent value → stop, write nothing (no `set`, `write`, `begin-run`, `claim-driver`, kickoff or lint files), then `driver-mode exit`. → same.
- L33 Build the backlog through the adapter (`next`, `nodes`), never parse `gspec/`; or `$ARGUMENTS`; non-gspec task text into run-state. → same.
- L34 Write the initial run-state atomically from the template. → same.
- L35 Replacing a `done` checkpoint: carry the `findings:` index inside the one `write`, read from disk line-for-line with the span rule, never from `runstate.sh findings`; no `run_id` line. → same.
- L36 `set status running`, `begin-run`, `claim-driver`, `clear-pause`. → same.
- L37 Keep `status` truthful; only pause and completion clear `running`. → same.
- L38 Kickoff: Session line from the digest's `enter` line, never memory; forward plan from the backlog; Routing config, Routing and Effort override lines only when their source printed; the four statements; emitted after preflight and the backlog. → same.
- L39 Kickoff lint: literal `<RUN_DIR>` paths, never a variable; `--shape C`; correct at most once, never re-lint; a finding changes nothing; read as §4 says. → same, the reading by pointer to §4's **How to read the lint's result**.

`## 3. Loop`:
- L40 **Branch**: `git switch -c orch/<task-id> <base>`, or switch if it exists; no worktree. The baseline's value chain (`else develop, else main/master`) is removed: the key `integration_branch` in `.agents/project-overrides.yaml`, fallback per §1's **Branch** bullet. → same (the `main`/`master` arm as L21).
- L41 **Form**: form the membership before the sweep. → same.
- L42 Read the cap from `bundle-cap`. The baseline's value (`default 1`) is removed: the key `bundle_max_tasks` in `.agents/project-overrides.yaml`, read through `runstate.sh bundle-cap`'s `CAP=`. → same.
- L43 `group` non-zero exit → cursor alone, said in a later report as a plain sentence; never halt; never guess membership. → same.
- L44 Leading `HANDOFF=unknown` → no bundling, cursor alone, straight to the sweep. → same.
- L45 Walk `MEMBER=` lines; a design-heavy cursor ends the group; stop before the first design-heavy member; cursor first, plan order. → same.
- L46 One tier for the bundle; the agent mapping; a multi-member bundle is never design-heavy. → same.
- L47 `$MEMBERS` is shell state; recover it from the handoff's `BUNDLE=` with the mechanical refusals only, never re-running `group`. → same (stated at the top of the step).
- L48 Sweep: `--list`, `task-status`, `GONE`, `--gone`; `--paused-cursor "$MEMBERS"` exactly when continuing, decided from `--list`; skip on an empty list; capture `$SWEEP` and carry it to the report. → same.
- L49 **Write the handoff**: check `HANDOFF=unknown` first; non-gspec task text or skip with no record. → same.
- L50 `HANDOFF=refused` for any member: cursor skipped, later member truncated and re-run, never pipe the body. → same.
- L51 Append the two conditional REQUIRED lines, judged on the union of scope; nothing from the verification contract. → same.
- L52 `runstate.sh handoff` takes the cursor alone; the title is the cursor's `TEXT=`. → same.
- L53 A refused handoff skips the packet without `record-start`. → same.
- L54 `SINCE` before `record-start`; fresh or `--continue` as the sweep decided; one call. → same.
- L55 Read back the header; pass the handoff path. → same.
- L56 **Dispatch**: every dispatch resolves its model; a deviation carries `Model override:` and applies once. → same; T13 states the non-empty → `model`, empty → omit rule once, at the head of **Dispatch, then route**, for every dispatch "here or later", and each dispatch site keeps its own `routing.sh resolve`.
- L57 `check-status` every line; one re-dispatch with the reason only; the second-refusal split; never substitute a line; the content gate stays the reviewer's. → same.
- L58 Fresh agent with the handoff path only (review path on a re-attempt); never open its result file. → same.
- L59 First token `continue` → `route`, no reviewer. → same.
- L60 Reviewer resolved and dispatched; `route` with the header's run-state path and a single-quoted status. → same; the empty/non-empty rule as L56.
- L61 **Act**: `land` → §3.6. → same.
- L62 `attempt`: `refresh-handoff` before every re-dispatch, resolve, dispatch with handoff and review, record no start. → same.
- L63 `continue`: the three steps in order; no attempt spent; no reviewer, no verdict. → same.
- L64 `decider`: resolve and dispatch the Chief Engineer with handoff, review, `ATTEMPTS=`/`LIMIT=` only; pass the token back; record nothing; apply no order. → same; the empty/non-empty rule as L56.
- L65 `discard-advance`: keep a branch with a decider commit; `git stash push`, never `reset --hard`/`clean -fd`; `record-outcome … rolled-back` once. → same.
- L66 `reorder`: remove nothing; cursor = first `pending`; a reordered packet still first → blocking question through pause. → same.
- L67 `append-task`: merge only when every commit is the decider's, never to `main`, hard-gate diff re-escalates, then `git branch -d`; otherwise do not merge and hand pause a question; cursor as `reorder`. → same.
- L68 `hand-off-feature`: remove every member wherever it sits; never assume a prefix. → same (the never-assume clause), and the remove-wherever-it-sits and cursor rule by pointer to §3.6's cursor rule, stated in the **Land** step.
- L69 No order surfaced as a question; shape-A report with every member's title, the `$SWEEP` lines and 🔀 per non-`retry` decision. → same; the title source by pointer to §3.6's title rule (the **Land** step's report bullet).
- L70 `stop`: question text from `route`'s `question:` or the triggering line; hand it to pause as blocking; write no run-state. → same.
- L71 **Land**: record every member's completion first, in plan order, in the same commit, before committing. → same (`record-completion --tasks "$MEMBERS" --feature … --restore index`).
- L72 One `check-task` call per member. → **record-completion**.
- L73 Exit 0 `#T<n>` or `already` → stage the plan file. → **record-completion** (`STAGE=`); same stages every `STAGE=`.
- L74 Exit 0 `CHECKED=none` → nothing staged from `gspec/`. → same ("No `STAGE=` line…"), via **record-completion**.
- L75 Exit 4 → drift: commit, report the member, never halt; it still gets its trailer and `green`. → same (`TASK_DRIFT=` bullet).
- L76 Exit 1 → `record-outcome "$MEMBERS" failed`, stop, report, commit nothing, `driver-mode exit`. → same (`HALT=` bullet).
- L77 One `complete-capabilities` call; slug from `#T<n>`, else the handoff's `FEATURE=`; skip only when every member read `CHECKED=none` at exit 0. → **record-completion** (`--feature` from the handoff).
- L78 Stage the PRD only when `completed=` is above 0. → **record-completion** (`STAGE=`).
- L79 Held feature stages nothing; the bundle commits as normal. → same (`HELD=` bullet).
- L80 Capability failure: report on shape A, never halt, withhold or change the outcome; restore the PRD from the index, not `HEAD`. → same (`CAPABILITIES=…failed` bullet); the restore is **record-completion** `--restore index`.
- L81 Trailers: one `[orch packet:]` per member, own line, plan order, cursor first; `[orch tier:]` as actually worked; `[orch impl:delegated]`. → same.
- L82 Run-state after landing: `last_green_commit`; remove every member wherever it sits; cursor = first remaining. → same.
- L83 The close's `write` carries `schema`, `run_id`, `branch`, every `driver_*`, `status: running`, `pending_questions`, `findings:` from disk line-for-line, never from `runstate.sh findings`; `updated_at` is the writer's. → same.
- L84 Outcome vocabulary: five triggers, the precedence, one shared outcome per bundle, a retry records nothing. → same.
- L85 Close out: `record-outcome … green` once; overwrite `note:`; the stale-findings drop, capture before drop; `OVER_THRESHOLD=yes` → `stale-findings: <N>`. → same.
- L86 Keepers become findings naming a still-pending packet, never a landed member. → same.
- L87 Shape A from `run-digest --since "$SINCE"`: ✅ or 🔁; every member's title; `$SWEEP` ⚠️ lines; 🔀 per non-`retry` decision; ⚠️ per capability failure; never from agents' words. → same.
- L88 **Integrate**: merge, rebase, push off `main` only; a hard-gate diff re-escalates. → same.
- L89 **Advance**: poll `pause-status` and beat the heartbeat at each boundary; `PAUSE=1` → finish only if green, hand to pause; no outcome. → same.
- L90 Periodic pause: `periodic-pause`; `EVERY=off` never fires; `DUE=yes` → capture `EVERY`, `request-pause` naming the setting, hand to pause. The baseline's fallback for an unset key (`missing/invalid/0 …, and the default`) is removed: the key `pause_every_packets` in `.agents/project-overrides.yaml`, read through `periodic-pause`'s `EVERY=`. → same.
- L91 Periodic review: between packets; `review-due`; `DUE=yes` including `unmeasured`; resolve and dispatch with the `run-state:` path only; `check-status`; route and record nothing; a second refusal carries on; carry both counts, `unmeasured` never `0`; the review's own results only through `run-digest`. → same; the empty/non-empty rule as L56.

`## 4. Termination`:
- L92 Resolve and dispatch one whole-branch review bounded by this run's trailers, diffing from the first such commit's parent; the base diff only when nothing anchors. → same; the resolve result's use by pointer to §3.4's rule, with the empty-result frontmatter clause kept.
- L93 No handoff: hand the diff, the run-state path and a result path; the reviewer writes through `write-result`. → same.
- L94 Never open the review file; relay its line verbatim with the path; never summarize unread findings or dispatch a router. → same.
- L95 One `add-finding` per note, summary only what the line says, `--packets` mandatory, id charset and duplicate suffix, nothing into `gspec/`; no notes → nothing. → same.
- L96 Merge and name every branch a `discard-advance` left with a decider commit. → same.
- L97 End-of-run capability scan: the same call; one `(end-of-run)` commit with no trailers; none when nothing staged; on the integration branch when §3.7 merged, else the run's own branch; `failed=` above 0 or a failed commit → commit nothing, restore with `HEAD`, report, never withhold `done`. → same; per-slug calls, the staging test and exit semantics are **record-completion** (L9, L10, L14).
- L98 Flips, held features, failures and the `unjudgeable` figure into ▶ Next, unglyphed; `none` silent; no tally change. → same; what a held feature is, and naming only the `unjudgeable` classes present, by pointer to §1's **Drifted capability checkboxes** bullet (T13 states each once, there).
- L99 Then `status: done`, `metrics.sh collect || true`, and the shape-B stop report from the whole-run digest with its listed contents. → same.
- L100 Tally from `run-tally`, none computed. → same.
- L101 Naming a landed bundle: one line; check `BUNDLE=`; confirm from the feature and integration branches with the anchored grep, `--all` fallback; every trailer in order; titles from the handoff. → same.
- L102 No commit found → render from `BUNDLE=` with a note; never silently single. → same.
- L103 A bundle that did not land renders as `run-digest` gives it. → same.
- L104 Lint the stop report on literal paths, correct at most once, never re-lint, a finding changes nothing. → same; "never re-lint in a loop" by pointer to §2's lint paragraph ("as at §2").
- L105 How to read the lint's result. → same.
- L106 `driver-mode exit` after every stop report. → same.
- L107 **Blocked**: pause already handled it; render nothing further. → same.

`## Never`:
- L108 The never-list; merging to `main`, releasing and PRs are the human's; non-`main` integration is the loop's only extra. → same.

### Result

- **Restored in this packet:** none. No baseline rule was found without a place a
  session reads it, so no skill was edited.
- **Removed by decision, not lost:** the `main`/`master` arm of the integration-base
  fallback (L21, L40). T7 removed it by operator decision because it contradicted
  "Never run on `main`/`master`". The fallback that remains is the template
  comment's.
- **Rules gone with nowhere a session would read them: 0.**

## One-shot skill rule review
