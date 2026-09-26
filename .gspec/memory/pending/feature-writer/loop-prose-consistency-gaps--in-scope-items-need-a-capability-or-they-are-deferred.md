---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: a Scope→In bullet had no capability, while Deferred Decisions said it might not happen"
---

## Every Scope→In bullet must map to a capability; a conditional item belongs in Scope→Deferred

Completion derives from capability checkboxes and every plan task carries a truthful
`covers:`, so in-scope work with no capability can neither be scheduled nor recorded —
it is dropped silently or attached to a mismatched `covers:`. Before finishing, check
each In bullet against the capability list; anything conditional or opportunistic moves
to Deferred rather than staying In without an owner.
