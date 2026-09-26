---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: a P0 acceptance criterion said 'carrying the overrun refusal below', defining itself by reference to the P1 capability's text"
---

## Make every acceptance criterion self-standing; a P0 must be judgeable without any P1/P2 text

When a criterion needs a mechanism that another capability specifies, restate it inline in one clause (name the form: "a negative assertion on the following line, or a line-count ceiling") rather than pointing "below" or "above". Capabilities are independent checkboxes that ship in priority order, so a higher-priority one that references a lower-priority one cannot be marked complete on its own — and a span or block a criterion names should carry its own bounds (start key, end condition, the empty case) in the same clause.
