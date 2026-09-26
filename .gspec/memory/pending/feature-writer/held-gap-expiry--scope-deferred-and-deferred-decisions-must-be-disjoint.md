---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA FAIL: three of four Deferred Decisions bullets duplicated Scope/Deferred bullets in substance, in a PRD 560 words over budget"
---

## Keep Scope/Deferred and Deferred Decisions strictly disjoint — out-of-scope work versus a within-scope choice

Scope/Deferred holds work deliberately left out of this feature; Deferred
Decisions holds a choice inside the feature's scope that decomposition will
make. A bullet that appears in both is one fact stated twice and is the cheapest
budget to recover when a revision must pay for required additions. The test
before writing a Deferred Decisions bullet: if the thing is *work*, it belongs
in Scope/Deferred only; if it is a *choice about how already-scoped work is
realized*, it belongs in Deferred Decisions only.
