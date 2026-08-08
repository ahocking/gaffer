# Human-facing report shapes — what the HUMAN reads (ADR 0003 / 0012)
# -----------------------------------------------------------------------------
# `check-in.md` is the AGENT-TO-AGENT wire format. A lane or a dispatched Chief
# Engineer returns that shape to the scheduler, which parses it and records state
# from it. It is unchanged and must stay machine-shaped.
#
# THIS file is the HUMAN-FACING layer. Whoever holds the main context window —
# usually the Chief Engineer driving the loop — renders the wire check-ins into one
# of the shapes below before they reach the human.
#
# One shared block, three shapes. The letters are stable identifiers, NOT an order;
# in time you meet them C → A → B:
#
#   THE DECISION BLOCK — the shared primitive. Used inside A, B, and C, and by any
#                        agent asking the human to choose anything at all.
#   A. CHECK-IN     — a packet or a wave of lanes came back. Emitted per landing.
#   B. STOP REPORT  — the loop stopped (done, paused, blocked, or out of gas).
#   C. KICKOFF      — emitted BEFORE a run starts, and on resume. The cheapest
#                     moment to correct a wrong assumption.
#
# Render from what you already know — the check-in text you were handed, the backlog
# you already resolved. Do not re-open the repo, re-read a diff, re-run tests, or
# re-derive a fact to write these. The rendering is free; going back to disk to
# embellish it is the context refill ADR 0012 forbids, and it is what makes a relayed
# loop expensive.
#
# ## Four rules every shape obeys
#
# 1. **Every id carries a plain-English title the first time it appears** — packets,
#    ADRs, findings, tasks, branches. `wbr-t14` alone is unreadable to someone who is
#    not holding the numbering in their head, and the human never is. Write
#    **Rate-limit auto-pause** (`wbr-t14`), or drop the id entirely. Same for an ADR:
#    **ADR 0017 (cooperative pause)**, never a bare number.
# 2. **One line per thing.** If a status needs two lines it is not a status — it is a
#    decision or a finding, and it belongs in a decision block or in
#    `.agents/findings/`.
# 3. **Omit an empty section entirely.** Never write "Findings: none" or
#    "Blockers: n/a". A line the human must read to learn nothing is exactly the
#    cost these shapes exist to remove.
# 4. **Leave out the machinery.** No diffs, no file lists, no test output, no tool
#    names, no token counts, no transcript quotes, no restating of the packet's own
#    goal text. The human asks a follow-up when they want depth — do not pre-empt
#    them with a paragraph they did not ask for.
#
# Status markers, fixed set:  ✅ landed green · ⚠️ needs a decision · ⏸ paused ·
# ⛔ failed or rolled back · 🔁 retried and landed.


# --- THE DECISION BLOCK (shared — used by A, B, C, and any ask at all) --------
# Every time an agent needs the human to choose, it uses THIS, whatever the
# surrounding shape. A question that is not in this form is one the human has to do
# work to answer, and an unanswered question stalls the run exactly as hard as an
# unasked one.

**<The question, asked as an actual question>**
- **<Option A>** → <what follows if you pick it>
- **<Option B>** → <what follows if you pick it>
- *I'd pick <A>* — <half a line of why> · *If you say nothing:* <the default path>

# ## Rules — this is the part that has to be right
#
# - **Answerable in one word.** If the human cannot reply "A" or "yes", it is not
#   scoped enough yet — split it, or go decide the sub-parts yourself. Two options is
#   the target; three is the ceiling. If more exist, name the two real ones and say in
#   half a line what you ruled out and why.
# - **Each option states its CONSEQUENCE, not its rationale.** "→ ships this week,
#   schema migration later" is a consequence. "→ cleaner separation of concerns" is an
#   argument, and the human did not ask for one.
# - **Say the asymmetry out loud when there is one** — reversible vs not, an hour vs a
#   day, affects one packet vs the whole backlog. That is usually the only fact they
#   need in order to decide.
# - **Always give a lean, and always give the default.** "If you say nothing: <X>"
#   tells them whether silence is safe. Never present a menu with no recommendation.
# - **Order by what is blocking the most**, not by when you hit it.
# - **Four per report, maximum.** Past that, give the top four and add
#   "*<N> more, lower stakes — ask and I'll lay them out.*" A decisions block too long
#   to scan does not get scanned, and then none of them get answered.
# - **Detail lives elsewhere.** A decision that needs background points at the finding
#   or ADR by title (`.agents/findings/<id>.md`, "ADR 0017 (cooperative pause)"); it
#   does not inline the background.
#
# Where it appears: **B** under `Decisions for you` (the usual place) · **A** inline
# under a ⚠️ lane, when that lane is blocked but the run keeps going · **C** when the
# plan itself has an open choice · and in the Chief Engineer's intake, where "2–3
# approaches with trade-offs" means exactly one of these, not a design essay.


# --- A. CHECK-IN (a packet landed, or a wave of lanes came back) ---------------
# One line per packet or lane, in the order they landed. In sequential mode that is a
# single line; in parallel mode it is one per lane. Keep the whole thing under roughly
# six lines — this is read on a phone, between other things.

### Check-in — <N> landed · <M> need you
<!-- drop the "· M need you" clause when M is 0 -->

✅ **<What is now true, in human words>** (`<id>`) — <one clause of outcome>. `<sha>`
⚠️ **<Title>** (`<id>`) — <what stopped it, one clause>.
⛔ **<Title>** (`<id>`) — <what failed>. Rolled back to `<sha>`, nothing lost.

**Next:** <plain title of the next packet> (`<id>`) · <N> left
**Worth knowing:** <one line, only when something genuinely changed the picture>

# When a ⚠️ lane is blocked but the rest of the run continues, put ONE decision block
# directly under that lane's line — indented, so the wave stays scannable above it.
# Do not promote the whole check-in to a stop report for a decision the run does not
# need answered right now; that is how a still-running loop starts reading as stopped.
#
# `Worth knowing:` is for a fact that changes what the human expects — a scope that
# turned out bigger, an assumption that proved wrong, a dependency discovered. It is
# NOT a place to restate what landed, and it is NOT the findings index (that lives in
# run-state; the human reads it on request, not on every packet).

# Worked example — sequential, one packet:
#
#   ### Check-in — 1 landed
#
#   ✅ **Transaction list now paginates instead of loading every row** (`txn-t4`)
#      — 200 per page, server-side. green · `a3f9c21`
#
#   **Next:** **Date-range filter on the list** (`txn-t5`) · 4 left
#
# Worked example — parallel wave, one lane blocked, run continues:
#
#   ### Check-in — 2 landed · 1 needs you
#
#   ✅ **Category totals cached per account** (`txn-t7`) — dashboard drops from ~4s
#      to under 400ms. green · `9b21e04`
#   ✅ **CSV export respects the filters on screen** (`txn-t9`) — green · `c40aa11`
#   ⚠️ **Duplicate-import detection** (`txn-t8`) — two banks send the same
#      transaction under different ids. Nothing written yet.
#
#      **How do we decide two imported transactions are the same one?**
#      - **Match on amount + date + description** → duplicates vanish silently; ~1 in
#        500 genuine same-day repeat charges gets swallowed and re-added by hand.
#      - **Flag them for the user to confirm** → nothing is ever lost, but a first
#        50k-row import can surface ~1,000 prompts.
#      - *I'd match automatically* — the raw import is kept, so a bad match is
#        recoverable. · *If you say nothing:* automatic, with matches logged.
#
#   **Next:** the other three lanes keep going · 3 left


# --- B. STOP REPORT (the loop stopped, for any reason) ------------------------
# Emitted on backlog complete, on pause, on a hard gate, and on a blocking question.
# This is the one the human reads carefully, so it earns more room than a check-in —
# but every section still has to survive a ten-second scan.

## <What this run was about, in plain words> — <done | paused | blocked | stopped>
<one sentence: why it stopped, and whether anything is at risk right now>

**Shipped** — <N> of <M>
- **<What is now true that wasn't before>** — <one clause of consequence>
- **<…>** — <…>

**Not done**
- **<Title>** (`<id>`) — <why, one clause>

**Decisions for you**
1. <a decision block, per the rules above>
2. <…>

**Recommended next**
- <one imperative action> — <why, half a line>

**State:** branch `<branch>` at `<sha>`, tree clean · <how to pick it back up>

# Worked example:
#
#   ## Transaction import — paused
#   Stopped at a green commit after the fifth packet. Nothing is at risk and nothing
#   is half-written.
#
#   **Shipped** — 5 of 9
#   - **Imports no longer time out on large files** — a 50k-row CSV goes through in
#     one pass.
#   - **Transaction list paginates** — 200 rows a page instead of the whole table.
#   - **Category totals are cached** — dashboard loads in under 400ms, was ~4s.
#   - **CSV export respects the filters on screen** — what you see is what exports.
#   - **Import errors name the row and column** — instead of "import failed".
#
#   **Not done**
#   - **Duplicate-import detection** (`txn-t8`) — blocked on decision 1.
#   - **Date-range filter** (`txn-t5`) — depends on the matching logic from `txn-t8`.
#
#   **Decisions for you**
#   1. **How do we decide two imported transactions are the same one?**
#      - **Match on amount + date + description** → duplicates vanish silently; ~1 in
#        500 genuine same-day repeat charges gets swallowed and re-added by hand.
#      - **Flag them for the user to confirm** → nothing is ever lost, but a first
#        50k-row import can surface ~1,000 prompts.
#      - *I'd match automatically* — recoverable, and the confirm flow is the one
#        users abandon. · *If you say nothing:* automatic, with matches logged.
#   2. **Hold the release for the date-range filter?**
#      - **Hold** → ships complete, about two more days.
#      - **Ship now** → the speed fixes land this week; filter follows next release.
#      - *I'd ship now* — the five landed packets are the ones people complained
#        about. · *If you say nothing:* ship now.
#
#   **Recommended next**
#   - Answer decision 1 — it unblocks the last two packets and nothing else is
#     waiting on anything.
#
#   **State:** branch `orch/txn-import` at `c40aa11`, tree clean · `/gaffer:resume`


# --- C. KICKOFF (before a run starts, and on resume) --------------------------
# The cheapest moment to catch a wrong assumption: a sentence here, versus several
# packets and a stop report later. Emit it BEFORE the first packet — after preflight
# and after the backlog resolves, so it states facts rather than intentions. On
# resume it says what is LEFT, not what the original run was.

### Starting — <what this run is for, in plain words>
<!-- on resume: "### Resuming — <…>" -->

**Plan** — <N> packets<, in M waves | , sequential>
1. **<Title>** — <one clause of what it changes>
2. **<…>**

**Assuming:** <the one assumption most likely to be wrong — say it, don't bury it>
**Will need you:** <the packets/moments likely to stop for a decision, by title>
**Won't touch:** <only the hard gates this backlog realistically approaches>
**Autonomy:** <level> · **Stops at:** <branch ready for review | integrated on <branch>>

# - **List up to six packets in order.** Past that, group into three to five themes
#   with counts ("**Import pipeline** — 7 packets") — a 30-line numbered list is not
#   a plan the human can check, it is a wall they scroll past.
# - **`Assuming:` is the highest-value line in this shape.** One line, the single
#   assumption whose being wrong would waste the most work — a data shape, an
#   ownership boundary, what "done" means for this feature. If you genuinely have
#   none, omit the line rather than inventing a safe-sounding one.
# - **`Will need you:` is a forecast, not a promise** — name the packets you expect to
#   stop at and why, so a later stop is not a surprise. "Nothing expected" is a
#   legitimate and useful value here; this is the one line worth keeping when empty.
# - **`Won't touch:` names only what this backlog actually gets near** — a migration
#   it borders, the auth code it stops short of. Do not recite the whole danger floor;
#   a boilerplate list the human learns to skip is worse than no list.
# - **Do not fabricate a duration.** Packet and wave counts are real; a time estimate
#   is a guess unless this repo's own history supports one. Say the counts and stop.
# - **If the plan itself has an open choice** — an ordering that could go two ways, a
#   feature that may be out of scope — put a decision block here rather than picking
#   silently and surfacing it eight packets later.

# Worked example:
#
#   ### Starting — Transaction import: make it survive real bank files
#
#   **Plan** — 9 packets, in 3 waves
#   1. **Stop large imports timing out** — stream the file instead of loading it.
#   2. **Paginate the transaction list** — the table currently loads every row.
#   3. **Cache category totals** — the dashboard recomputes them on every visit.
#   4. **Detect duplicate imports** — two banks send the same transaction twice.
#   5. **Filter by date range** — depends on 4's matching logic.
#   …plus 4 smaller packets: error messages, export filters, and two test sweeps.
#
#   **Assuming:** every bank in the sample set sends a stable per-transaction id.
#     If that's wrong, packet 4 gets substantially bigger.
#   **Will need you:** packet 4 (**Detect duplicate imports**) — auto-match or
#     confirm-each is a product call, not a technical one.
#   **Won't touch:** the transactions table schema — packet 3 caches alongside it
#     rather than adding a column, so no migration.
#   **Autonomy:** autonomous · **Stops at:** `orch/txn-import` ready for review
