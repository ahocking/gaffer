---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: a capability promised a closure whose discrimination the matching surface cannot express; demoted to Deferred"
---

## A capability that closes a gap by pattern must name a discriminator the matcher can actually see

Before writing a capability whose acceptance criteria turn on "this case matches
and that one does not", confirm what the matching surface is given: if it sees only
a raw, unresolved string, then absolutisation, symlink resolution and surrounding
context are not available to the rule, and any two cases with identical strings are
indistinguishable. Check as well that the discriminator has a home that survives —
a machine-local value with nowhere safe to live is not a closure. When it cannot be
expressed, move the case to Scope Deferred with the reason and the cost stated
plainly, rather than writing a criterion the implementer cannot satisfy. The same
check applies to *spellings*: a tier that resolves nothing covers only the exact
forms it is handed, and the criterion must say which.
