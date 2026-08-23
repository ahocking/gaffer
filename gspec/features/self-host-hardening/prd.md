---
spec-version: v2
---

# Feature: self-host-hardening

Make it safe for this repo to drive its own development with `/gaffer:run-loop`.

The plugin already partly self-hosts: `.agents/autonomy` is set, the guardrail
runs here, and part of the metrics corpus behind ADR 0019 v3.x was captured in
this repo. What is missing is protection against **reflexivity** — the loop
editing the code the loop is running from, which never happens in a consumer repo
because the plugin sits outside the working tree there.

The risk splits by surface, and the answers differ:

> `scripts/*.sh` are invoked fresh per Bash call, so an edit takes effect
> **mid-run, in the run that made it**. `runstate.sh` is the loop's own single
> writer of durable state.
>
> A hook's **body** is spawned fresh per matching event, so — like a script — an
> edit to it takes effect **mid-run, on the next event, in the run that made it**.
> Only its **registration** (`hooks/hooks.json`, `.claude/settings.json` — which
> hooks exist and what they match) loads at **session start**, so a break there
> is invisible in-session and surfaces in the next one.
>
> `agents/*.md` and `skills/*/SKILL.md` are read at dispatch, so a mid-run edit
> changes how later packets in the same run behave.

`hooks/guard.sh` is the sharpest case: it is the plugin's own safety floor, and
here it is a first-class edit target at `full-autonomy`. A packet that weakens it
is live on the next matching tool call, in the same run — not caught by a loop
still running the old guard.

## Capabilities

- [x] **P0**: Self-modification of the reflexive surface is human-gated, not silent
  - `hooks/`, `scripts/`, `agents/`, `skills/` and `.claude-plugin/` are enumerated in `.agents/guard-extra-review` at the REVIEW/ASK tier, so the surface is declared and one line re-arms it
  - that tier is currently bypassed here (`bypass-ask-tier: true`), so the gate in force is the reviewer plus the pull-request boundary — the hard-deny floor (secrets, key material, recursive deletes, history rewrite) and the git gates to `main` are unaffected, and `escalate_to_human_on` covers the judgement calls a path pattern cannot express
  - deliberately ASK and not `.agents/guard-extra-paths` (hard deny) — a hard floor there makes most of this repo's real backlog unexecutable
  - a consumer repo is unaffected: the file is repo-local and the plugin's built-in defaults do not change

- [x] **P0**: A packet that touches a script cannot land without its regression sweep
  - the matching `scripts/test-*.sh` is an acceptance criterion on the packet, not an honour-system house rule
  - covers the existing CLAUDE.md rule "a behavior worth having is a behavior worth a test in its sweep"

- [x] **P1**: Packets touching session-loaded surfaces declare that they need a session boundary
  - a change to hook or agent/skill **registration** — `hooks/hooks.json`, `.claude/settings.json`, or a component's existence and registered frontmatter — cannot be verified in the run that made it; a hook's or agent's body, by contrast, is live in-run (a hook per event, an agent at its next dispatch)
  - the packet says so rather than implying in-run verification it did not perform

- [x] **P1**: `.agents/task-files.yaml` carries fingerprinted file scope for this repo's packets
  - lets file-disjoint packets run concurrently under `--parallel` instead of serializing on empty scope
  - every entry fingerprinted, so a re-decomposed task drops to empty scope rather than a stale narrow one

- [x] **P2**: A self-host run is distinguishable in the metrics corpus
  - this repo's own loop runs feed the same corpus used to make claims about the plugin's cost
  - without a marker, dogfooding runs and consumer runs are averaged together
</content>
