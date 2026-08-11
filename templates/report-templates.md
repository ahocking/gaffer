# Human-facing report SHAPES — what the HUMAN reads (ADR 0012)
# -----------------------------------------------------------------------------
# **Read `report-conventions.md` (this directory) first — this file assumes it.**
# The glyph vocabulary, the indentation contract, the decision block, the header
# tally and the four rules live there and are NOT repeated here — except the ✅
# scope rule, restated at each shape that carries the bucket. They apply to every
# human-facing report in this plugin; the three shapes below apply only to the loop.
#
# `check-in.md` is the AGENT-TO-AGENT wire format. A lane or a dispatched Chief
# Engineer returns that shape to the scheduler, which parses it and records state
# from it. It is unchanged and must stay machine-shaped.
#
# Three shapes. The letters are stable identifiers, NOT an order; in time you meet
# them C → A → B:
#
#   A. CHECK-IN     — a packet or a wave of lanes came back. Emitted per landing.
#   B. STOP REPORT  — the loop stopped (done, paused, blocked, or out of gas).
#   C. KICKOFF      — emitted BEFORE a run starts, and on resume. The cheapest
#                     moment to correct a wrong assumption.
#
# All three open with the header tally and use the shared decision block — both
# defined in `report-conventions.md`.


# --- A. CHECK-IN (a packet landed, or a wave of lanes came back) ---------------
# One line per packet or lane, in the order they landed. Sequential mode is a single
# line; parallel mode is one per lane. Keep it under roughly eight lines — this is
# read on a phone, between other things.
#
# ✅ N landed is THIS SESSION (report-conventions.md's header-tally rule) — count the
# check-ins already rendered this run, nothing read from disk.

▶ **RUNNING** · <what this run is> · ✅ **N landed** · 🔀 **N decisions** · ⬚ **N left**

> ✅ **<What is now true, in human words>** — <one clause of outcome> · `<sha>`
> 🔀 **<Title>** — <what it is asking, one clause>
> ⛔ **<Title>** — <what failed>. Rolled back to `<sha>`, nothing lost.

> <a decision block, when a lane raised one and the run keeps going>

▶ **Next** — <the next packet by title, or what the other lanes are doing>

# Put the decision block directly under the lanes, not in a separate section — a
# check-in has at most one or two. Do NOT promote the whole check-in to a stop report
# for a decision the run does not need answered right now; that is how a still-running
# loop starts reading as stopped.
#
# When something changed the picture — a scope that turned out bigger, an assumption
# that proved wrong, a dependency discovered — add ONE `⚠️ **Worth knowing** — …`
# line after the lanes. It is not a place to restate what landed, and it is not the
# findings index (that lives in run-state and is read on request).

# Worked example — parallel wave, one lane asking:
#
#   ▶ **RUNNING** · Transaction import · ✅ **2 landed** · 🔀 **1 decision** · ⬚ **3 left**
#
#   > ✅ **Category totals cached** — dashboard 4s → 400ms · `9b21e04`
#   > ✅ **Export respects on-screen filters** — `c40aa11`
#   > 🔀 **Duplicate detection** — two banks send the same transaction under different ids
#
#   > **How do we decide two imports are the same transaction?**
#   >
#   > - **A ›** Match on amount + date + description
#   >   → duplicates vanish silently; ~1 in 500 genuine repeats gets swallowed
#   > - **B ›** Flag for the user to confirm
#   >   → nothing is ever lost; ~1,000 prompts on a first big import
#   >
#   > **→ Pick A** — recoverable, and confirm-flows are the ones users abandon.
#   > *Silence = A, matches logged.*
#
#   ▶ **Next** — the other three lanes keep going.


# --- B. STOP REPORT (the loop stopped, for any reason) ------------------------
# Emitted on backlog complete, on pause, on a hard gate, and on a blocking question.
# This is the one the human reads carefully, so it earns more room than a check-in —
# but every section still has to survive a ten-second scan.
#
# ✅ N shipped is THIS SESSION, same rule as shape A — the ✅ Shipped enumeration below
# is exactly that session's list, never a run-cumulative count.

⏸️ **PAUSED** · <what this run was about> · ✅ **N shipped** · ⚠️ **N blocked** · 🔀 **N decisions** · ⬚ **N queued**

<one sentence: why it stopped, and whether anything is at risk right now>

✅ **Shipped**

> ✅ **<What is now true that wasn't before>** — <one clause of consequence>

⚠️ **Blocked**

> ⚠️ **<Title>** (`<id>`) — <what it is waiting on, one clause>

⬚ **Queued**

> ⬚ **<Title>** · ⬚ **<Title>** — <one clause covering them>

🔀 **Decisions** — reply `1A 2B`

> <decision block 1>

> <decision block 2>

▶ **Next** — <the single action that unblocks the most>

> `<branch>` @ `<sha>` · tree clean · <how to pick it back up>

# `⬚ Queued` collapses: untouched packets with no blockers are a count and a list of
# titles on one line, not a section of their own lines. If everything remaining is
# blocked, omit it entirely.

# Worked example:
#
#   ⏸️ **PAUSED** · Transaction import · ✅ **5 shipped** · ⚠️ **2 blocked** · 🔀 **3 decisions** · ⬚ **2 queued**
#
#   Stopped at a green commit after the fifth packet. Nothing at risk, nothing
#   half-written.
#
#   ✅ **Shipped**
#
#   > ✅ **Large imports don't time out** — 50k-row CSV goes through in one pass
#   > ✅ **Transaction list paginates** — 200 a page, not the whole table
#   > ✅ **Category totals cached** — dashboard 4s → 400ms
#   > ✅ **Export respects on-screen filters** — what you see is what exports
#   > ✅ **Import errors name row and column** — instead of "import failed"
#
#   ⚠️ **Blocked**
#
#   > ⚠️ **Duplicate detection** (`txn-t8`) — waiting on decision 1
#   > ⚠️ **Date-range filter** (`txn-t5`) — needs t8's matching logic first
#
#   ⬚ **Queued**
#
#   > ⬚ **Import audit log** · ⬚ **Bulk re-categorise** — untouched, no blockers
#
#   🔀 **Decisions** — reply `1A 2B 3A`
#
#   > **1 · How do we decide two imports are the same transaction?**
#   >
#   > - **A ›** Match on amount + date + description
#   >   → duplicates vanish silently; ~1 in 500 genuine same-day repeats swallowed
#   > - **B ›** Flag for the user to confirm
#   >   → nothing is ever lost; ~1,000 prompts on a first big import
#   >
#   > **→ Pick A** — recoverable, and confirm-flows are the ones users abandon.
#   > *Silence = A, matches logged.*
#
#   > **2 · Hold the release for the date filter?**
#   >
#   > - **A ›** Hold
#   >   → ships complete, about two more days
#   > - **B ›** Ship now
#   >   → speed fixes land this week, filter follows next release
#   >
#   > **→ Pick B** — the five landed packets are what people complained about.
#   > *Silence = B.*
#
#   ▶ **Next** — answer decision 1; the other two can wait.
#
#   > `orch/txn-import` @ `c40aa11` · tree clean · `/gaffer:resume`


# --- C. KICKOFF (before a run starts, and on resume) --------------------------
# The cheapest moment to catch a wrong assumption: a sentence here, versus several
# packets and a stop report later. Emit it BEFORE the first packet — after preflight
# and after the backlog resolves, so it states facts rather than intentions. On resume
# the run-state word is ▶ **RESUMING** and the plan is what is LEFT, not what the
# original run set out to do.

▶ **STARTING** · <what this run is for, in plain words> · ⬚ **N packets** · <M waves | sequential>

> **Wave 1 — <theme>** · ⬚ <Title> · ⬚ <Title> · ⬚ <Title>
> **Wave 2 — <theme>** · ⬚ <Title> · ⬚ <Title>

⚠️ **Assuming** — <the one assumption most likely to be wrong, and what it costs if it is>

🔀 **Will need you** — <the packets expected to stop for a decision, by title, and why>

> **Won't touch:** <only the hard gates this backlog realistically approaches>

▶ **Autonomy** <level> · **Stops at** <branch ready for review | integrated on <branch>>

# - **Group by wave or theme, not as a numbered list of every packet.** Up to six
#   packets may be listed individually; past that, three to five themed lines with
#   their packets inline. A 30-line numbered list is not a plan the human can check,
#   it is a wall they scroll past.
# - **`⚠️ Assuming` is the highest-value line in this shape** and it takes ⚠️ because
#   a wrong assumption IS the alert. One line, the single assumption whose being wrong
#   would waste the most work — a data shape, an ownership boundary, what "done" means
#   here. If you genuinely have none, omit it rather than inventing a safe-sounding
#   one.
# - **`🔀 Will need you` is a forecast, not a promise** — naming the packets you expect
#   to stop at means a later stop is not a surprise, and it previews the tally the
#   check-ins will carry. "Nothing expected" is a legitimate and useful value; this is
#   the one line worth keeping when empty (rule 3's exception).
# - **`Won't touch:` names only what this backlog actually gets near** — a migration it
#   borders, the auth code it stops short of. Do not recite the whole danger floor; a
#   boilerplate list the human learns to skip is worse than no list.
# - **Do not fabricate a duration.** Packet and wave counts are real; a time estimate
#   is a guess unless this repo's own history supports one. Say the counts and stop.
# - **If the plan itself has an open choice** — an ordering that could go two ways, a
#   packet that may be out of scope — put a decision block here rather than choosing
#   silently and surfacing it eight packets later.

# Worked example:
#
#   ▶ **STARTING** · Transaction import: make it survive real bank files · ⬚ **9 packets** · 3 waves
#
#   > **Wave 1 — speed** · ⬚ Stream large imports · ⬚ Paginate the list · ⬚ Cache totals
#   > **Wave 2 — correctness** · ⬚ Duplicate detection · ⬚ Import audit log
#   > **Wave 3 — polish** · ⬚ Date filter · ⬚ Error messages · ⬚ Export filters · ⬚ Bulk re-categorise
#
#   ⚠️ **Assuming** — every bank in the sample set sends a stable per-transaction id.
#   If that's wrong, duplicate detection gets substantially bigger.
#
#   🔀 **Will need you** — **Duplicate detection**: auto-match or confirm-each is a
#   product call, not a technical one.
#
#   > **Won't touch:** the transactions table schema — totals cache alongside it
#   > rather than adding a column, so no migration.
#
#   ▶ **Autonomy** autonomous · **Stops at** `orch/txn-import` ready for review
