# Status line — what every loop-dispatched agent returns (thin-loop-driver, ADR 0028)

Every agent the loop dispatches — the `implementer`, `doc-writer`, `researcher`,
`architect`, `ux-designer`, `reviewer`, and the escalation decider
(`chief-engineer` in its loop role, which also runs the periodic review) — returns **exactly one line** as the whole of its
response to the driver, and writes everything else (diffs described, review
findings, research answers, reasoning) to its **result file** via
`runstate.sh write-result`. The driver never opens that file — it passes the
path straight back to whoever routes on it (the reviewer verdict, an
escalation decision, or the operator asking a question) or to the operator
directly.

## Grammar

```
<status> · <what changed> · result: <needs-reading|no> · <path>
```

Four fields, separated by ` · ` (space, U+00B7 MIDDLE DOT, space), in this
exact order:

1. **`<status>`** — one word, first field, so the driver can split on ` · `
   and take the first token without parsing anything else. For the
   `reviewer` this is one of `pass`, `fix`, `escalate` (its verdict). For the
   escalation decider this is one of `retry`, `reorder`, `append-task`,
   `hand-off-feature`, `ask-operator` (its decision) when it decides an
   escalated packet, and the word `reviewed` when it returns from a periodic
   review — `reviewed` is not a sixth decision and nothing routes on it; the
   review's routings reach the report through `run-digest`, not this word. For
   the `implementer` this is `continue` when it stopped at its turn budget with
   work left to do — the one implementer status the driver routes on, passed
   straight to `runstate.sh route` in place of the reviewer dispatch that any
   other first token leads to. Any
   other dispatched agent — an implementer that finished its packet, the
   architect or
   UX designer implementing a design-heavy packet, the doc-writer, the
   researcher answering an operator question — reports its own outcome in
   plain language (`done`, `blocked`), since nothing routes on it directly.
2. **`<what changed>`** — one short clause, plain English, no `file:line`
   list and no diff. Enough for the driver to relay to the operator without
   opening the result file.
3. **`result: <needs-reading|no>`** — literally `result:` followed by
   `needs-reading` when the result file carries something the next reader
   (the driver, another agent, or the operator) should actually open, or
   `no` when the status line already says everything that matters. This is
   a claim the agent makes about its own result file, not a promise the
   result file is empty when it says `no` — `write-result` always writes
   one.
4. **`<path>`** — the result file's path, exactly as `runstate.sh
   write-result` printed it (`RESULT=<path>`), so the reader can open it
   without reconstructing it.

**Parse `<status>` as everything before the FIRST ` · `, and `<path>` as
everything after the LAST ` · `.** The middle two fields are free text and may
themselves contain ` · ` (a clause with its own aside, for instance) — do not
assume the line splits cleanly into exactly four pieces by that separator.
Only the first and last boundaries are load-bearing.

## Passing this line to a shell — single-quote it, always

Whoever routes on this line (the driver, calling `runstate.sh route` or
`write-result`) passes it as a shell argument: `--status '<line>'`, single
-quoted, never double-quoted. A double-quoted `"<line>"` lets a backtick or
`$(...)` inside the agent's own text execute in the driver's shell — the
guard treats quoted text as inert, but only single quotes actually are.
Single-quoting also means a literal `'` inside the line must be escaped as
`'\''` (close the quote, an escaped literal quote, reopen the quote) — this
is the ONE escaping rule, stated here once, and every caller uses it the same
way rather than re-deriving it. **A status line must not contain a
backtick (`` ` ``) or a `$`** — nothing legitimate in a one-clause status
report needs either, and forbidding them outright is simpler and safer than
trusting every caller's quoting.

## The same line opens the result file

`runstate.sh write-result <run-state> <path> --status '<line>'` writes the
status line as the file's **first line**, followed by whatever the agent
piped in on stdin. An agent that later needs to recall what it already
reported can read its own result file rather than holding it in context; a
different agent picking the file up sees the status line first and the detail
below it.

## Your reply is the saved line, byte for byte

Your final reply is **exactly** the line you passed to `write-result
--status`, byte for byte, with nothing added and nothing reformatted: no
backticks or code fence around it, no quotes, no leading label or trailing
remark, no changed spacing or separator. The driver runs `check-status` on
the line it reads from your reply, not on the one in your result file, so a
line that passed the check in `write-result` is still refused on return if
the reply wraps it in backticks. The `'\''` escape above is shell quoting,
not part of the line: a `'` in your text appears in the reply as a plain
`'`.

## One line, no exceptions

A status line that grows past one line — a second line, a wrapped paragraph,
an embedded list — breaks this contract: the driver never opens the result
file, so anything after the first line is invisible to it and to whatever the
driver dispatches next. This is refused mechanically: `runstate.sh
check-status --status '<line>'` is the one mechanical reading of the Grammar
above, and `runstate.sh route` and `runstate.sh write-result` run it on their
own `--status` argument **before either touches disk** — so an off-grammar
line writes no routing record and no result file, and all three refuse it
with the same one-sentence reason naming the rule that failed. The driver's
move on that refusal is to re-dispatch the same agent once, passing the
printed reason and nothing else.

What the check reads is the **shape**: one line, no backtick, no `$`, a
one-word first field, `result: needs-reading` or `result: no` in the
next-to-last field, and a non-empty whitespace-free path in the last. What it
cannot read is whether the line is **true** — whether `<status>` is the right
verdict, whether `<what changed>` describes what actually changed, whether
`result: no` is an honest claim about the result file. That stays the
**reviewer's** gate, the same way it catches any other acceptance-criterion
failure, and it reports it as a `fix`.
