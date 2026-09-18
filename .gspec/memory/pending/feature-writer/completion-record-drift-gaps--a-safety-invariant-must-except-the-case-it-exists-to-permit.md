---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: capability 4's criteria stated the safety invariant as an absolute that the widening its own criterion permitted would violate"
---

## Write every acceptance-criterion absolute so it excepts the case the capability exists to permit

An acceptance criterion carrying "never", "no", or "always" has to name the
condition under which the forbidden thing is correct — otherwise the invariant
reads as a licence to suppress a true finding, and a criterion in the same
capability that permits a widening contradicts it. Sweep every absolute in the
Capabilities section for this, and scope a no-regression criterion to its own
capability's change rather than leaning on a sibling's, so it does not forbid
what that sibling permits.
