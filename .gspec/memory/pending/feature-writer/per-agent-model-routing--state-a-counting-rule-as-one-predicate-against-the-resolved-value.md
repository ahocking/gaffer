---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: override counter stated as two cases, leaving a dispatch back to the default uncounted"
---

## State a counting or classification rule as one predicate against the resolved value

When a capability says when something counts (an override, a deviation, a mismatch), define it as one predicate comparing the observed value with the single resolved value. Listing cases ("equal to X counts 0, differs from X and Y counts 1") leaves gaps, such as a deviation back to the default. Pin each boundary case in the sweep-case criterion.
