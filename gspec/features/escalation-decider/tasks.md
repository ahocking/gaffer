---
spec-version: v2
feature: escalation-decider
---

# Plan: escalation-decider

**Mechanism first, prompt second, wiring third, documents last.** Every write the
decider makes is either a `runstate.sh` subcommand or an `architect` dispatch — it
gains no `Edit`/`Write` tool, exactly as `write-result` kept the reviewer and the
researcher read-only (ADR 0028). So the six new subcommands (T1–T7) land before the
agent prose that calls them (T8–T10), which lands before the driver prose that
dispatches it (T11–T12). A prompt that names a subcommand which does not exist yet is
the failure this order exists to prevent: the agent would improvise a shell write, and
a shell write into run-state is how the loop's only unrecoverable state gets corrupted.

**`reorder` stops being a question and becomes a write, and that changes what
`discard-advance` may do.** Today the driver treats `reorder` exactly like
`append-task`/`hand-off-feature` — stash, remove **every** member from `pending`,
advance — and surfaces the proposed order as a question. Under this feature the
decider has already rewritten `pending`, and the capability says the packet *can
proceed once other pending work lands*, so removing it would delete the very packet
the decision preserved. T11 is where that is corrected, and it is a driver-prose
change, not a `route` change: `route`'s token→action map is untouched
(`reorder` → `discard-advance` still), because the attempt limit and the mapping are
the one thing the decider deliberately does not re-implement.

**The decision log is a THIRD log, and the directory choice is load-bearing.** It
cannot live in `.agents/loop/<run_id>/` — `begin-run` prunes that to the current run
plus one — and it must not live in `.agents/metrics/outcomes/`, because
`_rs_open_packets` reads **any** record carrying `kind` as a packet start and a
decision record would reopen packets that never existed (the same trap ADR 0028
already names for driver-mode records). `.agents/metrics/decisions/<session>.jsonl`
is a new sibling of the driver-mode log, append-only, and gitignored with the rest of
`.agents/metrics/`.

**`run-digest` reads only the review records from that log, never the decision
records.** Every packet decision already produces a `routing.jsonl` line, because the
driver routes the token; the decider's own record of the same decision is for the
audit and the success metric. Emitting digest `decision` lines from both sources
would report every decision twice — that is T7's named mutation check, and it is the
most likely wrong implementation of the whole feature.

**`.agents/roadmap.yaml` is edited by an `architect` the decider dispatches, not by
the decider.** The capability puts a roadmap order change inside `reorder`, but the
decider holds no `Edit`, and a shell write into a YAML file the loop schedules from is
precisely the write surface `guard.sh` exists to keep behind a diff. The dispatch
pattern is already written for `append-task` (ADR 0026 arm 1) and T9 reuses it
verbatim rather than inventing a second one.

**Most of this plan is sequential, and the reason is file overlap, not logic.**
`scripts/runstate.sh` and `scripts/test-runstate.sh` carry T1–T7;
`agents/chief-engineer.md` carries T8, T9, T10 and T14; `skills/run-loop/SKILL.md` and
`agents/loop-driver.md` carry T11 and T12. Only **T13** and **T15** are `[P]`, and
each touches a file no other task in this plan touches. A task reading `deps: —` has
no logical prerequisite; it is not thereby safe to run beside its neighbours.

**Cross-feature overlap — `handoff-verification-contract` is being planned at the same
time and edits four of the same files.** T1–T7 (`scripts/runstate.sh`,
`scripts/test-runstate.sh`), T11–T12 (`skills/run-loop/SKILL.md`) and T15
(`CLAUDE.md`) must stay sequential with that feature's tasks; the two features have no dependency on each
other, only a write-scope collision. T4's `amend-handoff` is the sharpest of them —
it writes into a handoff file that feature is specifying a verification contract for —
so land one feature's handoff task clear of the other's rather than interleaving them.

**Reflexivity.** `scripts/runstate.sh` takes effect **mid-run, in the run that edits
it** — T1–T7 are live on the next tool call, so the run landing them can call the new
subcommands itself. `agents/*.md` and `skills/*/SKILL.md` are read at dispatch, so the
run landing T8–T12 is still driving under the interim stand-in and the first run under
the real decider is the next `/gaffer:run-loop`. `CLAUDE.md` is standing instruction
loaded at session start, so T15 reaches the harness next session. No agent file is
added and no hook registration changes, so no packet here needs `session_boundary`.

**Three capabilities exceed the ≤3-tasks-per-capability guideline, deliberately.**
"Each escalation gets exactly one next step", "The decider acts only within fixed
authority" and "A periodic review keeps the findings index small and honest" are each
a subsystem — a deterministic mechanism, an agent
contract, driver wiring and a reporting surface — and the alternative is fusing a
script change with skill prose into one unreviewable task. The guideline is advisory;
the right-sizing bar is not.

## Plan

- [x] **T1** **P0** Add `runstate.sh record-decision <run-state> <packet-id> <decision> --trigger <name> [--finding <id> --summary <text>]` and `record-review <run-state> --bytes-before <n> --bytes-after <n> --merged <n> --routed <n> --dropped <n>`, both appending one JSONL record to `.agents/metrics/decisions/<session>.jsonl` — a new log beside the driver-mode one, outside `.agents/loop/` where `begin-run`'s prune cannot reach it and outside `.agents/metrics/outcomes/` where a record carrying `kind` would be read as a packet start; `scripts/test-runstate.sh` gains a case asserting both records survive a later `begin-run` and that `sweep-open` and `run-digest` still report no open packet after them, which rules out writing them into the outcomes log, where `_rs_open_packets` reopens a packet that never existed and a swept `interrupted` outcome is then attributed to it.
  - deps: —
  - covers: The decider acts only within fixed authority · A periodic review keeps the findings index small and honest
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T2** **P1** Add `runstate.sh review-due` printing `NON_GREEN=`, `BEGINNINGS=`, `EVERY_NON_GREEN=`, `EVERY_BEGINNINGS=` and `DUE=yes|no`, counting failed/rolled-back/blocked/abandoned/interrupted outcome records and `kind: start` records (never a continuation) across every session's outcomes log since the latest `record-review` record — or since the repo's first start record when none exists — against `review_after_non_green_endings` (2) and `review_after_beginnings` (10) token-scanned from `.agents/project-overrides.yaml` in the `_rs_packet_attempts_limit` shape so a quoted or comment-trailed value is honoured and a missing or invalid one falls back, and document both keys in `templates/spec-driven-base/.agents/project-overrides.yaml`; `scripts/test-runstate.sh` gains cases for a continuation that must not raise `BEGINNINGS`, a count that resets only at a recorded review, and an unreadable outcomes directory reporting `unmeasured` with `DUE=yes`, the last ruling out reporting `0`, which reads as "nothing has happened since the last review" and suppresses every review for the rest of the run.
  - deps: T1
  - covers: A periodic review keeps the findings index small and honest
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh, templates/spec-driven-base/.agents/project-overrides.yaml
- [x] **T3** **P0** Add `runstate.sh reorder-pending <run-state> <id[,id...]>`, which replaces `backlog.pending` with the given order through the same validated whole-file write `cmd_write` already guards (never `set`, which refuses a key nested under `backlog:` and would otherwise append a second column-0 `pending:` nothing reads), refusing an empty list or a repeated id and printing which ids it added and removed; `scripts/test-runstate.sh` gains a case asserting the file still parses as YAML with `cursor` and `findings:` intact, ruling out an append that leaves two `pending:` keys and two sources of truth.
  - deps: —
  - covers: The decider acts only within fixed authority
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T4** **P0** Add `runstate.sh amend-handoff <run-state> <packet-id>`, which reads replacement text on stdin into one marked decider block in that packet's `handoff.md`, refusing lexically any path outside the current run directory exactly as `write-result` does; `scripts/test-runstate.sh` gains a case asserting `run-digest` still prints exactly one `packet` line carrying the original title, which rules out a rewrite that loses the `# <pkt>: <title>` first line the digest parses. This is the one task that writes into the handoff file `handoff-verification-contract` is putting a contract on: land it clear of that feature's handoff tasks.
  - deps: —
  - covers: The decider acts only within fixed authority
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [x] **T5** **P1** Add `runstate.sh merge-findings <run-state> <survivor-id> <removed-id>`, which unions the two entries' `packets:` lists, appends the removed entry's summary and the whole of its body to the survivor's body file — creating that body and the entry's `file:` pointer when the survivor had none — and only then drops the removed entry and its body, both-or-neither exactly as `drop-finding` sequences it; `scripts/test-runstate.sh` gains a case asserting every line of the removed body and its summary appear in the survivor's body and that both entries' packets appear in the survivor's `packets:`, which rules out a merge that copies only the summary before deleting the body — the one failure that makes a lossless merge lossy while every visible count still looks right.
  - deps: —
  - covers: A periodic review keeps the findings index small and honest
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [ ] **T6** **P1** Cap the index summary in `cmd_add_finding` at 160 characters counted after the existing newline collapse, shortening a longer one on a character boundary with a visible mark, writing the full text to `.agents/findings/<id>.md` and pointing the entry at it with `file:` even when `--body` was not passed, and never rejecting the call for length; `scripts/test-runstate.sh` gains cases for a 161-character summary, one whose cut falls inside a multi-byte character, and a `--body`-less call — asserting the entry is within the cap, the file still parses, and the body holds the full text — the multi-byte case ruling out a byte-count truncation that splits a character and writes a line the decoder cannot read back, and the `--body`-less case ruling out a cap that silently discards the text it removed.
  - deps: —
  - covers: Finding summaries stay within 160 characters
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [ ] **T7** **P0** Give `run-digest` a `review` line carrying a completed review's merged, routed and dropped counts and its index bytes before and after, plus a `decision` line per review routing, both read from `.agents/metrics/decisions/` and `--since`-scoped the way the existing decision lines are, and make `run-tally` count a review's routings as decisions while its merges and drops stay counts; `scripts/test-runstate.sh` gains a case asserting a run with one routed reviewer verdict and one recorded review reports that packet decision exactly once, which rules out emitting a digest `decision` line for every record in the decision log — every packet decision would then appear twice, once from `routing.jsonl` and once from the decider's own audit record, and the stop report's 🔀 tally would double.
  - deps: T1
  - covers: The decider acts only within fixed authority
  - arch: —
  - files: scripts/runstate.sh, scripts/test-runstate.sh
- [ ] **T8** **P0** Replace the `## Escalation decider (interim stand-in for \`escalation-decider\`)` section of `agents/chief-engineer.md` with the decider's own contract: the bounded read set (this packet's handoff file, its result files, the findings naming this packet with their bodies, `escalate_to_human_on` in `.agents/project-overrides.yaml`, the backlog's PRDs and plans and `.agents/roadmap.yaml`, and no other packet's handoff or result file), the five triggers written so each excludes the others, the precedence `ask-operator` → `hand-off-feature` → `append-task` → `reorder` → `retry` when more than one fits, the gspec-only condition on the two arm decisions, and the one status line naming the packet and exactly one decision with the trigger that fired and the reasoning written to its result file. Prose only, no sweep case; checkable by reading the section against the PRD's trigger list — each of the five names a test, the five appear in the precedence order exactly once, and no trigger is stated as a judgement call except `ask-operator`'s own catch-all.
  - deps: —
  - covers: Each escalation gets exactly one next step
  - arch: —
  - files: agents/chief-engineer.md
- [ ] **T9** **P0** State the decider's authority in the same section as the exact calls it makes: `reorder` → `reorder-pending`, plus the `.agents/roadmap.yaml` order when the new order crosses features, written by an `architect` it dispatches because it holds no `Edit`; `append-task` → that same `architect` dispatch appending one unchecked task with a truthful `covers:`, committed on its own paths with the `[orch decider:<packet-id>]` trailer, then `reorder-pending` putting it ahead of the packet; `retry` → `amend-handoff` carrying the change and naming it in the result file — each followed by `add-finding` naming the packet and `record-decision`, all before the status line returns — together with `ask-operator` stopping on a blocking question naming the matched entry or the options it could not choose between, `hand-off-feature` recording a question naming what `/gspec-feature` should be run with and not stopping the run, the never-list (never edit a checked task or a capability checkbox, never record an outcome, never make a packet abandoned), and the two timing rules (a result file with no returned status line is not a decision, and a change already on disk from that decider is recorded as a finding at the packet's next escalation and not repeated; a pause lands before dispatch or after the decision is carried out and recorded, never between). Prose only, no sweep case; checkable by reading each of the five decisions against the subcommands T1, T3 and T4 added — every write the section asks for resolves to a call that exists.
  - deps: T1, T3, T4, T8
  - covers: The decider acts only within fixed authority
  - arch: —
  - files: agents/chief-engineer.md
- [ ] **T10** **P1** Add the periodic-review section to `agents/chief-engineer.md`: what a review reads (the outcomes log and the findings index, nothing else), the merge rule carried out through `merge-findings` so both bodies and the removed summary survive in the surviving entry, the routing rule — a finding saying something should be built into gspec goes through `append-task` or `hand-off-feature` under the triggers and authority above, leaving pending order unchanged and naming the routed finding's packets, then is dropped as ADR 0024's capture, while any other finding is dropped only on ADR 0024's positive evidence — and the close: one status line, every merge, routing and drop written to the result file, and `record-review` carrying the index bytes before and after. Prose only, no sweep case; checkable by confirming every write the section asks for is a `runstate.sh` call and no step asks the decider to edit a body or the index directly.
  - deps: T1, T2, T5, T6, T9
  - covers: A periodic review keeps the findings index small and honest
  - arch: —
  - files: agents/chief-engineer.md
- [ ] **T11** **P0** Rewrite the `ACTION=decider` and `ACTION=discard-advance` entries in `skills/run-loop/SKILL.md` §3.5 and `agents/loop-driver.md` §Routing in the same words: the driver dispatches the decider as the decider rather than an interim stand-in, with the handoff path, the review path and the `ATTEMPTS=`/`LIMIT=` the `route` call printed and nothing else, and a `discard-advance` reached by a `reorder` token stashes, records `rolled-back` and sets the cursor to whatever is now first in `pending` **without removing any member**, since the decider's `reorder-pending` has already placed them — the removal and the proposed-order-as-a-question both go, while `append-task` and `hand-off-feature` keep today's removal exactly. Prose only, no sweep case; checkable against a `reorder`ed packet: it is still in `pending`, it is not the cursor, and the stop report carries no question proposing an order that has already been applied.
  - deps: T3, T8, T9
  - covers: Each escalation gets exactly one next step · The decider acts only within fixed authority
  - arch: —
  - files: skills/run-loop/SKILL.md, agents/loop-driver.md
- [ ] **T12** **P1** State the periodic review at the one boundary it may run at, in `skills/run-loop/SKILL.md` §3.8 beside the existing `periodic-pause` check and in `agents/loop-driver.md` in the same words: between packets and never while one is open, run `review-due`, and on `DUE=yes` — including when a count reads `unmeasured` — dispatch the decider for a review with the run-state path and nothing else, read its one status line, record nothing yourself, and carry both counts into the next report. Prose only, no sweep case; checkable by reading the two call sites together — both state the same trigger, the same dispatch and the same `unmeasured`-still-runs rule, and neither sits inside the packet loop's body.
  - deps: T2, T10, T11
  - covers: A periodic review keeps the findings index small and honest
  - arch: —
  - files: skills/run-loop/SKILL.md, agents/loop-driver.md
- [ ] **T13** [P] **P1** Teach the two template surfaces the decider's output lands in: `templates/report-templates.md` gains the rendering rule for `run-digest`'s `review` line — a review's routings render as decision lines naming the routed finding by id and summary and its packets by id and plain-English title, while its merges and drops render as counts and never as 🔀 — and `templates/status-line.md` stops calling the decider a stand-in and names the review's own status word beside the five decisions. Prose only, no sweep case; checkable against a run holding one review with one routing, two merges and one drop: the header tally counts one decision, the body renders one decision block, and the merges and drops appear only as numbers.
  - deps: T7, T12
  - covers: The decider acts only within fixed authority · Each escalation gets exactly one next step
  - arch: —
  - files: templates/report-templates.md, templates/status-line.md
- [ ] **T14** **P1** Slim the rest of `agents/chief-engineer.md` to the decider's role, removing only material no shipped surface still uses and keeping everything the skills, templates and sweeps that dispatch it outside a loop packet rely on — `skills/review-change/SKILL.md`, `skills/new-project/SKILL.md`, `templates/check-in.md`'s wire format, `scripts/test-report-conventions.sh` — along with the concurrent-editing rule `retire-unused-loop-modes` left in place; and correct `README.md`'s agent table entry and its stand-in paragraph so both name the decider rather than a stand-in that ships later. Prose only, no sweep case; checkable by grepping `chief-engineer` and `stand-in` across the repo and confirming every reference still names something the file carries and none says the decider does not exist yet, with `scripts/test-report-conventions.sh` and `scripts/test-routing.sh` green afterwards.
  - deps: T8, T9, T10
  - covers: Each escalation gets exactly one next step
  - arch: —
  - files: agents/chief-engineer.md, README.md
- [ ] **T15** [P] **P1** Record the decision where it is read as standing instruction and where it is read as history: `CLAUDE.md`'s driver-mode bullet stops describing `chief-engineer` as an interim stand-in and states the decider's precedence, its authority and the new decision log's location and reason; ADR 0024 is amended — dated and marked, never rewritten — so its rule against an unattended judgment prune of the index inside the loop admits a periodic review's merges under the lossless `merge-findings` mechanism; and ADR 0028's "the escalation decider does not exist yet" paragraph is superseded in place with what replaced it. Prose only, no sweep case; checkable by reading each amended paragraph against the behaviour that shipped — no sentence describes a stand-in, and ADR 0024's amendment names what changed and what it does not license.
  - deps: T12, T14
  - covers: The decider acts only within fixed authority · A periodic review keeps the findings index small and honest
  - arch: —
  - files: CLAUDE.md, docs/adr/0024-findings-are-packet-scoped-and-expire.md, docs/adr/0028-loop-driver-mode.md
