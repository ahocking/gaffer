---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: two P0 capabilities disagreed about whether an item that fails to resolve is outside the scanned set or inside it as unjudgeable"
---

## When capabilities quantify over a scanned set, define membership once and say which resolution failures fall outside it versus inside it as unclassifiable

A detection capability and its companion "what we cannot judge" capability quantify
over the same set, and each will silently assume a different membership rule — one
excluding unresolvable items, the other admitting them as unjudgeable. In a real
backlog those readings differ by orders of magnitude, which makes every derived
count and success metric unreadable. Fix it with clauses on the existing criteria,
not a new criterion: name the resolution failures that put an item **out of scope**
and state that only failures inside a resolved item land as unclassifiable, then
re-scan every other quantifier over that set (Scope bullets and metrics included)
for the same clause.
