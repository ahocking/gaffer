---
target: gspec-product
layer: skill
agent: feature-writer
trigger: "QA: the four refusal observables and the no-tools mirror were restated in three capabilities, and a P0 umbrella capability enumerated shapes a P1 introduces"
---

## Define a shared observable set once, in the capability that owns the sweep, and reference it by title everywhere else

When several capabilities are proven by the same assertion bundle (exit code, unchanged file, no new key, key named — or a no-tools mirror), enumerate it exactly once in the capability that owns the test sweep and have the others say "asserting the observables the <title> capability defines". An umbrella P0 sweep capability quantifies over "every new case this feature adds", never over a list of named shapes, or it silently inherits every P1 it names.
