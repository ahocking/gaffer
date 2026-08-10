# ADR 0012 — Delegated loop driver: the session that runs the loop is a relay, not the driver

- Status: Accepted
- Date: 2026-07-16
- Deciders: user (tech lead), orchestration plugin
- Amends: [ADR 0004](0004-graduated-autonomy-and-pausable-loop.md). The autonomy
  levels, the hard/soft gate split, the pause/resume contract, and the check-in
  shapes are all unchanged. What changes is **which context executes the loop**:
  0004 tacitly assumed the session reading the skill also does the work. It does
  not any more.
- Builds on [ADR 0005](0005-crash-safe-resume.md): the per-packet dispatch
  boundary is deliberately placed on the existing crash boundary, so a fresh
  Chief Engineer per packet is the already-tested resume path rather than a new
  mechanism.
- Constrained by the plugin's standing frontend-agnostic rule: it produces
  check-ins and builds **no notification transport**. That rules out the
  otherwise-obvious progress designs — see Rejected alternatives.

## Context

`/gaffer:run-loop` and `/gaffer:resume` both say *"The **Chief
Engineer** runs this."* That sentence is ambiguous, and a session resolves it the
lazy way: *I am the Chief Engineer, so I will run it here.* The loop then executes
in the main session, and every packet's implement → test → review transcript —
diffs, build output, test logs, review findings — accumulates in the one context
that has to survive the whole run.

This is exactly backwards for the loop's purpose. The loop is built for long,
semi-attended, multi-packet runs (ADR 0004); the context that must last longest
is the one being filled with the most disposable material. The user's existing
workaround is to type "defer to agents" alongside the skill invocation, which
makes the session dispatch a `chief-engineer` subagent that then spawns its own
specialists. That works, and it keeps the main window small. It is undiscoverable,
unenforced, and easy to forget — which is the whole defect this ADR closes.

### What the loop actually needs from the main session

Very little. Per packet, the session needs to know: did it land, what is the next
cursor, and is anyone blocked. That is precisely the **status check-in** already
specified in `templates/check-in.md` — about six lines. Everything else the loop
touches (the packet, the diff, the test output, the review) is material the Chief
Engineer needs and the driving session does not.

## Empirical findings

Established by direct dispatch against this harness (Claude Desktop 2.1.209)
before the design was fixed. Recorded because two of them contradict what the
repo currently asserts, and one of them is load-bearing for the brief's shape.

1. **Nesting works.** main → `gaffer:chief-engineer` →
   `gaffer:researcher` completed with no error, and an explicit
   `model: sonnet` override on the inner dispatch was honored — so the per-role
   model tiering `run-loop` §2.3 demands survives a level of nesting. The inner
   agent burned 14k tokens; the dispatching context saw only its one-sentence
   return. That ratio is the entire point of this ADR, measured rather than
   assumed.
2. **`Task` in agent frontmatter is what grants delegation; it maps to a tool
   actually named `Agent`.** The `chief-engineer` declares `Task` and holds
   `Agent`. **Do not "correct" that line to `Agent`** — the name that works is the
   one that looks wrong, and whether `Agent` is even accepted in frontmatter is
   untested. This was very nearly changed on the false premise below.
3. **The `tools:` allowlist is enforced, and there is no delegation-based
   privilege escalation.** The read-only `reviewer` (declaring
   `Read, Grep, Glob, Bash`) holds exactly `Read` and `Bash` — **no delegation
   tool at all**. It cannot spawn an implementer to write on its behalf. An
   earlier reading of finding 1 — that `Agent` is handed out irrespective of the
   allowlist — was **wrong**, and is recorded here so it is not re-derived: the CE
   has `Agent` *because it declares `Task`*, not in spite of declaring nothing.
4. **A dispatched Chief Engineer has no `Skill` tool.** Its full list is
   `Read, Bash, Agent, WebSearch, WebFetch`. It therefore **cannot invoke
   `/gaffer:run-loop`** the way a human-facing session can. A brief that
   names the skill without giving its path silently produces a CE that improvises
   the loop from memory. The dispatch brief **must** point at
   `${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md` as a file to `Read`.
5. **`Grep`, `Glob`, and `TodoWrite` are declared across the agent files but do
   not exist in this harness** (search runs through `Bash`); they are silently
   dropped. Harmless — nothing depends on them — but the frontmatter is partly
   fiction. Out of scope here; flagged for a cleanup pass.

## Decision

**The loop picks its execution mode from the backlog size: inline below 20
packets, relay at 20 or more. The threshold is the measured crossover, not a
preference.** `--inline` / `--relay` override it explicitly.

Neither mode is right in general, which is why this is not a default:

- **< 20 packets → inline** (the session runs §1–§2 itself). The relay costs ~29%
  more tokens and ~40% more wall clock here and prevents nothing — the coordinator
  never approaches the window.
- **≥ 20 packets → relay** (a fresh Chief Engineer per packet; the session relays
  check-ins). Past the crossover the relay is *both* cheaper and the only mode that
  finishes: inline's coordinator hits a forced compaction near packet ~28 and loses
  its own thread.

Counting **remaining** packets, not the run's original size, is what makes this
correct on resume: a 40-packet run with 4 left is a small backlog now.

### 0. Why a threshold rather than a default

The first draft of this ADR made the relay unconditional, on the intuition that a
growing main context is resent every request and must therefore be the dominant
cost. Measurement refuted it (see Measurement): with prompt caching a resend bills
at ~0.10×, and — the real surprise — the inline coordinator only grows ~6.7k per
packet, because the loop **already** delegates the expensive work and keeps only
compact returns. The context this ADR set out to shrink was not the problem it
was assumed to be.

Surveying the real consumer repos then refuted the opposite conclusion. Live
run-state backlogs: **a small repo 7 packets, a mid-size repo 33, a large repo 52**;
the small repo's
per-feature task breakdowns run 9–54 (median ~16). Both regimes occur routinely in
the same workflow, and the gap between them is large in both directions — at 52
packets the relay is ~50% *cheaper*, at 7 it is ~29% *more expensive*. A fixed
choice is wrong roughly half the time, and a manual flag is wrong precisely when it
is forgotten, which is on the long runs where forgetting costs the most.

### 1. The relay contract (when the threshold selects it)

Per packet, the driving session:

1. reads the run's shape from disk — `runstate.sh summary`, a few lines — never by
   opening the repo;
2. dispatches a **fresh** `gaffer:chief-engineer` whose brief carries only
   the repo root, the autonomy level, the run-state path, the cursor packet id,
   the skill's **file path** (finding 4), and the instruction to execute **exactly
   one packet** and return **only** its check-in;
3. **renders** that check-in into the human check-in shape
   (`templates/report-templates.md`, named `human-report.md` when this ADR was
   written — renamed in [ADR 0023](0023-report-conventions-delivered-not-referenced.md),
   which also moved the conventions out to `templates/report-conventions.md`) — see
   the amendment below;
4. re-reads `status` / `cursor` from run-state, and either dispatches the next
   packet or stops.

The relay does not read diffs, test output, or source; does not re-derive or
verify a check-in; and does not answer a blocking question on the human's behalf —
it surfaces it and waits, then carries the human's answer into the next brief.

**Amendment (2026-08-07) — "relays verbatim" became "renders".** Step 3 originally
said the driver relays the check-in verbatim and does not summarize it. The
prohibition it was reaching for is *going back to disk*: re-opening the repo, the
diff, or the test output to enrich a check-in is what refills the relay's context and
erases the whole benefit, and that prohibition stands unchanged. Rendering the
returned text into the human-facing shape is a **bounded transform of text already in
context** — it reads nothing, costs a few hundred tokens once per packet, and does
not grow with the backlog, so the relay's flat per-packet floor is unaffected. The
verbatim rule was never load-bearing for cost; it was a proxy for "don't go looking."
The wire check-in (`templates/check-in.md`) is unchanged and is still what the
scheduler parses — only the human-facing layer differs.

### 2. One packet per dispatch — this is what buys the progress reporting

A subagent returns nothing until it finishes. A single long-running Chief Engineer
driving the whole backlog is therefore a **black box for the duration of the run**:
no check-in reaches the human until the last packet lands. Dispatching per packet
makes each check-in surface the moment its packet lands, using no transport beyond
the subagent's own return value — which is the only progress mechanism available
that builds no notification transport.

It is also mechanically cheap to *build*, because `.agents/run-state.yaml` is
*already* the durable memory designed to survive session death (ADR 0004/0005). A
fresh CE rehydrating from run-state at a packet boundary is not a new mechanism —
it is `resume`, which is already specified, already tested, and already exercised
on every crash. The dispatch boundary is placed exactly on the existing crash
boundary, so the two recovery stories stay one story.

It is **not** cheap in tokens. Rehydration costs roughly 40k effective input-token
equivalents per packet, and below ~20 packets this ADR **costs more than it saves**
— see Measurement. That is a deliberate trade for window durability, not a
performance win, and must not be sold as one.

### 3. The durable invariant

> **The driving session's context grows with the number of check-ins, not with
> the amount of work.**

Roughly six lines per packet, whatever the packet costs. Any future change here
must preserve that. A design that routes a diff, a test log, or a review finding
through the relay breaks it — that is the test to apply, not "does it feel
delegated."

### 4. Escape hatch

`--inline` on either skill runs the loop in the driving session, as today. For
debugging the loop itself, and for a harness where nesting is unavailable.

### 5. Fallback

If a dispatched CE cannot spawn (a harness without nesting — ADR 0007 parity), it
does the packet's work in its **own** context and still returns just the check-in.
Degraded, but the invariant holds: the relay's context is unaffected either way.

## Measurement

Measured, not modeled — because the intuition that motivated this ADR ("a growing
main context is resent every request, so isolating it must save tokens") is
**wrong at realistic backlog sizes**, and the ADR should say so where a reader
will hit it.

Method: the same 3-packet backlog (add `subtract`/`multiply`/`divide` to a toy
module, unit-tested) run twice through real dispatches — **Arm A** one Chief
Engineer context carrying all 3 packets, **Arm B** three fresh CE contexts, one
per packet. Both delegated a `sonnet` implementer and reviewer per packet, so the
worker cost is common and cancels (Arm A 94.8k vs Arm B 88.4k effective — within
noise). Both arms landed all 3 packets green. Totals come from each agent's
transcript, deduplicated by message id, priced as **effective input-token
equivalents**: `fresh + 1.25 × cache_write + 0.10 × cache_read`. Deviation: the
commit + run-state write was skipped in both arms (the guard's config-root walk
starts at the session cwd, so a scratch repo's `.agents/autonomy` is never
discovered and every commit would deny at `interactive`).

| 3 packets | inline | relay | delta |
|---|---|---|---|
| coordinator only | 68,211 | 122,228 | **+79%** |
| whole run (incl. workers) | 163,027 | 210,677 | **+29%** |
| wall clock | 200s | 285s | +43% |

The two parameters that decide it, both measured:

- **The inline coordinator grows by only ~6.7k tokens/packet** (12.3k → 32.4k over
  3 packets, 4 requests/packet). It is already lean *because the loop already
  delegates* — what lands in it is a compact implementer return, not a transcript.
  This is the number the ADR's premise got wrong.
- **A fresh CE costs a flat ~40.7k/packet**, of which ~27k is pure startup before
  any work: 12.3k for its system prompt + agent definition, then ~9.5k to `Read`
  the SKILL.md that finding 4 forces into every brief.

Extrapolating the measured growth (inline marginal `4 × 0.10 × ctx_k + 1.25 ×
6.7k`, relay flat 40.7k): inline's **marginal** packet stays cheaper until ~k=12,
and the **cumulative** lines do not cross until **~k=21**. That crossover is where
the threshold comes from (rounded to 20).

Applied to the observed backlogs — which is what makes the threshold worth having
rather than academic:

| backlog | inline (eff.) | relay (eff.) | inline end context | verdict |
|---|---|---|---|---|
| 7 (small repo, live) | ~146k | ~285k | ~59k | inline, ~2× cheaper |
| 33 (mid-size repo, live) | ~1.85M | ~1.34M | **~233k — compacts** | relay, ~27% cheaper |
| 52 (large repo, live) | ~4.24M | ~2.12M | **~360k — compacts hard** | relay, ~50% cheaper |

The mid-size repo had already completed 30 packets when surveyed. Run inline, that run was
compacting — the exact lossy failure this ADR prevents, occurring in a real repo
before the ADR existed.

Two things the model deliberately does not capture, both favoring the relay:

- **Trivial packets understate inline's growth.** Real packets produce more test
  output, more review findings, and more requests per packet, so the ~6.7k/packet
  is a floor and the real crossover is earlier. How much earlier is unmeasured.
- **Cache TTL is the cliff the arithmetic hides.** The 0.10× read multiplier holds
  only while the prefix stays cached (1h here). A semi-attended run — the loop's
  entire purpose — expires it across gaps, and inline then re-reads its whole
  accumulated context at **1.0×**. Every expiry costs inline ~`ctx_k` fresh tokens
  and the relay nothing, because the relay has no accumulated context to lose.

## Consequences

- **The main window survives a long run.** ~6 lines/packet instead of a full
  implement → test → review transcript. This is the point — and per Measurement it
  is the *only* point: it buys durability, not tokens.
- **The honest ceiling on inline is a window, not a bill.** At ~6.7k/packet an
  inline coordinator reaches a 200k window around packet ~28 and is then forced
  into a lossy compaction that discards the coordinator's own thread. The relay
  cannot reach that cliff at any k. Note the convergence: inline's compaction
  ceiling (~28) sits just past the token crossover (~21), so the range where
  inline is both cheaper *and* safe ends at roughly the same place.
- **Below 20 packets the relay costs ~29% more tokens and ~40% more wall clock**,
  which is why the threshold exists and why small runs stay inline. The cost is a
  slope; the failure it prevents is a cliff. Only past the crossover is paying it
  rational — and there it is not even a cost, it is a saving.
- **The threshold is a measured constant sitting in prose, and will drift.** 20
  derives from ~6.7k/packet growth and a ~40.7k/packet relay floor, both measured
  on *trivial* packets in July 2026. Heavier packets grow the coordinator faster
  and move the real crossover **down**; a cheaper brief (see the SKILL.md lever
  below) moves it down too. Treat 20 as a calibrated guess, not a constant of
  nature: if the numbers are re-measured, update this ADR and both skills together.
- **`--relay` on a short backlog is a legitimate override, not a mistake.** A run
  expected to grow, or a session already carrying a large conversation, can want
  the flat cost even at k < 20.
- **~9.5k/packet goes to re-reading SKILL.md.** A direct consequence of finding 4
  (no `Skill` tool in a dispatched agent) and the largest single lever on the
  crossover: a condensed §2-only extract for the CE brief would cut relay cost
  materially. Not done here — the full file is what makes the CE follow the real
  contract rather than improvise it, and correctness precedes optimization.
  Flagged as the obvious follow-up.
- **A batched relay (N packets per dispatch) would likely dominate both.** It
  amortizes the ~27k startup over N packets while capping context growth at N ×
  6.7k. Unexplored; the natural next iteration if the token cost bites.
- **"Defer to agents" stops being a thing the user has to remember.** The behavior
  it produced is now the default, and the `run-loop`/`resume` prompts say which
  context does what instead of leaving it to inference.
- **Per-packet rehydration costs tokens** — a fresh CE re-reads run-state, the
  skill file, and the packet each time. Real, but spent in a disposable subagent
  at a tiered model, which is the whole trade: cheap context repeatedly, instead of
  expensive context permanently.
- **A non-advancing dispatch must stop the relay.** If `cursor` is unchanged after
  a dispatch, the relay reports and halts rather than re-dispatching. Without this,
  a CE that returns without landing anything spins a dispatch loop that burns
  tokens and looks like progress. Pinned in the skills.
- **Check-in cadence, autonomy, and every gate are unchanged.** The relay resolves
  no autonomy and crosses no gate; the CE does, exactly as before.
- **VERIFIED — the guard covers subagent tool calls identically.** This design
  leans on `hooks/guard.sh` firing for a *nested* agent's `Bash` calls exactly as
  it does for the main session's; if it did not, this ADR would move work outside
  the guard. Probed directly: a dispatched subagent's `Bash` call was intercepted
  with the same `category: risky-bash`, the same matched `rule`, and the same
  GUARDRAIL text the main session received for the identical command. `PreToolUse`
  is enforced at the tool-call layer, so nesting does not escape it. **The gate
  model is unchanged by this ADR, as claimed.**

  No case was added to `scripts/test-guard.sh` for this, deliberately: the hook
  receives an identical envelope either way — there is no "subagent" dimension in
  it to assert on — so a unit case would pin nothing. The evidence is the empirical
  probe recorded here.
- **`implement-feature` is deliberately left alone.** It is an interactive,
  human-approves-the-commit chain that already delegates per stage, and its context
  does not need to survive a long unattended run. The relay pattern is aimed at the
  loop, not at every chain.

## Rejected alternatives

- **One long-running Chief Engineer for the whole backlog.** The obvious reading
  of "defer to agents", and the reason it is wrong is not obvious: a subagent
  returns only on completion, so this delivers *zero* check-ins until the run ends.
  It trades the context problem for a visibility problem, on a loop whose entire
  premise is semi-attended operation.
- **Long-running CE + check-ins written to disk, relay tails the file.** Restores
  the progress reporting, but it is a notification transport in everything but
  name — precisely what this plugin does not build. It also adds a second durable state file
  alongside run-state, with its own torn-write story. Per-packet dispatch gets the
  same visibility from a mechanism that already exists.
- **Rename `Task` → `Agent` in the agent frontmatter.** Proposed on the false
  premise that `Task` was dead and `Agent` was ambient. Empirically disproved
  (findings 2 and 3): `Task` is the grant. Renaming it risks silently stripping the
  CE's delegation — the exact capability this ADR depends on.
- **Leave it to the human to type "defer to agents".** The status quo. It works
  and it is invisible; a behavior that only happens when you remember it is not a
  property of the system.
