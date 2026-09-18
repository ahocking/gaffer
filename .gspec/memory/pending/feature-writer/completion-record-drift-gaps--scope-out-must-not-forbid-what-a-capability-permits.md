---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: Scope/Out forbade changing the verbatim match, while a capability's criterion permitted widening the very pattern that match reads"
---

## Write each Scope/Out bullet at the granularity of the behaviour, not of the mechanism a capability touches

An exclusion naming a mechanism ("the X match") silently forbids every capability
that edits any part of that mechanism, including ones the PRD deliberately
permits. Exclude the observable behaviour instead (the comparison, the outcome,
the contract) and say which component remains a named capability's business.
After drafting Capabilities, re-read every Out bullet against them and confirm no
bullet forbids a change a criterion requires.
