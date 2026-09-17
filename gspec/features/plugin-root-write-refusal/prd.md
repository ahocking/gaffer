---
spec-version: v2
depends_on: [thin-loop-driver, thin-loop-driver-gaps]
---

# Feature: plugin-root-write-refusal

## Overview

Driver mode refuses a main-thread write unless the guard can prove the target
lands under the repository's own `.agents/`. Packet t4 of
`thin-loop-driver-gaps` narrowed that refusal to targets that could reach a
packet's commit — correct against the tier's stated scope. But in a consumer
repository the plugin lives **outside** the driven tree and is not a discovered
config root, so after the narrowing a driving main thread may write the plugin's
own guard, its other hook bodies, and its agent and skill prompts with no prompt
at all. Before t4 the blanket outside-`.agents/` rule refused them incidentally.

Three facts make this worth closing rather than accepting. A hook body is
**spawned per event**, so such an edit takes effect **mid-run**, on the next tool
call, in the run that made it — not at the next session. **No other tier covers
it:** the guard carries no plugin-root pattern anywhere and the secret floor does
not apply. And this is the **control over the control** — the one surface where
the reviewer and the pull-request boundary are the only line of defence. It is
not a defect against t4's acceptance criterion, and nothing here re-widens what
t4 deliberately narrowed.

## Users & Use Cases

- **The operator running long unattended loops in a consumer repository.** A
  driving session that edits the plugin's guard changes the rules the rest of the
  run is judged by, mid-run. Nothing in the run announces it; the operator finds
  out from a diff, hours later, if at all.
- **The maintainer developing the plugin in its own checkout.** Needs the
  boundary written down: the rule's shape is that a refusal reaches a plugin copy
  at another path and never the checkout they are working in, whose central
  artifact is the guard.
- **A later reviewer of the control surface.** Needs the tier choice and its
  consequence recorded where the tier is described, so the next review reads it
  as a settled decision rather than re-deriving it.

## Scope

**In**
- a shipped default pattern in the retrofit's per-repository sensitive-path file
  — `.agents/guard-extra-paths`, shipped from the copy under
  `templates/spec-driven-base/` — covering an out-of-tree plugin copy's guard,
  hook bodies, agent prompts and skill prompts, plus the sensitive-tier refusal
  naming that file
- the retrofit path that adds the pattern to a repository that already exists
- regression cases for every newly-refused shape **and** its paired permit
- the decision note where the tier is described

**Out**
- adding any plugin-root pattern to the guard's built-in arrays; the plugin's
  defaults stay generic and this closure stays per-repository
- re-widening the narrowing t4 landed: a write whose target cannot reach a
  packet's commit still draws no driver-mode refusal
- the driver-mode tier's keying, its pause route out, and its refusal wording —
  the only message edited here is the sensitive tier's
- the prompt-bypass setting itself, except to assert the refusal survives it
- the target-extraction and sanitization defects owned by
  `guard-write-target-detection` and the deletion verbs owned by
  `driver-mode-deletion-refusal`

**Deferred**
- Recognising a plugin copy at an installation shape other than the one the
  harness produces today.
- Closing the same hole between two checkouts of *this* repository. The shape is
  identical to the consumer case — a plugin copy outside the driven tree — but
  the mechanism does not transfer: the sensitive-path tier matches the payload
  path with separators normalised and nothing else, and two checkouts are
  byte-identical below their roots, so the only discriminator is an absolute root
  prefix. This repository carries no sensitive-path file, so that prefix would
  live either committed as machine-specific junk or untracked-and-unignored —
  which the pause path's stash sweeps and the green checkpoint discards as
  scratch. The cost of deferring: a driver in this repository can still write a
  foreign checkout's plugin sources, unrefused.

## Capabilities

- [ ] **P0**: A plugin copy outside the driven repository is refused at the hard floor
  - a write from the driven repository to that copy's guard, any other hook body,
    any agent prompt or any skill prompt is denied at the sensitive-path floor,
    at every autonomy level, naming the rule it matched — through the edit tools
    and through the shell write forms the guard already recognises, covering the
    absolute spellings the harness produces, and **not keyed to driver mode**: a
    call carrying an agent id is refused the same way
  - the refusal holds where the repository has opted out of prompts
    (`bypass-ask-tier: true`), which is what makes the hard floor the only tier
    that refuses in the general case; the ask tier is inert there
  - the closure ships as one default pattern in that sensitive-path file, with no
    change to the guard's built-in patterns, and **the refusal names that file**
    — so a repository that develops the plugin, or an operator who must edit an
    installed copy, removes one line and learns from the refusal where it lives
  - `scripts/test-guard.sh` gains, against a fixture carrying the shipped
    pattern: a refusal case per covered file class; refusals with prompts
    bypassed and with an agent id present; a case asserting the refusal names the
    sensitive-path file; the **paired permit** for a neighbouring path in the
    same copy the pattern must not reach; and t4's worked example — an
    out-of-repository write that is not a plugin copy — still allowed. Each fails
    if the pattern is removed, broadened, or stops naming its file

- [ ] **P0**: The pattern never reaches the driven checkout's own plugin sources
  - a target at the driven repository's own guard, hook bodies, agent prompts or
    skill prompts does not match the shipped pattern, whether the target is named
    relative to the repository root or as an absolute path under it; editing them
    is judged exactly as it is today
  - the discrimination is on where the copy's root sits, not on the file names:
    a same-named file inside the driven tree is not matched because it is inside
    it, so the rule cannot be written as "any path ending in the guard's name"
  - `scripts/test-guard.sh` gains a case per covered file class asserting a
    target under the fixture repository's own root is **not** refused by this
    pattern, in both the relative and absolute spellings, against that same
    pattern-carrying fixture; each fails if the pattern is widened to match by
    file name

- [ ] **P1**: An existing repository is closed by the retrofit rather than by hand
  - the retrofit's check reports a repository whose sensitive-path file lacks the
    pattern as a finding naming what is left open and what closes it
  - its apply adds the pattern line to that file, byte-identical to the
    template's pattern line, leaving every operator-authored line untouched,
    removing no pattern, and creating the file from the template when the
    repository has none
  - re-running apply adds nothing a second time, so a repository that has been
    retrofitted twice carries one copy of the pattern
  - `scripts/test-migrate.sh` covers the finding, the first apply, the second
    apply as a no-op, preservation of operator-authored lines, and a byte
    comparison of the pattern line against the template's — the drift guard this
    repository already applies wherever one text has two homes

- [ ] **P2**: The decision is recorded where the tier is described — pinned by
  prose alone, by choice: the literals pinned elsewhere here are single facts — a
  version, a filename — whereas a pin on this would have to copy the decision's
  wording, and a duplicated paragraph drifts from its original more readily than
  the original goes missing
  - `docs/adr/0028-loop-driver-mode.md` records that the narrowing left an
    out-of-tree plugin copy writable, that the closure is a shipped
    sensitive-path pattern rather than a built-in tier or an ask-tier entry, and
    why the hard floor is the tier that actually refuses
  - it records the non-match constraint as part of the decision, so a later
    reader does not "harden" the pattern onto the driven tree and brick
    development in this repository's own checkout

## Dependencies

- `thin-loop-driver` — defines driver mode, the main-thread refusal and the
  `.agents/` exemption this feature's gap sits beside. Derived-done; nothing here
  re-opens a capability or edits a checked task.
- `thin-loop-driver-gaps` — its packet t4 narrowed the refusal to targets that
  could reach a packet's commit, which is what exposed this surface. Derived-done;
  this feature closes what the narrowing exposed and does not re-widen it.
- `guard-write-target-detection` — **not blocking.** One of the two existing
  driver-mode coverage-gap features on this surface; it edits the shared
  sanitization and target-extraction path, so whichever of the three lands second
  rebases onto the other.
- `driver-mode-deletion-refusal` — **not blocking.** The other coverage-gap
  feature on this surface, same shared code, same rebase consequence.

## Assumptions & Risks

- **Hard constraint:** the pattern must match a plugin copy at another path and
  must never match the driven checkout's own guard. A pattern that accidentally
  matched the local tree would make this repository's central artifact
  unmaintainable, and the failure would look like the guard working — which is
  why it is an acceptance criterion with its own sweep cases rather than advice.
- Assumption: a consumer never edits the installed plugin, and plugin
  development happens in the plugin's own checkout. That is what makes a hard
  floor affordable here.
- Risk: the hard floor applies to every context in the driven repository, not
  only the driving main thread — subagents included. Wider than the hole it
  closes, and deliberate: this is the control over the control.
- Risk: the route out is repository-wide — removing the line reopens every
  covered file class at once, and there is no per-call override. That is the
  price of the only tier that still refuses where prompts are bypassed.
- Risk: matching is by literal path shape; this tier absolutises nothing and
  resolves neither `..` nor a symlinked ancestor. A copy at an unanticipated
  location **or the same copy under an unanticipated spelling** is a silent
  allow, not a refusal — nothing announces it.

## Success Metrics

- No write from a repository carrying the shipped pattern reaches an out-of-tree
  plugin copy's guard, hook bodies, agent prompts or skill prompts. The sweep is
  the measurement: the metrics pipeline records a command head and a path hash,
  never a path, so a field metric for this is not collectable.
- Zero refusals against a driven checkout's own plugin sources — the paired
  permit cases are the standing detector, and in the field the symptom would be a
  refused edit naming this pattern.
- Every case in `scripts/test-guard.sh` and `scripts/test-migrate.sh` that passed
  before this feature still passes after it.

## Implementation Context

> This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **How the non-match is expressed.** Whether one pattern anchored on the
  out-of-tree copy's location shape satisfies both P0 capabilities, or whether
  the discrimination needs the driven root excluded explicitly, is an
  architecture call. If no pattern can express it without changing the guard's
  path matching, that matching change is outside this feature's stated surface
  and the scope returns for a decision — the same limit already known to bite the deferred
  self-host case, and the same return applies wherever else it bites, not only to
  this pair.
- **Whether a driven checkout's own plugin sources deserve the ask tier.** They
  are left as they are here; a consumer repository that wants prompts on them can
  add the entry itself, and nothing in this feature depends on that choice.
