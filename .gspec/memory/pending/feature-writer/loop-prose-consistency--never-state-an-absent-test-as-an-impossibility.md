---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA [major]: the PRD said four capabilities 'cannot be pinned by a sweep' when the existing regression script already used, on those exact files, the techniques that would pin three of them"
---

## Before writing that a capability cannot be verified mechanically, read the project's existing test suite for that surface

An unverifiable-by-nature claim in a PRD is a factual assertion about the
surface, and it is almost always a scope choice wearing a property's clothes —
open the sweep/test file that already covers those artifacts and check which of
its techniques transfer before asserting the limit. When a pin is real but out
of scope, write it as a declined choice with its reason ("pinnable by the same
technique already used at X; declined to hold this feature to N cases"), never
as something the surface does not admit; the difference decides whether a later
reader re-examines it or trusts it forever.
