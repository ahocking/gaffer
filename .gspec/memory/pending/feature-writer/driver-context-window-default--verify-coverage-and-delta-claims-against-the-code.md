---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: a PRD claimed 'prose only — no sweep case' where an existing sweep already asserts on both files, and a criterion restated shipped text as if it were new work"
---

## Check every coverage claim and every change claim in a PRD against the code before writing it

Two acceptance-criterion claims are load-bearing and both are checkable: that no
verification is possible, and that a file must newly say something. For the first,
read what the existing test sweeps already do — where a pin exists and is declined,
write it as a choice with its reason ("the one pin available is X; declined to hold
this feature to the cases above"), never as a property that makes none exist; and
where an existing case already holds a constraint, say so, so no new case is owed.
For the second, open the target file: if it already says the thing, either name the
delta it must NEWLY say or move the observation into Assumptions as "no change owed
here" — a criterion satisfied by shipped text specifies no observable change and
leaves the implementer choosing between a no-op edit and a reviewer failure. Sweep
the whole document for both claim classes; they are rule classes, not single spots.
