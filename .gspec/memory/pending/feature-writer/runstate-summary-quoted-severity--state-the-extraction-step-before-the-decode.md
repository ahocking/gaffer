---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA minors: criterion named the decode but not how the value is extracted (whitespace/CR); a 'workaround disappears' success metric was unmeasurable"
---

## Say how a parsed value is extracted before saying how it is decoded

When a criterion says a value is read "through the decode rule", also say where the value starts and what surrounding bytes (whitespace, a trailing CR) are stripped first, and include that padded form among the variants the criterion counts. Otherwise two implementations can both meet the criterion and still disagree. Do not write a success metric whose only evidence is that a workaround stops appearing. Nothing collects that, so tie the metric to a check someone can actually run.
