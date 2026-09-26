---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: outcomes used 'cannot run to a verdict'; adding `escalated` needed exclusive triggers"
---

## When adding an outcome, test its trigger against the host system's routing and update every site that enumerates outcomes

Before writing a new outcome's trigger in terms of a depended-on system's routing ("the loop would route it to X"), check whether that system also routes the *other* outcomes' endings to X (e.g. a past-the-limit retry routed to the same decider) — if so, bound the trigger ("while an attempt remains") or the precedence makes a later outcome unreachable. Then grep the PRD for every list of outcomes (eligibility rules, rates, rankings) and add the new one to each, or a replay ending in it blocks or skews them silently.
