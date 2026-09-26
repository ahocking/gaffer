---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: 'any later record' left the ordering basis and tie behaviour undefined"
---

## When a criterion orders records by "later", state what is compared and what a tie means

"Later" is ambiguous until the criterion names the comparison basis (parsed time, not raw string order, when timestamp formats vary) and whether a tie counts. Resolve the tie toward the failure direction the PRD already calls safe, and say so in the criterion.
