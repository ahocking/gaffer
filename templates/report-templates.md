# Human-facing report SHAPES — what the HUMAN reads (ADR 0012, reworked by ADR 0028)
# -----------------------------------------------------------------------------
# **Read `report-conventions.md` (this directory) first — this file assumes it.**
# The glyph vocabulary, the indentation contract, the decision block, the header
# tally and the four rules live there and are NOT repeated here. They apply to every
# human-facing report in this plugin; the three shapes below apply only to the loop.
#
# ## Loop agents return STATUS LINES, not check-ins (ADR 0028)
#
# `check-in.md` is the agent-to-agent wire format, and the loop no longer uses it.
# Every agent `/gaffer:run-loop` and `/gaffer:resume` dispatch returns **one status
# line** (`status-line.md`) and writes everything else to its own result file, which
# the driver never opens. `check-in.md` survives for a Chief Engineer dispatched for
# self-contained work outside a loop packet, and nothing here reads it.
#
# So the driver does NOT hold a running narrative of the run to render from, and
# after a compaction — or in a session that resumed another session's run — it holds
# nothing at all. Shapes B and C are therefore **assembled from files**, not memory.
#
# ## The one source for B and C: `runstate.sh run-digest`
#
#   runstate.sh run-digest <run-state> [--since <ts>]
#
# It reads the run's handoff files, its routing records (including the routed status
# recorded for a hand-off, written by that routing call's own --status argument -- an
# omitted one leaves the hand-off line's status empty), the outcomes log and the driver-
# mode records, and prints ONLY these, tab-separated, one per line, in no particular
# order and with no header -- never a result file, which it does not open.
#
#   packet\t<id>\t<title>\t<outcome>
#       one per packet the run BEGAN (a handoff file exists for it). <outcome> is
#       one of: green · failed · rolled-back · blocked · abandoned · interrupted ·
#       paused (the run's cursor, paused on it) · open (begun, nothing recorded).
#   decision\t<id>\t<token>
#       one per escalation-decider decision: retry · reorder · append-task ·
#       hand-off-feature · ask-operator. A bare reviewer verdict is never one of
#       these. `--since <ts>` scopes this section and only this section.
#   decision\t\treview-routing\t<finding-id>\t<summary>
#       one per finding a periodic review routed. The packet-id field is EMPTY on
#       purpose — a review routes a finding, not a packet — so never join this line
#       to a `packet` line by that field. <finding-id> and <summary> are the routed
#       finding's id and the summary the review recorded for it, which opens
#       `review:` and names every packet the finding names. Read the finding's name
#       from these two fields and from nowhere else. An empty <summary> means the
#       routing was recorded without one; both fields empty means its record could
#       not be found — render either as *not recorded*, never a summary you wrote.
#   review\t<merged>\t<routed>\t<dropped>\t<bytes_before>\t<bytes_after>
#       one per completed periodic review, scoped by `--since` with its routing
#       lines. A value may be the literal `unmeasured` — state it as unmeasured,
#       never as 0. An unmeasured <routed> has no routing lines.
#   handoff-feature\t<id>\t<status>
#       one per `hand-off-feature` question the run recorded, for the WHOLE run
#       regardless of `--since`, carrying that routing call's own status line.
#   enter\t<model>\t<effort>\t<threshold>
#       at most one — the model, effort and compaction threshold recorded at the
#       most recent driver-mode `enter` in this checkout. `unknown` is a legitimate
#       value for effort and for threshold. The whole line is ABSENT when no session
#       ever entered driver mode here.
#
# **`<title>` is the packet's task text, not a title.** It is the first line of the
# packet's own handoff file, and it is routinely a whole sentence with backticks and
# file paths in it. Shorten it to a plain-English title when you render — that is a
# bounded transform of text you were just handed, which is exactly what ADR 0012's
# "render, don't relay" permits. Pasting the raw digest field is not rendering.
#
# **A packet named inside a review routing's summary takes its title from the
# digest too**: look the id up among the same digest's `packet` lines and use that
# line's title. A packet with no `packet` line — one this run never began — renders
# by its id alone. That lookup is the digest you already hold, not a fourth fact.
#
# **Three facts the digest does not carry**, and the only three a shape below may
# read from anywhere else — each a FILE read at render time, never a memory:
#
#   the packets still queued        `runstate.sh summary <run-state>` (`N pending`),
#                                   or the backlog you resolved moments ago in the
#                                   kickoff's case
#   a periodic pause's setting      `runstate.sh periodic-pause` (`EVERY=<N>`)
#   the branch and the commit       `git` — for the state line only
#
# Anything else you want in a report and cannot get from those: leave it out. Going
# back to the repo to enrich a report is the context growth driver mode exists to
# avoid, and a fact recalled from memory is the one thing these shapes forbid.
#
# Three shapes. The letters are stable identifiers, NOT an order; in time you meet
# them C → A → B:
#
#   A. PACKET LINE  — a packet ended. One line. No tally, no sections.
#   B. STOP REPORT  — the loop stopped (done, paused, blocked, or out of gas).
#   C. KICKOFF      — emitted BEFORE a run starts, and on resume. The cheapest
#                     moment to correct a wrong assumption.
#
# B and C open with the header tally and use the shared decision block — both
# defined in `report-conventions.md`. **A does neither**, on purpose: see below.


# --- A. PACKET LINE (a packet ended) ------------------------------------------
# One line per packet that ENDED since your last report, plus one line per decider
# decision since then. That is the whole shape. No header tally, no sections, no
# decision block, no `▶ Next`.
#
# This replaced a multi-section per-packet check-in (ADR 0023's shape A) because the
# driver no longer has the material to write one: it holds a status line, not a
# narrative. A tally on top of one or two lines is longer than what it summarizes,
# and the run's state is what shape B is for.
#
# Render it from the packet's own `packet` and `decision` lines in
# `run-digest --since <your last report>`. The status line the agent returned is
# fine as the wording of the outcome clause — it was written for exactly this.

> ✅ **<Title>** (`<id>`) — <one clause of what is now true> · `<sha>`
> 🔁 **<Title>** (`<id>`) — <one clause>, after a retry · `<sha>`
> ⛔ **<Title>** (`<id>`) — <what failed>. Rolled back, nothing lost.
> ⚠️ **<Title>** (`<id>`) — <what it is waiting on>
> 🔀 **<Title>** (`<id>`) — handed off as a question: <what it is asking>

# Glyph by the digest's `<outcome>`, with no judgment left to you:
#
#   green                             ✅   — 🔁 instead when this packet also has a
#                                            `decision` line reading `retry`
#   failed · rolled-back              ⛔
#   blocked · interrupted · abandoned ⚠️
#
# Every `decision` line gets a 🔀 line of its own EXCEPT `retry`, which is already
# visible as the 🔁 on the packet's own line and must not be reported twice. So
# `reorder`, `append-task`, `hand-off-feature` and `ask-operator` always take a line,
# **including when the decision is what ended the packet it names** — a
# `hand-off-feature` always ends its packet, so any rule conditioned on "it did not
# end the packet" would exclude the commonest case in the shape.
#
# That is one packet on two lines, and it is deliberate: the packet's line keeps its
# own outcome glyph and the 🔀 line says what the human is being asked. It is the one
# documented exception to `report-conventions.md`'s "a blocked packet whose blocker IS
# a question takes 🔀" rule — that rule exists so such a packet counts once in each
# tally, and shape A has no tally.
#
# A sweep runs before every start/continuation (loop-measurement T8). A packet it
# closed reads as `interrupted` in the digest and takes the ⚠️ line above with
# *swept as interrupted* as its clause — there is no separate sweep line any more.

# Worked example (digest lines, then what they render as):
#
#   packet  txn-t3  Cache the category totals so the dashboard…  green
#   packet  txn-t4  Add a duplicate-detection pass over…         rolled-back
#   decision txn-t4 hand-off-feature
#
#   > ✅ **Category totals cached** (`txn-t3`) — dashboard 4s → 400ms · `9b21e04`
#   > ⛔ **Duplicate detection** (`txn-t4`) — two banks send one transaction twice. Rolled back, nothing lost.
#   > 🔀 **Duplicate detection** (`txn-t4`) — handed off as a question: auto-match
#   >   or confirm-each is a product call


# --- B. STOP REPORT (the loop stopped, for any reason) ------------------------
# Emitted on backlog complete, on pause, on a hard gate, and on a blocking question.
# This is the one the human reads carefully, so it earns more room than a packet
# line — but every section still has to survive a ten-second scan.
#
# **Assemble it from `runstate.sh run-digest <run-state>` with no `--since`**, plus
# at most the three file reads named at the top of this file. Every packet the run
# began has a `packet` line, so this report names every one of them with its outcome
# — or that it is paused — whether or not the session rendering it was there when
# they ran. That property is the point: a stop report after a compaction, or from a
# session that resumed someone else's run, is the same report.
#
# The tally counts `packet` lines by outcome, and the core does the counting: read
# each digest-derived figure from `runstate.sh run-tally <run-state>` — ✅ from its
# `SHIPPED`, ⛔ from `FAILED`, ⚠️ from `UNFINISHED`, 🔀 from `DECISIONS` — and
# render it as printed, never recounted from the digest. The core groups `packet`
# outcomes as ✅ green · ⛔ failed and rolled-back · ⚠️ blocked, interrupted,
# abandoned, open and paused, so a reader checks a figure against that grouping
# rather than against arithmetic the report did. ⬚ queued is not one of its
# figures: it is the `N pending` from `runstate.sh summary`; omit the bucket if
# you did not read it rather than guessing a number.
#
# The core's 🔀 figure counts one per `handoff-feature` line, plus one per
# `decision` line whose token is `hand-off-feature`, plus one per still-awaiting
# `ask-operator` `decision` line — each EXCEPT one whose id already has a
# `handoff-feature` line of its own — plus one per still-awaiting
# retry-past-limit stop: a routing record whose `retry` token was routed `stop`
# because the packet was already at its attempt limit. **Still awaiting** is
# defined here, once, and the rules below refer to it: an `ask-operator` line, or
# a retry-past-limit stop, counts until the same packet has a start, continuation
# or `abandoned` record in the outcomes log whose parsed timestamp is STRICTLY
# later than the question's. A tie does not answer (the count fails toward
# over-reporting), and the `blocked` outcome the pause records for the stop the
# question itself caused does not answer either — only the `ask-operator` lines
# and the retry-past-limit stops are aged this way; the other two kinds count for
# the whole run. A retry-past-limit stop has no digest line of its own (the
# digest's line kinds are unchanged) and is a distinct question from any
# `ask-operator` or `hand-off-feature` line for the same packet, so the core
# counts it directly: it is never excluded by a `handoff-feature` line and never
# capped against a digest count. The digest's `decision` line carries no
# timestamp, so this is the core's judgement, not something to re-derive from
# the digest.
#
# A packet routed `hand-off-feature` always
# emits BOTH records for the same question (the digest's two records — left
# untouched here, see above), so counting both would tally that one question
# twice; the core's exclusion of the `decision` line once its `handoff-feature`
# line is counted is what makes a handed-off packet contribute exactly the one 🔀
# that the body renders exactly one block for. An `ask-operator` decision has no
# `handoff-feature` line and so the core never excludes it.
#
# The tally is the report's table of contents, not a separate count next to one:
# every glyph it totals names a section below, and every section the tally counts
# is headed by that glyph — ✅ Shipped, ⛔ Failed, ⚠️ Unfinished, 🔀 Decisions,
# ⬚ Queued, in that order. ✅, ⛔ and ⚠️ carry one line per packet counted, and
# 🔀 Decisions carries exactly as many blocks as the header's 🔀 figure, never
# more; ⬚ Queued is the one bucket whose count collapses to a single line (see
# below), and ▶ Next is the one section the tally does not count.

⏸️ **PAUSED** · <what this run was about> · ✅ **N shipped** · ⛔ **N failed** · ⚠️ **N unfinished** · 🔀 **N decisions** · ⬚ **N queued**

<one sentence: why it stopped, and whether anything is at risk right now>

✅ **Shipped**

> ✅ **<What is now true that wasn't before>** (`<id>`) — <one clause of consequence>

⛔ **Failed**

> ⛔ **<Title>** (`<id>`) — <what failed>, rolled back

⚠️ **Unfinished**

> ⚠️ **<Title>** (`<id>`) — paused here; the run stopped on this one
> ⚠️ **<Title>** (`<id>`) — swept as interrupted

🔀 **Decisions** — reply `1A 2B`

> <decision block 1>

> <decision block 2>

⬚ **Queued**

> ⬚ **<N> more** — <one clause covering them>

▶ **Next** — <the single action that unblocks the most>

> `<branch>` @ `<sha>` · tree clean · <how to pick it back up>

# - **The paused packet is named with the word *paused*, under ⚠️ Unfinished.** ⏸️
#   stays header-only (the glyph vocabulary), so it is the word and not a glyph that
#   carries this. The digest gives it to you as `<outcome>` = `paused`: that is the
#   run's cursor, and it is deliberately never swept, so it carries no terminal
#   record of its own and cannot be inferred any other way.
# - **Every `handoff-feature` line becomes exactly one decision block**, whatever
#   else is in the report, and so does every `decision` line with no
#   `handoff-feature` line of its own that is still awaiting an answer as the 🔀
#   paragraph above defines it (in practice, `ask-operator` — a
#   `hand-off-feature` decision line always has one). A hand-off's two digest
#   records name the same question, so render ONE block for it, matching the
#   header's 🔀 count above. The digest carries `handoff-feature` lines for the
#   WHOLE run, not just since the last report, precisely so a stop report cannot
#   drop an open question the run asked three hours and one compaction ago. Its
#   `<status>` field is the status line the decider routed — it holds the
#   question; write the two options and the lean.
# - **`⬚ Queued` collapses to a count and one clause**, never a list of its own
#   lines — the digest does not carry unbegun packets, so there is nothing to name
#   there anyway. If everything remaining is unfinished, omit the section.
# - **When a periodic pause stopped the run, say the setting.** Read
#   `runstate.sh periodic-pause` and name it in the one-sentence reason:
#   *"Paused after 5 packets — `pause_every_packets: 5` in
#   `.agents/project-overrides.yaml`."* Without the setting named, an operator
#   reads a scheduled pause as a failure, and that is the one thing it is not.
# - **Omit `⛔ Failed` and `⚠️ Unfinished` when the digest has no such lines.** Rule
#   3 — an empty section is never written as "none".

# Worked example of the dedup rule (one handed-off packet, one operator question):
#
#   packet          txn-t4  Add a duplicate-detection pass over…  rolled-back
#   decision        txn-t4  hand-off-feature
#   handoff-feature txn-t4  handed off as a question: auto-match or confirm-each
#   packet          txn-t9  Pick a retry backoff for the bank API  blocked
#   decision        txn-t9  ask-operator
#
#   Tally: ⛔ **1 failed** (txn-t4, rolled-back) · ⚠️ **1 unfinished** (txn-t9,
#   blocked) · 🔀 **2 decisions** — one `handoff-feature` line (txn-t4) plus one
#   `decision` line with no `handoff-feature` line of its own (txn-t9's
#   `ask-operator`, still awaiting as the 🔀 paragraph above defines it — its
#   `blocked` outcome is the pause's own and answers nothing). txn-t4's OWN
#   `decision` line (token `hand-off-feature`) is excluded, since its `handoff-feature` line already
#   counted that question. The body renders exactly two blocks under
#   🔀 **Decisions**, one per counted line above — the header's 🔀 figure and the
#   section's block count match, which is the table-of-contents property this
#   correction restores.
#
# Worked example (from a digest with five packets, one paused, one question):
#
#   ⏸️ **PAUSED** · Transaction import · ✅ **4 shipped** · ⚠️ **1 unfinished** · 🔀 **1 decision** · ⬚ **2 queued**
#
#   Paused after 5 packets — `pause_every_packets: 5` in
#   `.agents/project-overrides.yaml`. Nothing at risk, nothing half-written.
#
#   ✅ **Shipped**
#
#   > ✅ **Large imports don't time out** (`txn-t1`) — 50k rows in one pass
#   > ✅ **Transaction list paginates** (`txn-t2`) — 200 a page, not the whole table
#   > ✅ **Category totals cached** (`txn-t3`) — dashboard 4s → 400ms
#   > ✅ **Import errors name row and column** (`txn-t6`) — instead of "import failed"
#
#   ⚠️ **Unfinished**
#
#   > ⚠️ **Duplicate detection** (`txn-t4`) — paused here; the run stopped on this one
#
#   🔀 **Decisions** — reply `1A`
#
#   > **1 · How do we decide two imports are the same transaction?**
#   >
#   > - **A ›** Match on amount + date + description
#   >   → duplicates vanish silently; ~1 in 500 genuine repeats swallowed
#   > - **B ›** Flag for the user to confirm
#   >   → nothing is ever lost; ~1,000 prompts on a first big import
#   >
#   > **→ Pick A** — recoverable, and confirm-flows are the ones users abandon.
#   > *Silence = A, matches logged.*
#
#   ⬚ **Queued**
#
#   > ⬚ **2 more** — the date filter and the audit log, neither blocked
#
#   ▶ **Next** — answer decision 1, then `/gaffer:resume`.
#
#   > `orch/txn-import` @ `c40aa11` · tree clean · `/gaffer:resume`


# --- C. KICKOFF (before a run starts, and on resume) --------------------------
# The cheapest moment to catch a wrong assumption: a sentence here, versus several
# packets and a stop report later. Emit it BEFORE the first packet — after preflight
# and after the backlog resolves, so it states facts rather than intentions. On resume
# the run-state word is ▶ **RESUMING** and the plan is what is LEFT, not what the
# original run set out to do.
#
# **The session line comes from `run-digest`'s `enter` line, and nothing else.** On a
# fresh run the digest has no `packet` lines yet — the forward plan is the backlog you
# resolved moments ago in the same step, which is a file read, not a memory. On resume
# the digest's `packet` lines are what the run already did; render them as one ⚠️
# **Picked up** line naming what is unfinished, not as a second stop report.

▶ **STARTING** · <what this run is for, in plain words> · ⬚ **N packets** · <M phases>

> **Phase 1 — <theme>** · ⬚ <Title> · ⬚ <Title> · ⬚ <Title>
> **Phase 2 — <theme>** · ⬚ <Title> · ⬚ <Title>

⚠️ **Assuming** — <the one assumption most likely to be wrong, and what it costs if it is>

⚠️ **Routing config** — <n> entr(y|ies) ignored: <key> (<reason>), …

🔀 **Will need you** — <the packets expected to stop for a decision, by title, and why>

> **Won't touch:** <only the hard gates this backlog realistically approaches>

▶ **Session** <model> · effort <effort> · compaction <threshold>

▶ **Routing** <agent> <frontmatter> → <alias> · …

▶ **Stops at** <branch ready for review | integrated on <branch>>

# - **`▶ Session` states model and effort, and the auto-compaction threshold as a
#   number only when one is in effect, asking for nothing.** Model and effort are
#   taken verbatim from the digest's `enter` line. Where effort is `unknown`, say
#   so in words — *effort unknown* — since effort is always in effect and merely
#   unrecorded. Where the whole `enter` line is absent, write *`▶ **Session** —
#   can't tell: no driver-mode record`*. **Whenever the reader's `SOURCE` named no
#   value in effect** (`gaffer-default` or `unknown` — neither is a value the
#   harness enforces), the threshold element states the absence in exactly the
#   words the two loop entry points use — *no compaction threshold in effect for
#   this session — the settings key `autoCompactWindow` supplies one* — in place
#   of `compaction <threshold>`: never a figure, and never the bare word
#   `unknown`, since omitting the element would read as a measured run. State a
#   real number, as `compaction <threshold>`, only when the repo or the operator
#   set one — the harness enforces those. This line never carries a `SOURCE` slot
#   of its own; the source decides which form the threshold element takes, not
#   something rendered alongside it.
#   **Never ask the operator to raise the effort, switch model or change the
#   threshold.** It is their setting; the line exists so a surprising run cost is
#   explainable afterwards, not to open a negotiation at the top of a report. A
#   run that would genuinely be better on another model is a thing to say once,
#   in conversation, never as a line in this shape.
# - **`⚠️ Routing config` and `▶ Routing` are rendered only from `routing.sh
#   validate` and `routing.sh table` output, run once at preflight — never from the
#   `model_routing` YAML itself — and neither asks the operator to change anything.**
#   `⚠️ Routing config` appears only when `validate` printed something: one line
#   total, naming each ignored entry's key and reason (an ignored entry falls back to
#   its agent's frontmatter model, and the run continues). `▶ Routing` appears only
#   when `table` printed something: one line total, each agent the map routes away
#   from its frontmatter with both models. An empty or all-default map adds no line.
#   Like `▶ Session`, these explain a run's cost and routing afterwards; they do not
#   open a negotiation about configuration.
# - **Group by phase or theme, not as a numbered list of every packet.** Up to six
#   packets may be listed individually; past that, three to five themed lines with
#   their packets inline. A 30-line numbered list is not a plan the human can check,
#   it is a wall they scroll past.
# - **`⚠️ Assuming` is the highest-value line in this shape** and it takes ⚠️ because
#   a wrong assumption IS the alert. One line, the single assumption whose being wrong
#   would waste the most work — a data shape, an ownership boundary, what "done" means
#   here. If you genuinely have none, omit it rather than inventing a safe-sounding
#   one.
# - **`🔀 Will need you` is a forecast, not a promise** — naming the packets you expect
#   to stop at means a later stop is not a surprise. "Nothing expected" is a
#   legitimate and useful value; this is the one line worth keeping when empty
#   (rule 3's exception).
# - **`Won't touch:` names only what this backlog actually gets near** — a migration it
#   borders, the auth code it stops short of. Do not recite the whole danger floor; a
#   boilerplate list the human learns to skip is worse than no list.
# - **Do not fabricate a duration.** Packet and phase counts are real; a time estimate
#   is a guess unless this repo's own history supports one. Say the counts and stop.
# - **If the plan itself has an open choice** — an ordering that could go two ways, a
#   packet that may be out of scope — put a decision block here rather than choosing
#   silently and surfacing it eight packets later.

# Worked example:
#
#   ▶ **STARTING** · Transaction import: make it survive real bank files · ⬚ **9 packets** · 3 phases
#
#   > **Phase 1 — speed** · ⬚ Stream large imports · ⬚ Paginate the list · ⬚ Cache totals
#   > **Phase 2 — correctness** · ⬚ Duplicate detection · ⬚ Import audit log
#   > **Phase 3 — polish** · ⬚ Date filter · ⬚ Error messages · ⬚ Export filters · ⬚ Bulk re-categorise
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
#   ▶ **Session** claude-opus-5[1m] · effort unknown · no compaction threshold in
#   effect for this session — the settings key `autoCompactWindow` supplies one
#
#   ▶ **Routing** implementer sonnet → opus
#
#   ▶ **Stops at** `orch/txn-import` ready for review
