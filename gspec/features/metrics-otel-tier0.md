---
spec-version: v1
depends_on: [run-metrics]
---

# Feature: metrics-otel-tier0

OpenTelemetry as an optional, richer metrics source alongside the hook-based
event spine.

ADR 0019 demoted Tier 0 from accepted to **optional/deferred** and shipped Tier 1
without it. Tier 1's default source is the transcript, which is version-fragile
and fails soft; OTEL would be a more stable source for the same numbers, at the
cost of a runtime dependency the plugin currently does not have.

This is specced but not planned: it competes with `metrics-coverage-gaps`, which
addresses things Tier 1 genuinely cannot see, whereas Tier 0 mostly re-sources
things it already reports.

## Capabilities

- [ ] **P2**: OTEL is an optional source that degrades to the existing spine when absent
  - never a required dependency — the collector must keep working with no OTEL present
  - `token_source` distinguishes it, exactly as the transcript source is stamped today

- [ ] **P2**: The added coverage over Tier 1 is stated before implementation
  - which fields become more reliable, and which currently-invisible ones become visible
  - if the answer is only "the same numbers, more stably", that is a reason to keep deferring
</content>
