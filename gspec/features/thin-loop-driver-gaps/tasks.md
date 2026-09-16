---
spec-version: v2
feature: thin-loop-driver-gaps
---

# Plan: thin-loop-driver-gaps

The two defects that corrupt a report on ordinary input land first — the digest's
split lines, then the packet reported twice — because they degrade every run until
they are closed. The rest are corrections, ordered by how much a wrong statement
costs while it stands: the reconcile classifier that can stash unreviewed work, the
guard rule that blocks the driver from recording anything, the threshold nobody
enforces, then the four prose surfaces. `scripts/runstate.sh`,
`scripts/test-runstate.sh`, `hooks/guard.sh`, `scripts/test-guard.sh`,
`skills/run-loop/SKILL.md`, `skills/resume/SKILL.md`, `scripts/metrics.sh`,
`templates/report-templates.md` and `CLAUDE.md` are each one file and each is
touched by more than one task, so **most of this plan is sequential**: only T4, T8
and T11 are `[P]`, and each of those three touches a file no other `[P]` task
touches. A task carrying `deps: —` here means it has no logical prerequisite, not
that it may run beside its neighbours.

**The title fix is an `awk ENVIRON` fix, not a quoting fix.** `_rs_digest_title`
passes the handoff's first line through `awk -v line=…`, which expands `\n` in the
*value* — the repository's standing rule, learned in ADR 0022's `add-finding`. The
packet id beside it stays on `-v`: it is charset-validated and can carry no
backslash, so widening the change to it would only enlarge the diff.

**The two sweep-exclusion capabilities are one task, because the criterion is that
both call sites state the rule in the same words.** `skills/run-loop/SKILL.md` omits
the cursor argument entirely and `skills/resume/SKILL.md` passes it only on
`status: paused`; the rule is *the cursor packet is excluded exactly when this
session is about to continue it*. Written into one file at a time they would drift
again. `sweep-open`'s own behaviour and its `--paused-cursor` flag name are
unchanged — the exclusion is the caller's decision, and the sweep still closes
everything else, including the cursor of a crash or a run whose work is gone. The
flag name reads misleadingly after this task; renaming it would touch every caller
and the sweeps for no behaviour change, so it is deliberately left for another time
and recorded in the PRD's Deferred Decisions, which outlives this plan.

**The threshold capability lands as two tasks, in this order, and both must land in
the same run.** Suppressing the line comes first and removing the invented default
second, so that at no point does a report state a number that is wrong: after T5 the
kickoff and the resume session line carry no threshold clause when nothing is in
effect, and only then does T6 delete the constant behind it and retire the two sweep
cases that pin `200000`. The reader's `APPLIED` field **cannot** carry the
condition — it reads `no` on every path, including one an operator set and the
harness genuinely enforces, which must still be stated — so the suppression keys on
`SOURCE`, which is what T6's no-value-in-effect source makes expressible. The value
is removed rather than corrected because ADR 0028 result 3 records `1m tokens` as
the default *on Opus 5 (1M)*, a model-conditional reading rather than a harness-wide
one, and that ADR's own instruction to this reader is to report `unknown` rather
than invent one. The halves are separately reviewable — one is skill and template
prose, the other is a constant and two sweeps — which is why they are not one
six-file task.

**The end-of-run review's scope is STATED, not computed.** The driver applies the
rule when it builds the diff, from `run-digest`'s own `packet` lines and the
`[orch packet:<id>]` trailers those ids already carry; nothing new is recorded. A
computed range would need a field in the digest or in run-state, and new measurement
fields are out of this feature's scope — which is also why the PRD marks this
criterion prose only. The rule is the one the worked example selects: this run's
integrated work (23 files), never the integration branch against its base (211
files, ~30,000 insertions of already-reviewed work).

**Four capabilities, and half of two more, land where no sweep can reach:
`CLAUDE.md`, `templates/report-templates.md`, the digest's header comment,
`skills/metrics/SKILL.md` and skill prose.** Their only detector is a careful read —
the same detector that missed them — so each prose task names the concrete check a
reviewer can run instead of a sweep case. Do not invent a test for prose; where the
PRD names a sweep and its cases, the task adds them.

**Widening what driver mode permits weakens a control by construction, so the
permitted class is the criterion.** T4 admits only a target that cannot enter any
packet's commit — outside the repository the loop is driving — never "anything the
driver judges harmless". Every other tier still judges the call, the secret and
key-material floor first, driver mode after it and before the ask tier, so
`bypass-ask-tier` still cannot skip it. An unresolvable or repository-relative
target that resolves outside stays refused for being unverifiable.

**Reflexivity.** `scripts/runstate.sh` and `hooks/guard.sh` take effect **mid-run,
in the run that edits them** — T1, T3, T4 and T6 are live on the next tool call, so
the run landing T4 gains the wider permission itself. `skills/*/SKILL.md` and
`templates/*.md` are read at dispatch or at render, so the run landing T2, T5 or T9
is still driving under the old prose and the first run under them is the next
`/gaffer:run-loop`. `CLAUDE.md` is standing instruction loaded at session start, so
T8 reaches the harness next session. No hook registration changes here, so nothing
else needs a session boundary.

## Plan

- [x] **T1** **P0** Interpolate the handoff's first line into `_rs_digest_title` (`scripts/runstate.sh`) through `awk ENVIRON` rather than `awk -v`, leaving the charset-validated packet id on `-v`, so a title carrying a literal `\n` or a Windows path yields one digest line; `scripts/test-runstate.sh` gains a case with a backslash-bearing title asserting exactly one output line for that packet and no fragment lacking its leading type field.
  - deps: —
  - covers: The digest emits one line per item, whatever a task title contains
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T2** **P0** State one sweep rule in both loop skills — the cursor packet is excluded exactly when this session is about to continue it — so `skills/run-loop/SKILL.md` §3.2 passes the cursor when it is continuing one and `skills/resume/SKILL.md` stops keying the exclusion on `status: paused`, leaving `sweep-open`'s behaviour and its `--paused-cursor` flag name unchanged and everything else the sweep closes untouched (a crash, or a run whose work is gone, still writes `interrupted` for the cursor); `scripts/test-runstate.sh` gains a continued cursor packet under the run-loop call shape and a resume from a status the rule admits and one it excludes.
  - deps: —
  - covers: A packet continued in the same run is reported once, with one outcome · A run that stopped on a blocking question resumes like a paused one
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, scripts/test-runstate.sh
- [x] **T3** **P1** Make `_reconcile_tree` in `scripts/runstate.sh` return `escalate` for a tree holding deliberate output the loop did not create rather than `discard`, leaving a packet's own uncommitted scratch on the green checkpoint decided `discard` as today, and make `skills/resume/SKILL.md`'s `discard` instruction escalate to the operator before stashing anything it did not produce, matching the instinct `skills/pause/SKILL.md` already carries; `scripts/test-runstate.sh` covers both tree shapes, including the thirteen-untracked-files-under-a-reviewed-output-directory case that returned `discard`.
  - deps: —
  - covers: Reconcile separates the loop's own scratch from deliberate output it did not produce
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, skills/resume/SKILL.md
- [ ] **T4** [P] **P1** Narrow driver mode's write refusal in `hooks/guard.sh` to targets that could reach a packet's commit — admitting a target that resolves outside the driven repository, keeping the check after the secret and key-material floor and before the ask tier, and keeping an unverifiable or repository-relative-but-outside target refused — and rewrite the refusal hint so its stated remedy applies to every write it still refuses; `scripts/test-guard.sh` covers a permitted write outside the repository, an out-of-repository secret path still hard-denied, an unchanged refusal for an in-repository target outside `.agents/`, and a repository-relative target that resolves outside.
  - deps: —
  - covers: Driver mode refuses only writes that could reach a packet
  - arch: —
  - files: hooks/guard.sh, scripts/test-guard.sh
- [x] **T5** **P1** Give `skills/run-loop/SKILL.md` and `skills/resume/SKILL.md` one identical instruction for the session line — when `compact-threshold` reports a `SOURCE` of `gaffer-default` or `unknown` (the enumerated set naming no value in effect; only `unknown` survives T6, and naming both is what makes the suppression real in the interval between the two packets rather than only after T6), state no number and pass `--threshold unknown` to `driver-mode enter`, so the measurement reads unmeasured rather than flagging a threshold nothing enforces, while an operator- or repo-sourced value is still stated because the harness enforces it — and drop run-loop's request for `SOURCE` as a rendered field, since it becomes the condition and never a slot in the line; state the same omission in `templates/report-templates.md`'s shape C, whose worked example stops carrying a threshold number and shows the omission case instead, and which gains no source slot. Checkable by reading the two skills' instructions and the shape's example line together: all three either carry the clause or omit it.
  - deps: —
  - covers: The kickoff never states a compaction threshold that is not in effect
  - arch: —
  - files: skills/run-loop/SKILL.md, skills/resume/SKILL.md, templates/report-templates.md
- [x] **T6** **P1** Remove `GAFFER_DEFAULT_COMPACT_THRESHOLD` and the `gaffer-default` branch from `cmd_compact_threshold` in `scripts/runstate.sh`, that path instead reporting `THRESHOLD=unknown` with a `SOURCE` naming nothing in effect — ADR 0028 result 3 records `1m tokens` as the default *on Opus 5 (1M)*, model-conditional rather than harness-wide, and instructs this reader to report `unknown` rather than invent one — and retire the two sweep cases pinning the old 200000 (`scripts/test-runstate.sh`'s `compact-threshold` gaffer-default assertion and its digest `enter` fixture, `scripts/test-metrics.sh`'s null-together case) in favour of the unknown-source shape, adding no fourth field to the digest's `enter` record and leaving the operator and repo precedence paths unchanged; `scripts/metrics.sh` needs no edit — it already nulls a non-numeric threshold and forces `max_context` null with it — so `scripts/test-metrics.sh` gains a case asserting both `driver_mode_context` fields read null for an `unknown`-threshold `enter` record, pinning the third consumer rather than assuming it.
  - deps: T5
  - covers: The kickoff never states a compaction threshold that is not in effect
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, scripts/test-metrics.sh
- [x] **T7** **P1** Correct the stop report's counting rule in `templates/report-templates.md` so a handed-off packet contributes exactly one 🔀 — counting `handoff-feature` lines and only those `decision` lines with no `handoff-feature` line of their own — leaving the digest's two records untouched, and restate the tally as a table of contents: every glyph counted has a section beneath it and every section a glyph above it. Prose only, no sweep case; checkable against a run with one handed-off packet and one operator question, whose header must read two decisions above a body holding two decision blocks.
  - deps: —
  - covers: The stop report's decision tally matches the sections it indexes
  - arch: —
  - files: templates/report-templates.md
- [x] **T8** [P] **P1** Correct two statements in `CLAUDE.md` where the harness reads them as standing instruction: name shape A as covering every **ended** packet — failed, blocked and interrupted included — at `:760`, and give the ✅-counts-this-session rule at `:576`/`:604` the exception that supersedes it for the stop report, naming `templates/report-templates.md` as the authority and dropping its reference to a per-packet check-in the loop no longer produces. Prose only, no sweep case; checkable by reading each corrected sentence against the template section it now cites.
  - deps: —
  - covers: The standing instructions describe the loop that actually runs
  - arch: —
  - files: CLAUDE.md
- [x] **T9** **P1** Express the end-of-run whole-branch review's scope in `skills/run-loop/SKILL.md` §4 as **this run's integrated work** — a rule the driver applies when it builds the diff, bounded by the packet ids `run-digest` already prints and the `[orch packet:<id>]` trailers they carry, falling back to the integration branch's base only when the run landed nothing traceable — rather than everything the branch has accumulated since its base. Prose only, no sweep case and no new recorded field; checkable on the run that found this defect, where the rule must select 23 files rather than 211.
  - deps: —
  - covers: The standing instructions describe the loop that actually runs
  - arch: —
  - files: skills/run-loop/SKILL.md
- [x] **T10** **P1** Describe the digest as reading the routed status recorded for a hand-off, never result files it does not open, in both places that describe it — the `run-digest` header comment in `scripts/runstate.sh` and `templates/report-templates.md:24` — restating the parent's constraint unchanged and making the routing call's `--status` argument read as load-bearing, since a routing call omitting it leaves the hand-off line empty and the stop report silently loses the question. Prose only, no sweep case; checkable by reading the two descriptions and `cmd_run_digest`'s inputs together and confirming they name one mechanism.
  - deps: —
  - covers: The digest's documented mechanism is the one it uses
  - arch: —
  - files: scripts/runstate.sh, templates/report-templates.md
- [x] **T11** [P] **P2** Resolve the contradiction in the two context fields' null semantics where it actually survives — the two comment blocks in `scripts/metrics.sh` claiming both fields go null together, one of them contradicted by its own next sentence; `skills/metrics/SKILL.md` already reads "independently, not together" and needs no correction there, only the two additions below — then add to both copies one sentence naming why the digest takes the most recent `enter` record across sessions while the measurement takes the earliest in scope, and state the same-setting-on-re-entry claim as an assumption rather than a fact; neither consumer's record selection changes. Prose only, no sweep case; checkable by reading the defining sentence and the one after it in sequence, in both copies.
  - deps: —
  - covers: The measurement's nulls read unambiguously
  - arch: —
  - files: scripts/metrics.sh, skills/metrics/SKILL.md
