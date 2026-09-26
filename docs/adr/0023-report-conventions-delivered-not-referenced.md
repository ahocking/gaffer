# ADR 0023 — Report conventions are delivered, not referenced

- Status: Accepted
- Date: 2026-08-09
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0012](0012-delegated-loop-driver.md) (the wire/human report split, and the
  "render, don't relay" amendment),
  [ADR 0005](0005-crash-safe-resume.md) (the SessionStart hook this adds a sibling to),
  [ADR 0017](0017-graceful-cooperative-pause.md) (why hook-injected context is
  advisory and never enforcement).

## Context

The plugin has a detailed human-facing report contract — a fixed glyph vocabulary, an
indentation contract, a shared decision block, three loop shapes. It was written into
`templates/report-templates.md` and referenced from every skill and from the Chief
Engineer.

In consumer repos it did not take. Reports came out as free prose unless the human
restated the format **every session**. Two independent gaps, each sufficient on its
own:

**1. Inside a skill run, nothing ever read the file.** Every reference was prose naming
a path — *"Render the returned check-in into the human check-in shape in
`${CLAUDE_PLUGIN_ROOT}/templates/report-templates.md` (shape A)"*. None was an imperative
`Read`. (The plugin already knew the difference: `run-loop/SKILL.md` explicitly `Read`s
`parallel.md`, because that one had a measured token cost attached to *not* loading it.)
So an agent rendered from the one-sentence paraphrase in the SKILL.md and had never seen
the 383-line contract. Drift inside a skill run was not disobedience — the rules were
never delivered.

**2. Outside a skill run, nothing wired it at all.** A plugin's own root `CLAUDE.md`
does not propagate to consumer repos (this repo's first line says so). The consumer
overlay `templates/spec-driven-base/CLAUDE.md` — 131 lines, read every session — never
mentioned reports, glyphs, or the decision block. The one always-on channel,
`hooks/session-start.sh`, stayed silent unless a run was in flight and only ever spoke
about resume.

## Decision

Deliver the contract through three layers, each covering what the others cannot.

**L1 — the skills `Read` it.** Each skill now carries an explicit `Read` at its first
emission point. Scoped two ways, because the cost is real:

- **By role.** Only the agent writing to the *human* reads it. A dispatched Chief
  Engineer (relay mode) or worktree lane returns the machine-shaped wire format and the
  scheduler renders it — those agents must not read either file, or a 20-packet relay
  pays ~5k tokens per packet for a shape it never emits.
- **By need.** `templates/report-templates.md` was split. The conventions — glyph
  vocabulary, indentation contract, decision block, header tally, the four rules — moved
  to **`templates/report-conventions.md`**; the A/B/C shapes stayed. Skills with no
  shape of their own (`review-change`, `metrics`, `migrate`, `new-project`) read only
  the conventions, roughly half the bytes.

**L2 — the consumer repo's own `CLAUDE.md` carries a distilled card.** This is the
strongest channel and the only one that is genuinely always-on: a repo's `CLAUDE.md` is
the *human's standing instruction*, in context on every turn, and treated as
authoritative rather than as observed data. `templates/report-conventions-card.md` ships
in the overlay (so `/gaffer:new-project` bootstraps with it) and `migrate.sh apply`
stamps it into existing repos byte-verbatim behind a `gaffer:report-conventions` marker.

**L3 — a SessionStart hook injects the same card** when the repo's `CLAUDE.md` does not
carry the marker. This covers repos that never re-run migrate, and it upgrades with the
plugin where a stamped `CLAUDE.md` does not.

**Scope: reports, not responses.** The conventions govern anything summarizing work,
state, a plan, a verdict, or a choice. They explicitly do **not** govern ordinary
conversation — a question answered or a snippet handed over is an answer, and a glyph
tally on a two-line reply is decoration. The card says so in its second paragraph,
because that boundary is what stops the rule from discrediting itself.

## Consequences

**L2 and L3 are mutually exclusive by construction.** The marker suppresses the hook. A
repo that has been migrated pays for the card once, in standing context; a repo that has
not pays for it once, at session start. Never both.

**L3 is advisory and must never be described otherwise.** Hook `additionalContext`
reaches the model — verified for PreToolUse in the ADR 0017 probe — but a correct agent
treats injected context as untrusted *data*, not instruction. That probe's subagents
read an injected "stop" and declined it. That asymmetry is exactly why L2 outranks L3:
the same words in the repo's own `CLAUDE.md` are the human's instruction and are obeyed
as such. **Format enforcement is not available and was not attempted** — see below.

**Two SessionStart entries, not one.** The card fires on `startup|resume|clear|compact`;
`session-start.sh` keeps `startup|resume`. Merging them would be a bug:
`session-start.sh` reads `status: running` as "the previous session died", so firing it
after a mid-run compact would announce a crash that never happened and push a live run
into reconcile.

**Three copies of one contract is the standing risk.** The full file, the card, and the
overlay's copy can drift. `scripts/test-report-conventions.sh` byte-compares the overlay
against the card and caps the card's size (detail belongs in the full file, which is not
paid for every session); `scripts/test-migrate.sh` asserts the stamp is verbatim.

**What was rejected: a `Stop`-hook format validator.** A hook could in principle inspect
the assistant's output and block. It was not built. Most turns in a consumer repo are
not reports, so a regex looking for glyphs would false-positive constantly, and "is this
a report?" is precisely the judgment a regex cannot make. Blocking a turn over a format
opinion is also disproportionate to the harm. The honest position is that this ADR makes
the contract **reliably present**, not enforced.

**Known gap.** L2 lands in existing repos only when `/gaffer:migrate` is re-run. Until
then those repos are on L1 (inside skills) and L3 (everywhere else), which is the
configuration L3 exists to serve.

## Amendment — the loop's shapes are rebuilt on `run-digest` (2026-09-16, ADR 0028)

- Status: Accepted, amending this record. Nothing above is retracted.
- Relates to: [ADR 0028](0028-loop-driver-mode.md) (driver mode), [ADR 0025](0025-remove-backlog-done.md)
  (the "✅ is this session" rule this narrows), `thin-loop-driver` T18.

**What changed and why.** This ADR's three delivery layers (L1 `Read`, L2 the stamped
card, L3 the SessionStart hook) are unchanged and still correct. What changed is the
thing being delivered: ADR 0028 made the loop driver thin. Every agent the loop
dispatches now returns **one status line** (`templates/status-line.md`) and writes its
detail to a result file the driver never opens, so the driver no longer holds a running
narrative of the run — and after a compaction, or in a session that resumed another
session's run, it holds nothing of the run at all. Shape A's multi-section per-packet
check-in assumed material the driver stopped having.

**Three consequences, recorded here so the shapes are not "fixed" back later:**

**1. Shape A is one line per ended packet, with no tally and no decision block.** It
carries the packet's id, a plain-English title and its outcome, plus one line per
escalation-decider decision since the last report. A header tally on top of one or two
lines is longer than what it summarizes, and the run's state is what shape B is for.
The header tally therefore opens **B and C only**.

A decision that *ended* its packet — a `hand-off-feature` always does — still takes its
own 🔀 line beneath the packet's own outcome line, so one packet can occupy two lines
here. That is the single documented exception to the conventions' rule that such a
packet takes one line carrying 🔀, and it is recorded in both files: that rule exists so
the packet counts once in each tally, and shape A has no tally to count in. The
alternative — folding the decision into the packet's line — would drop the decision line
this shape exists to emit.

**2. Shapes B and C are assembled from `runstate.sh run-digest`, not from memory.** The
digest reads the run's handoff files, its result files' first lines, its routing records,
the outcomes log and the driver-mode records, and prints four line kinds: `packet`,
`decision`, `handoff-feature` and at most one `enter`. Three facts it does not carry are
named in `templates/report-templates.md` and are the **only** ones a shape may read from
elsewhere — the pending count, a periodic pause's setting, and the branch/sha. This is
not a licence to re-open the repo to enrich a report; it replaces one unreliable source
(memory) with one cheap, fixed-size file read, and the "do not go back to disk" rule in
`templates/report-conventions.md` is otherwise intact.

**3. ✅ in shape B now counts the RUN, from the digest — narrowing ADR 0025 D3.** D3's
rule was that ✅ counts what *this session* landed, read from check-ins the agent itself
rendered and never from disk. Its purpose was to stop a backlog-wide or `backlog.done`-
derived count from being reconstructed by scanning trailers. That purpose survives: the
digest is one read of the run's own records, `backlog.done` stays deleted, and nothing
scans trailers. But the PRD requires a stop report to name **every packet the run began**
with its outcome, whoever renders it — which a session-scoped count cannot do across a
compaction or a hand-over. So ✅ in shape B counts `packet` lines reading `green`.
Everywhere else, including any report with no digest behind it, D3 stands unchanged.

**What this amendment does NOT change.** The card (`templates/report-conventions-card.md`)
and its two copies are untouched and stay byte-identical — the change is to the shapes,
not to the conventions the card distills, which is why L2/L3 need no re-stamp. The glyph
vocabulary gains nothing: ⏸️ stays header-only, and a paused packet is named in shape B's
⚠️ **Unfinished** section with the *word* paused. The ⚠️ bucket's *label* does move —
shape B words it **unfinished**, because there it aggregates `blocked`, `interrupted`,
`abandoned`, `open` and `paused`, and "blocked" would be wrong for four of those five.
Glyph, tally position and fixed order are unchanged, the section heading moves with the
word so the table-of-contents correspondence holds, and `templates/report-conventions.md`
states the two labels together rather than leaving the shapes file to contradict it. `templates/check-in.md` survives for a
Chief Engineer dispatched for self-contained work outside a loop packet, and now says so;
it is no longer an input to any loop report.

**Known gap.** Nothing mechanically checks that a rendered report was actually assembled
from the digest rather than recalled — the same honest position this ADR already takes
about format enforcement. `scripts/test-report-conventions.sh` asserts the contract is
*present and consistent* (the shapes name the digest, the wire format says it is not the
loop's, this amendment is an appended section rather than a rewrite); the reviewer is
what catches a report that ignored it.

## Relocated from CLAUDE.md (2026-09-22) — design notes with no other home

Nothing above is changed by this section. These points were carried only in the repo-root
`CLAUDE.md` and are recorded here so that file can hold the rules without the reasoning.

- **The card is small on purpose.** `templates/report-conventions-card.md` is a ~2.9k-char
  distillation, the always-on layer, and the one source both L2 (the consumer `CLAUDE.md`
  stamp) and L3 (the hook) copy from. It is a fourth file, not a fourth contract.
- **The decision block is a shared primitive, not stop-report furniture.** It is also the
  Chief Engineer's intake "2–3 approaches with trade-offs", `review-change`'s Risks
  section, and an inline ask under a blocked packet in a report whose run is still going.
  It is factored out because four near-identical shapes would drift apart, and the
  un-actionable form ("things a human should weigh") is what they drift into.
- **The kickoff is the cheapest correction point in a run.** A wrong assumption costs a
  sentence there and several packets at the stop report, which is why shape C carries an
  explicit `Assuming:` line and why `run-loop` emits it after preflight and backlog
  resolution, when it states facts rather than intentions.
- **Deliberately not built, so they are not invented later:** a welcome-back shape
  (identical content to B — reuse it); a metrics shape (numbers-dense and pulled on
  demand, not pushed); anything for guard ASK-tier prompts (Claude Code renders those
  natively and a template cannot reach them); and a mid-packet progress heartbeat (a
  subagent returns nothing until it finishes, a transport limit — a shape that implied
  liveness would be lying).
- **No header tally on a report with nothing to count.** Reports without a shape
  (`review-change`, `metrics show`/`analyze`, `new-project`, `migrate`) still owe the
  glyph vocabulary, the indentation contract and the decision block, but a tally on a
  metrics summary is decoration, and decoration is what teaches a reader to stop trusting
  the glyphs.

## Relocated from skills (2026-09-25) — the pause skill's report reasons

Moved out of `skills/pause/SKILL.md` by `skill-prompt-trim`. The skill keeps each
rule with at most a one-clause reason; the fuller wording is recorded here.

- **Why the report contract is `Read`, not named** (the pause skill's preamble):

  > Naming a path is not reading it, and unread they produce free prose.

- **Why Shipped lines are not a packet-id list** (pause step 4):

  > Not a packet-id list: `wbr-t14` means nothing to the human a week later,
  > **Rate-limit auto-pause** (`wbr-t14`) does.

- **Why each blocking question is rewritten as an answerable choice** (pause
  step 4):

  > A question the human must go reading to understand is a question that stalls
  > the run.

## Relocated from skills (2026-09-25) — the resume skill's report reasons

Moved out of `skills/resume/SKILL.md` by `skill-prompt-trim`. The skill keeps each
rule with at most a one-clause reason; the fuller wording is recorded here.

- **Why a surfaced question names its packet by title** (resume §3). The skill keeps
  "since the human will not recognise the id". It used to read:

  > These were written by a session that no longer exists, so give the human the
  > plain-English title of the packet they block — they will not recognise the id.

- **Why the resuming kickoff states what is left** (resume §4):

  > The human may be days removed from the run and remembers none of the ids; the
  > checkpoint you just loaded is the only thing that does.

## Relocated from skills (2026-09-25) — the run-loop skill's report reasons

Moved out of `skills/run-loop/SKILL.md` (the report-contract section and §2) by
`skill-prompt-trim`. The skill keeps each rule with at most a one-clause reason; the
fuller wording is recorded here.

- **Why the report contract is `Read`, not named** (the report-contract section). The
  skill keeps "unread, you render from memory". It used to read:

  > **Naming a path is not reading it** — unread, you render from memory and
  > produce free prose, which is the exact failure these files exist to prevent.

- **Why a fresh run's kickoff plans from the backlog it just resolved** (§2's
  kickoff). The skill keeps "a fresh run's digest has no `packet` lines yet". It
  used to read:

  > a fresh run's digest has no `packet` lines yet, so the forward plan is the
  > backlog you just resolved above, a file read moments old.

## Relocated from skills (2026-09-25) — the run-loop skill's per-packet report reasons

Moved out of `skills/run-loop/SKILL.md` §3's **Form this packet's members** and
**Write the handoff, then start** steps by `skill-prompt-trim`. The skill keeps each
rule with at most a one-clause reason; the fuller wording is recorded here.

- **Why a non-zero `group` exit is reported.** The skill keeps "since a silent
  fallback reads as "nothing to bundle"". It used to read:

  > since a silent fallback would read as "nothing to bundle" rather than "the check itself failed."

- **Why `$SWEEP` is carried to the packet's report.** The skill keeps "this sweep is
  the only point that knows which packets are newly closed". It used to read:

  > since `run-digest`'s `packet` lines are never filtered by `--since` and this sweep
  > is the only point that knows which of them are newly closed; without it a swept
  > packet's line is never picked out of the digest until the eventual stop report.

- **Why `SINCE` is captured before the start is attested.** The skill keeps "so
  §3.5/§3.6's report scopes `run-digest --since "$SINCE"` to this packet's own
  decisions". It used to read:

  > so §3.5/§3.6's shape-A report can later scope `run-digest --since "$SINCE"` to
  > only the decisions made during THIS packet's own attempts, never one already reported for an earlier packet

## Relocated from skills (2026-09-25) — the run-loop skill's landing and stop-report reasons

Moved out of `skills/run-loop/SKILL.md` §3's **Land (the `land` action)** step and
`## 4. Termination` by `skill-prompt-trim`. The skill keeps each rule with at most a
one-clause reason; the fuller wording is recorded here.

- **Why each swept packet gets its own ⚠️ line in the landing report.** The skill keeps
  "since that sweep's record is the only thing marking these as new". It used to read:

  > `run-digest`'s `packet` lines are never filtered by `--since`, so this sweep's own
  > record of what it just closed is the only thing marking these as new, not already
  > carried by an earlier report

- **Why a failed capability call is an alert, not a withheld line.** The skill keeps
  "as an alert alongside the ✅/🔁 line, never a reason to withhold it". It used to
  read:

  > the packet still landed, so this is an alert alongside the ✅/🔁 line, never a
  > reason to withhold it.

- **Why a capability flip in the stop report carries no ⚠️.** The skill keeps "since a
  capability flip is not a packet". It used to read:

  > (the conventions reserve that glyph for a tally-counted section carrying one line
  > per packet, and a capability flip is not a packet)

- **Why the stop report reads the whole-run digest.** The skill keeps "whether or not
  this session was the one that ran it". It used to add:

  > (a compaction or a resumed session reads the same report)

- **Why a landed bundle's one line must name every member.** The skill keeps "A bundle
  is ONE packet — one `packet` line in `run-digest`, one ✅ line, never one per member —
  but `<title>` on that line is only the cursor's own `TEXT=` line (§3.3)". It used to
  read:

  > a bundle's several members share the one directory keyed to its own id,
  > `<cursor>` — so it still counts as ONE packet, matching `run-digest`'s own line
  > count and this shape's tally: a bundle earns exactly one ✅ line, never one per
  > member. But `<title>` on that line is only the cursor's own `TEXT=` line (§3.3),
  > so rendering it as-is would read a four-task bundle as one task, and the header
  > tally would read `✅ 1` for four landed tasks.

- **Why membership is confirmed from the branch.** The skill keeps "since that line
  records the intent at §3.3 and the commit's own trailers record what landed". It
  used to read:

  > This session may not be the one that landed it (a compaction, or a resumed session
  > inheriting someone else's run), so confirm membership from the branch itself
  > rather than trusting the `BUNDLE=` line alone — that line was written back at
  > §3.3, before the packet even started, and names an intent

- **Why both branches are searched, never `<base>..HEAD`.** The skill keeps "§3.7 has
  already merged each earlier bundle's commit into the integration branch". It used to
  read:

  > §3.7 merges a landed packet's branch into the integration branch right after it
  > lands, so by stop-report time `HEAD` is wherever the *last* packet in the run
  > happens to have run, and every earlier bundle's commit is only reachable from the
  > integration branch, not from `<base>..HEAD`; that range finds nothing for any
  > bundle but the most recent one — exactly the resumed/compacted case this step
  > exists to cover.

- **Why the trailer list is read in commit order.** The skill keeps "`<cursor>` first
  (§3.6 writes it first)". It used to add:

  > and that ordering is load-bearing there for orphan-adopt — see that step

## Relocated from skills (2026-09-25) — the migrate skill's report and conventions-card reasons

Moved out of `skills/migrate/SKILL.md` by `skill-prompt-trim`. The skill keeps each
rule with at most a one-clause reason; the fuller wording is recorded here.

- **Why the conventions are `Read` before the summary.** The skill keeps "that summary
  has **no shape of its own**, so those conventions *are* its format; naming the path
  is not reading it". It used to add:

  > the glyph vocabulary, the indentation contract, and the decision block that every human-facing report in this
  > plugin owes.

  > and unread they produce free prose.

- **Why the stamped card is left exactly as inserted.** The skill keeps "since a
  paraphrase drifts from the plugin's own contract". It used to read:

  > The marker is what stops `hooks/report-conventions.sh` injecting the
  > same text again at every session start, and a paraphrase drifts from the plugin's own
  > contract. This is the layer that makes reports come out in the house format *without
  > the human asking each session*; a repo without it gets free prose on every turn that
  > is not inside a gaffer skill.
