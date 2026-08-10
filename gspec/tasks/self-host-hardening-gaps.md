---
spec-version: v1
feature: self-host-hardening-gaps
---

# Plan: self-host-hardening-gaps

Corrections to what `self-host-hardening` shipped, plus the one interaction bug
its final review surfaced. Small on purpose: four capabilities, five packets.

One ordering constraint runs across the set and is encoded in `deps:` — the
load-timing correction (T1) lands before the packet-rule delivery (T3), because
delivering the packet template more reliably while it still states the wrong
model propagates the error harder than leaving it referenced by path.

Three packets carry their own regression sweep case rather than deferring it to
a follow-up task: the parent feature split code from sweep across T6/T7 and a
fail-open shipped in the gap, which is the observed failure capability 3 exists
to close.

**T5 is instruction-only.** If the mechanism T4 chooses also requires a code
change, that lands as an appended task with its own sweep case rather than
widening T5 — one of the three candidates would otherwise silently turn T5 into
a patch of a vendored hook that is re-stamped on install.

`allowed_files` for these tasks lives in `.agents/task-files.yaml`, fingerprinted.
T5 is deliberately absent from that sidecar until T4 lands — its file set depends
on which mechanism T4 chooses, and a wrong-narrow entry costs correctness while a
missing one only costs parallelism.

## Plan

- [ ] **T1** [P] **P0** Correct the load-timing model in all five places in one change — `CLAUDE.md`, `templates/task-packet.yaml`, `.agents/guard-extra-review`, and in the already-complete `gspec/features/self-host-hardening.md` BOTH its blockquote and the session-boundary acceptance criterion under the checked P1 capability (the bullet's text only — never the checkbox, no checked task, no plan file) — so a hook's body reads as live on the next tool call and only its registration and the settings that load it cross a session boundary, with `scripts/test-guard.sh` passing unchanged since the enforcement-config edit is comment-only and warrants no new case
  - deps: —
  - covers: P0 load-timing model matches the harness
- [ ] **T2** [P] **P0** Make `scripts/metrics.sh` report `self_host=false` when a repository root cannot be resolved on **either** side — never synthesizing one from the script's own location nor from `--main-root` — and add fixtures to `scripts/test-metrics.sh` covering both shapes (a non-git plugin copy, and a non-git `--main-root` sited under a real plugin root), replacing the sweep comment's claim that only the driven side's resolution ever fails here while keeping its two-fixed-working-directories rationale
  - deps: —
  - covers: P0 marker yields no answer rather than a wrong one
- [ ] **T3** **P0** Deliver the packet contract instead of naming it — make both scoping sites (`skills/run-loop/SKILL.md` §3.2 and `agents/chief-engineer.md` step 3) `Read` `templates/task-packet.yaml` before filling a packet, and assert that delivery plus the presence of both REQUIRED rules in `scripts/test-report-conventions.sh`, extending that sweep's header block with a fifth numbered subject naming contract delivery by `Read` as the thing under test
  - deps: T1
  - covers: P0 packet rules delivered, not referenced
- [ ] **T4** [P] **P1** Choose and record in a new ADR which mechanism carries a finding discovered after a plan is fully checked into the backlog — regeneration through the supported planning path, a purely-additive-at-EOF allowance, or routing to a new feature — naming why the two rejected candidates are rejected, and noting that the immutability hook is vendored and re-stamped on install so a local patch to it would be silently reverted
  - deps: —
  - covers: P1 findings from a completed plan reach the backlog
- [ ] **T5** **P1** Update the loop's termination instruction (`skills/run-loop/SKILL.md` §4 and `skills/run-loop/parallel.md`) to name the mechanism T4 chose rather than "append to the backlog", and add the one `CLAUDE.md` conventions bullet naming it
  - deps: T3, T4
  - covers: P1 findings from a completed plan reach the backlog
