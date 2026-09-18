---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: skip predicate 'all capabilities checked' is vacuously true for a PRD with zero recognized capability lines, and disagrees with the adapter's own completion derivation"
---

## When a capability skips or filters a set, state the predicate as the system's own derivation, never as a bare universal

A bare "all X are Y" is vacuously true for the empty set, so a criterion written
that way silently admits the degenerate input — usually the legacy or malformed
case where the capability matters most — and can contradict the derivation the
code already applies. Name the existing derivation and its non-emptiness clause
("at least one recognized item, and every one of them checked"), then say
explicitly what the complement still receives.
