---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: Success Metric's 'within one run' is not achievable on the path the Deferred bullets carve out"
---

## A success metric's bound must hold on every path the Scope/Deferred bullets leave uncovered

Before stating a metric's time or count bound, walk the Deferred bullets: each one removes a
reporting or detection site, and the bound has to survive their worst path, not the happy one.
State the weaker case in the same sentence ("…within one run, or by the next fresh run where
the previous one ended blocked") rather than asserting a bound the deferrals make unreachable.
