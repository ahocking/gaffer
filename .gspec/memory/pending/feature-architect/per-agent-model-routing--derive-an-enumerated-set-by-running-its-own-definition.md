---
target: gspec-architect
layer: skill
agent: feature-architect
trigger: "QA: arch.md defined the dispatching-file set by a regex but listed its members from recall, omitting one match and mis-describing another"
---

## When a spec defines a set mechanically, list its members by running that definition

If an arch file gives a mechanical membership rule (a regex, a frontmatter test) and also lists the files it covers, derive the list by actually running the rule over the repo before writing it — every match, including descriptive-prose matches a sweep will enforce — rather than recalling the sites you expect. Likewise, state an event hook's timing by its real event (a PostToolUse hook fires on completion, not at call time), since counting semantics hinge on it.
