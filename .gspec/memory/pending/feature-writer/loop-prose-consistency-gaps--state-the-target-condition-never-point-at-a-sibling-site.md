---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: an acceptance criterion held up a sibling site as the model, but that site's trigger was itself a pointer"
---

## State the target condition in the criterion; never make another site the target by reference

When a criterion says the fix should match an existing site ("corrected toward X",
"as X already does"), it is only checkable if X states the condition — and a site
that defers to a third site reproduces the defect being fixed. Read the named site
first, extract the concrete condition it actually carries, and write that condition
into the criterion instead of the pointer.
