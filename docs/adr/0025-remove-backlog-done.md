# ADR 0025 — The gspec checkbox is the completion record; `backlog.done` is removed

- Status: Proposed
- Date: 2026-08-10
- Deciders: user (tech lead), orchestration plugin
- Amends: [ADR 0005](0005-crash-safe-resume.md) (the sequential run-state schema),
  [ADR 0020](0020-gspec-boundary-and-version-pin.md) D2 (extends "derived, never stored"
  from feature completion down to task completion),
  [ADR 0023](0023-report-conventions-delivered-not-referenced.md) (the header tally's ✅
  bucket is session-scoped, not run-cumulative)
- Relates to: [ADR 0012](0012-delegated-loop-driver.md) (what a relayed driver holds),
  [ADR 0016](0016-parallel-worktree-lanes.md) (the single-writer rule this reuses),
  [ADR 0019](0019-run-metrics-observability.md) v3–v3.4 (why a trailer scan is not a
  standing mechanism; `record-outcome`, the actual outcome record),
  [ADR 0024](0024-findings-are-packet-scoped-and-expire.md) (the sibling run-state
  cleanup; both migrate in the same skill pass).

## Context

### The principle already exists one level up

ADR 0020 D2 decided that **feature completion is derived from the PRD's capability
checkboxes and must never be stored**, and that `.agents/roadmap.yaml` carries planning
preference only. Task completion is the same shape one level down: `gspec/tasks/<slug>.md`
carries a checkbox per task, the adapter builds the backlog from the **unchecked** ones,
and that file is committed, cross-machine, human-readable and reviewable.

`backlog.done` is a stored copy of exactly that derivable state, in a gitignored file, in
a worse medium. It is the thing D2 forbids, one level down, and it was never justified —
it predates D2 and was simply never revisited.

### Three records, and the authoritative one is unmaintained

Auditing what actually records done-ness today turns up three mechanisms:

| Record | Committed? | Written by |
|---|---|---|
| `gspec/tasks/<slug>.md` checkboxes | yes | **nobody in the plugin** |
| `[orch packet:<id>]` commit trailers | yes | the loop, at packet commit |
| `backlog.done` | no (gitignored) | the loop, at packet close |

The first row is the finding. **The loop reads `gspec/tasks/` and never writes it** —
there is no instruction anywhere in `skills/`, `agents/` or `templates/` to flip a task
checkbox. Packet close appends to `done`, sets `last_green_commit`, advances `cursor`, and
calls `record-outcome`. Nothing more.

Yet the plugin *depends* on those boxes being flipped. `gspec-backlog.sh nodes` emits one
node per **unchecked** task, and `skills/resume/SKILL.md` leans on it explicitly: *"the
adapter already omits tasks that are checked off, so a task completed before the crash
will not reappear."*

In practice they are being flipped by hand, inconsistently, in two different shapes —
observed in the first consumer repo:

```
455151d feat(ai): the 90-day window becomes the only dial on transaction volume   <- flipped inside the packet commit
8dfa2af feat(ai): tell the owner the truth when a send fails after egress          <- same
df78d7d docs(spec): check off the redaction-provenance task                        <- a separate follow-up commit
2ae7d71 docs(spec): check off search-escaping task and file the sibling defect     <- same
```

A separate `docs(spec): check off …` commit is somebody noticing the gap and patching it
manually. That is the symptom this ADR fixes.

### Nothing reads `backlog.done`

Verified at HEAD (`64722c2`, v2.5.0):

| Where | What it does |
|---|---|
| `templates/run-state.yaml:68` | the schema comment |
| `skills/pause/SKILL.md:86,118` | describes what pause persists; the heredoc placeholder |
| `skills/resume/SKILL.md:90` | reads it as session-start context |
| `skills/resume/SKILL.md:120` | reconstruction: *"`backlog.done` = `DONE`"* |
| `skills/resume/SKILL.md:169` | orphan adoption **writes** it |
| `scripts/test-runstate.sh:75,232` | a fixture, and one assertion on the *git derivation* |
| `scripts/runstate.sh` `cmd_reconstruct` | does not read it; **rebuilds it from git trailers** |

`cmd_summary` counts `pending` and blocking severities. `reconcile` works off
`last_green_commit` plus trailers. `outcome` answers off `status`. No script consumes the
field.

### The cost is the rewrite surface, not the bytes

On the measured repo the field holds **95 entries in 4,409 bytes — 16% of a 27,400-byte
run-state**. But `runstate.sh write` **replaces** the whole file, so on every packet the
loop re-emits all 95 lines from the agent's memory. A list reproduced from memory once per
packet, forever, with no reader, no checksum and nothing that would notice a dropped line,
is a drift surface bought for nothing.

### No question anyone asks needs a stored count either

A first draft of this ADR proposed replacing the list with an integer `landed:` counter, on
the grounds that ADR 0023's header tally opens with `✅ **N landed**` and a relayed driver
has no other source. That took the template as ground truth instead of asking what the
number is for. Nothing acts on a run-cumulative landed count: a resuming session acts on
`cursor`/`pending`; metrics reconstructs from trailers and never reads run-state; the real
outcome record (including failed, rolled-back and abandoned work, which `done` never held)
is `record-outcome`. On a run alive for three weeks across several features, with a backlog
that **grows** as tasks are filed, `✅ 95 landed` is an odometer, not progress.

## Decision

### D1 — The gspec checkbox is the completion record, and the loop maintains it

At packet close, when the packet came from a gspec task, the loop flips that task's
checkbox from `[ ]` to `[x]` **in the packet commit itself**. The work and the record that
it happened land atomically, which is what makes the record trustworthy — a separate
follow-up commit can be lost, forgotten, or rolled back independently of the work.

Four constraints, each load-bearing:

- **Only the checkbox character changes.** Never the task text. gspec's immutability floor
  blocks edits to checked task lines, and rewriting one destroys the record of what was
  actually built (the same rule `/gaffer:migrate` obeys when it refuses to canonicalize
  legacy task lines).
- **The driver flips it, not the implementer.** `gspec/tasks/<slug>.md` is outside the
  packet's `allowed_files`; the implementer stays in scope and the orchestrator, which
  already stages and commits, makes the flip.
- **In parallel mode the scheduler flips at integration, not the lane.** Every packet in a
  feature shares one task file, so lanes flipping it concurrently would collide on
  serialize-merge — and ADR 0016 escalates real conflicts rather than auto-resolving them.
  The scheduler flips when it merges a green lane back. This is the same single-writer rule
  a lane already obeys for run-state (ADR 0022) and the same reason `record-outcome` *is*
  lane-callable: it writes append-only, outside the contended file.
- **gspec is optional (ADR 0020 D4).** A packet from a run-state backlog or an explicit
  argument has no checkbox; the step is conditional and its absence is not a failure.

This is the plugin's one write into `gspec/`, and the ADR 0020 seam holds: the plugin is
recording that a unit of work **executed** — its half — not deciding what to build or in
what order, which stays gspec's. Flipping the state of gspec's own tracking primitive is
the sanctioned mutation of that format, not authoring into it.

### D2 — Delete `backlog.done`. No counter, no tail, no replacement

```yaml
backlog:
  cursor: <next packet>
  pending:
    - …
```

With D1 in place this is not a trade-off — it is removing the second copy of a record that
now has a maintained, committed, cross-machine home.

### D3 — The tally's ✅ bucket is this session, everywhere

Amending ADR 0023. `templates/report-conventions.md` and both shapes state it:

- **✅** — what **this session** landed or shipped. The driver has rendered every check-in
  in the session and needs nothing on disk to count them. Shape B already behaves this way,
  paired with its `✅ Shipped` enumeration; shape A was simply never pinned down.
- **⚠️ / 🔀 / ⬚** — the forward state, from `pending` and `pending_questions`.

The "buckets must account for the whole backlog" rule applies to the **forward** buckets.
It was written against a progress bar collapsing *waiting on you* into *not started*, and
that concern lives entirely on the forward side. *2 landed, 25 to go* reads honestly, and
nobody parses it as a partition of a fixed set — which a growing backlog is not.

### D4 — `reconstruct` keeps `DONE=`, now explicitly informational

It stays because a human rebuilding a lost run-state wants the identities, and because it
is the fallback when a repo's commits carry no trailers. Its note gains one clause: no
field is populated from it any more. `skills/resume/SKILL.md:120` becomes *"`pending` = the
committed backlog minus `DONE`, in order"* — the same computation without the intermediate
storage.

This ADR deliberately puts **no** trailer scan on the check-in path. Three revisions of ADR
0019 are the reason: v3 fixed a scan reading 156 phantom packets over 17 days as one 3-hour
session; v3 then shipped an open upper bound that inflated 12 of 19 runs 2x–45x; v3.2 had
to cap the grace at the next session's first event. `reconstruct` runs once, for a human,
where a wrong count is visible and correctable.

### D5 — Five skill sites, not two

An earlier scoping called this change confined to the template, the pause heredoc and two
test lines. It is not: `skills/resume/SKILL.md` needs three edits (:90, :120, :169) and
`skills/pause/SKILL.md` two (:86, :118). The orphan-adoption site at :169 is the one that
matters — it is a **write**, and it becomes "remove the packet from `pending`" plus, if
the adopted commit did not already carry it, the D1 checkbox flip.

### D6 — No schema bump; migration is a deletion plus a reconciliation

Every reader is a grep, so a schema-3 file still carrying `done:` parses and the field is
ignored. No flag day.

`scripts/migrate.sh` gains a `FINDING=backlog-done` detection and, in `cmd_apply`, drops
the block. Before dropping it, `cmd_detect` **reports any id in `done` whose gspec task is
still unchecked** — the backlog of hand-flips that D1 will prevent going forward, and the
one piece of information the field holds that its replacement does not yet. Reconciling
those is a human decision (a task may be unchecked because the work was later reverted),
so `apply` reports and does not flip. `cmd_verify` asserts `done:` is gone.

## Consequences

- **One completion record, committed and cross-machine.** The identity of what landed
  survives a lost laptop, is reviewable in a PR, and is the same file the backlog is
  derived from — so the record and the thing it governs cannot drift apart.
- **The last unbudgeted growth field in run-state is gone.** `note:` has `trim-note`,
  findings get ADR 0024, and `done` had neither and no possible meaningful one — a byte cap
  on a list of ids truncates arbitrarily.
- **A per-packet drift surface disappears.** No agent reproduces a remembered list again.
- **`pending` survives, and should not be the next thing deleted by this logic.** It is not
  a copy of derivable state: it carries the *chosen order*, which is a real decision (in the
  measured repo the ordering is deliberate and annotated, and cross-feature packets appear
  in it that no single task file knows about). Derivable ordering and chosen ordering are
  different things.
- **A checkbox is not an outcome record.** It says a task's work landed; it says nothing
  about failed, rolled-back or abandoned attempts. That is `record-outcome` (ADR 0019
  v3.4), and neither the checkbox nor the deleted field should be described as an audit.
- **The plugin now writes into `gspec/`.** Small, bounded to one character on one line, and
  justified above — but it is a new seam crossing and the ADR 0020 boundary section should
  name it explicitly rather than leave it inferred. This raises **coupling**, not
  dependence: a format change on a read is a loud parse failure that
  `gspec-backlog.sh check` catches, while a format change on a write can corrupt a file the
  plugin does not own. The write is confined to the adapter's contract (`[ ]` → `[x]` on a
  task line) and must stay there.
- **D4's inventory of gspec-dependent surfaces was incomplete, and this corrects it.** It
  named two places — `run-loop` §2 and `build-packet-dependency-tree` §1. There was a third:
  the plugin *relied* on task checkboxes being flipped (the adapter emits one node per
  unchecked task; `skills/resume/SKILL.md` states the reliance in prose) and **nothing
  owned the flip**. An unowned assumption living in the optional half is invisible because
  nothing exercises it. Requiring gspec would not have caught this — the box still would not
  have been flipped. Naming the dependency and assigning it an owner is what catches it, and
  the standing lesson is that every cross-seam reliance needs an owner named in the ADR that
  creates it.
- **Non-gspec backlogs fall back to the trailers, and are not worse off.** A run-state or
  explicit-argument backlog has no checkbox, so after this change its only completion record
  is the `[orch packet:]` trailer — which is **committed and cross-machine**, against a
  `backlog.done` that was gitignored and same-machine. The loss is legibility (a scan rather
  than a read), and `reconstruct` already ships the scan.
- **The dependency should be self-verifying, not documented.** `run-loop` preflight, in a
  gspec repo, should report any `[orch packet:]` trailer naming a task that is still
  unchecked — the runtime form of D6's migration check. That turns the assumption D4 missed
  into something that fails loudly the next time it drifts.
- **One irreversible loss, stated plainly:** in a repo whose commits carry no
  `[orch packet:]` trailer *and* whose task boxes were never flipped, `done` was the only
  record those packets ran. `reconstruct` already reports that case as unrecoverable, and
  D6 is why `migrate` reports the mismatch before deleting rather than deleting silently.

## Alternatives considered

- **Leave the checkbox to the human and gspec's own tooling; delete `done` anyway.**
  Coherent — the checkbox is only *consumed* at backlog resolution, where a lag is harmless
  because the in-run forward state is `pending` and `reconstruct` uses trailers. Rejected
  because it leaves the authoritative record maintained by memory, and the separate
  `docs(spec): check off …` commits show that is already failing.
- **Replace the list with an integer `landed:` counter.** This ADR's own first draft.
  Rejected: no reader needs a run-cumulative landed count, and the one cited consumer — the
  header tally — was a template requirement mistaken for a real one. Worth naming because a
  counter would have been *cheap and harmless*, which is exactly how a field with no reader
  gets kept.
- **Flip the checkbox in a follow-up commit after the packet lands.** Non-atomic: the work
  can land and the record not, which is the failure already observable in the wild.
- **Have the implementer flip it as part of its packet.** Puts a file outside
  `allowed_files` into every packet's write scope, and in parallel mode makes every lane in
  a feature contend on one file.
- **Derive the count from `git log --grep` at render time.** Puts the plugin's most
  bug-prone mechanism on the path of every check-in, where a plausible wrong number is
  indistinguishable from a correct one.
- **Keep a bounded tail of the last N ids.** Still a list re-emitted from memory every
  packet, still drifts, `N` arbitrary, and it implies a recency guarantee nothing needs.
