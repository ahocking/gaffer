---
spec-version: v1
feature: self-host-hardening
---

# Plan: self-host-hardening

The one forward feature with a real decomposition, because it is the immediate
next work and its scope is fully known. The other forward features are specced
without plans on purpose — decompose them with `/gspec-plan <slug>` when the work
comes up, so the decomposition reflects the repo as it is then.

`allowed_files` for these tasks lives in `.agents/task-files.yaml`, fingerprinted.

## Plan

- [x] **T1** **P0** Add `.agents/guard-extra-review` listing the reflexive surface so self-modification lands in the ASK tier
  - deps: —
  - covers: P0 self-modification gated
- [x] **T2** **P0** Add allow/deny cases to `scripts/test-guard.sh` proving each reflexive path asks and that consumer-repo defaults are unchanged
  - deps: T1
  - covers: P0 self-modification gated
- [ ] **T3** **P0** Make the matching regression sweep a required acceptance criterion in the task-packet template
  - deps: —
  - covers: P0 sweep is an acceptance criterion
- [ ] **T4** **P1** Add a session-boundary declaration to the task-packet template for packets touching hooks or agents
  - deps: T3
  - covers: P1 session boundary declared
- [ ] **T5** **P1** Populate `.agents/task-files.yaml` with fingerprinted file scope for this repo's packets
  - deps: —
  - covers: P1 fingerprinted file scope
- [ ] **T6** **P2** Mark self-host runs in the collected run packet so dogfooding and consumer runs are not averaged together
  - deps: —
  - covers: P2 self-host runs distinguishable
- [ ] **T7** **P2** Add a `scripts/test-metrics.sh` case asserting the self-host marker is present and does not alter any existing field
  - deps: T6
  - covers: P2 self-host runs distinguishable
</content>
