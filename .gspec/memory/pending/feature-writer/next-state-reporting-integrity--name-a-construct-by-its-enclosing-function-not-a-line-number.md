---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: PRD identified code sites by bare :NNN line numbers"
---

## Identify a code site by its enclosing function or subcommand, never by a line number

A PRD is read by a maintainer after the numbers have moved — and when the feature's own work is
to edit those sites, closing one shifts the rest. Name the site by its enclosing function,
subcommand, or role ("the set-membership helper and the two duplicate-id checks in `foo.sh`");
the description beside a line number is almost always already sufficient and shorter, so
dropping the number costs nothing and removes a guaranteed staleness surface.
