---
name: house-prd-shape-and-revalidation
description: Judge a PRD against the repo's established house shape and re-validate strictly against the prior verdict — do not fault a local format or invent fresh nits.
metadata:
  type: feedback
---

## Validate a PRD against the house shape its siblings establish, and let a clean revision PASS

- target: gspec-qa
- layer: skill
- trigger: "House PRD format is framing paragraphs + `## Capabilities` + optional `## Deferred Decisions`, NOT the persona's standard section set" and "do not manufacture findings to justify a second round" (relayed with a re-validation task)
- lesson: Before flagging a missing/extra section, read one or two sibling PRDs in the same
  directory — a repo may run a compressed house shape, and the persona's section list is then
  the *content* bar (priorities, testable criteria, named dependencies, bounded scope), not a
  literal heading checklist. On a re-validation, verify each prior finding against the source
  evidence rather than the revision's own summary, then stop: a revision that resolves every
  blocker/major PASSes even if a new precision nit is visible. Naming the product's own
  files/fields is not an implementation leak when the product *is* that codebase.

**Why:** re-validation exists to converge. Grading newly-added text harder than the original,
or treating a local format as a defect, turns one gate into an endless loop.

**How to apply:** re-check prior findings first and say resolved/not for each; cap anything
noticed only in the new text at `minor` unless it is genuinely unsafe to build on.
