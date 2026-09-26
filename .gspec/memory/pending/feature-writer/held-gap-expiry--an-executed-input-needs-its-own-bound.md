---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA FAIL: capability delegated the safety of a recorded, later-replayed command entirely to 'the same guard tiers', which the repo's own overrides largely bypass"
---

## State a bound on any input the system records now and executes later — an existing control is a dependency, not a bound

When a capability lets one run record something a later run executes (a command,
a script, a query), the PRD must state the bound itself: what it may do, what it
must never do, and a time limit — plus what result an over-bound or timed-out
attempt yields. Writing "it runs under the same controls as every other command"
names a dependency, not a constraint: those controls may be configured off, and
they were sized for a command issued by the agent in front of them, not for one
replayed unattended against a repo whose state has moved. An unbounded execution
also silently contradicts any non-halting promise in the same capability.
