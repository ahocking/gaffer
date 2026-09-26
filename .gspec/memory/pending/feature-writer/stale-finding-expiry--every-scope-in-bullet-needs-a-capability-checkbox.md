---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: a Scope/In bullet was stranded with no capability behind it after the capability that carried it was deleted"
---

## After deleting or merging a capability, re-check every Scope/In bullet still maps to a checkbox

Completion is derived from capability checkboxes, so a Scope/In bullet no
capability records lets the feature read done with that work never checked.
Walk the In list against the capabilities as a final pass: each bullet is either
work some checkbox records, or it is a *consequence* of another capability and
belongs in Scope/Out beside the other consequence bullets with the same
one-clause reason — not left in scope because the observable survives in a
Success Metric.
