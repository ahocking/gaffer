---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: progress ladder tested null last (unreachable) and an unresolved agent_id join summed to a measured-looking 0"
---

## Test the unjudgeable case first in every value ladder, and null every count an unresolved join would zero

When a criterion assigns one of several values in a stated order, the "cannot be judged"
value is the first rung, with its triggers enumerated (the window is unmeasured, the run
predates the record, the join resolved nothing) — placed last it is unreachable and
contradicts every sibling rule that emits null. Then trace each per-unit count back to the
join that supplies it: a unit the join could not resolve must carry null for every count
derived from that join (calls, edits, durations, tokens), never a 0 that flows into a rollup
as measured; and say which candidate wins when the join finds more than one.
