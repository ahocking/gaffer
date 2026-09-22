# ADR 0029 — The handoff verification contract is appended by the handoff writer, from one template, and refused rather than degraded

- Status: Accepted
- Date: 2026-09-20
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0028](0028-loop-driver-mode.md) (the handoff file is a
  dispatched agent's whole brief, and the driver never opens a result file);
  [ADR 0023](0023-report-conventions-delivered-not-referenced.md) (naming a path
  is not delivering a file — the rule that decides *where* the contract lives);
  [ADR 0011](0011-guard-config-root-discovery.md) (config-root discovery and the
  restrictive union, reused here for the per-repository extension);
  [ADR 0021](0021-guard-fails-closed-on-unreadable-payload.md) (the same
  fail-closed shape: an unreadable input refuses rather than silently weakening);
  [ADR 0026](0026-post-completion-findings-route-by-scope.md) arm 2 (how this
  feature was filed: a new feature against a derived-done parent).
- Feature: `gspec/features/handoff-verification-contract/prd.md` and its plan
  T1–T6. This ADR is T6; the mechanism it records landed in T1–T5.

## Context

Under `thin-loop-driver` (ADR 0028) the driver hands an implementer and a
reviewer a handoff file path as their whole brief and reads back one status
line. The reviewer is the only check on an agent's self-report, so the gate is
exactly as strong as the handoff is specific. One 8-packet driver-mode run on
2026-09-16 measured that: seven packets reached review, five needed at least
one retry, and every defect was in work whose own status line said done. The
packet that had failed three earlier attempts closed first-try once its handoff
carried a `REQUIRED` line demanding a mutation check with both observed counts.
Two of the retries were this repository's known defect class — an unmeasured
state rendered as a measured one (PRD, Overview).

Those lines were being written into handoffs one packet at a time, by the
driver, from its own context. Nothing durable held them: a compaction or a
fresh session starts again from the bare `templates/task-packet.yaml`, which
carries only the weaker ancestor of the first line (a sweep must be named as its
own acceptance criterion), and `skills/run-loop/SKILL.md` §3.3 has the driver
append at most two conditional lines. The defect rate returns with the next
session.

The finding's literal proposal — put the lines in `templates/task-packet.yaml`
— would not deliver them. The template is what the *driver* reads; the agents
read only the handoff. ADR 0023 already made this rule for report conventions:
naming a path is not delivering a file, and a contract has to arrive in the
file its reader actually opens.

## Decision

### 1. The handoff writer appends the block; the packet template does not carry it

`scripts/runstate.sh handoff` appends the verification contract to **every**
handoff it writes — gspec-sourced, run-state-sourced, or a bundle — reading it
from `templates/handoff-required.md`. The template is resolved from the
script's **own** location (`HERE`, `scripts/runstate.sh:533-540`), never the
caller's cwd: the driving session's cwd is the consumer repository's checkout,
which has no `templates/` of its own, and a cwd-relative path would refuse
every handoff outside the plugin root. `ORCH_HANDOFF_REQUIRED` redirects
*where* the block is read from, for test fixtures; it is an override and not an
omission path. There is no flag, environment variable or code path that writes
a handoff without the block (`scripts/runstate.sh:2725-2743`).

The block goes **after** the piped body (`scripts/runstate.sh:2775-2781`). The
driver's two conditional lines — the sweep criterion and `session_boundary`,
per `run-loop` §3.3 — arrive inside that body and stay exactly where the driver
put them, neither moved into the block nor repeated by it. This resolves the
PRD's first deferred decision (before or after the driver's lines): after,
because `cmd_handoff` only ever appends to the stream it receives, and putting
the block first would mean the script splitting or re-ordering its own input,
which it does not do. The block's heading is therefore also the marker where
the task text ends.

> **Amended 2026-09-22 (`implementer-continuation`), not rewritten.** Two further
> lines now reach a handoff, both **above** the piped body and so above this
> block: the implementer's budget line and the spliced partial-work block. This
> paragraph's placement rule is unchanged; the additions and why they sit where
> they do are recorded in the 2026-09-22 amendment at the end of this ADR.

A driver that forgets §3.3 entirely still produces a handoff carrying all six
lines. That is the property the feature exists for: the contract reaches the
next packet with nothing for the driver to remember.

### 2. A missing template refuses the handoff; it never degrades it

When the template is missing, unreadable, or whitespace-only, `handoff` exits
non-zero naming the path it could not read and writes **nothing** — no
`handoff.md`, and no temp file beside it. The check runs at a deliberate point
(`scripts/runstate.sh:2725-2735`): **after** `cat` has drained stdin, so the
producer on the other side of the driver's pipeline (`gspec-backlog.sh
handoff`) finishes its write and the driver sees the real message rather than
`rc=141` from SIGPIPE; and **before** `mktemp`, so a refusal leaves no partial
file on disk.

The reason is the same one ADR 0021 gave for the guard: an agent cannot tell a
handoff that dropped its contract from a handoff whose contract did not apply.
A warn-and-continue would produce exactly the file the refusal exists to
prevent, with a warning on a stderr the dispatched agent never sees. The
`HANDOFF=refused` return for a packet already routed `hand-off-feature`
(`thin-loop-driver` T9) is untouched — that is a *report* the loop skips on, where this
is a *failure* the loop must stop on. `scripts/test-runstate.sh` pins both the
refusal and the mutation it rules out (warn-and-continue), recorded in the
case's comment.

### 3. `.agents/handoff-extra` unions across config roots by ADR 0011's rules

A repository extends the block without editing the plugin: each non-blank,
non-`#` line of `.agents/handoff-extra` is appended after the six as
`REQUIRED: ` followed by the line verbatim (`scripts/runstate.sh:2622-2647`).
The comment and blank-line rules are the whole syntax; the prefix is what keeps
a repository line that reads as prose or as a heading from dissolving the
block's boundary. The file is read from **every** discovered config root, and
discovery is ADR 0011's: candidates are `CLAUDE_PROJECT_DIR` and the cwd, every
ancestor of either that declares a `.agents/` directory, bounded by `$HOME` and
`/` and a depth cap, deduplicated by canonical path
(`scripts/runstate.sh:2581-2601`). The merge is the same restrictive union the
guard applies to `guard-extra-*`: a nested or foreign root can only **add**
lines, never remove or override another root's, so ambiguity about which root
is the real project can never yield a weaker contract than that project
declared. Identical lines from two roots collapse to one.

The walk is **reimplemented** in `runstate.sh`, not shared with
`hooks/guard.sh`, and that duplication is deliberate: the guard is a hook body
that reads a JSON payload on stdin, derives its roots from the payload's `cwd`
and exits with a tier decision — it has no callable form, and sourcing it would
run its policy. The guard defers its walk behind a read-only fast path because
it pays the cost on every tool call; here it is paid once per packet, so no
laziness is needed.

Two edges follow the rest of the design. Absent in every root, the mechanism
emits nothing — no header, no empty section, no warning — and the handoff is
byte-identical to one written before the mechanism existed; the stub shipped in
`templates/spec-driven-base/.agents/handoff-extra` is comments-only for exactly
that reason, so a consumer discovers the extension point without any handoff
changing. **Present but unreadable** is refused exactly as a missing template
is: the repository declared criteria, and a handoff that silently dropped them
is indistinguishable from one that never had any. Presence is tested as
`-e` or `-L` (a dangling symlink is present-and-unreadable, not absent) and
readability is probed by execution, since `[ -r ]` answers true for root on a
mode-000 file.

The PRD's second deferred decision — an applicability hint on an extension line
— stays deferred. A consumer's line applies to every packet; no syntax is
invented until the need is seen.

### 4. The six lines' text has one home

The text of the six lines lives **only** in `templates/handoff-required.md`.
Every other surface refers to the block by its heading, **"REQUIRED — the
verification contract"**, and restates nothing from it:

- `templates/task-packet.yaml` carries a short comment naming the template as
  the block's source and leaves its own sweep-criterion rule — the driver's
  first conditional line — where and as it was (`templates/task-packet.yaml:117-122`).
- `skills/run-loop/SKILL.md` §3.3 tells the driver that its two conditional
  lines are the whole of what it appends (`skills/run-loop/SKILL.md:463-468`).
- `agents/reviewer.md` and `agents/implementer.md` each carry a section headed
  "The handoff's verification contract" that states the contract from its own
  side and points at the template (`agents/reviewer.md:55-82`,
  `agents/implementer.md:113-130`).
- `CLAUDE.md`'s driver-mode bullet, amended alongside this ADR, names the
  template as the block's one home.

The lines are phrased by kind for any repository — they name no path, script,
tool or field of this one — because every consumer reads the template in place
from the plugin root. Each line carries a short label (`mutation-verification`,
`unmeasured`, `real-interface`, `report-the-limitation`, `current-file`,
`second-run`), and that label, not the line's text, is how a prompt or a review
refers to it. The check for drift is a search: each line's distinctive phrase
occurs in exactly one file under `templates/`, `agents/` and `skills/`. A copy
of a line anywhere but the template is the thing to remove.

### 5. Each applicable line is an acceptance criterion, judged by the reviewer

The reviewer holds the result file to every block line that applies to the
packet with the standing of any other acceptance criterion: a result file that
does not satisfy an applicable line is a `fix` naming that line, never a `pass`
with a note. What the reviewer judges is each line's **applicability** — it
never judges whether to check. A line that does not apply is skipped, not
marked satisfied. The implementer states the same contract from its side: its
result file addresses each applicable line, and where a line asks for a
limitation to be reported rather than approximated, reporting it is the pass.
The verdict vocabulary (`pass` / `fix` / `escalate`) and the routing of each
verdict are unchanged.

## Consequences

- **The contract survives compaction and a fresh session by construction.** The
  driver has nothing to remember; the script that writes the handoff is what
  carries it, and it is live on the next `handoff` call in the run that landed
  it (`runstate.sh` is invoked fresh per command). `agents/*.md` bodies reach
  the next dispatch this run; `skills/run-loop/SKILL.md` and
  `templates/task-packet.yaml` were read at run start, so their pointers first
  take effect on the next `/gaffer:run-loop`; `CLAUDE.md` is loaded at session
  start. No hook registration changes.
- **Six unconditional lines cost context on every packet**, including packets
  where most do not apply. The applicability rule bounds that cost to a read;
  the lines are not made conditional at the writer, because the writer parses
  none of its input and the reviewer is the one who knows what applies.
- **The contract is prompt-enforced at the reviewer.** Nothing mechanical reads
  a result file. A Stop-hook or regex validator was considered and declined for
  ADR 0023's reason: "does this result file satisfy this line" is judgment, and
  a regex cannot make it. The detector for a reviewer that stops checking is
  the retry rate in the next driver-mode run, countable from its routing
  records — not a sweep.
- **What is deliberately excluded.** Two of the originating finding's eight
  lines are not in the block: "deduplicate by `message.id`" is specific to this
  repository's metrics collector and stays in `CLAUDE.md`; "hook bodies are
  live mid-run" is already the packet template's `session_boundary` field. The
  block is generic by design, and repository-specific criteria go in
  `.agents/handoff-extra`.
- **An extension line is repository prose appended verbatim.** The `REQUIRED: `
  prefix frames it; the comment and blank-line filter is the only parsing. A
  line written as a heading or as task text is the consumer's own risk, stated
  in the shipped stub.
- **Regression sweep.** `scripts/test-runstate.sh` asserts the block on a
  handoff built from a piped task body (a `TEXT=` line plus one stand-in
  driver `REQUIRED:` line) and on one built from empty stdin; the block is not
  conditional on the body's source because `cmd_handoff` never inspects it,
  and no bundle- or run-state-sourced case exists in the sweep. It also covers
  the refusal (missing and whitespace-only), the
  script-relative resolution from a foreign cwd, and the extension file across
  a root with the file, one without, one comments-only (byte-identical to
  absent), one unreadable (refused), and two nested roots whose lines both
  appear. Each case records in its comment the wrong implementation it turns
  red on.
- **Measuring the contract's effect in consumer repositories is deferred.** The
  PRD's success metrics — first-attempt pass rate, both mutation counts stated
  wherever a test changed, zero retries for the unmeasured-as-measured class —
  are for this repository's next driver-mode run of five or more reviewed
  packets.

## Amendment (2026-09-22) — two new lines sit above the body, and the `REQUIRED` block did not move

`implementer-continuation` T1 (`55942e1`) and T5 (`7a969a4`) add two things to a
handoff file, and both had to be placed against the order decision 1 fixed. This
section records where they sit and why; decisions 1 and 2 are amended by nothing
here — the block still goes after the piped body, every handoff still carries all
six lines, and a missing template still refuses the handoff.

### Both additions go after the header and before the piped body

The implementer's **budget line** is written by `handoff` itself, for `--agent
implementer` and for no other agent, directly after the header. The **partial-work
block** — one marked `## Partial work on disk` block — is spliced in by
`runstate.sh refresh-handoff` directly after that budget line, before a
continuation and before every `fix`/`retry` re-dispatch. So a continuation's
handoff reads: header, budget line, partial-work block, task body (with the
driver's two conditional `REQUIRED` lines where §3.3 put them), then the block
this ADR is about.

The alternative — appending either after the body — is what the placement rules
out, and the reason is decision 1's own. The block goes after the body, and the
driver's two conditional lines arrive at the body's end; a line inserted after
the body would land **between those conditional lines and the six**, splitting
the contract into two halves with unrelated text in the middle. Above the body,
nothing is inserted between any of the contract's lines, the body stays adjacent
to the block, and "the block's position and content are untouched" needs no
argument beyond reading the file.

### The contract is never rewritten, because the handoff is spliced

`refresh-handoff` replaces, inserts or removes exactly one marked block and
leaves every other byte alone — the `REQUIRED` block and any `amend-handoff`
block included. It refuses rather than guesses where a block ends when the
markers are unpaired or duplicated, or when a block sits at or above the end of
the header, for the same fail-closed reason decision 2 gives for a missing
template: a handoff whose contract was swallowed is indistinguishable, to the
agent reading it, from one whose contract did not apply. With an empty set the
block is removed together with its trailing blank line, leaving the file
byte-identical to one written without the mechanism; the budget line survives
every splice, so a continuation carries it without a second code path.

`scripts/test-runstate.sh` pins both halves directly: with the budget line
removed, the body and the `REQUIRED` block are byte-identical to a handoff
written without it; and around a spliced partial-work block, the `REQUIRED`
block from its heading to the end of file compares equal to the first dispatch's,
with the driver's conditional line still immediately after the body. Each case
records the wrong implementation it turns red on.
