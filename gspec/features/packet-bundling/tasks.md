---
spec-version: v2
feature: packet-bundling
---

# Plan: packet-bundling

**Measurement lands first, alone, and ships on its own.** `scripts/metrics.sh`'s
trailer scan assigns `pk=v` per matching line, so a commit yields ONE packet row
however many trailers it carries — bundling without that fix makes the loop's own
cost numbers coarser exactly where this feature claims to make them better
(tokens per landed task is the success metric, and its denominator is packet
rows). It needs nothing else here, it is verifiable today against real history
(`8f236af` landed five tasks and reads as one row), and it is the only task that
improves a run recorded before this feature exists.

**The bundle's packet id IS its first member's node id.** Nothing in
`scripts/runstate.sh` learns what a bundle is: `route`, the attempt limit, the run
directory, `handoff`'s header, the result/review paths and `run-digest`'s `packet`
line all key on that one id and are untouched. That is what makes "the attempt
limit applies to the bundle, not to each task" true by construction rather than by
a second counter, and it is why only three mechanical widenings are needed
(T3) — the places where the loop now holds several ids for ONE boundary.

**The cap lands before the grouping, so grouping arrives inert.** With
`bundle_max_tasks` defaulting to 1, every group is the cursor task alone and every
step of §3 behaves exactly as it does today; raising the cap is the explicit act
that turns the feature on. That ordering also means the intermediate states of this
plan are safe: a repo running T4/T5/T6 with the shipped default never forms a
bundle, so no half-built landing path can lose work.

**The adapter groups mechanically; the DRIVER owns the tier.** Scope, deps,
consecutiveness and the cap are readable from the plan, so they belong in
`scripts/gspec-backlog.sh` — the only place this plugin reads `gspec/` (ADR 0020).
Tier is not in the plan: §3.3 decides it. So the design-heavy rule is enforced by
the driver **truncating** the group before any member it would judge design-heavy,
using the member titles `group` already printed — such a task never joins a group,
and when it arrives as a cursor its own design-heavy tier makes its group one task.
Both halves of the criterion, no tier judgement pushed into shell.

**Consecutive means consecutive among the UNCHECKED tasks.** A checked task is
done work that `nodes` does not emit at all, so one sitting between two unchecked
tasks does not break the run. `nodes` itself is untouched — the backlog is still
one node per unchecked task, and grouping is an execution-time decision, which is
the seam this feature is careful not to cross.

**Sibling rows of a multi-trailer commit share ONE boundary, and that must read as
unmeasured, never as zero.** The per-packet window is `(previous end, this end]`,
so for the second and later rows of one commit it collapses to zero width and every
derived count would read a real, honest 0 — indistinguishable from a packet that
genuinely did nothing. `metrics.sh` already has the right shape for this in its
`swept` treatment: carry the derived fields on the first row and emit `null` plus
an audit flag on the siblings. Reuse it; a second nulling shape is how the two
drift. Totals then count each row once and are unchanged, which is the PRD's fourth
criterion for free.

**`check-task` is NOT widened.** The plugin's only write into `gspec/` stays one id,
one character, one line; the loop calls it once per member in plan order and applies
the existing exit-code rules per member (`CHECKED=none` at exit 0 is skipped-not-
failed; exit 4 is drift that reports and never halts). Widening the one write
surface to a list to save four shell calls is the wrong trade in the one place this
repo has deliberately kept narrow.

**Every script task names its sweep case.** T1 → `scripts/test-metrics.sh`;
T2 and T3 → `scripts/test-runstate.sh`; T4 and T5 → `scripts/test-gspec-backlog.sh`.
T6 and T7 are prose read at dispatch, which no sweep can reach, so each names the
concrete read a reviewer performs instead of an assertion that pins wording.

**File contention, and why five tasks are `[P]`.** `scripts/metrics.sh` +
`test-metrics.sh` are T1 alone; `scripts/runstate.sh` + `test-runstate.sh` are T2
and T3; `scripts/gspec-backlog.sh` + `test-gspec-backlog.sh` are T4 and T5;
`skills/run-loop/SKILL.md` is T6 alone and `skills/resume/SKILL.md` is T7 alone.
**T1**, **T2**, **T4**, **T6** and **T7** hold file sets disjoint from each other,
so they carry the marker; T3 collides with T2 and T5 with T4, so neither takes it.
Deps are no bar — every one of them points strictly backwards in the plan order.

**`gspec-adapter-consistency` must not be in flight against T4 and T5.** It
refactors this adapter's shared pattern blocks and adds cases to the same sweep;
there is no logical dependency in either direction, but the two edit the same two
files. `loop-measurement`'s outcomes half has shipped, which is what T3 widens.

**Reflexivity.** `scripts/*.sh` take effect mid-run, in the run that edits them —
including T3, which changes the loop's own single writer for boundary records — so
a later task in the same run calls what an earlier one landed. `skills/run-loop/
SKILL.md` and `skills/resume/SKILL.md` are read when the command is invoked, so the
run that lands T6/T7 is still driving under the old prose: the first bundled run is
the next `/gaffer:run-loop`. **No task touches `hooks/hooks.json`, a settings file
that registers hooks, or any agent's or skill's FRONTMATTER, so no packet here owes
a `session_boundary` declaration.**

Every regression sweep must pass green after every task.

## Plan

- [x] **T1** [P] **P0** Change `scripts/metrics.sh`'s trailer-scan awk — the `pk=v` assignment in its `[orch packet:]` rule, whose single-value overwrite is why a commit yields one packet row however many trailers it carries — to accumulate every packet trailer on a commit in message order and emit one row per trailer, each carrying that commit's own author date and its `[orch tier:]`/`[orch impl:]` labels, with a deterministic ordinal so rows sharing one end time keep message order through the sort and per-id reduction below; a commit carrying exactly one trailer must produce byte-identical output to today, and because sibling rows share a single boundary their event window collapses to zero width, so the derived per-packet fields (`tool_calls`, `active_seconds`, `duration_ms`, `by_agent`, `by_tool`, `edits`, `by_command_class`, `failed_tool_calls`, `human_interactions`, `dispatched`, `tokens`) are carried on the FIRST row and emitted as `null` on every sibling with an `unmeasured:shared-packet-boundary` audit flag — reusing the existing `swept` nulling shape rather than inventing a second one, and never 0, which would read as measured-and-idle — leaving the run's totals counting each row exactly once and otherwise unchanged; add cases to `scripts/test-metrics.sh` over a synthetic two-trailer commit (one row per trailer, both labelled, siblings null and not zero, totals equal to the single-trailer fixture's) and a single-trailer commit asserting today's output unchanged, and verify against this repo's own history by re-collecting the run holding commit `8f236af`, which landed five tasks and reads as one row today.
  - deps: —
  - covers: Run metrics emit one packet row per trailer on a commit
  - arch: —
  - files: scripts/metrics.sh, scripts/test-metrics.sh
- [x] **T2** [P] **P0** Add a `bundle_max_tasks` reader to `scripts/runstate.sh` in the same token-scanning shape as `_rs_packet_attempts_limit` (skipping non-digit tokens so a trailing comment cannot defeat it, stripping one matching quote pair per token so `'4'` is not read as missing) plus a `bundle-cap` subcommand printing `CAP=<n>` the way `periodic-pause` prints `EVERY=`, reading `.agents/project-overrides.yaml` and returning **1** for a missing, invalid, zero or negative value so bundling is off until a repository raises it; document the setting in `templates/spec-driven-base/.agents/project-overrides.yaml` and, commented out, in this repo's own `.agents/project-overrides.yaml` beside `packet_attempts` and `pause_every_packets` and in their voice, naming a recommended starting value of **4** and the two costs of a larger one — a larger review diff, and more discarded work when a bundle ends non-green; add cases to `scripts/test-runstate.sh` for the default with no overrides file, a missing key, a quoted value, a value with a trailing comment, `0`, a non-numeric value, and a valid value read back.
  - deps: —
  - covers: Bundling is off until the repository raises the cap
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, .agents/project-overrides.yaml, templates/spec-driven-base/.agents/project-overrides.yaml
- [x] **T3** **P0** Accept a comma-joined packet-id list in `scripts/runstate.sh` at each of the three places the loop now holds several ids for ONE packet boundary — `record-start <id[,id...]> [--continue]` and `record-outcome <id[,id...]> <outcome>`, each writing one record per id sharing a single timestamp and session so a bundle's members cannot be ordered apart by accident, and `sweep-open --paused-cursor <id[,id...]>`, which today exempts only the first member and would close the rest of a live paused bundle as `interrupted`, the one outcome `loop-measurement` reserves for `sweep-open` alone — validating every id with `_rs_check_pkt_id` and refusing the whole call when any is malformed, so a boundary is never half-recorded; `route`'s attempt counting, `_rs_open_packets`, `record-outcome`'s refusal of `interrupted` and the record shapes themselves are untouched, and a single id must behave byte-identically to today; add cases to `scripts/test-runstate.sh` for a three-id start and a three-id continuation, a three-id terminal outcome, a malformed member refusing the whole call with nothing appended, a multi-member paused cursor leaving every member open while an unrelated open packet is still swept, and single-id compatibility on all three subcommands.
  - deps: —
  - covers: Every task in a bundle keeps its own record
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T4** [P] **P0** Add a `group <packet-id> [--cap <n>]` subcommand to `scripts/gspec-backlog.sh` that forms the bundle from the plan as it stands — the cursor task plus the unchecked tasks consecutive after it in plan order within that one feature, a checked task between two of them not breaking the run since `nodes` emits no node for it — admitting a task only when its declared file scope shares at least one file with the union of the scopes already in the group and every task it names in `deps:` is either earlier in the same group or already checked, and stopping at the cap (default 1, so the command arrives inert), at the first task that does not qualify, or at a task whose scope is empty and therefore overlaps nothing and runs alone; scope comes from `_nodes_for`'s existing `files:` > fingerprint-matched sidecar > empty precedence reused through that function rather than copied into a second reader, the output is `GROUP=<packet-id>`, one `MEMBER=<node-id><TAB><title>` line per member in plan order, `FILES=` the union scope and `STOP=<cap|scope|deps|end>`, and an id resolving to no plan or no task reuses `handoff`'s `HANDOFF=unknown` refusal shape; `nodes` and every other subcommand are untouched, because the backlog stays one node per unchecked task and grouping is an execution-time decision on gaffer's side of ADR 0020's seam; add cases to `scripts/test-gspec-backlog.sh` in both layouts the sweep already builds for a cap of 1 yielding exactly the cursor, three overlapping tasks grouping whole, a cap truncating mid-run with `STOP=cap`, a non-overlapping neighbour ending the group, an empty-scope cursor and an empty-scope neighbour each running alone, a task whose `deps:` names an unchecked task outside the group being excluded, a checked task between two members not breaking consecutiveness, and the group never crossing into the next feature.
  - deps: T2
  - covers: The loop groups consecutive same-scope tasks of one feature into a single packet
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
- [x] **T5** **P0** Extend `scripts/gspec-backlog.sh`'s `handoff` to accept a comma-joined list of packet ids and emit each task's existing block in plan order, unchanged and delimited so an implementer can tell one task's `TEXT=`, body, `FILES=`, `COVERS=` quotes and indented acceptance criteria from the next's, preceded by a `BUNDLE=<id,id,...>` line and a `BUNDLE_FILES=` union scope computed through the same `_nodes_for` precedence `group` uses so the two can never disagree about a packet's scope — both lines emitted only when more than one id is given, so a single id's output stays byte-identical to today and every existing caller is undisturbed — and refusing the whole call, naming the offending member, with the existing `HANDOFF=unknown`/`HANDOFF=refused` shapes when any member does not resolve, carries no task, or has already been routed `hand-off-feature` this run, and likewise refusing a list spanning two features (grouping across features is out of scope); `check-task` stays at exactly one id, the plugin's single write into `gspec/`; add cases to `scripts/test-gspec-backlog.sh` for a three-id bundle (every member's block present, in plan order, criteria intact, union scope correct), a single id unchanged byte for byte, an unresolvable member refusing the whole call with no partial output, a `hand-off-feature` member refusing, and a two-feature list refusing.
  - deps: T4
  - covers: A bundle is one unit of work for dispatch, review and routing
  - arch: —
  - files: scripts/gspec-backlog.sh, scripts/test-gspec-backlog.sh
- [x] **T6** [P] **P0** Rewrite `skills/run-loop/SKILL.md` §3.2 through §3.6 so the loop executes a bundle as one packet: at §3.3 read the cap with `runstate.sh bundle-cap`, form the group with `gspec-backlog.sh group <cursor> --cap <n>`, decide the tier as today and **truncate the group before any member after the first whose tier you would judge design-heavy** using the titles `group` just printed, a cursor you would judge design-heavy yielding a group of exactly one (so such a task never joins a group and never starts one), pipe `gspec-backlog.sh handoff <members>` into `runstate.sh handoff` unchanged, so the union scope reaches the implementer as T5's `BUNDLE_FILES=` line in the piped body rather than through any new flag on `runstate.sh handoff`, and judge the REQUIRED sweep and `session_boundary` lines against that union rather than the first task's scope, record one start for every member in a single `record-start` call, and pass every member to §3.2's `sweep-open --paused-cursor`; the bundle's packet id is its first member's node id, so the single dispatch, the single review, `route`, the attempt limit, the run directory and the result/review paths are unchanged, one `attempt` re-does the whole bundle, and a `discard-advance` stashes the bundle once, records `rolled-back` for every member in one call and advances the cursor past all of them so no part of a bundle lands on its own; at §3.6 flip each member's checkbox with its own `check-task` call in plan order, applying the existing exit-code rules per member and staging every touched plan file into the one commit, write one `[orch packet:<id>]` trailer per landed member on its own line beside the single `tier`/`impl` trailers, record `green` for every member in one call, advance the cursor past the whole bundle, and name the bundle in the shape-A report by its packet id and its members' plain-English titles; extend the same to §4's stop-report rendering, where `run-digest` emits one `packet` line per id whose title comes from the handoff's FIRST `TEXT=` line, so a landed bundle would otherwise read as one line under one member's title and the header tally would count `✅ 1` for four landed tasks — name a landed bundle there by its packet id and EVERY member's plain-English title, recovering membership from the commit's `[orch packet:]` trailers (the same read T7 gives the `adopt` path) and their titles from the bundle's own `handoff.md` per-member `TEXT=` lines, so a session that resumed or compacted can still name them; the tally still counts ONE packet per bundle, matching `run-digest`'s own line count and shape B's definition of the tally as every green packet of the run, with every member named on that packet's line rather than counted separately; `run-digest` stays untouched; a cap of 1 must leave every step in these subsections behaving exactly as it does today; prose only, no sweep case, checkable by reading §3.2–§3.6 and §4 with a cap of 1 for whether every step still reads as it does today, and by confirming every id-taking call in §3 and §4 (`sweep-open --paused-cursor`, `record-start`, `record-outcome`, `check-task`, the trailer block, the cursor advance and the stop report's own naming of a landed bundle) names the member list rather than the cursor alone.
  - deps: T1, T3, T4, T5
  - covers: A bundle is one unit of work for dispatch, review and routing · Every task in a bundle keeps its own record · The loop groups consecutive same-scope tasks of one feature into a single packet
  - arch: —
  - files: skills/run-loop/SKILL.md
- [x] **T7** [P] **P0** Carry the same bundle shape into `skills/resume/SKILL.md` so a run picked up in a fresh session recovers every task of a bundle rather than its first: re-form the cursor's group with `bundle-cap` and `group` before continuing it, so §4's `sweep-open --paused-cursor` exempts every member and `record-start --continue` records one continuation per member in a single call, and make the `adopt` path bundle-aware — read **every** `[orch packet:]` trailer on the orphan commit it adopts rather than matching the cursor's alone, `check-task` each one under the existing exit-code rules, record `green` for each in one call, and remove every adopted member from `pending` before advancing the cursor — so a crash between a bundled commit and the run-state write cannot leave four landed tasks unchecked and queued for re-execution; prose only, no sweep case, checkable by reading this file's continuation and adopt paths against `skills/run-loop/SKILL.md` §3.2, §3.3 and §3.6 for whether the two sites agree on how members are formed, exempted, continued and adopted, and by confirming no third place in either file still assumes one id per packet boundary.
  - deps: T6
  - covers: Every task in a bundle keeps its own record · A bundle is one unit of work for dispatch, review and routing
  - arch: —
  - files: skills/resume/SKILL.md
