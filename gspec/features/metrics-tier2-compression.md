---
spec-version: v1
depends_on: [run-metrics]
---

# Feature: metrics-tier2-compression

Input compression (RTK-style) for the loop's tool output.

ADR 0019 defers Tier 2 explicitly and gates it on Tier 1's before/after numbers,
so this is a decision awaiting evidence rather than a queued build. Tier 1 has now
produced some of that evidence, and it points in a specific direction:

> `by_command_class` was built as the "where an output filter helps most" map.
> But the v3.3 correction found the cost claim behind shell-search filtering was
> never measured: shell search across 30 sessions totals ~187k tokens against
> 105M deduped lifetime cacheCreation — about **0.18%**. Eliminating it entirely
> saves a rounding error.
>
> `Read` is **7.6x** all shell search combined, with the top decile of calls
> carrying half the volume. Separately, **26% of `Read` calls re-read a file
> already in that context** (~2.4M tokens over one production week, ~11% of that
> repo's weekly spend at the measured ~16 effective tokens per source token).

So the lever is what agents read and re-read, not how they search. A compression
feature aimed at command output would optimize the 0.18%.

## Capabilities

- [ ] **P2**: The Tier 2 decision is made against Tier 1 numbers, not in the abstract
  - a written before/after using the existing run packets, naming which dimension is being compressed
  - explicitly tests the read-volume hypothesis above rather than the original command-output one
  - a decision not to build is a valid, recorded outcome

- [ ] **P2**: If built, compression is measurable in the same run packet
  - the effect shows up in `by_agent_role.<role>.cc_shape` p90/max, which read standing-context size
  - not in cacheCreation-per-packet, which spans 1.76x across untouched same-regime sessions and would hide a 20–30% trim
</content>
