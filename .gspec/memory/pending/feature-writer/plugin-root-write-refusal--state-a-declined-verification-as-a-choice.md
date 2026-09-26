---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: 'prose only — no sweep case' states an available-but-declined pin as a property of the surface (third PRD in this set with the defect)"
---

## When a capability declines an available verification, write the choice and its reason, never a bare property of the surface

"Prose only — no sweep case", "not testable", "no automated check" read as *nothing
could check this* — which is usually false, since projects routinely pin
documentation and contract literals. Before writing such a clause, check whether
the project already pins comparable literals; if it does, state the decision in the
same line: what a pin would have to duplicate, and why that duplicate is the worse
risk. And when a finding names this clause, grep the whole document for the claim
class rather than fixing only the quoted line.
