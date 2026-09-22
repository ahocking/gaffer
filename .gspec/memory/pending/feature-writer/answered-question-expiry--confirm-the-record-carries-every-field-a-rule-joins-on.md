---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: PRD applied a timestamp-ordered rule to list entries that carry no timestamp"
---

## Confirm the record carries every field a rule compares before the PRD applies the rule to it

When a capability reuses an existing rule on a new kind of record (compare a timestamp, join on an id), first check that the record's documented shape has every field the rule reads. If a field is missing, the PRD adds a capability that makes the record carry it. It also states what happens to records that lack it, such as legacy or hand-made ones. Do not leave the gap as a deferred "how it reads the field" decision. A join on a coarser key (for example, only the parent id) is wrong once that key can repeat.
