---
spec-version: v1
---

# Feature: self-host-hardening

Make it safe for this repo to drive its own development with `/gaffer:run-loop`.

The plugin already partly self-hosts: `.agents/autonomy` is set, the guardrail
runs here, and part of the metrics corpus behind ADR 0019 v3.x was captured in
this repo. What is missing is protection against **reflexivity** — the loop
editing the code the loop is running from, which never happens in a consumer repo
because the plugin sits outside the working tree there.

The risk splits three ways by load timing, and each needs a different answer:

> `scripts/*.sh` are invoked fresh per Bash call, so an edit takes effect
> **mid-run, in the run that made it**. `runstate.sh` is the loop's own single
> writer of durable state.
>
> `hooks/*.sh` and `hooks.json` load at **session start**, so a break is
> invisible in-session and surfaces in the next one.
>
> `agents/*.md` and `skills/*/SKILL.md` are read at dispatch, so a mid-run edit
> changes how later packets in the same run behave.

`hooks/guard.sh` is the sharpest case: it is the plugin's own safety floor, and
here it is a first-class edit target at `full-autonomy`. A packet that weakens it
would be reviewed by a loop still running the old guard.

## Capabilities

- [ ] **P0**: Self-modification of the reflexive surface is human-gated, not silent
  - `hooks/`, `scripts/`, `agents/`, `skills/` and `.claude-plugin/` route through `.agents/guard-extra-review` (ASK tier)
  - deliberately ASK and not `.agents/guard-extra-paths` (hard deny) — a hard floor there makes most of this repo's real backlog unexecutable
  - a consumer repo is unaffected: the file is repo-local and the plugin's built-in defaults do not change

- [ ] **P0**: A packet that touches a script cannot land without its regression sweep
  - the matching `scripts/test-*.sh` is an acceptance criterion on the packet, not an honour-system house rule
  - covers the existing CLAUDE.md rule "a behavior worth having is a behavior worth a test in its sweep"

- [ ] **P1**: Packets touching session-loaded surfaces declare that they need a session boundary
  - a change to `hooks/` or `agents/` cannot be verified in the run that made it
  - the packet says so rather than implying in-run verification it did not perform

- [ ] **P1**: `.agents/task-files.yaml` carries fingerprinted file scope for this repo's packets
  - lets file-disjoint packets run concurrently under `--parallel` instead of serializing on empty scope
  - every entry fingerprinted, so a re-decomposed task drops to empty scope rather than a stale narrow one

- [ ] **P2**: A self-host run is distinguishable in the metrics corpus
  - this repo's own loop runs feed the same corpus used to make claims about the plugin's cost
  - without a marker, dogfooding runs and consumer runs are averaged together
</content>
