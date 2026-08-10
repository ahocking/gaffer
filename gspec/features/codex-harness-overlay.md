---
spec-version: v1
---

# Feature: codex-harness-overlay

A generated Codex / GPT-5.x overlay of the persona team and skills, so the
orchestration layer is not single-harness.

ADR 0007 accepted this and specifies v1 as a generated `codex/` overlay derived
from the existing prompts — incremental, not a rewrite. **Nothing is built:
there is no `codex/` or `.codex/` directory in the tree.**

Two constraints from the ADR that shape the work and must not be lost:

> Guardrails are out of scope for v1. `guard.sh` is portable bash and could later
> be wired to Codex's gating model, but the overlay ships **without** the approval
> guardrail initially — a known and deliberate reduction in safety posture
> relative to the Claude Code target.
>
> A refactor to a single shared core plus two generated adapters is deferred to a
> follow-up ADR, and only if the duplication proves costly.

## Capabilities

- [ ] **P2**: The persona team and skills are available on a Codex target
  - generated from the existing prompts rather than hand-maintained in parallel
  - uses native Codex mechanisms where they exist

- [ ] **P2**: The reduced safety posture is explicit at the point of use, not only in the ADR
  - a Codex overlay user is told the approval guardrail is absent before they run anything
  - shipping it silently is the failure mode this capability exists to prevent

- [ ] **P2**: Prompt duplication between targets is measured before any shared-core refactor
  - the ADR gates that refactor on duplication proving costly
  - a number, not an impression, decides it
</content>
