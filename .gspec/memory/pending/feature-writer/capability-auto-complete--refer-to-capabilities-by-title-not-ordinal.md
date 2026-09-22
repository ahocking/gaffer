---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: PRD referred to 'the fourth capability' / 'the fifth capability' from Dependencies and Risks"
---

## Refer to a capability by a short title form, never by its ordinal position

When one PRD section points at a capability (Dependencies, Risks, another criterion), name it by a short title form ("the read-only-detector capability"), not "the fourth capability" — ordinals silently break when capabilities are reordered, added or split, and the reader has to count to resolve them.
