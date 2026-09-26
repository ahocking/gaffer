---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: the PRD's recorded diagnosis of a defect ('each site defers to the other') did not match the source, which restates the trigger tautologically"
---

## Open the source and verify each defect's mechanism before recording it, then fix the diagnosis everywhere it was restated

A PRD for a defect-correction feature is read later as evidence of what was wrong, so a
plausible-sounding mechanism ("defers in a circle", "duplicates the other") must be read off
the cited lines, not inferred from the symptom — the conclusion can be right while the stated
cause is false. The wrong cause is rarely in one place: it propagates into the Overview lede,
a capability's acceptance criterion and a Success Metric's gloss, so correcting only the
quoted sentence leaves the same claim standing two sections away.
