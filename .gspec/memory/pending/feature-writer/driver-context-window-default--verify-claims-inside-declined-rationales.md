---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: the rationale for declining a pin asserted an existing test 'already applies to both those files'; it covered only one"
---

## Verify every factual claim in an acceptance criterion, including ones inside a rationale for *not* doing something

A clause that justifies declining or deferring work is held to the same evidence bar as one
that requires work — "this technique already covers X and Y" must be checked against the
artifact before it is written, even when nothing is built on it. An unverified claim parked in
a declined rationale survives as a false premise for whoever later takes the item up. Where the
claim cannot be checked cheaply, weaken it to what is verifiable ("the technique exists") rather
than naming a coverage scope.
