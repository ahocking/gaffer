---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: a direct reader of the changed config shape (compare.sh) was left as a Risk bullet instead of a Scope/Out bullet naming its owner; a stale-note fix would have erased a dated probe"
---

## Give every reader your by-reader count finds an owner in Scope, not a line in Risks

When enumerating consumers of a value whose shape the feature changes turns up one the
feature will not update, put it in Scope/Out naming the feature or task that owns it; a
Risk bullet leaves the breakage unowned and unscheduled. Likewise, when a criterion corrects
a stale note that records a dated observation, amend it with the new dated observation
rather than replacing it — the old probe is evidence, not an error.
