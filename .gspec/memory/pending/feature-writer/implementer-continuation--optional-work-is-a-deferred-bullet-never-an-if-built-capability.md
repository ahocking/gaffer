---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: a P2 'if built, …' capability can never honestly flip under derived completion and would block every dependant forever"
---

## Optional work is a Deferred bullet, never an "if built" capability

A capability whose criteria begin "if built" or "optionally" cannot be checked honestly: completion is derived from the checkbox, so leaving it unchecked reads the feature as incomplete and blocks everything that depends on it, while checking it asserts work that was never done. When a brief marks something optional, record it once under Scope/Deferred with the reason it is not built now and the evidence that would trigger building it — and give every remaining capability's criteria the "holds with it absent" clause, so no P0 leans on the deferred piece.
