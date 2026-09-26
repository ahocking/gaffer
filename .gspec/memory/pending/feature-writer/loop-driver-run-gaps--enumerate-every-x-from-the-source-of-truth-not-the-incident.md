---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: Scope promised a clause naming 'every key that must survive a whole-file write' but the criterion enumerated only the keys the motivating incident lost; a retry rule said 'proceeds as today' with no branch for the case where the retried output is what the consumer routes on"
---

## When a criterion promises "every X", derive the list from X's source of truth, not from the incident that motivated it

An enumeration that Scope calls "every key / every case / every field" must be built by walking the canonical definition of X (the template, the schema, the grammar) and stating which members are excluded and why — never by listing only the members the observed failure dropped. Likewise, a retry-once rule is incomplete until it says what happens on the second failure for the case where the retried output is the thing the consumer acts on: escalate with the reason, never let the consumer substitute its own.
