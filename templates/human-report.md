# Human-facing report shapes — what the HUMAN reads (ADR 0003 / 0012)
# -----------------------------------------------------------------------------
# `check-in.md` is the AGENT-TO-AGENT wire format. A lane or a dispatched Chief
# Engineer returns that shape to the scheduler, which parses it and records state
# from it. It is unchanged and must stay machine-shaped.
#
# THIS file is the HUMAN-FACING layer, and it governs TWO things:
#
#   * The three SHAPES below (A/B/C) — the loop's reports.
#   * The CONVENTIONS in the next three sections — the glyph vocabulary, the
#     indentation contract, and the decision block. Those apply to EVERY report a
#     human reads from this plugin, including ones with no shape of their own:
#     review verdicts, dependency-tree plans, metrics summaries, bootstrap and
#     migration reports. A skill without a shape still owes the conventions.
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
# ## Four rules every report obeys
#
# 1. **Every id carries a plain-English title the first time it appears** — packets,
#    ADRs, findings, tasks, branches. `wbr-t14` alone is unreadable to someone who is
#    not holding the numbering in their head, and the human never is. Write
#    **Rate-limit auto-pause** (`wbr-t14`), or drop the id entirely. Same for an ADR:
#    **ADR 0017 (cooperative pause)**, never a bare number.
# 2. **One line per thing.** If a status needs two lines it is not a status — it is a
#    decision or a finding, and it belongs in a decision block or in
#    `.agents/findings/`.
# 3. **Omit an empty section entirely.** Never write "Blocked: none". A line the human
#    must read to learn nothing is exactly the cost these shapes exist to remove. The
#    one exception is the kickoff's `Will need you`, where "nothing expected" is real
#    information.
# 4. **Leave out the machinery.** No diffs, no file lists, no test output, no tool
#    names, no token counts, no transcript quotes, no restating of the packet's own
#    goal text. The human asks a follow-up when they want depth — do not pre-empt
#    them with a paragraph they did not ask for.


# --- THE GLYPH VOCABULARY (fixed — one glyph, one meaning, everywhere) --------
# This is the thing that makes a report recognizable at a glance, and it only works
# if it never drifts. Do not invent a glyph, do not reuse one for a second meaning,
# and do not decorate a line with a second glyph.
#
#   ✅  landed green                          tally · section · line
#   ⛔  failed / rolled back                   tally · section · line
#   ⚠️  blocked, alert, problem, risk          tally · section · line
#   🔀  a decision for you                     tally · section · line
#   ⬚  queued, not started                    tally · section · line
#   🔁  retried, then landed                   line
#   ⏸️  the run is paused                      header only
#   ▶  the next action / run is live          header · footer
#
# **⚠️ and 🔀 are different states and the distinction is load-bearing.** A packet can
# be blocked without needing anything from the human (it is waiting on another
# packet) — that is ⚠️. A decision can exist without blocking anything (a release
# call, a retention policy) — that is 🔀. A blocked packet whose blocker IS a question
# for the human counts once in each tally, and its line takes 🔀, because the action
# is the human's.
#
# **Section headings are the same glyphs as the header tally, in the same order.**
# That is the whole trick: the header doubles as a table of contents, so a reader who
# sees `⚠️ 2 blocked` knows there is a `⚠️ Blocked` section below and can jump to it
# without reading anything in between. Do not add decorative section markers (📦, 🎯,
# ⚡) — they break the correspondence and turn the header back into a caption.


# --- THE INDENTATION CONTRACT -------------------------------------------------
# Markdown renders in a PROPORTIONAL font here, and **plain leading spaces do not
# indent anything** (up to 3 are stripped; 4+ becomes a code block). Real indentation
# comes from exactly three devices, and each one means exactly one thing:
#
#   flush left        — section headings ONLY. Four or five landmarks per report and
#                       nothing else at this level, so the page has an obvious spine.
#   `> ` quote bar    — facts. Landings, blocked packets, the decision's question,
#                       the state line. The bar also draws a continuous vertical rule
#                       down each section, which is what separates them — so no
#                       horizontal rules anywhere in these reports.
#   `> - ` bullet     — choices. The ONLY place a bullet appears in a whole report,
#                       so a bullet MEANS "something for you to pick".
#   hanging line      — consequences. Indented under a bullet, never bulleted itself,
#                       so options and outcomes never blur together.
#
# Never align with spaces or pad into columns: it looks correct while you write it and
# collapses when it renders. If something genuinely needs columns, a fenced code block
# is the only way — and it costs you every bold in that block, so it is almost never
# worth it. Do not use tables: they read worst on a phone, which is where these land.


# --- THE DECISION BLOCK (shared — used by A, B, C, and any ask at all) --------
# Every time an agent needs the human to choose, it uses THIS, whatever the
# surrounding shape. A question not in this form is one the human has to do work to
# answer, and an unanswered question stalls the run exactly as hard as an unasked one.

> **<n> · <The question, asked as an actual question>**
>
> - **A ›** <the option, named in three or four words>
>   → <what follows if you pick it>
> - **B ›** <the option>
>   → <what follows if you pick it>
>
> **→ Pick <A>** — <half a line of why>
> *Silence = <A>, <what that means concretely>.*

# The two-line option is deliberate: the bold **A ›** stubs let the human read the
# SHAPE of the decision in one pass, then drop a level only for the one they are
# weighing. Keep the stub short enough to scan and put the cost on the `→` line.
#
# When there is more than one decision, head the section with the reply affordance —
# `🔀 **Decisions** — reply \`1A 2B\`` — and number the questions. Turning three
# decisions into six keystrokes is the single change most likely to actually speed the
# human up, and numbering also survives renderers that merge adjacent blockquotes.
#
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
# - **Always give a lean, and always give the default.** `Silence = A` tells them
#   whether not answering is safe. Never present a menu with no recommendation.
# - **Order by what is blocking the most**, not by when you hit it.
# - **Four per report, maximum.** Past that, give the top four and add
#   "*<N> more, lower stakes — ask and I'll lay them out.*" A decisions block too long
#   to scan does not get scanned, and then none of them get answered.
# - **Detail lives elsewhere.** A decision needing background points at the finding or
#   ADR by title (`.agents/findings/<id>.md`, "ADR 0017 (cooperative pause)"); it does
#   not inline the background.
#
# Where it appears: **B** under `🔀 Decisions` (the usual place) · **A** directly under
# the lane that raised it, when the run keeps going · **C** when the plan itself has an
# open choice · `review-change`'s risks · and the Chief Engineer's intake, where "2–3
# approaches with trade-offs" means exactly one of these, not a design essay.


# --- THE HEADER TALLY (opens A, B, and C) -------------------------------------
# One line, always first, always the same grammar:
#
#   <run-state> · <what this run is> · <tally, in fixed order>
#
# Fixed order, omitting any bucket that is zero:
#   ✅ N shipped · ⛔ N failed · ⚠️ N blocked · 🔀 N decisions · ⬚ N queued
#
# The buckets must account for the whole backlog (decisions overlap and are the one
# exception) — a tally that does not add up is obvious rather than plausible, which is
# the point of using counts instead of a progress bar. A bar collapses "waiting on
# you" and "not started" into one grey tail; those are the two states the human most
# needs to tell apart.
#
# Run-state word: ⏸️ **PAUSED** · ✅ **DONE** · ⚠️ **BLOCKED** · ▶ **RUNNING** ·
# ▶ **STARTING**. Bold it — it is the first thing read and often the only thing.


# --- A. CHECK-IN (a packet landed, or a wave of lanes came back) ---------------
# One line per packet or lane, in the order they landed. Sequential mode is a single
# line; parallel mode is one per lane. Keep it under roughly eight lines — this is
# read on a phone, between other things.

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


# --- REPORTS WITH NO SHAPE OF THEIR OWN ---------------------------------------
# A skill that reports to the human but has no shape above still owes the conventions:
# the glyph vocabulary, the indentation contract, the decision block for every ask,
# plain-English titles before every id, one line per thing, empty sections omitted.
#
#   `review-change`   verdict — ✅ ready / ⚠️ issues / 🔀 risks-as-decisions / ▶ next
#   `build-packet-dependency-tree`  the plan it prints IS a kickoff — use shape C
#   `metrics show` / `analyze`      numbers-dense by nature; no tally, no glyph
#                                   gutter, but titles-over-ids and one line per
#                                   finding still apply, and every recommendation
#                                   that is a real choice is a decision block
#   `new-project` / `migrate`       the closing summary + its approval request: ✅
#                                   what was done, ⚠️ what needs checking, 🔀 the
#                                   approval itself as a decision block
#
# Do NOT bolt a header tally onto a report with nothing to count. The tally means
# "this is a run and here is its state"; on a metrics summary it is decoration, and
# decoration is what teaches a reader to stop trusting the glyphs.
