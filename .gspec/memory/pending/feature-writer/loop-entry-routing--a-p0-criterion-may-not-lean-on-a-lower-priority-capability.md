---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: a P0 criterion asserted a fallback ('falls to the stop below') that only the P1 capability delivered"
---

## Priority-rank every capability a criterion leans on: a criterion may never depend on a lower-priority capability

Priorities are a shipping order, so P0 must be coherent shipped alone. A criterion phrased as "falls through to", "otherwise reaches", or "the X below" names another capability's deliverable — if that capability is ranked lower, the higher one lands with the fallback missing and the criterion describes behaviour the code does not have. After drafting the capability list, walk every cross-reference between criteria and confirm the referenced capability's priority is equal or higher; the fix is usually to raise the depended-on capability, not to reword the criterion.
