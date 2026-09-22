---
spec-version: v2
depends_on: [thin-loop-driver, handoff-verification-contract]
---

# Feature: handoff-spec-inlining

## Overview

Under `thin-loop-driver` the handoff file is the implementer's whole brief,
and it already carries the acceptance criteria a task's `covers:` quotes name
(ADR 0020 D2 amendment; ADR 0023: naming a path is not delivering a file). It
does not carry the architecture. `scripts/gspec-backlog.sh handoff` strips a
task's `- arch:` line from the body it prints and hands `arch.md` as a bare
`ARCH=` path, so the implementer opens the whole file — and, since content in
context is re-read on every later turn, pays for it on every turn after. This
repository's own measurements have the shape: the implementer holds most of
the turns and does nearly all the reading, a quarter of its reads are
re-reads, and one UI-heavy consumer feature re-read ~81M tokens per packet
against 4–12M on non-UI features. gspec 3.2.0 measured the same thing in its
own build driver and
inlined only the sections a task's anchors resolve to, telling the agent there
is no spec file to open; spec reads per continuation fell from ~14 to 1.4.
None of that reaches a `/gaffer:run-loop` packet, because gaffer does not run
gspec's driver (ADR 0020: gspec owns what to build, gaffer owns how a unit of
work is executed).

This feature does the same at the handoff: the anchored sections of `arch.md`,
and the design blocks those sections name, are inlined in the body under
their own markers, bounded by a word budget, and the paths disappear from the
handoff; the implementer's own read discipline — terse test output, never
hunting for its own prompt — is in scope with it, since the same context pays
for both. `arch.md` and `design.html` are outside the adapter's pinned consumed
contract today; anchored sections of them come inside, through the one place
layout is resolved and pinned by the adapter's sweep — gspec has moved these
files twice, and a fourth silent reader is the trap.

## Users & Use Cases

- **The implementer reading a handoff** — its whole brief is that file. It
  needs the architecture text its task depends on in the file it reads, and a
  clear statement that there is nothing more to open for it.
- **The driver session in driver mode** (ADR 0028) — passes a handoff path,
  reads one status line, never opens a result file. It must not have to
  resolve anchors, judge budgets, or name spec files by hand.
- **The adapter maintainer** — needs one resolver for the two files' location
  and one sweep pinning it, so the next gspec relocation fails loudly in
  `scripts/test-gspec-backlog.sh` rather than silently emptying handoffs.
- **A consumer repository operator with large architecture and design files**
  — needs the inlined text bounded, and the bound adjustable per repository
  without editing the plugin.

## Scope

**In**
- `scripts/gspec-backlog.sh handoff` resolves each `- arch:` anchor on the task
  line to the heading section of the feature's `arch.md` it names and inlines
  that section's text under a marker, in place of the `ARCH=` path; an
  unresolvable anchor is reported, never guessed.
- The design block a `### Screen:` section names, inlined the same way;
  `design.html` is otherwise not named.
- A word budget, default in the region of 6,000 words, overridable in
  `.agents/project-overrides.yaml`, past which sections are named by heading
  with a line count instead of inlined.
- A line in the handoff body stating that the spec content the task needs is
  in the handoff.
- Lines in `agents/implementer.md`: the inlined-sections contract, keep test
  output terse, never re-read a skill or agent prompt file.
- Both files' paths resolved in one `_resolve_*` function beside the PRD and
  plan resolvers, used by every site that names them; sweep cases in
  `scripts/test-gspec-backlog.sh`.

**Out**
- Any parsing of `arch.md` or `design.html` anywhere but
  `scripts/gspec-backlog.sh` — the standing rule that every gspec read goes
  through the adapter.
- What gspec writes into either file, including the `- **route:**` line
  gspec 3.2.0 added to screen blocks — tolerated, never interpreted.
- The reviewer's brief: it reads the same handoff and gains the same text.
- The acceptance-criteria inlining `COVERS=` already does, and its budget-free
  treatment.
- `gspec-backlog.sh next`'s `ARCH=`/`DESIGN=` lines, which the driver reads
  and the implementer never sees; they keep printing paths.
- gspec's own `gspec build` continuation briefs.
- The REQUIRED block `runstate.sh handoff` appends, and its position after the
  piped body.

**Deferred**
- Inlining for an architect or ux-designer dispatched on a design-heavy
  packet; either may legitimately need the whole file.
- Measuring the effect in this repository: one feature here has an `arch.md`
  and none has a `design.html`, so the success metrics below are for consumer
  runs.

## Capabilities

- [x] **P0**: A handoff inlines the `arch.md` section each `- arch:` anchor names
  - `scripts/gspec-backlog.sh handoff` splits the task's `- arch:` value on
    ` · ` exactly as `_split_covers` splits `covers:`, and accepts each entry
    in any of the three forms gspec's plan floor treats as one anchor —
    `#entity-order`, `### Entity: Order`, `Entity: Order` — compared by slug
    with hyphens ignored; `—` or no `- arch:` line means no anchors, and the
    `- arch:` line itself stays out of the printed body as today
  - each resolved anchor prints a marker line carrying the anchor (working
    name `ARCH-SECTION=<anchor>`) followed by that H3 block's text, from its
    heading through the line before the next H2 or H3, indented under the
    marker the way `COVERS=` indents criteria and placed in the body before
    the REQUIRED block; a `- **route:** /path` status line inside a
    `### Screen:` block is carried as block text and never ends the block
  - an anchor matching no heading prints `UNMATCHED-ARCH=<anchor>` and inlines
    nothing for it — never a nearest match, the `UNMATCHED=` rule for covers
    quotes — on a checked task as on an unchecked one, where a frozen anchor
    may name a superseded heading; a task with no anchors prints no marker and
    no path; no `ARCH=` line of any form, the `absent` sentinel included,
    appears in `handoff` output for any task
  - a bundle's handoff carries each distinct anchor's text once, at its first
    member's marker, however many members name it

- [x] **P1**: The design block a screen section names rides with it
  - when an inlined section is a `### Screen: <Name>` block and the feature's
    `design.html` holds `<section id="screen-<kebab>">` for the slugified
    name, the handoff prints `DESIGN-SECTION=screen-<kebab>` (working name)
    followed by that element's markup from its opening tag through its
    matching close, indented and placed as an arch section is
  - a screen section whose `design.html` is present but holds no matching
    element prints `UNMATCHED-DESIGN=screen-<kebab>` and inlines nothing for
    it, counting as an unmatched report for the statement line above, whose
    path clause then names each file the handoff drew sections from; when no
    inlined section is a screen, or the feature has no
    `design.html`, the file is not named at all — no `DESIGN=` line, no empty
    marker
  - a design block counts against the same budget as the arch sections and is
    named by heading past it under the same rule; `scripts/test-gspec-backlog.sh`
    gains a case for a screen's design block inlined, and one for
    `design.html` unnamed when no screen is inlined

- [x] **P0**: A word budget bounds what one handoff inlines
  - the budget defaults to 6,000 words and a key in
    `.agents/project-overrides.yaml` overrides it, and the annotated reference
    copy under `templates/spec-driven-base/` documents the key, its default,
    and what raising it costs in handoff size; a missing, empty or
    non-numeric value reads as the default, never as unbounded
  - sections are inlined in `- arch:` order until the next would carry the
    running word count over the budget; from that section on, every remaining
    resolved section prints a distinct marker (working name
    `ARCH-HEADING=<anchor> lines=<n>`) with its heading and line count instead
    of its text, and one line states that the budget was reached and its
    value; a handoff under budget carries no such line
  - the budget counts inlined section text only, of whichever section kinds
    the handoff draws in; the acceptance criteria `COVERS=` inlines are
    outside it and unchanged; for a bundle the budget spans the whole bundle
    handoff

- [x] **P0**: The handoff says the spec it needs is in it
  - whenever at least one section was inlined and none was named-not-inlined
    or reported unmatched, the body carries one fixed line stating that the
    specification text this
    task needs is inlined under the section markers above and there is no
    spec file to open for it; a task with no anchors carries no such line
  - when one or more sections were named rather than inlined, or one or more
    anchors were reported unmatched, the line instead names the file's path
    once — the only place a spec-file path (`arch.md`, `design.html`, the PRD
    body) appears; the `PRD=` bookkeeping line the loop's recovery steps read
    is not a spec-file path and stays — and says the named sections are to
    be read there by heading, not the whole file
  - `agents/implementer.md` states the same contract from its side: the
    inlined sections are the specification for the packet; a spec file the
    handoff draws from is opened only for a section the handoff named rather
    than inlined, or to investigate an anchor it reported unmatched, and then
    by heading with `offset`/`limit`, never whole

- [x] **P1**: The implementer keeps its own context lean
  - `agents/implementer.md` states: run the narrowest test target that covers
    the change, and report the summary and failures rather than piping a whole
    test log into context — the full log belongs in the result file when the
    reviewer needs it
  - `agents/implementer.md` states: never `Read` a skill or agent prompt file,
    its own or another's, and never search for one with `Grep`/`Glob` either
    — its instructions are already in context, and the handoff is the whole
    brief
  - prose only; no sweep case

- [ ] **P0**: The two files are read through one resolver and pinned by the sweep
  - `arch.md` and `design.html` paths come from a resolver beside
    `_resolve_prd_path`/`_resolve_plan_path`, enumerating the layouts these
    two files have existed in (today only the 3.x feature folder), newest
    first, and every site that names either file takes the path from it — `cmd_next`'s
    `ARCH=`/`DESIGN=` lines and `cmd_handoff`'s inlining — with no literal
    path test remaining at either site; `next`'s output is unchanged and its
    existing cases keep passing
  - the section grammar the resolver reads is the H2/H3 shape
    `gspec-conventions` defines, and a heading form it does not recognise
    resolves to nothing, reported as unmatched rather than guessed
  - `scripts/test-gspec-backlog.sh` gains cases for: an anchor resolved to its
    text under the marker, in each of the three anchor forms; an anchor
    unmatched; a task with no anchors printing neither marker nor `ARCH=`; the
    budget reached, with headings, line counts and the statement; a
    `- **route:**` line inside a screen block carried without ending it; and a
    fixture whose files sit in the layouts the resolver enumerates, so a
    relocation turns the sweep red
  - the standing statements that the two files are outside the consumed
    contract and never parsed are corrected to say anchored sections are now
    inside it and no path surfaces in a handoff: the adapter's opening
    consumed-contract list ("nothing outside this list is read") and its
    layout comment (the "3.x feature folder also holds" block) in
    `scripts/gspec-backlog.sh`, the `handoff` output contract in the subcommand
    summary header and in the block above `_handoff_one`, the ADR 0020 bullet in
    `CLAUDE.md`, the "Scope stays narrow on purpose" paragraph of
    `docs/adr/0020-gspec-boundary-and-version-pin.md`, and the "also holds"
    paragraph of `docs/gspec-3.2.0-migration.md`

## Dependencies

- `thin-loop-driver` — the parent: the handoff file is the whole brief, which
  is what makes a section inlined there delivered and a path there not.
  Derived-done; nothing here re-opens a capability or edits a checked task.
- `handoff-verification-contract` — `runstate.sh handoff` appends the REQUIRED
  block after the piped body; the inlined sections travel in the body, before
  it. Nothing here moves that block.
- `packet-bundling` — shipped; a bundle handoff is one of the handoff sources
  the inlining and the budget must reach. Not blocking.
- `gspec-adapter-consistency` and `implementer-continuation` — **not
  blocking, but same files**: the first edits `scripts/gspec-backlog.sh` and
  `scripts/test-gspec-backlog.sh`, the second `agents/implementer.md`. Neither
  should be in flight against those files at once with this one.

## Assumptions & Risks

- Assumption: the handoff is the only thing the implementer reads as its
  brief, so text in it is delivered and a path in it is a file opened whole.
- Assumption: a task's `- arch:` anchors name the sections it needs. gspec's
  plan floor requires every anchor to resolve, and `/gspec-plan` writes them;
  a plan authored without them gets today's behaviour, minus the path.
- Assumption: the payoff is in consumer repositories. This one has one
  `arch.md` and no `design.html`, so the mechanism is built and pinned here
  and measured there.
- Risk: an anchor-heavy task or a bundle produces a large handoff. It is
  bounded by the budget, and a large handoff read once still costs less than
  a whole file re-read on every turn.
- Risk: a future gspec changes the anchor or heading grammar and every section
  reads as unmatched. The sweep and the pinned resolver are the detector; an
  unmatched report is loud where a bare path was silent.
- Risk: the no-file-to-open line is prompt-enforced, and an implementer may
  open `arch.md` regardless. The detector is per-packet `by_tool.Read` and
  `by_agent_role.implementer.cc_shape.max` in run-metrics, not a sweep.

## Success Metrics

Baseline: the operator's session measurement of 2026-09-14 over consumer
transcripts (~81M tokens re-read per packet on a UI-heavy feature against
4–12M on non-UI features); the scripts that produced it were not preserved,
so it is context, not a figure the metrics below re-derive. The re-derivable
baselines are the prior run's own: its per-packet implementer `Read` count
against the two files, and its count of retries attributed to a missing spec
detail — each unmeasured today, never zero.

- On the next consumer run of five or more packets whose feature has an
  `arch.md`, the implementer's `Read` calls against
  `gspec/features/*/arch.md` or `design.html` fall to zero for every packet
  whose anchors all resolved and stayed under budget — countable from that
  run's transcripts, since `by_tool` counts `Read` calls per packet but does
  not record the path; the prior run's count is taken the same way.
- `by_agent_role.implementer.cc_shape.max` per packet in that run's
  `.agents/metrics/<run>/run-metrics.json` falls against the same feature's
  prior run.
- Zero packets in that run are retried for a missing spec detail that an
  inlined section carried — countable from the review files, against the
  prior run's count taken the same way.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **The exact marker names** (`ARCH-SECTION=`, `DESIGN-SECTION=`,
  `ARCH-HEADING=`, `UNMATCHED-ARCH=`, `UNMATCHED-DESIGN=`). The working names
  above satisfy every criterion; the plan fixes them with the parser.
- **Whether the word count is computed by splitting on whitespace or
  approximated from bytes at a stated ratio.** The budget is stated and
  reported in words either way; decided at plan time with the counting code.
- **The override key's name and how it merges across nested config roots.**
  A numeric limit has no restrictive union the way `bypass-ask-tier` does; the
  need for a per-root rule has not been seen.
