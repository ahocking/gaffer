---
name: no-invented-interface-names
description: When QA asks to make a criterion checkable, take the identifier from the source document or leave the spelling to planning — never invent a flag or constant name in a PRD
metadata:
  type: feedback
---

## Never invent an interface name to make an acceptance criterion checkable

- target: gspec-product
- layer: skill
- trigger: QA flagged two criteria as uncheckable ("exceeds its byte threshold", "created only when explicitly requested") and helpfully proposed concrete names. The human's brief overrode QA with a hard guard: check the source decision record first, and if it does not name the thing, do not invent one.
- lesson: A PRD states *what and why*; naming a flag or a constant is an interface decision owned by `/gspec-plan` and the architecture spec. When a finding says a criterion is unverifiable because a value or mechanism is unnamed, resolve it in this order — (1) the source document (ADR, brief) names it, so use that spelling **verbatim**; (2) it does not, so make the criterion checkable *without* an identifier ("a single named, documented constant with a stated default", "an explicit argument to the command"), and say in the summary that the spelling is left to planning. Adopting a reviewer's invented name silently locks a downstream decision and reads as authoritative in the PRD.

**Why the ordering matters:** in this run both names *did* exist upstream (`ORCH_FINDINGS_INDEX_MAX_BYTES` default 4096, and `--body`), and they happened to differ from nothing QA proposed only by luck. Had I adopted QA's suggestion without checking, a correct-looking PRD would have been right by coincidence. Check first regardless of how plausible the proposal looks.

Related: [[prd-pin-order-between-interdependent-capabilities]]
