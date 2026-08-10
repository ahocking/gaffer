---
spec-version: v1
depends_on: [self-host-hardening]
---

# Feature: self-host-hardening-gaps

The defects the whole-branch review of `self-host-hardening` found in that
feature's own output, after every one of its capabilities was checked.

Split out deliberately, following the precedent of `metrics-coverage-gaps`
against `run-metrics`: completion is derived from capability checkboxes, so
folding a gap back in as an unchecked capability on the parent would make
shipped work read as incomplete forever and — through the dependency rule —
block everything downstream of it. The parent is done; these are new scope.

Three of the four are corrections to work that shipped, not gaps in what it
measured. That is what separates this feature from `metrics-coverage-gaps`,
where the notes were honest about what could not yet be seen. Here the shipped
artefacts state something that is **wrong**: a load-timing model that
contradicts the harness, a marker that inverts its own answer, and two REQUIRED
packet rules that may never reach the agent expected to apply them. The fourth
is an interaction bug between two individually-correct rules, surfaced by this
run and the reason these findings arrived as a report rather than as backlog.

One ordering constraint runs across the set: the load-timing correction must
land before or with the delivery of the packet-scoping rules, so that what
reaches the scoping agent is the corrected session-boundary field and not the
over-declaring one. Otherwise the delivery fix succeeds at delivering the wrong
model, and does it more reliably than before.

## Capabilities

- [ ] **P0**: The load-timing model matches what the harness actually does, in every place that states it
  - hooks are registered as commands, so a hook's body is spawned per event and its change is live on the next tool call; only the hook registration, the settings that load it, and which agents/skills exist with what registered frontmatter cross a session boundary
  - the four places that carry the old model are corrected **together**, so no uncorrected copy is left to re-derive the others from: `CLAUDE.md` (the reflexivity bullet), `templates/task-packet.yaml` (the `session_boundary:` field's session-start bullet and its hook attribution), `.agents/guard-extra-review` (the per-surface timing table in its rationale header), and `gspec/features/self-host-hardening.md` (the parent feature's own prose) — the parent's prose **is in scope**, because it is the most quotable statement of the wrong model and correcting prose alters no capability checkbox and no checked task
  - `CLAUDE.md` no longer contradicts itself: the older claim that hooks load at session start and the newer claim that only their registration does cannot both remain
  - the corrected guidance attributes in-run verifiability of a hook to the hook being executed, not to its regression sweep — the sweep is the deliberate check, not the mechanism

- [ ] **P0**: The self-host marker yields no answer rather than a wrong one when it cannot resolve a repository root
  - when both root resolutions fail, the comparison cannot succeed and the marker reports not-self-host, honouring the stated "on any doubt, false" rule instead of synthesizing a root from the collector's own location
  - a non-git install of the plugin (an archive extraction rather than a checkout) with the driven root under the plugin root no longer reports self-host, and no longer emits the dogfooding note
  - the matching regression sweep covers it, with a fixture that omits the repository metadata so the previously unreachable path is exercised, and the sweep comment no longer claims the path is unreachable — the rest of that comment, which records why the guard asserts from two fixed working directories, stands

- [ ] **P0**: The packet-scoping rules are delivered to the agent that applies them, not referenced by path
  - the agent that scopes a packet has the packet template's content in context before it fills the fields in — naming a file by path is not delivering it
  - both rules added by the parent feature are in force at scoping time: that a packet touching a script carries its regression sweep as an acceptance criterion, and that a packet touching a session-loaded surface declares the session boundary
  - a packet that edits a script and ships with no sweep case is the observed failure this closes: `self-host-hardening-t6` edited `scripts/metrics.sh` and landed with no case in `scripts/test-metrics.sh`, which arrived only in the packet after it — under the rule that forbids exactly that

- [ ] **P1**: A review finding discovered after a plan is fully complete reliably reaches the backlog
  - the outcome is specified, not the mechanism: findings from a completed plan land as tracked work through a supported path, without editing the completed record and without routing around the control that protects it
  - the loop's own instruction is updated to name that path, so the next run does not rediscover the dead end and fall back to reporting findings in prose
  - if the chosen mechanism changes a script, the matching regression sweep covers the new behaviour

## Deferred Decisions

- **Which mechanism carries findings from a completed plan into the backlog.** Three candidates were identified and none chosen: regenerate through the supported planning path; allow a purely-additive append at end-of-file past the immutability rule; or route findings from a completed plan to a new feature. Deferred because the choice changes how the loop classifies findings, which is a planning call; the reasoning for each candidate is already recorded in `.agents/findings/cannot-append-to-checked-plan.md`.
- **Whether the delivery fix for the packet rules is verified by a check or by inspection.** The corresponding contract-delivery work elsewhere in this repo ships a regression sweep asserting that the contract text is actually carried; whether that pattern is worth repeating for the packet template, or whether the delivery is self-evident once stated, is a planning call.
