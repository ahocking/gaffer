---
spec-version: v2
feature: skill-prompt-trim
---

# Plan: skill-prompt-trim

Twelve tasks for six capabilities: **measure, build the one landing call, switch the
sites to it, restructure resume, trim run-loop in three ranges, gate, then the one-shot
skills.** T1 is the only first-wave barrier; T2 (the subcommand) and T3 (pause) fan out
from it as a `[P]` pair with disjoint files. Every other task is sequential, because
they share `skills/run-loop/SKILL.md`, `skills/resume/SKILL.md` or the ledger.

**Why this order.** T4 switches the four landing and scan sites to one call before any
other loop-skill edit: it deletes the longest restated block in both files, so later
trims cut only what remains. T5 restructures resume before run-loop is trimmed, because
it moves rules *into* run-loop (bundle-membership recovery, the recovered-bundle
handoff check); T6–T8 then cut the one copy left. T6–T8 split run-loop by section range
to fit the packet budget. T9 closes the gate after every loop-skill edit. T10–T12 apply
capability 6 only after T9, as the PRD orders.

**Blocked on `loop-prose-consistency-gaps` and `implementer-continuation`** (the PRD's `depends_on`; the second is already done). T1 measures after
it lands, so the baseline is the prose as it finally stands. Every site is located by
content, never by line number; no task depends on the wording that plan changes (the
source-branching clauses, and the continuation trigger in run-loop §3.2 and §3.3).

**Decisions the decomposition needs.**
1. **The landing subcommand is `gspec-backlog.sh record-completion`** (PRD deferred
   decision 1), named after `check-task`/`complete-capabilities`, its summary key after
   `COMPLETE_CAPABILITIES=`/`CAPABILITY_DRIFT=`. It has a landing form (`--tasks`,
   optional `--feature`) and a scan form (`--drift`, reading `capability-drift` output on
   stdin and passing it through). `--restore index|head` is required, so the caller
   always states the restore source. It calls the existing `check-task` and
   `complete-capabilities` and changes neither; `check-task` stays the adapter's only
   task-line writer. It never stages or commits — it prints `STAGE=` paths for the
   caller. The PRD it restores is the path `_resolve_prd_path` gives, the resolver
   behind a handoff's `PRD=` line, so the restored file is the same as before — when the slug validates and resolves; otherwise it prints `RESTORED=none` and touches nothing.
2. **The ledger is `docs/skill-prompt-trim.md`** (PRD deferred decision 2): tracked,
   unlike the gitignored `.agents/metrics/`; outside `gspec/`, whose files only the
   adapter reads; not matched by `test-migrate.sh`'s stale-runbook glob. **T1 is its own
   packet** because the loop lands one commit per packet — folded into the first trim,
   the baseline would share that commit rather than precede it. T1's scope is the ledger
   alone and T2 shares no file with it, so `group` never bundles them. T1 also records
   the reported, non-gating `cc_shape` baseline from the `loop-prose-consistency-gaps`
   run that precedes this feature.
3. **The rule-by-rule review fits a read-only reviewer.** In T9 (and T12 for the
   one-shot skills) the implementer lists every baseline rule beside where a session now
   reads it. The packet's reviewer, directed by the task text, redoes the comparison
   against the baseline commit independently of the list and returns `fix` naming any
   lost rule or wrong entry; the fix round restores the rule and lists it as restored.
   The ledger lands only on a `pass`, so its zero count is the reviewer-confirmed result.
4. **A changed sweep assertion is named in the ledger's `Changed sweep assertions`
   list**, which lands in the same packet commit — the loop driver writes commit
   messages, not the implementer. T9 reconciles the list against
   `git diff <baseline>..HEAD -- scripts/`.
5. **References name a heading**: run-loop's `##` headings, and inside §3 a step's bold
   title. Run-loop is not restructured into new headings, so the sweep's content anchors
   hold.

**Out of every task:** any change to what the loop does; `agents/*.md` and
`templates/`; any existing ADR line (relocations append under a dated
`Relocated from skills (<date>)` section of the ADR that owns the rule); checked lines
under `gspec/`; the gspec preamble in `CLAUDE.md`; `skills/compare-models/SKILL.md`,
which the PRD does not name; the behaviour of `check-task`, `capability-drift` and
`complete-capabilities`. Every `routing.sh resolve` beside a dispatch stays. `files:`
lists skill and sweep scope only, because the owning ADR is decided per passage.

**Reflexivity.** Skills take effect when read: the running driver keeps the run-loop it
read at session start; a resumed or compacted session reads the trimmed text. T2 only
adds a subcommand, live on the next call; the prose T4 replaces stays correct for a
driver still holding it, because nothing it calls changes. No `compare.sh` amendment is
owed: no task changes run-loop §3's sequence, and replay skips landing.
`scripts/test-report-conventions.sh` and `scripts/test-routing.sh` must pass after every
task; `scripts/test-gspec-backlog.sh` after T2 and T4; `scripts/test-migrate.sh` after
T10.

**Budget.** Capabilities 3 and 4 are each covered by six tasks, over the
three-per-capability ceiling: about 143 KB of prose across three files splits by packet
size, not by criterion.

## Plan

- [x] **T1** **P0** Create `docs/skill-prompt-trim.md`, the feature's ledger, before any skill is edited; stop and report if any `loop-prose-consistency-gaps` or `implementer-continuation` task is still unchecked. Record: the baseline commit (`git rev-parse HEAD` at measurement); the `wc -c` byte count of `skills/run-loop/SKILL.md`, `skills/resume/SKILL.md` and `skills/pause/SKILL.md`, their total, and the gate figure (half that total, rounded down); the byte counts of `skills/migrate/SKILL.md`, `skills/metrics/SKILL.md`, `skills/new-project/SKILL.md` and `skills/review-change/SKILL.md`, reported and not gated; and the driving session's `cc_shape` max and p90 (ADR 0019) from the `loop-prose-consistency-gaps` run, read through `scripts/metrics.sh`, with ADR 0019's noted run-to-run variance beside them — or `unmeasured` when that run's figures cannot be read, never 0. Add a placeholder line for the after-trim `cc_shape` figure, marked to be filled on the first loop run after this feature, and three empty sections for later tasks: `Changed sweep assertions`, `Loop-skill rule review` and `One-shot skill rule review`. Edit no skill, script or ADR. Verify: `git show <baseline>:<path> | wc -c` reproduces each recorded count, and `git diff <baseline> -- skills/` is empty.
  - deps: —
  - covers: The loop skills together meet the size gate
  - arch: —
  - files: docs/skill-prompt-trim.md
- [x] **T2** [P] **P0** Add `gspec-backlog.sh record-completion`, which holds the landing and scan decisions by calling the existing `cmd_check_task` and `cmd_complete_capabilities` and changing neither. **Landing form**, `record-completion --tasks <id[,id...]> [--feature <slug>] --restore index|head [root]`: run `check-task` per member in the order given, printing `TASK=<id>\t<CHECKED value>` on exit 0 and `TASK_DRIFT=<id>\t<REASON>` on exit 4; on exit 1 print `HALT=<id>\t<reason>` and exit 1 with no further call. Then run `complete-capabilities` once, for the slug of the first `CHECKED=<feature>#T<n>` line, else `--feature`; skip that call with `RECORD_COMPLETION=skipped` and a `REASON=` when every member read `CHECKED=none` at exit 0, or when there is neither a slug nor `--feature`. **Scan form**, `record-completion --drift --restore index|head [root]`: read `capability-drift` output on stdin, pass every line through unchanged, and run `complete-capabilities` once per distinct `DRIFT=` slug in first-seen order, with no `check-task` and no `--feature` fallback. **Both forms** print `CAPABILITIES=<slug>\t<ok|blocked|failed>\tcompleted=<n>` per call followed by its `COMPLETED=` lines; `HELD=<slug>\t<REASON>` for a blocked call; and `STAGE=<path>` once per plan file an exit-0 `CHECKED=<feature>#T<n>` or `CHECKED=already` names, and once per PRD whose call completed more than 0. **On any non-zero `complete-capabilities` exit**, restore that slug's PRD (the path `_resolve_prd_path` gives) from the index or from `HEAD`, as `--restore` states, and print `RESTORED=<path>\tfrom=<index|head>` — but only when the slug passed the adapter's slug validation and the resolver returned a path; otherwise print `RESTORED=none\t<reason>` and touch no path. The subcommand never stages, commits or infers the restore source; it refuses a missing `--restore`; its last line is `RECORD_COMPLETION=<ok|halt|skipped> staged=<n> completed=<n> held=<n> failed=<n>`. Document it in the header comment and the usage line. `scripts/test-gspec-backlog.sh` gains fixture-repo cases for: each `check-task` branch (flipped; already; none at exit 0; drift at exit 4; halt at exit 1, with no capability call and the earlier member's flip left unstaged); each `complete-capabilities` branch (completed above 0 is staged; completed 0 is not; blocked is held with no stage or restore; exit 4 with a PRD present is restored; exit 1, and exit 4 with no PRD, restore nothing and touch no path outside `gspec/`); each restore source (`index` keeps a staged edit to the PRD, `head` resets it); the `--feature` fallback (every member already; one drift member with the rest at exit 0; every member none at exit 0, which skips); the skip with no slug and no `--feature`; the scan form's slug dedupe and pass-through; and a refused missing `--restore`. Leave every existing case unchanged. Verify: reverting each branch in turn turns at least one new case red, and the sweep is green with nothing reverted.
  - deps: T1
  - covers: The landing and scan decisions live in one adapter subcommand, and every site calls it
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
- [x] **T3** [P] **P0** Apply capability 3's relocation and one-clause rule and capability 4's value rule to `skills/pause/SKILL.md`. Append each relocated passage under a dated `Relocated from skills (<date>)` section of the ADR that owns its rule, editing no existing ADR line. Change no step, order, command or report the skill carries. Verify: each rule of the pause skill at T1's baseline commit is still in it, every sweep passes, and the diff under `docs/adr/` is additions only.
  - deps: T1
  - covers: Rationale in the loop skills is relocated to an ADR or deleted, and each rule keeps at most a one-clause reason · No loop skill states the current value of a configurable setting or code default
  - arch: —
  - files: skills/pause/SKILL.md
- [x] **T4** **P0** Switch the four landing and scan sites to `record-completion`, each stating its own restore source: run-loop §3's **Land (the `land` action)** step (`--tasks "$MEMBERS" --feature <the handoff's FEATURE= value> --restore index`); resume's `adopt` bullet (`--tasks "$MEMBERS" --restore head`, passing `--feature` only when `$RUN_DIR/<cursor>/handoff.md` exists); and the capability-drift scans in run-loop §1's **Drifted capability checkboxes** bullet and §4's end-of-run paragraph (`capability-drift | record-completion --drift --restore head`). At each site delete what the subcommand now owns — the per-command exit-code reading, the slug choice, the `FEATURE=` fallback, the staging test and the per-slug loop — and keep what each site does with the output: staging each `STAGE=` path; on `HALT=`, ending the bundle as `failed` at the Land step and escalating at adopt; the adopt path's own rules (the `HEAD` restore at the path the handoff's `PRD=` line names, the no-slug-no-handoff skip stated in the kickoff, and the `spec: reconcile capability record (adopt)` commit, never an amend); each scan's single reconcile commit, its off-integration-branch restore, its commit-failure restore, and its restore of every `STAGE=` PRD when the summary line reads `failed=` above 0; and each site's report lines for flips, `HELD=`, `TASK_DRIFT=`, failures and the unjudgeable count. Verify: for each site, the old prose and the new call stage, restore and report the same files for every `check-task` outcome and for a `complete-capabilities` call that completes above 0, completes 0, is blocked, or fails; no site carries a copy of the exit-code table. Change a sweep case only to follow a moved rule, never loosened, listed with its reason under `Changed sweep assertions` in `docs/skill-prompt-trim.md`.
  - deps: T2
  - covers: The landing and scan decisions live in one adapter subcommand, and every site calls it
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, scripts/test-report-conventions.sh, docs/skill-prompt-trim.md
- [x] **T5** **P0** Reduce `skills/resume/SKILL.md` to four things at full length — loading the checkpoint (including the `mode: parallel` stop), reconstructing the checkpoint from git, reconciling the working tree (including the `adopt` path as T4 left it), and surfacing pending questions — with everything else a reference to run-loop by its `##` heading or, inside run-loop §3, by the step's bold title. First make run-loop the one full statement of each rule both files carry — bundle-membership recovery, the sweep before start, the handoff checks, and the capability flip's shared rules: move membership recovery into run-loop §3's **Form this packet's members** step (including taking `tier:`/`agent:` from the existing handoff header and never re-running `group`), and a non-cursor `HANDOFF=unknown` in a recovered bundle into run-loop §3's **Write the handoff** step. Then delete resume's copies, replace its line-number references to run-loop with heading references, keep each `routing.sh resolve` beside a dispatch it names, and apply capability 3's relocation and one-clause rule and capability 4's value rule to what stays. A sweep case that reads resume changes only to follow a moved rule, is never loosened, and is listed with its reason under `Changed sweep assertions` in `docs/skill-prompt-trim.md`. Verify: each rule of the resume skill at T1's baseline commit is in resume or in a run-loop section resume refers to by heading, and `scripts/test-report-conventions.sh` and `scripts/test-routing.sh` pass.
  - deps: T4
  - covers: The resume skill states only what is unique to resuming, and refers to run-loop for everything else · Rationale in the loop skills is relocated to an ADR or deleted, and each rule keeps at most a one-clause reason · No loop skill states the current value of a configurable setting or code default
  - arch: —
  - files: skills/resume/SKILL.md, skills/run-loop/SKILL.md, scripts/test-report-conventions.sh, docs/skill-prompt-trim.md
- [x] **T6** **P0** Apply capability 3's relocation and one-clause rule and capability 4's value rule to `skills/run-loop/SKILL.md` from the top of the file through the end of `## 2. Enter driver mode, then establish the backlog and the run`, as T4 and T5 left it. Keep every passage `scripts/test-report-conventions.sh` extracts from this range (the packet-template `Read`, the compact-threshold block, and §2's entry-routing bullet and fresh-run carry-through clause). Change a case only to follow a moved rule, never loosened, listed with its reason under `Changed sweep assertions` in `docs/skill-prompt-trim.md`. Relocations append under a dated `Relocated from skills (<date>)` ADR section. Verify: each rule of this range at T1's baseline commit is still in run-loop, and `scripts/test-report-conventions.sh` and `scripts/test-routing.sh` pass.
  - deps: T5
  - covers: Rationale in the loop skills is relocated to an ADR or deleted, and each rule keeps at most a one-clause reason · No loop skill states the current value of a configurable setting or code default
  - arch: —
  - files: skills/run-loop/SKILL.md, scripts/test-report-conventions.sh, docs/skill-prompt-trim.md
- [x] **T7** **P0** Apply capability 3's relocation and one-clause rule and capability 4's value rule to `skills/run-loop/SKILL.md` from `## 3. Loop — for the packet at backlog.cursor` through the end of its step 5, **Act on `route`'s action**. Keep every `routing.sh resolve` beside a dispatch, and every passage the sweep extracts from this range (the `check-status` refusal clause, the implementer-line branch, and the attempt-refresh and `ACTION=continue` arms). Change a case only to follow a moved rule, never loosened, listed with its reason under `Changed sweep assertions` in `docs/skill-prompt-trim.md`. Relocations append under a dated `Relocated from skills (<date>)` ADR section. Verify: each rule of this range at T1's baseline commit is still in run-loop, and `scripts/test-report-conventions.sh` and `scripts/test-routing.sh` pass.
  - deps: T6
  - covers: Rationale in the loop skills is relocated to an ADR or deleted, and each rule keeps at most a one-clause reason · No loop skill states the current value of a configurable setting or code default
  - arch: —
  - files: skills/run-loop/SKILL.md, scripts/test-report-conventions.sh, docs/skill-prompt-trim.md
- [x] **T8** **P0** Apply capability 3's relocation and one-clause rule and capability 4's value rule to `skills/run-loop/SKILL.md` from §3's step 6, **Land (the `land` action)**, to the end of the file (steps 7–8, `## 4. Termination` and `## Never`). Keep every `routing.sh resolve` beside a dispatch, and every passage the sweep extracts from this range (§3.6's packet-close carry-through clause, the `## 4. Termination` heading, and §4's whole-branch review and relay-and-record clause). Change a case only to follow a moved rule, never loosened, listed with its reason under `Changed sweep assertions` in `docs/skill-prompt-trim.md`. Relocations append under a dated `Relocated from skills (<date>)` ADR section. Verify: each rule of this range at T1's baseline commit is still in run-loop, and `scripts/test-report-conventions.sh` and `scripts/test-routing.sh` pass.
  - deps: T7
  - covers: Rationale in the loop skills is relocated to an ADR or deleted, and each rule keeps at most a one-clause reason · No loop skill states the current value of a configurable setting or code default
  - arch: —
  - files: skills/run-loop/SKILL.md, scripts/test-report-conventions.sh, docs/skill-prompt-trim.md
- [x] **T9** **P0** Close the size gate in `docs/skill-prompt-trim.md`: record the combined `wc -c` of `skills/run-loop/SKILL.md`, `skills/resume/SKILL.md` and `skills/pause/SKILL.md` against T1's gate figure; run every `scripts/test-*.sh` and record each result; reconcile `Changed sweep assertions` against `git diff <baseline>..HEAD -- scripts/` so every changed assertion is named with its reason and none is loosened; and under `Loop-skill rule review`, list every instruction, prohibition and trap in each of the three skills at T1's baseline commit (`git show <baseline>:<path>`) beside where a session now reads it — the same skill, a run-loop section resume refers to by heading, or, for a removed value, the key and the file or script output that holds it — ending with the count of rules gone with nowhere a session would read them. Restore any lost rule to its skill in this packet, under capability 3's one-clause rule, and list it as restored. If the gate figure is not met, report the shortfall and never cut a rule to meet it. Verify (for the reviewer): compare each skill rule by rule against its baseline, independently of the list, and return `fix` naming any rule that is gone or any rule the list marks present that is not; the list lands only on a `pass`, so its zero count is the reviewer's recorded result.
  - deps: T3, T8
  - covers: The loop skills together meet the size gate · The resume skill states only what is unique to resuming, and refers to run-loop for everything else · Rationale in the loop skills is relocated to an ADR or deleted, and each rule keeps at most a one-clause reason · No loop skill states the current value of a configurable setting or code default
  - arch: —
  - files: docs/skill-prompt-trim.md, skills/run-loop/SKILL.md, skills/resume/SKILL.md, skills/pause/SKILL.md
- [x] **T10** **P1** Apply capability 3's relocation and one-clause rule and capability 4's value rule to `skills/migrate/SKILL.md`. Keep its `docs/gspec-migration.md` pointer and its read of `gspec-backlog.sh pin`, and add no literal pinned version. Change a `scripts/test-migrate.sh` case only to follow a moved rule, never loosened, listed with its reason under `Changed sweep assertions` in `docs/skill-prompt-trim.md`. Relocations append under a dated `Relocated from skills (<date>)` ADR section. Verify: each rule of the migrate skill at T1's baseline commit is still in it, and `scripts/test-migrate.sh` passes, including its no-literal-pinned-version case.
  - deps: T9
  - covers: The one-shot skills get the same relocation and value removal, last
  - arch: —
  - files: skills/migrate/SKILL.md, scripts/test-migrate.sh, docs/skill-prompt-trim.md
- [x] **T11** **P1** Apply capability 3's relocation and one-clause rule and capability 4's value rule to `skills/metrics/SKILL.md`, `skills/new-project/SKILL.md` and `skills/review-change/SKILL.md`. Keep review-change's `routing.sh resolve` beside its dispatch. Change a `scripts/test-routing.sh` case only to follow a moved rule, never loosened, listed with its reason under `Changed sweep assertions` in `docs/skill-prompt-trim.md`. Relocations append under a dated `Relocated from skills (<date>)` ADR section. Verify: each rule of the three skills at T1's baseline commit is still in its skill, and `scripts/test-routing.sh` passes, including the `routing.sh resolve` case over review-change.
  - deps: T9
  - covers: The one-shot skills get the same relocation and value removal, last
  - arch: —
  - files: skills/metrics/SKILL.md, skills/new-project/SKILL.md, skills/review-change/SKILL.md, scripts/test-routing.sh, docs/skill-prompt-trim.md
- [x] **T12** **P1** Under `One-shot skill rule review` in `docs/skill-prompt-trim.md`, list every instruction, prohibition and trap in `skills/migrate/SKILL.md`, `skills/metrics/SKILL.md`, `skills/new-project/SKILL.md` and `skills/review-change/SKILL.md` at T1's baseline commit beside where a session now reads it, ending with the count of rules gone with nowhere a session would read them. Restore any lost rule to its skill in this packet and list it as restored. Record the results of `scripts/test-migrate.sh` and `scripts/test-routing.sh`. Verify (for the reviewer): compare each of the four skills rule by rule against its baseline, independently of the list, and return `fix` naming any rule that is gone or mislisted; the list lands only on a `pass`.
  - deps: T10, T11
  - covers: The one-shot skills get the same relocation and value removal, last
  - arch: —
  - files: docs/skill-prompt-trim.md, skills/migrate/SKILL.md, skills/metrics/SKILL.md, skills/new-project/SKILL.md, skills/review-change/SKILL.md
- [x] **T13** **P0** Trim `skills/run-loop/SKILL.md`, `skills/resume/SKILL.md` and `skills/pause/SKILL.md` further toward the gate figure recorded in `docs/skill-prompt-trim.md`, since T3–T8 left their combined `wc -c` above it: shorten how each rule is worded — state once a rule a skill states in more than one place, and cut restated context, connective prose, and examples or lists that repeat a rule already given — without removing any instruction, prohibition or trap and without changing any step, order, command, printed token or report the skills carry. Keep every `routing.sh resolve` beside a dispatch, every `##` heading and §3 step bold title that resume, pause or a sweep names, and every passage `scripts/test-report-conventions.sh` or `scripts/test-routing.sh` extracts. Record the combined `wc -c` after the trim in the ledger beside the gate figure; if the figure is still not met, report the remaining shortfall and never cut a rule to meet it. Change a sweep case only to follow a moved rule, never loosened, listed with its reason under `Changed sweep assertions` in `docs/skill-prompt-trim.md`. Relocations append under a dated `Relocated from skills (<date>)` ADR section. Verify: each rule of the three skills as T8 left them is still in its skill or in a run-loop section resume refers to by heading, and `scripts/test-report-conventions.sh` and `scripts/test-routing.sh` pass. T9 runs after this task and closes the gate.
  - deps: T3, T8
  - covers: The loop skills together meet the size gate
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, skills/pause/SKILL.md, scripts/test-report-conventions.sh, docs/skill-prompt-trim.md
- [x] **T14** **P1** [P] In `agents/chief-engineer.md`'s packet-branch bullet, give the integration base the way run-loop §1 **Branch** now does: drop the `else main/master` arm, which T7 removed from run-loop by the operator's decision recorded in `docs/skill-prompt-trim.md` (it contradicts never running on `main`/`master`). Name the setting by key only, never a value or default. Change nothing else in the file. Filed from the end-of-run whole-run review (finding `chief-engineer-integration-base-drift`). Verify: the passage names no `main`/`master` fallback, and `scripts/test-report-conventions.sh`, `scripts/test-routing.sh` and `scripts/test-runstate.sh` pass.
  - deps: —
  - covers: Agent prompts that restate a rule this trim changed agree with the trimmed skill
  - arch: —
  - files: agents/chief-engineer.md
- [x] **T15** **P1** [P] In `agents/loop-driver.md` §The periodic review, stop claiming the section is stated "in the same words" as run-loop §3.8 — T8 trimmed the run-loop copy, so it is the same rule, not the same words — and bring the section in line with run-loop §3.8 as it now stands, removing anything run-loop §3.8 no longer states. Move no rule out of the agent. If a sweep extracts this passage, change its case only to follow the rewording, never loosened, and list it with its reason under `Changed sweep assertions` in `docs/skill-prompt-trim.md`. Filed from the end-of-run whole-run review (finding `loop-driver-same-words-claim-stale`). Verify: no "same words" claim remains in the section, and `scripts/test-report-conventions.sh`, `scripts/test-routing.sh` and `scripts/test-runstate.sh` pass.
  - deps: —
  - covers: Agent prompts that restate a rule this trim changed agree with the trimmed skill
  - arch: —
  - files: agents/loop-driver.md, scripts/test-report-conventions.sh, docs/skill-prompt-trim.md
- [ ] **T16** **P1** [P] Make a `/gaffer:resume` started directly read `templates/task-packet.yaml` before it writes a handoff, the way run-loop §2 has a fresh run read it, so the conditional REQUIRED lines run-loop §3.3 appends (the regression-sweep criterion and the `session_boundary` line) are never left out on that path. State it once in `skills/resume/SKILL.md`, at the step that hands handoff writing to run-loop §3.3, as a `Read` of `${CLAUDE_PLUGIN_ROOT}/templates/task-packet.yaml`; a resume reached through run-loop §2's redirect has already read it, and a second read is harmless. Change nothing else in the file. Filed from the periodic findings review of the `model-comparison-harness` run (finding `standalone-resume-skips-task-packet-read`), at the operator's call. Verify: resume names the template read before its handoff step, and `scripts/test-report-conventions.sh` and `scripts/test-routing.sh` pass.
  - deps: —
  - covers: The trimmed skills, their ADR relocation sections and the trim ledger state only what is true
  - arch: —
  - files: skills/resume/SKILL.md
- [ ] **T17** **P1** [P] In `skills/pause/SKILL.md` step 3, remove the claim that `.agents/run-state.yaml` is tracked and may be committed on the feature branch: it is gitignored (`.gitignore`), which the same skill already says in step 1. Keep the rule that nothing is ever committed on `main`/`master`. Change nothing else in the file. Filed from the periodic findings review of the `model-comparison-harness` run (finding `pause-run-state-tracked-contradiction`), at the operator's call. Verify: no passage in the pause skill calls run-state tracked or committable, and `scripts/test-report-conventions.sh` and `scripts/test-pause.sh` pass.
  - deps: —
  - covers: The trimmed skills, their ADR relocation sections and the trim ledger state only what is true
  - arch: —
  - files: skills/pause/SKILL.md
- [ ] **T18** **P1** In `docs/skill-prompt-trim.md`, correct the new-project figure the T11 paragraph gives (`new-project 8448`) to the size `wc -c skills/new-project/SKILL.md` measures at `1f6bfdf`, and check every other byte figure in the ledger against `wc -c` of its file at the commit it names, correcting any that differ. Figures only: change no rule list, count or verdict. Filed from the periodic findings review of the `model-comparison-harness` run (finding `ledger-new-project-bytes-wrong`), at the operator's call. Verify: every byte figure in the ledger matches `git show <commit>:<path> | wc -c` for the commit and file it names.
  - deps: —
  - covers: The trimmed skills, their ADR relocation sections and the trim ledger state only what is true
  - arch: —
  - files: docs/skill-prompt-trim.md
- [ ] **T19** **P1** [P] In the ADR `Relocated from skills` sections of `docs/adr/0022-findings-index-not-content.md`, `docs/adr/0023-report-conventions-delivered-not-referenced.md` (three sections), `docs/adr/0024-findings-are-packet-scoped-and-expire.md` and `docs/adr/0026-post-completion-findings-route-by-scope.md`, update each quote of a kept skill clause that T13 reworded to the clause as the skill now words it, so a grep from the ADR quote finds the skill text. Change no relocated rationale and no rule. Filed from the periodic findings review of the `model-comparison-harness` run (finding `adr-kept-clause-quotes-stale`), at the operator's call. Verify: every kept-clause quote in those sections is found verbatim in the skill it names.
  - deps: —
  - covers: The trimmed skills, their ADR relocation sections and the trim ledger state only what is true
  - arch: —
  - files: docs/adr/0022-findings-index-not-content.md, docs/adr/0023-report-conventions-delivered-not-referenced.md, docs/adr/0024-findings-are-packet-scoped-and-expire.md, docs/adr/0026-post-completion-findings-route-by-scope.md
