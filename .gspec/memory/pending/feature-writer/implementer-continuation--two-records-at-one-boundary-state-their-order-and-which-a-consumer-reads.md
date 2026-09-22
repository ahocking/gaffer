---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: the continue routing record was written after record-start --continue, so a consumer taking the latest record at the boundary classified every continuation as initial"
---

## Two records at one boundary: state their order and which one a consumer reads

When a capability writes more than one record for the same event (a routing record and a start record, a log line and a state write), the criterion names the write order and says which record a consumer joining the logs reads in preference at that boundary. Check the ordering against any sibling PRD that classifies from "the latest record before X" — a consumer written against that rule reads whichever record lands last, and an unstated order silently picks the wrong one.
