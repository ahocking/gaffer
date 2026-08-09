<!-- gaffer:report-conventions v1 -->

## Report conventions

These govern every **report** you give the human: work summaries, run check-ins, stop
reports and kickoffs, plans, review verdicts, metrics summaries, bootstrap and migration
summaries, and any time you ask them to choose.

They do **not** govern ordinary conversation. A question answered, a file explained, a
snippet handed over — that is an answer, not a report. Just answer it. Bolting a glyph
tally onto a two-line reply is decoration, and decoration teaches the reader to stop
trusting the glyphs.

**Glyphs — one glyph, one meaning, never two on a line.**
✅ landed · ⛔ failed or rolled back · ⚠️ blocked, alert, risk · 🔀 a decision for you ·
⬚ queued · 🔁 retried then landed · ⏸️ paused · ▶ the next action, or the run is live.
⚠️ and 🔀 are not interchangeable: waiting on another packet is ⚠️, waiting on the
**human** is 🔀. Never invent a glyph, and never add decorative markers (📦, 🎯, ⚡).

**Layout.** Section headings sit flush left. Facts go inside a `> ` quote bar — the bar
draws each section's vertical rule, so there are no horizontal rules anywhere. Bullets
appear **only** for choices, so a bullet means "something for you to pick". Consequences
hang unbulleted under their choice. Plain leading spaces indent nothing when this
renders, so never pad into columns. No tables — these are read on a phone.

**Always.** Every id carries a plain-English title the first time it appears —
**Rate-limit auto-pause** (`wbr-t14`), never a bare id, and **ADR 0017 (cooperative
pause)**, never a bare number. One line per thing. Omit an empty section entirely;
never write "Blocked: none". Leave out the machinery — no diffs, file lists, test
output, tool names, or token counts. The human asks when they want depth.

**Every ask the human has to decide is a decision block**, never a paragraph of
considerations:

> **The question, asked as an actual question?**
>
> - **A ›** the option, in three or four words
>   → what follows if you pick it
> - **B ›** the other option
>   → what follows if you pick it
>
> **→ Pick A** — half a line of why.
> *Silence = A, and what that means concretely.*

Two options is the target and three the ceiling. Each option states its **consequence**,
not its rationale ("ships this week, migration later", not "cleaner separation"). Always
give a lean and always give the default. With more than one, number them and head the
section `🔀 **Decisions** — reply 1A 2B`; four per report maximum.

The full contract — the header tally, the shapes the guided loop emits, and the rules
behind each rule — is in the gaffer plugin's `templates/report-conventions.md` and
`templates/report-templates.md`. The gaffer skills read those directly; you do not need to
unless you are emitting a loop report.
