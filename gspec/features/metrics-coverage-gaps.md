---
spec-version: v1
depends_on: [run-metrics]
---

# Feature: metrics-coverage-gaps

The gaps the shipped collector documents in its own `notes[]` but cannot yet
measure. Split out of `run-metrics` deliberately: the collector is shipped and
must read as done, and folding a known gap in as an unchecked capability would
make it read as incomplete and block everything downstream of it.

Each capability below corresponds to a line the collector currently emits in
`notes[]` to say "this is not captured" — the honest state, and the reason this
feature exists rather than the note being quietly dropped.

## Capabilities

- [ ] **P1**: Guard ASK-tier frequency is captured
  - `PostToolUse` sees allowed calls only, and `Notification` was probed and does NOT fire on a denied call
  - so how often the guard prompts, and for what, is currently invisible
  - needs a different sensor than the existing hook — establish which event carries it before designing the field

- [ ] **P1**: Failed and uncommitted packets appear in the run packet
  - a packet exists only via its green-commit trailer, so work that failed or was rolled back leaves no row at all
  - `record-outcome` (v3.4) attests the outcome of packets that DID commit; it does not create rows for those that did not
  - without this, packet counts remain survivorship — the more work is discarded, the better a run looks

- [ ] **P2**: Edit overlap distinguishes correction from division of labour within a packet
  - `packets[].edits` and `contended_files` (v3.4) give per-role counts and same-file overlap by hash
  - what is still missing is a derived rework rate by editor role, which needs both this and failed-packet rows above
  - depends on P1 failed-packet capture to avoid computing a rate over green work only
</content>
