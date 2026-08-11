---
name: prd-pin-order-between-interdependent-capabilities
description: When one capability's trigger is another capability's output, state the order inside both — an unstated sequence is a major PRD finding, not a planning detail
metadata:
  type: feedback
---

## If capability A produces the evidence capability B tests, pin the order in both

- target: gspec-product
- layer: skill
- trigger: QA's one major finding on a two-ADR PRD — capability "the checkbox flips at packet close" and capability "a finding expires only on positive evidence of completion" were each individually faithful, but neither said which runs first. Evaluating expiry before the flip would have made every packet read `unknown`, `unknown` blocks expiry, and the whole expiry mechanism would have shipped permanently inert.
- lesson: Two capabilities in one PRD are frequently coupled by a *happens-before* relation, and each reads as complete on its own — which is exactly why the gap survives a faithfulness review. Whenever one capability writes state that another capability reads as its precondition, name the order explicitly in the dependent capability's criteria, and name it **per execution mode** if the PRD has more than one (sequential vs. concurrent/parallel paths often differ in *who* performs the step and *when*). This is in-scope for a PRD: it is observable behaviour, not mechanism, so it does not belong to the architecture spec.

**How to apply:** after drafting the capability list, re-read it looking only for cross-capability preconditions — "positive evidence of X", "after Y lands", "once Z is recorded" — and check that something in the PRD says when X/Y/Z happens relative to the test. Fold the ordering into an existing criterion rather than adding one, so the 2–4 bound holds.

Related: [[no-invented-interface-names]]
