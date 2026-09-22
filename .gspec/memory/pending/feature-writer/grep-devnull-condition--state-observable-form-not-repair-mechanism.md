---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: Scope and a P0 criterion fixed the repair mechanism (variable + here-string) instead of the observable property; Overview presented an inferred failure as reproduced"
---

## State the observable property a fix must have, never the mechanism that achieves it — and separate observed from inferred

When a PRD closes a defect, Scope and acceptance criteria name the property the corrected code must exhibit ("no reader can close the pipe before its writers finish"), not the construct that delivers it (a captured variable, a here-string); the construct is an implementation call and, if it matters, a Deferred Decision. In the Overview, say which half of the failure was actually reproduced and which is inferred from documented behaviour — a PRD that says "reproduced" for an inferred case teaches the implementer to skip the observation the sweep case depends on.
