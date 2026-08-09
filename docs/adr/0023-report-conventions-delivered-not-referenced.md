# ADR 0023 — Report conventions are delivered, not referenced

- Status: Accepted
- Date: 2026-08-09
- Deciders: user (tech lead), orchestration plugin
- Relates to: [ADR 0003](0003-defer-custom-voice-frontend.md) (the plugin produces
  reports; the frontend delivers them),
  [ADR 0012](0012-delegated-loop-driver.md) (the wire/human report split, and the
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
