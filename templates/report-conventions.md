# Report conventions — the layer EVERY human-facing report owes (ADR 0012)
# -----------------------------------------------------------------------------
# There are four report layers in this plugin, and they have different readers:
#
#   `status-line.md`       what every LOOP-DISPATCHED agent returns: ONE line, which
#                          the driver routes on and never expands. Loop agents return
#                          status lines, NOT check-ins (ADR 0028). Not governed by
#                          this file.
#   `check-in.md`          the AGENT-TO-AGENT wire format, for a Chief Engineer
#                          dispatched for self-contained work OUTSIDE a loop packet.
#                          Whoever dispatched it PARSES it, so it stays
#                          machine-shaped. Not governed by this file, and no longer
#                          an input to any loop report.
#   THIS FILE              the conventions — glyph vocabulary, indentation contract,
#                          decision block, header tally. They apply to every report a
#                          human reads from this plugin, including the ones with no
#                          shape of their own.
#   `report-templates.md`  the three SHAPES (A packet line / B stop report / C
#                          kickoff) the loop emits. It assumes this file.
#
# ## What this governs — and what it does not
#
# **It governs REPORTS**: anything this plugin emits to summarize work, state, a plan,
# a verdict, or a decision. Loop packet lines, stop reports, kickoffs, `review-change`
# verdicts, dependency-tree plans, metrics summaries, bootstrap and migration
# summaries. A skill with no shape of its own still owes every convention here.
#
# **It does not govern ordinary conversation.** A question answered, a file explained,
# a snippet handed over, a "yes, that works" — those are answers, not reports, and
# forcing a glyph tally onto them is decoration. Decoration is precisely what teaches
# a reader to stop trusting the glyphs. If you are not reporting on work, state, or a
# choice, just answer.
#
# Render from what you were handed — a status line, the backlog you already resolved.
# Do not re-open the repo, re-read a diff, re-run tests, or re-derive a fact to write
# a report. The rendering is free; going back to disk to embellish it is the context
# refill ADR 0012 forbids.
#
# **The loop's own shapes B and C are the exception that proves it**: they are
# assembled from ONE cheap, fixed-size file read — `runstate.sh run-digest` — rather
# than from the driver's memory of the run, because after a compaction, or in a
# session that resumed someone else's run, that memory is gone (ADR 0028). That is
# still not permission to go reading the repo: the digest is the whole source, and
# `report-templates.md` names the only three facts a shape may read from elsewhere.
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
#    must read to learn nothing is exactly the cost these reports exist to remove. The
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
# **That single-line rule has exactly one exception, and it is the loop's shape A**
# (ADR 0028). It is written for a report WITH a tally: the packet counts once in each
# bucket, so one line carrying the human-facing glyph is the honest rendering of it.
# Shape A has no tally and no sections — it is one line per ended packet plus one line
# per decider decision — so there is no tally for the packet to count once in, and
# folding the question into the packet's line would drop the decision line that shape
# exists to emit. There, and only there, the packet keeps its own ⚠️ line for its
# outcome and the decision gets its own 🔀 line beneath it, naming the same packet.
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
# Where it appears: **B** under `🔀 Decisions` (the usual place) · **C** when the plan
# itself has an open choice · `review-change`'s risks · and the Chief Engineer's
# intake, where "2–3 approaches with trade-offs" means exactly one of these, not a
# design essay. **Not in shape A** (ADR 0028) — a packet line is one line, and a
# question raised mid-run is a 🔀 line there pointing at the decision block that the
# stop report, or the driver's own next message, carries.


# --- THE HEADER TALLY (opens shapes B and C — NOT A) --------------------------
# **Shape A, the loop's per-packet line, carries no tally** (ADR 0028): it is one
# line per ended packet, and a tally on top of one line is longer than the thing it
# summarizes. Everywhere a tally does appear it is one line, always first, always the
# same grammar:
#
#   <run-state> · <what this run is> · <tally, in fixed order>
#
# Fixed order, omitting any bucket that is zero:
#   ✅ N shipped · ⛔ N failed · ⚠️ N blocked · 🔀 N decisions · ⬚ N queued
#
# **The ⚠️ bucket is worded *blocked* in general and *unfinished* in the loop's shape
# B** (ADR 0028), where it aggregates the digest's `blocked`, `interrupted`,
# `abandoned`, `open` and `paused` outcomes — "blocked" would be wrong for four of
# those five, and a bucket word that is wrong four times in five is how a reader
# learns to stop trusting the tally. Only the word moves: same glyph, same position,
# same fixed order, and the section heading below it changes with it so the
# table-of-contents correspondence still holds.
#
# **✅ is THE RUN, counted from the digest, in the loop's shape B (ADR 0028)** — one
# per `packet` line reading `green`, so a stop report rendered after a compaction, or
# by a session that resumed another session's run, still counts every packet the run
# began. This SUPERSEDES ADR 0025 D3's "this session" rule for shape B only, and it
# does so without reopening what D3 forbade: the count still comes from one cheap
# read of the run's own records, never from `backlog.done` (deleted) and never from a
# trailer scan. Anywhere else ✅ appears — a report with no digest behind it — it is
# still what this agent itself landed, never a backlog-wide count.
#
# The FORWARD buckets — ⚠️ / 🔀 / ⬚ — must account for the whole backlog (decisions
# overlap and are the one exception) — a tally that does not add up is obvious rather
# than plausible, which is the point of using counts instead of a progress bar. A bar
# collapses "waiting on you" and "not started" into one grey tail; those are the two
# states the human most needs to tell apart. This "accounts for the whole" rule does
# NOT extend to ✅: a backlog grows as tasks get filed, so it is not a fixed set to
# partition, and *2 landed, 25 to go* reads honestly rather than as a partial count.
#
# Run-state word: ⏸️ **PAUSED** · ✅ **DONE** · ⚠️ **BLOCKED** · ▶ **RUNNING** ·
# ▶ **STARTING**. Bold it — it is the first thing read and often the only thing.
#
# **Do NOT bolt a header tally onto a report with nothing to count.** The tally means
# "this is a run and here is its state"; on a metrics summary it is decoration, and
# decoration is what teaches a reader to stop trusting the glyphs.


# --- REPORTS WITH NO SHAPE OF THEIR OWN ---------------------------------------
# A skill that reports to the human but has no shape in `report-templates.md` still owes
# everything above: the glyph vocabulary, the indentation contract, the decision block
# for every ask, plain-English titles before every id, one line per thing, empty
# sections omitted.
#
#   `review-change`   verdict — ✅ ready / ⚠️ issues / 🔀 risks-as-decisions / ▶ next
#   `metrics show` / `analyze`      numbers-dense by nature; no tally, no glyph
#                                   gutter, but titles-over-ids and one line per
#                                   finding still apply, and every recommendation
#                                   that is a real choice is a decision block
#   `new-project` / `migrate`       the closing summary + its approval request: ✅
#                                   what was done, ⚠️ what needs checking, 🔀 the
#                                   approval itself as a decision block
