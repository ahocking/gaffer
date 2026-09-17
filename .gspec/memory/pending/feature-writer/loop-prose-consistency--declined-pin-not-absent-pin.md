---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: one risk bullet framed a missing regression case as 'not mechanically expressible' while its siblings named the available pin and said it was declined"
---

## State an omitted test as a pin that is available and declined, with what it would cost

When a capability ships without a regression case, the honest form names the pin that *is*
available and gives the reason it is not taken (it expires, it pins the wrong thing, it is out of
this feature's case budget). "No pin exists" is almost always false and hides a choice behind a
property — and where sibling bullets in the same section already use the declined form, the odd
one out also reads as an inconsistency the spec itself is meant to be fixing.
