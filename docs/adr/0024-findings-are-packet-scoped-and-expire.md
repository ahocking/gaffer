# ADR 0024 — Findings are packet-scoped and expire

- Status: Proposed
- Date: 2026-08-10
- Deciders: user (tech lead), orchestration plugin
- Amends: [ADR 0022](0022-findings-index-not-content.md) — its index-hot/body-cold split
  is retained unchanged; its retention model and its "durable and reviewable" framing are
  superseded.
- Relates to: [ADR 0005](0005-crash-safe-resume.md) (run-state is the durable memory),
  [ADR 0009](0009-single-directory-feature-branch-workflow.md) (run-state and findings are
  gitignored and same-machine),
  [ADR 0012](0012-delegated-loop-driver.md) (what a relayed coordinator re-reads at every
  dispatch), [ADR 0016](0016-parallel-worktree-lanes.md) (the single-writer rule a lane
  obeys), [ADR 0019](0019-run-metrics-observability.md) v3.4 (`trim-note`, `cc_shape`),
  [ADR 0020](0020-gspec-boundary-and-version-pin.md) (the seam that decides where a
  resolved finding goes).

## Context

ADR 0022 gave findings a home, a creation path (`add-finding`) and a read path
(`findings`). It never specified how a finding **ends**. Retention was left implicit at
*forever*, and the unbounded growth 0022 removed from `note:` reappeared one directory
over.

### Measured

On the first consumer repo to adopt 0022, three days after adoption:

| | |
|---|---|
| run-state total | **27,400 bytes** |
| findings index (hot — re-cached on every large turn) | **14,777 bytes — 54% of the file** |
| `backlog` block (95 `done:` entries + comments) | 9,356 bytes — 34% |
| `note:` (budgeted, enforced by `trim-note`) | 2,081 bytes — 8% |
| index entries | 29, of which **8 carry `packets:`** |
| bodies on disk (cold) | 1.3 MB; five ADR-0022 migration slices are **1.20 MB of it (87%)** |
| mean summary / mean body | **362 bytes / 6,789 bytes — 18.7x** |

The two fields 0022 budgeted are now the two smallest. The one it did not budget is the
largest. That is the whole finding.

### The defect is in the definition, not the discipline

The summaries are good. The carry-through discipline held — zero orphan bodies and zero
orphan index lines. What failed is that **nothing in the design could tell a live entry
from a dead one**, because the field that would say so was optional and therefore usually
absent. 21 of 29 entries name no packet at all.

`f-026` is the whole problem in one entry: it is one of only two entries still doing work
— it constrains `qac-t018`, which is still `pending` — and it carries **no `packets:`
field**. Its forward binding exists as prose in the summary and nowhere structured. Any
mechanical expiry rule would have deleted it; any rule cautious enough to keep it would
keep everything.

### "Run-wide" is not a scope

The entries with no packet were not under-specified findings. Sorted by what they are
actually about, none of them is scoped to the run:

- **environment** — web tests are Docker-only, never "repair" `node_modules` on the host
- **tool behaviour** — `reconcile` reads another session's pushed commits as crash scratch
- **agent behaviour** — verify a claimed artifact before relaying the claim
- **standing owner policy** — introducing a governed send is gated; hosting an existing
  one is not
- **spec-derived constraint** — an ADR binds readers to a derivation, not to its list

Every one outlives the run. None has an event that could ever end it. A finding with no
packet has no expiry, so permitting one is permitting unbounded growth — a `--run-wide`
flag would not bound anything, it would only label the unbounded part.

And "the run" is not a lifetime that exists. That consumer's run-state has been
continuously alive for three weeks across many sessions and several features, with no
moment at which its context is safely discarded. The lifetimes that are real here are
**a packet**, **a session**, and **forever** — and the schema already has a home for the
second (`note:`, one line, budgeted) and the third (the repo's own committed files).

### What 0022 got right, and the one line it should not have written

Index hot, body cold is correct and is retained in full. The framing to withdraw is
"`.agents/findings/` is **durable and reviewable**". It is not durable — the same ADR
concedes findings are same-machine and answers the objection with *"a finding worth
sharing across machines is not a finding; it is an ADR or a gspec item."* That answer is
right, and it is the entire argument for expiry: if the routing table already sends
durable things elsewhere, then everything remaining in `.agents/findings/` is by
definition transient. 0022 stopped one step short of drawing that conclusion.

## Decision

### D1 — The definition

> **A finding is a constraint on a packet that has not executed yet, recorded because
> there is nowhere permanent to put it until that packet runs.**

The reason there is no permanent home is usually structural rather than procrastination.
A rule like *"when deleting a bound, grep the number and its prose forms, not just the
constant name"* will live in the code — enforced by the three packets it binds. It cannot
live there yet because that code does not exist. The finding is scaffolding for a home a
future packet builds; when the packet lands, the rule is in the codebase and the finding
is a duplicate.

This names the three things 0022 left unnamed: the consumer (an unexecuted packet), the
reason it exists (no home until that packet runs), and the expiry (the packet lands).

### D2 — `packets:` is required; there is no run-wide finding

`add-finding` refuses without `--packets`. There is no `--run-wide` escape hatch, because
an entry that cannot expire is the thing this ADR exists to remove.

When an author has something to record and no packet to attach it to, it is one of three
things, and all three already have homes:

| What it is | Where it goes |
|---|---|
| A durable fact about the environment, the tools, the agents, or standing policy | The repo's `CLAUDE.md`, agent memory, or a comment at the site it constrains |
| An open question only the human can answer | `pending_questions:` — already schema'd, already carries `severity`, already surfaces in check-ins |
| Where this session stopped | `note:` — one line, already budgeted, already backstopped by `trim-note` |
| "this should be built/fixed" | **Backlog** — a gspec task, per the ADR 0020 seam. Unchanged from 0022. |

The refusal message names all four. This is the same move 0022 made with
`resolved_questions:` — an agent invents a field when the schema offers nowhere to put
something, so the fix is to point at the right place, not to widen the wrong one.

### D3 — Capture happens at resolution, by the session that resolves it

A finding has two terminal states: it is **captured somewhere permanent and dropped**, or
it is **dropped**. There is no archive directory, no tombstone, no `status: archived` —
moving a gitignored body into a gitignored subdirectory preserves nothing and creates a
folder nobody opens.

The capture is performed by the **live session at the moment of resolution**, not by a
later audit. This is not a preference; it is the only workable assignment. The session
that resolved the finding is holding the context that determines where it belongs. A
pruning pass three weeks later has to reconstruct that context from the body — one real
finding spends 2.6 KB of careful evidence to preserve a single instruction ("this
detector's warning is a false positive here; leave it"), which the session that wrote it
could have routed in ten seconds.

Consequently the plugin ships **no promotion receipts, no `promoted_to:` field, and no
`findings_routing` config**. Where a resolved finding goes is the consumer repo's
business (ADR 0020), the answer is obvious in the moment, and a routing table is a lookup
that will be ignored. Two corollaries worth stating because they are easy to get wrong:

- **Filing a gspec task *is* the capture.** When a finding causes a task to be filed, the
  knowledge is now in a committed, cross-machine task file. The finding dies at the moment
  of filing, not at the moment of landing.
- **An owner gate sign-off is not an ADR.** It is procedural approval in the moment: it
  gated an action, the action happened, the approval is spent. It expires with the packet
  it gated, like any other finding. Filing one per authorization would destroy the signal
  in `docs/adr/` — the same reason 0022 rejected an ADR per gotcha.

### D4 — `drop-finding` removes both halves, or neither

```
runstate.sh drop-finding <run-state-file> <id>
```

Removes the index entry **and** `rm`s the body, atomically (temp + rename). ADR 0022 has
zero orphans in either direction today precisely because deletion was impossible; that
property must survive the introduction of a destructive path, and the only way it does is
if one command owns both halves.

This must be a script for exactly the reason `add-finding` is one: splicing an item out of
a YAML list is the edit that reliably corrupts run-state, and run-state is the only state
that survives a session. Insertion dodged the problem by always writing immediately after
the `findings:` key. Deletion has no equivalent trick, so the mechanics are specified
rather than left to the implementer:

- Suppress the matching `  - id: <id>` line and its continuation lines **up to the next
  `  - id:` or the next column-0 key** — never to "the end of the list", which is the
  guess 0022 refused to make.
- Re-emit every surviving line **byte-verbatim**. Do not decode and re-quote a summary:
  the single-quoted encoding (`'' → '`) is lossless in one direction only when it is not
  round-tripped, and a re-quote introduces a corruption surface where there is currently
  none.
- Match the id **literally** (`grep -Fx` on the exact line), scoped to the findings block
  — the same two defects 0022's revision fixed in the duplicate check apply here.
- POSIX only, no `jq` — the stock Git Bash constraint `guard.sh` and `add-finding` are
  already built around.
- **A lane never calls it.** ADR 0016's single-writer rule is unchanged: a lane's worktree
  has no run-state. A lane reports in its check-in; the scheduler drops.

### D5 — The drop point is the packet boundary

The loop already stops at every packet close and already does commit → `record-outcome` →
run-state write → check-in. One bounded step joins it:

> For each finding naming this packet: is it now captured somewhere permanent, still
> needed by another packet, or spent? Drop the spent ones.

Bounded to that packet's findings — a couple of entries, not a sweep, and never an
LLM-judgment prune over the whole index inside the loop.

**Expiry requires positive evidence of completion, never absence.** A packet counts as
finished when its gspec task checkbox is checked (ADR 0025 D1) or, for a non-gspec
backlog, when an `[orch packet:<id>]` trailer names it. It does **not** count as finished
merely by being absent from `pending`: absence conflates *landed* with *never in this
run's backlog*, and the second is the normal state of a packet in a feature not yet
reached. In the measured repo, `iws-t002` sits in neither list and is described by a live
finding as a gate "not yet reachable" — an absence rule would drop that finding before its
packet ever ran. A packet that is neither checked, nor trailered, nor pending is
**unknown**, and unknown blocks expiry.

`findings --stale` lists entries naming no unfinished packet, with the blocking reference
where there is one. It surfaces as **one line** in the check-in when the index exceeds
`ORCH_FINDINGS_INDEX_MAX_BYTES` (default 4096). That is the same relationship `trim-note`
has to findings: a backstop for the days discipline slipped, not the intended path.

### D6 — The body is opt-in

`add-finding` currently always writes a stub carrying three headings. Hand an agent three
empty headings and it fills them: measured, **362-byte summaries against 6,789-byte
bodies, an 18.7x expansion generated by default** for content this ADR classifies as
transient.

The index entry alone is the default. `--body` creates the file, for the cases where
there is genuine evidence to preserve. The bodies that exist are not padding — they carry
line numbers, reproductions and re-verification commands — but they are written because
the stub asked for them, and most findings are fully carried by their summary.

### D7 — Migration is detection plus interactive triage; `apply` never deletes

`/gaffer:migrate` is where a repo is brought in line with the current plugin, so it is
where the existing findings backlog is drained. The split follows the plugin's standing
rule — deterministic core in the script, judgment in the skill prompt:

**`scripts/migrate.sh` (read-only).** A new `FINDING=findings` detection, and a new
`findings-audit <root>` subcommand that prints, per entry and without opening a body:
`ID`, `HAS_PACKETS=yes|no`, `LIVE=yes|no|unknown`, `SUMMARY_BYTES`, `BODY_BYTES`, plus run
totals `INDEX_BYTES=` and `BODY_BYTES=`.

`LIVE` follows the three-state rule above, not a two-state one: **`yes`** if a named packet
is in `cursor`/`pending`; **`no`** only if every named packet is positively finished
(checkbox checked, or a trailer names it); **`unknown`** otherwise — no `packets:` at all,
or a named packet that is neither pending nor demonstrably finished. `unknown` routes the
entry to a human instead of to a rule, and it is the honest answer far more often than a
two-state check would suggest.

**`cmd_apply` gains nothing.** `apply` is non-interactive and runs against a clean tree so
its result is one reviewable diff; it must not delete the only durable memory the run has.
The one mechanical exception is that legacy migration-residue bodies are *reported* with
their sizes, not removed.

**`skills/migrate/SKILL.md` §5 ("The parts no script can do") gains the triage.** One entry
at a time, per the plugin's interaction convention, applying D1 as the test — *does this
constrain a packet that has not executed yet?* Three outcomes: **drop** (`drop-finding`);
**capture then drop** (the human says where it goes, the session writes it there, then
drops); **keep and repair** (still live — add the missing `--packets` so it can expire on
its own next time).

Two things the triage should state up front, because they make the pass much shorter than
its entry count suggests: the ADR-0022 migration slices are mechanical deletions requiring
no judgment (in the measured repo, 1.20 MB of 1.3 MB, including a 692 KB verbatim copy of
a run-state that no longer exists), and entries whose packets are all in `done` with
nothing durable in them go as one batch rather than one at a time.

### No schema bump

`packets:` becoming required is a **write-side** constraint. Every reader is a grep, and an
entry without `packets:` still parses — it just reads as `LIVE=unknown`. So schema stays
**3**, migration is tolerant, and there is no flag day: new writes obey the rule, and
`/gaffer:migrate` drains what predates it.

## Consequences

- **The index becomes bounded by packets in flight, not packets ever run.** That is the
  property `note:` gained from `trim-note` and that findings never had. The bound is
  `|pending|`, not a constant — if findings routinely named packets deep in the backlog
  the index would track the backlog instead. Observed behaviour is that they cluster on
  the next few packets, but this is worth watching rather than assuming.
- **`packets:` stops being metadata and becomes the definition.** An entry without one is
  not an under-specified finding; it is not a finding.
- **Deletion is now possible, so the zero-orphan invariant becomes negotiable.** It was
  previously guaranteed by construction. What replaces the guarantee: one command owning
  both halves (D4), no lane able to call it (ADR 0016), and no unattended judgment prune
  in the loop (D5).
- **A guarantee becomes a discipline, and this is the real cost of the ADR.** Under 0022
  information could not be destroyed: omitting an index line **unlinked** a body, it never
  deleted one, which is why the measured repo has zero orphans in either direction and has
  never lost anything. The failure mode was *expensive*, not *gone*. This ADR trades that
  for boundedness. After it, a finding's content survives its packets only if the D3
  capture actually happened — and **nothing verifies that it did**. ADR 0022 named its
  prompt-enforced discipline as its fragile consequence; this ADR inherits the same
  fragility and attaches a destructive consequence to it. Three things narrow the exposure
  and none closes it: the drop happens at packet close while the session still holds the
  context, `drop-finding` is a deliberate act rather than an automatic sweep, and `unknown`
  blocks expiry rather than permitting it (D5).
- **The falsifier is blind to the way this fails.** `INDEX_BYTES` measures whether the
  index shrank, and an index that shrinks because entries are being dropped **without**
  being captured looks exactly like one that shrinks because the design worked — the
  failure is invisible in the metric and shows up months later as rework the finding
  existed to prevent. No counter can distinguish them, because the difference is whether a
  human wrote something down somewhere else. What can be watched instead is the ratio of
  drops to captures over a run, and whether `unknown` entries are being resolved or
  cleared: a run that drops many findings and files nothing is the shape to look for.
- **Durable knowledge stops accumulating in a same-machine file.** In the measured repo,
  nine entries — an environment constraint, a sync-loop hazard that caused a permanent
  outage and that 1,577 green tests missed, and five owner egress authorizations — existed
  only in a gitignored directory on one laptop. D2 refuses them at creation and names
  where they go instead.
- **Success is measured on `INDEX_BYTES`, not on `cc_shape`.** ADR 0022 named `cc_shape.max`
  as its detector and was right to, because its delta was ~42k tokens against a 198,397
  max — about 21%. This ADR's delta is roughly 2.7k tokens, ~1.4% of that max, and ADR 0019
  v3.4 measured aggregate cacheCreation spanning **1.76x across four untouched same-regime
  sessions**. `cc_shape` cannot see a change this size; claiming it as the falsifier would
  make a null result indistinguishable from success. The falsifiers are `INDEX_BYTES` from
  `findings-audit` and total run-state bytes, both deterministic and noise-free.

## Not in scope

- **`backlog.done`.** In the measured repo it is 95 entries inside a 9,356-byte block, it is
  derivable from the `[orch packet:]` trailers (`runstate.sh reconstruct` already ships the
  derivation), and nothing acts on it. Removing it is probably right and it is a **separate
  decision** — it touches the sequential schema, `skills/resume/SKILL.md` in three places,
  and `skills/pause/SKILL.md`, and bundling it here would make both harder to evaluate.
- **`note:` and `trim-note`.** With findings typed and expiring, `note:` is one line of
  current state and `trim-note` is close to dead code. Worth revisiting, not here.

## Alternatives considered

- **Typed kinds (`lesson` / `authorization` / `state`) with promotion receipts and a
  `findings_routing` config.** Rejected. It builds a taxonomy to answer a question the
  resolving session answers in one sentence, and its `authorization` tier rests on filing
  owner gate sign-offs into ADRs — which they are not: they are procedural approval in the
  moment, and one ADR per authorization would destroy the signal in `docs/adr/`. It also
  puts the routing decision in a config table read at audit time rather than in the session
  holding the context.
- **A `--run-wide` flag with a routing prompt.** Rejected on the analysis in Context: a
  run-wide finding has no expiry event, so the flag bounds nothing and becomes reflex.
  Every real instance turned out to belong in `CLAUDE.md`, `pending_questions:`, or `note:`.
- **Expire by wall-clock age.** Wrong across repos — a repo idle for six months has not
  gone stale.
- **Expire when the originating packet lands.** Deletes live constraints. Two of the
  measured repo's 29 entries were learned in a packet that has landed and bind packets that
  have not; those two are precisely the ones worth keeping.
- **Scan the body for packet-id-shaped tokens as a safety net for a missing `packets:`.**
  Rejected as a substitute for D2. The packet-id charset matches almost any lowercase word,
  so the useful version is intersecting the body against the *known* pending set — which is
  a workaround for an optional field, and making the field required is the fix.
- **Cap the index by entry count or bytes, evicting oldest.** Evicts by position, not
  relevance — 0022's own objection to `trim-note` as a substitute for findings.
- **Automatic pruning inside `migrate apply`.** Rejected: `apply` is non-interactive, and
  the material being deleted includes the only copy of things nobody has decided about yet.
