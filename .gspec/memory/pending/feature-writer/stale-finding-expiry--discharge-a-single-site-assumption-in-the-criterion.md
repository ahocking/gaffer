---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: the PRD assumed the rule being corrected was stated in one file and anchored its sweep criterion to that one file"
---

## Never assume a rule is stated in exactly one place — quantify the criterion over every site that states it

An Assumptions bullet saying "this is stated in one file" is undischarged: if a
second copy exists, the criterion anchored to the named file passes green while
half the correction ships. The cheapest fix is a clause on the existing
acceptance criterion asserting the condition *wherever the rule is stated* (name
the known site, keep the quantifier open) — not a new capability or Scope bullet
— and the assumption is then rewritten as the claim the criterion enforces.
