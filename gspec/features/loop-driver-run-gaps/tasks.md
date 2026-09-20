---
spec-version: v2
feature: loop-driver-run-gaps
---

# Plan: loop-driver-run-gaps

**Mechanism first, wiring second, driver prose third, documents last.** The
grammar check (T1) is a pure function over one string and lands before the two
subcommands that call it (T2), which land before the prose that tells the
driver what a refusal means (T3). A prompt naming a subcommand that does not
exist yet is the failure this order prevents: the driver would improvise, and
what it would improvise is a judgement about a status line — the exact thing
the operator chose a mechanical check over. The other two gaps are independent
of the first and of each other, so they follow in PRD order: the packet-close
carry clause (T4), then the termination record (T5) and its pins (T6).

**Capability 4 is a property of every script task here, not a task of its
own.** "Every change above has an owning sweep case, none vacuous, none
silently skipped without `jq` or `python3`" describes how the other three
capabilities are built, so a task that discharged it separately would be a task
that audits work already merged — and the only honest time to make the
mutation that proves a case non-vacuous is while the fix is still in your
hands. Each of T1–T6 therefore carries it in `covers:` alongside the capability
it delivers, names its own sweep case, and names the **wrong implementation
that case rules out**. Two rules inherited by reference from
`runstate-write-integrity-gaps` apply throughout and are not restated per task:
every new `scripts/test-runstate.sh` case is mirrored in the block that runs
with `jq` and `python3` absent from `PATH` and must produce the same result
there, and a case asserting a YAML parse goes through `yamlok`, which skips
**loudly and counted** rather than passing vacuously when no parser is present.
`scripts/test-report-conventions.sh` pins prose by content-anchored extraction
with a non-empty guard **and** an `under_ceiling` end-anchor refusal — the form
`loop-entry-routing-gaps` requires, because a dead end anchor yields a span
that swallows the rest of the file and satisfies every assertion made over it.

**Two of the PRD's three deferred decisions are decomposition calls and are
made here; the third stays deferred.** (1) The check is a **standalone
`runstate.sh check-status --status '<line>'`**, not logic folded into both
callers: one grammar, one reason text, one set of cases, and the driver needs
to run it on status lines nothing routes on — the implementer's and the
doc-writer's — which neither `route` nor `write-result` is on the path of. The
flag name is `--status` so the argument form is byte-identical at all three
call sites and the one `'\''` quoting rule in `templates/status-line.md`
carries across unchanged. (2) The termination id is **`end-of-run-review`**: it
satisfies the packet-id charset, contains no `..`, reads as a title when
rendered, and can collide with no packet — every gspec-sourced packet id is
`<slug>-t<n>`. (3) **Whether `runstate.sh write` itself refuses content lacking
a `run_id` line stays deferred**, exactly as the PRD leaves it. T4 delivers the
clause and pins its consequence; it does not add a refusal, because the
condition separating §2's deliberate omission over a `done` checkpoint from a
mid-run drop is the undecided part, and guessing it would refuse the loop's own
fresh-run write.

**The refusal lands on two different actors, and that is why one re-dispatch is
enough.** `write-result` is called by the **dispatched agent** — it is the one
write a read-only agent gets — so an off-grammar line is refused there first,
non-zero, with the reason, before the agent has returned anything; the agent
corrects its own line and re-runs. `route` is called by the **driver**, on a
line already returned. T3's single re-dispatch is the second net, not the
first, which is what makes the PRD's assumption (both observed failures were
one-line reformats) a cheap one to be wrong about.

**File overlap, not logic, is what keeps this sequential.**
`scripts/runstate.sh` carries T1–T2; `scripts/test-runstate.sh` carries T1, T2,
T4 and T6; `skills/run-loop/SKILL.md` carries T3, T4 and T5;
`scripts/test-report-conventions.sh` carries T3–T6. Only **T7** is `[P]`, and
its three files are touched by no other task in this plan. A task reading
`deps: —` has no logical prerequisite; it is not thereby safe to run beside its
neighbours.

**Cross-feature overlap, computed from the `files:` lines below.** Three other
open plans write into this plan's scope:

> `escalation-decider` (15 tasks) collides on **seven** files —
> `scripts/runstate.sh`, `scripts/test-runstate.sh`, `skills/run-loop/SKILL.md`,
> `agents/loop-driver.md`, `templates/status-line.md`, `CLAUDE.md` and
> `docs/adr/0028-loop-driver-mode.md`.
> `handoff-verification-contract` (6 tasks) collides on **four** —
> `scripts/runstate.sh`, `scripts/test-runstate.sh`,
> `skills/run-loop/SKILL.md`, `CLAUDE.md`.
> `driver-context-window-default` (being planned concurrently) collides on
> **four** — `scripts/runstate.sh`, `skills/run-loop/SKILL.md`, `CLAUDE.md`,
> `docs/adr/0028-loop-driver-mode.md`.
> Untouched by any of them: `scripts/test-report-conventions.sh`,
> `docs/adr/0026-post-completion-findings-route-by-scope.md`.

Every task here must stay sequential with those features' tasks on the shared
files. Three collisions are sharper than write scope alone and each is composed
with deliberately:

- **`escalation-decider` T11/T12 edit the same two files T3 does** —
  `skills/run-loop/SKILL.md` (their §3.5/§3.8 against T3's §3.4, different
  sections of one file) and `agents/loop-driver.md`, whose Routing section is
  the one paragraph both actually share. Land one feature's routing task clear of the other's
  rather than interleaving them, and whichever lands second carries the first's
  clause forward in the file it is editing rather than restating that section
  from memory. The refusal rule and the decider dispatch are independent
  statements about the same step; neither replaces the other.
- **`escalation-decider` T7 changes what `run-tally` counts** — it adds
  `run-digest` `review`/`decision` lines and makes a review's routings count as
  decisions. T6 is therefore written to assert a **delta of exactly one**
  against the same run without the termination record, never an absolute
  `DECISIONS=` figure, so it holds in either landing order. Do not
  "simplify" it to a fixed number.
- **`escalation-decider` T13 also edits `templates/status-line.md`** — it drops
  the stand-in wording and names the review's status word, in the intro and the
  Grammar list. T2 edits the *"One line, no exceptions"* paragraph of the
  same file and nothing else; the grammar itself is out of scope here. Same
  file, different paragraphs, so sequential landing is the whole constraint.

**Reflexivity — the three surfaces take effect at three different times.**
`scripts/runstate.sh` is live **mid-run, in the run that edits it**, so T1 and
T2 apply to that run's own remaining `route`/`write-result` calls: the run
landing T2 can have its own agents' lines refused. `templates/status-line.md`,
`skills/run-loop/SKILL.md` and `agents/loop-driver.md` are read **at dispatch**,
so the run landing T2's template correction, T3, T4 or T5 is still driving
under the old prose and the first run under them is the next
`/gaffer:run-loop`. `CLAUDE.md` is standing instruction loaded at session
start, so T7 reaches the harness next session. Only agent and skill
*frontmatter* is a session-start surface — every edit here is to a body — and
no hook registration changes, so no packet in this plan needs a
`session_boundary` declaration.

**Capability 1 takes three tasks plus a share of the documents task, one past
the ≤3 guideline, deliberately.** It spans four surfaces that cannot be
reviewed together — a deterministic grammar, its enforcement points, the
driver's judgement on a refusal, and the template statement that says nothing
enforces it — and the alternative is one task fusing a shell function with
prose in three files. The guideline is advisory; the right-sizing bar is not.

## Plan

- [x] **T1** **P0** Add `runstate.sh check-status --status '<line>'`, which accepts a line exactly when it is one line carrying no backtick and no `$`, its first field (everything before the first ` · `) is one word, the segment between its second-to-last and last ` · ` is literally `result: needs-reading` or `result: no`, and its last field (everything after the last ` · `) is non-empty and whitespace-free — taking those boundaries from the first and last separator rather than from a field count, and on failure exiting non-zero with one reason naming the rule that failed; `scripts/test-runstate.sh` gains the two shapes the PRD's Overview names (a free-form reply with no fields, no `result:` and no path; a line whose first field is the packet id and which carries no `result:`), each asserting its own expected reason, plus the pass case for a `<what changed>` clause containing its own ` · ` and a case asserting two different failures print two different reasons — the pass case ruling out splitting on ` · ` into exactly four fields, which refuses a line `templates/status-line.md` explicitly permits, and the two-reasons case ruling out one generic "malformed status line" message, which leaves T3's re-dispatch nothing actionable to pass back.
  - deps: —
  - covers: A malformed status line is refused before it reaches routing, and re-issued by the same agent once · Every change above has an owning sweep case, none vacuous, none silently skipped without `jq` or `python3`
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T2** **P0** Make `route` and `write-result` run `check-status` on their `--status` argument **before either touches disk** — before the routing record is appended, before the run directory is created and before the result file is written — failing non-zero with the byte-identical reason `check-status` prints, and correct the *"One line, no exceptions"* paragraph of `templates/status-line.md`, which states that nothing mechanically refuses a multi-line reply and that the reviewer is the gate, to name that refusal and keep the reviewer as the content gate, leaving the Grammar section itself unchanged; `scripts/test-runstate.sh` gains a refused `route` asserting `routing.jsonl` is byte-unchanged, a refused `write-result` asserting the target path does not exist, and a case asserting all three refusals print the same bytes — the two disk assertions ruling out checking *after* the append or write, which still exits non-zero and still prints the reason while leaving a routing record for a line the loop never routed on, and the identical-message case ruling out each caller wording its own refusal, which would hand the driver a reason the grammar's owner never stated.
  - deps: T1
  - covers: A malformed status line is refused before it reaches routing, and re-issued by the same agent once · Every change above has an owning sweep case, none vacuous, none silently skipped without `jq` or `python3`
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, templates/status-line.md
- [x] **T3** **P0** State the refusal rule in the same words in the driver's routing step in `skills/run-loop/SKILL.md` §3.4 and the Routing section of `agents/loop-driver.md`: run `check-status` on **every** status line read, including one nothing routes on; on a refusal re-dispatch the same agent **once**, passing the printed reason and nothing else; a second refusal of a line the driver does not route on proceeds to the reviewer dispatch exactly as today, a second refusal of a line it would have routed on (the reviewer's verdict, the decider's token) is escalated as a blocking question naming the agent and the printed reason, and the driver never substitutes a line of its own — the reviewer's content gate unchanged; `scripts/test-report-conventions.sh` pins both spans — the §3.4 clause and `agents/loop-driver.md`'s Routing section — by a content-anchored extraction with a non-empty guard and an `under_ceiling` end-anchor refusal, asserting the once-only limit, both second-refusal branches and the never-substitute rule all appear in each span, which rules out stating the rule in one file and paraphrasing it in the other — the ceiling ruling out a dead end anchor whose span runs on to end of file and passes every assertion on text from outside the clause.
  - deps: T2
  - covers: A malformed status line is refused before it reaches routing, and re-issued by the same agent once · Every change above has an owning sweep case, none vacuous, none silently skipped without `jq` or `python3`
  - arch: —
  - files: skills/run-loop/SKILL.md, agents/loop-driver.md, scripts/test-report-conventions.sh
- [x] **T4** **P0** Rewrite the packet-close write clause in `skills/run-loop/SKILL.md` §3.6 as an enumerated list of every column-0 key that must survive the whole-file `write` because the close does not itself produce it — `schema`, `run_id`, `branch`, every `driver_*` key present (`driver_host`, `driver_since`, `driver_heartbeat`, and `driver_pid` when the claim recorded one), `status: running`, `pending_questions` and the `findings:` block, each copied from the on-disk `.agents/run-state.yaml` being replaced under the source rule `loop-entry-routing-gaps` set — while naming `updated_at` as the writer's own stamp and `last_green_commit`, `backlog` and `note` as the close's own output; pin the clause in `scripts/test-report-conventions.sh` beside the fresh-run pin in the same extraction/guard/ceiling form, asserting each named key appears in the span, and pin its consequence in `scripts/test-runstate.sh` with a mid-run checkpoint written per the clause (`run-digest` resolves without its no-run-id refusal, `begin-run` reprints the `RUN_ID=` the file held and creates no second run directory, and the file still parses through `yamlok`) against a control write omitting `run_id` — the control ruling out a case that passes on any content at all, since a correct and an incorrect close take the same code path right up until the id is gone.
  - deps: —
  - covers: A packet-close write carries the run identity and driver claim through · Every change above has an owning sweep case, none vacuous, none silently skipped without `jq` or `python3`
  - arch: —
  - files: skills/run-loop/SKILL.md, scripts/test-report-conventions.sh, scripts/test-runstate.sh
- [ ] **T5** **P1** Add the termination record to `skills/run-loop/SKILL.md` §4: when the end-of-run architect's status line reports an ADR 0026 arm-2 proposal in its free-text clause — judged by the driver from the line it already relays, introducing no new status token — call `runstate.sh route <run-state> end-of-run-review hand-off-feature --status '<that line>'`, a fixed id that satisfies the packet-id charset, carries no `..`, reads as a title and collides with no packet (every gspec-sourced packet id is `<slug>-t<n>`), and treat the printed `ACTION` as **not to be acted on** — the record is the whole purpose of the call — recording no outcome for that id, while an architect that routed everything to arm 1 or found nothing to route records nothing at all and changes no figure; pinned in `scripts/test-report-conventions.sh` in the same extraction/guard/ceiling form, asserting the fixed id, the token, the `--status` argument, the ACTION-not-acted-on rule, the no-outcome rule, and that the record is written when the architect's status line is read — before the stop report's `run-tally` read — all appear in the span; the ordering assertion rules out recording the proposal after the tally is read, which prints `DECISIONS=0` beside a rendered decision block, the defect itself.
  - deps: —
  - covers: An end-of-run arm-2 proposal is a counted decision · Every change above has an owning sweep case, none vacuous, none silently skipped without `jq` or `python3`
  - arch: —
  - files: skills/run-loop/SKILL.md, scripts/test-report-conventions.sh
- [ ] **T6** **P1** Pin the termination record's effect end to end: `scripts/test-runstate.sh` gains a case writing one `hand-off-feature` routing record for `end-of-run-review` into a run's `routing.jsonl` and asserting `run-digest` emits a `handoff-feature` line carrying the architect's status line, emits no `packet` line for that id (it has no handoff file), `run-tally`'s `DECISIONS` rises by **exactly one** against the same run without the record, and `sweep-open` closes nothing for it; and `scripts/test-report-conventions.sh` gains a fixture stop report over that run whose header 🔀 is the printed `DECISIONS` and whose body carries one decision block, asserting `scripts/report-lint.sh` reports no `decision-count` finding, with the block dropped as the control that fires it — the `sweep-open` assertion ruling out writing the record into `.agents/metrics/outcomes/`, where `_rs_open_packets` reads any `kind`-bearing record as a packet start and the next sweep closes a packet that never existed as `interrupted`, and the delta assertion ruling out counting the proposal twice, once as its `handoff-feature` line and once as a `decision` line for the same id.
  - deps: T5
  - covers: An end-of-run arm-2 proposal is a counted decision · Every change above has an owning sweep case, none vacuous, none silently skipped without `jq` or `python3`
  - arch: —
  - files: scripts/test-runstate.sh, scripts/test-report-conventions.sh
- [ ] **T7** [P] **P1** Record all three gaps where the harness reads standing instruction and where the decisions are read as history: `CLAUDE.md`'s driver-mode bullet gains the status-line grammar check (its subcommand, that `route` and `write-result` refuse through it before touching disk, and the one re-dispatch), the packet-close carry set, and the termination routing record with its fixed id and why it may never go to the outcomes log; ADR 0028 is amended — dated and marked, never rewritten — where it says the driver reads one status line with nothing refusing an off-grammar one, and where it fixes the routing record's shape; and ADR 0026's arm-2 paragraph is amended the same way to say the proposal now leaves a routing record and is counted, the operator gate itself unchanged. Prose only, no sweep case; checkable by reading each amended paragraph against the behaviour that shipped — every sentence claiming nothing refuses an off-grammar line now names the check, and neither amendment rewrites the original text.
  - deps: T3, T4, T6
  - covers: A malformed status line is refused before it reaches routing, and re-issued by the same agent once · A packet-close write carries the run identity and driver claim through · An end-of-run arm-2 proposal is a counted decision
  - arch: —
  - files: CLAUDE.md, docs/adr/0028-loop-driver-mode.md, docs/adr/0026-post-completion-findings-route-by-scope.md
