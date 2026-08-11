---
spec-version: v1
depends_on: [run-metrics]
---

# Feature: loop-cost-controls

The orchestration loop spends most of its wall clock and most of its cache on
coordinating work rather than on doing it. This feature is the set of changes
that close that gap in the loop's own behaviour.

Every number below is **measured**, from one real run of this plugin against its
own backlog on 2026-08-10: 14,062s of wall clock (3h54m), 6 green packets, 818
tool calls of which 38 are unattributed to any packet, `failed_tool_calls=0`. That last figure
is not "no failures": the collector records a packet only via its green-commit
trailer, so failed or rolled-back packets are structurally absent from this
packet — the gap `metrics-coverage-gaps` names at P1. The run packet is tracked
at `docs/metrics/2026-08-10-loop-cost-baseline.json` with a rendered
`docs/metrics/2026-08-10-loop-cost-baseline.txt` beside it, so a later reader can
re-derive every claim here rather than take it on trust. That matters more than
usual in this repo: the standing rule is that **a frequency count is not a cost
measurement**, and a previous finding was retracted for exactly that confusion.
The figures below are cost measurements — cache-creation and cache-read tokens,
output tokens, wall-clock seconds — not counts of how often something happened.

The boundary against the two sibling metrics features is worth stating plainly,
because all three sit near the same evidence and a later reader will be tempted
to fold them together. `metrics-coverage-gaps` is about what the collector
**cannot see**. `metrics-tier2-compression` is about read and output **volume**.
This feature is about what the loop **does** — the behaviour the collector can
already see and that costs the run its time and its cache. Nothing here asks for
a new sensor except where an existing dimension cannot express a regression.

ADR 0020's seam holds throughout: gspec owns what to build and in what order,
this plugin owns how a unit of work is safely executed. All four capabilities
are squarely the plugin's half — dispatch behaviour, relay routing, tier
routing, and packet granularity are execution mechanism, not backlog content.

This feature also exists **because** of a mechanism accepted today. ADR 0026
routes findings discovered after a plan is fully checked to a new feature rather
than appending them to a completed one; these findings arrived that way, from a
run whose own plan was complete. This is the first use of that route.

One ordering constraint runs across the set: **the busy-wait fix must land
first.** Half the run's wall clock was spent in idle loops, and 7,819,592 of the
run's 8,180,248ms of tool duration sits in the coordinator's own context — so the
contamination is not only wall-clock, it reaches the coordinator's cache-creation
figure, which is the headline evidence for the relay capability. Re-measuring
before the fix lands buys a second number with the same defect as the first.

## Capabilities

- [ ] **P0**: No agent busy-waits on a dispatched subagent
  - 30 `until` shell loops consumed 7,135s — 51% of the run's entire wall clock — and produced no output at all; they were spinning rather than sleeping, since `sleep` was called twice for 4ms total across all **467 Bash calls** (`by_command_class` classifies Bash only). A dispatched Chief Engineer described the behaviour in its own check-in as "one of the idle-wait loops I used while blocking on subagents" — that check-in exists only in the run's session transcript and not in the repo, so it corroborates the command classes rather than being independently re-derivable from the run packet.
  - the prohibition belongs on the surfaces that dispatch (`agents/chief-engineer.md`, the `run-loop` skill), because a dispatching agent already receives its subagent's result on completion and has no reason to poll for it
  - testable today, with no threshold: a run's `by_command_class` carries no polling class attributed to an agent that dispatches
  - a regression stays detectable without new instrumentation, because the collector already classifies Bash by command head; the count at which polling becomes a regression is deferred below

- [ ] **P0**: The relay-versus-inline choice is re-measured on what actually costs, and the governing ADR amended
  - in this run the relay coordinator layer cost **63% of all cache creation** (3.18M of 5.04M) and **42% of all cache reads** (24.1M of 56.9M) to produce 20,415 output tokens, and was the only role in the run with any turns over 50k cacheCreation — 20 of them
  - that headline is contaminated at source: 7,819,592 of 8,180,248ms of tool duration sits in the coordinator's own context, so the busy-wait above ran **inside** the coordinator and inflated the very cache-creation figure being cited. This is a token-side contamination, not a wall-clock one, which is why it reaches the measurement at all.
  - the payload contrast ADR 0019 v3.4 designates for this question separates the roles more sharply than the share does: the coordinator's `cc_shape` max is 142,170 with 20 turns over 50k, against the reviewer's max of 33,484 with **none** — the reviewer is 12.8% of cache creation (642,021 of 5,035,030), so this is a standing-context *size* difference rather than a cheap agent; the implementer produced 17,514 output tokens on Sonnet
  - the re-measurement is a **two-arm A/B, inline and relay, spanning at least 20 packets**, run after the busy-wait fix lands, and ADR 0012 is amended with what it finds. This baseline cannot unseat the crossover on its own: it is a single relay arm over 6 packets with no inline comparator, ADR 0012's k≈21 is a pure token extrapolation whose wall-clock row is not an input, and relay was selected correctly here because the backlog included the 21-packet `run-state-cleanup`. "The crossover is a different number" and "the crossover is confirmed" are both legitimate recorded outcomes; **"relay is never worth it" is not** — no measurement below the crossover can license it, and the regime ADR 0012 rests on is the one a 6-packet run cannot observe.

- [ ] **P1**: The loop acts on the routing leak its own audit already detects
  - the collector flagged **4 of 6 packets, carrying 6 flags**, unprompted: `self-host-hardening-gaps-t1` and `run-state-cleanup-t1` both `waste:integration-tier-edited-inline-on-opus`; `self-host-hardening-gaps-t4` `suspect:design-heavy-label-with-2-review-rounds`; and `self-host-hardening-gaps-t5` three at once — `leak:orchestrator-edited-on-opus-without-delegating`, `label-contradiction:impl=delegated-but-no-implementer-dispatch`, and `waste:docs-tier-edited-inline-on-opus-not-doc-writer`
  - all six are in scope, `suspect:` and `label-contradiction:` included — the latter is this capability's own outcome restated as a flag, a packet labelled as delegating that dispatched no implementer
  - detection exists and is accurate; nothing consumes it, so the signal is produced and then discarded. The observable outcome is that a packet whose tier says delegate actually delegates, and that **no run ends with a routing flag that appears in nothing the human reads** — which surface carries it is deferred below.
  - this is the plugin's own stated routing policy — tier selects the agent, the agent's frontmatter selects the model — failing in practice, not a new policy being proposed

- [ ] **P2**: A packet's orchestration overhead is proportional to its work
  - summed tool duration runs 167s to 3,783s across the six packets, but that spread belongs to the busy-wait above, not here: the two packets with **zero** polling calls are the two shortest (`-t1` 0 calls / 166,926ms; `-t4` 0 / 446,981ms) while all four with polling are longer (2, 6, 9 and 13 calls). Net of polling, total tool duration is 1,045,582ms across the run — about 174s per packet.
  - the honest per-packet wall span is `active_seconds`, which runs 1,161s to 2,859s: a **2.5x** spread, not the 22.7x the tool-duration figure suggests
  - 2.5x across comparably-sized changes is still a real question, but this baseline does not establish it — like the relay measurement above, the granularity question is **pending re-measurement after the P0 busy-wait fix lands**: the post-fix `active_seconds` spread is recorded over at least the next six packets, and the result — a target ratio, or "within noise" — is written where the packet-scoping rule lives, so the answer lands somewhere the next scoping decision reads
  - this ranked below the three above once the busy-wait was found: it is real, and it is not the headline

## Deferred Decisions

- **Where the routing-audit signal surfaces.** The flags could reach a human through the loop's stop report, be recorded as a finding, or gate the packet at dispatch time. Deferred because the choice depends on whether the loop should refuse a mis-routed packet or merely report it, which is a policy call rather than a mechanism one.
- **The count of polling calls that makes a command class a regression.** The baseline gives one observation of the failing state and none of the healthy state, so any threshold set now would be picked from a single point. The presence check in the capability needs no threshold and does not wait on this.
- **Whether the packet-granularity fix changes packet scoping or packet execution.** Overhead proportional to work could come from batching small tasks at scope time or from cheaper per-packet execution; these have different blast radii, and the baseline's per-packet costs are contaminated by polling in a way that does not separate the fixed cost into its parts.
