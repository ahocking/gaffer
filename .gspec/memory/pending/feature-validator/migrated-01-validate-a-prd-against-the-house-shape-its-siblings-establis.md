---
agent: feature-validator
migrated-from: .claude/agent-memory/feature-validator/MEMORY.md
---

## Validate a PRD against the house shape its siblings establish, and let a clean revision PASS

- target: gspec-qa
- layer: skill
- trigger: relayed with a re-validation task — "house PRD format is framing + Capabilities, not the persona's section set" and "do not manufacture findings to justify a second round"
- lesson: Read a sibling PRD before flagging a missing/extra section — a repo may run a compressed house shape, making the persona's list the *content* bar (priority, testable criteria, named deps) rather than a heading checklist. On re-validation, verify each prior finding against the source evidence, not the revision's summary, then stop: resolving every blocker/major is a PASS. Detail in [feedback_house-prd-shape-and-revalidation.md](feedback_house-prd-shape-and-revalidation.md).
