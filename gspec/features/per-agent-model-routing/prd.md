---
spec-version: v2
depends_on: []
---

# Feature: per-agent-model-routing

## Overview

Routing is one decision made once: a packet's `tier` picks the agent, and the
agent's `model:` frontmatter picks the model. That frontmatter ships to every
consumer repo as the plugin's default policy, and a repo that wants a different
model for a role has nowhere to say so. `.agents/project-overrides.yaml`
already carries a `model_routing: {}` key, in this repo and in
`templates/spec-driven-base/`, but nothing reads it. So the operator passes
`model` by hand on every dispatch. That is error-prone, because a dispatch that
forgets it runs silently on the default, and it has already happened in a real
run. It is also mis-measured: every hand-passed model counts in
`dispatches_with_model_override` as a policy deviation, when it is in fact the
repo's policy.

This feature makes `model_routing` the repo's routing policy. It is a map keyed
by agent name, resolved by one deterministic lookup that every dispatch site
names, applied to every dispatch the plugin makes, and recorded in run-metrics
as policy rather than as an override. The plugin's frontmatter stays the
shipped default for any agent the map does not name.

## Users & Use Cases

- **The operator of a consumer repo** wants a stronger model for review and
  architecture and a different one for implementation. They want to set that
  once, have every dispatch honour it, and not have to remember it per call.
- **The agent dispatching work** (the loop driver, a skill, a delegating
  agent) needs one answer to "which model for this agent here" without
  parsing configuration itself.
- **The maintainer reading run-metrics** needs `dispatches_with_model_override`
  to mean a one-off departure again, and needs to see which roles a run
  routed away from their frontmatter.

## Scope

**In**
- reading `model_routing` from `.agents/project-overrides.yaml` as a map of
  agent name → model.
- one deterministic lookup that resolves an agent's model and validates the
  map, named by every dispatch site.
- applying the resolved model at every plugin dispatch: `run-loop`/`resume`
  (implementer, reviewer, doc-writer, architect, the chief-engineer decider
  stand-in, the end-of-run reviewer and architect), skills that dispatch
  agents (`review-change` among them), and agents that delegate
  (chief-engineer's own dispatches).
- fail-safe, visible handling of invalid entries.
- run-metrics counting map-routed dispatches as policy and recording the
  configured routing.
- the kickoff stating non-default routing, and the consumer template
  documenting the key.
- regression cases in the sweeps that own each changed file.

**Out**
- editing any agent's `model:` frontmatter.
- routing keyed by `tier`.
- an environment variable or session-level switch.
- the `loop-driver` role, which is the session itself (`model: inherit`) and
  the operator's own choice.
- the planned implementer model comparison. It is separate work, and its
  results would become values in `model_routing`.
- setting this repo's own `model_routing` values, which is operator
  configuration.

**Deferred**
- None beyond the Deferred Decisions below.

## Capabilities

- [x] **P0**: One deterministic lookup resolves an agent's model
  - given an agent name, it yields the map's value when `model_routing` names
    that agent, and otherwise yields "frontmatter default". A missing file,
    a missing key or an empty map yields the frontmatter default for every
    agent
  - its output is the exact value a dispatch passes. "Frontmatter default"
    means the dispatch passes no model, which is today's behaviour
  - it is a core subcommand. No prompt parses the YAML or restates the
    precedence rule. Each prompt names the subcommand

- [x] **P0**: Invalid entries fail safe and are reported, never dropped or fatal
  - a key naming no plugin agent, the key `loop-driver`, and a value the
    harness's `model` dispatch parameter does not accept are each reported, one
    line per entry, naming the key, the value and the reason
  - an agent whose entry is invalid resolves to its frontmatter default, and
    every other entry still applies
  - an unparseable `model_routing` block is reported once and every agent
    resolves to its frontmatter default. The lookup exits successfully in
    every case above, so a dispatch never fails on routing
  - `run-loop` and `resume` run the validation at preflight, and the kickoff
    carries any report as a ⚠️ line

- [ ] **P0**: Every plugin dispatch uses the resolved model
  - a dispatching file is every `skills/*/SKILL.md` and `agents/*.md` that
    instructs an Agent/Task dispatch. Each one names the lookup at its
    dispatch sites and passes its result
  - with `implementer` mapped and no other entry, an implementer dispatch
    passes the mapped model, and a reviewer dispatch passes no model
  - the `loop-driver` session's model is never set or changed by the lookup

- [ ] **P0**: Precedence is explicit deviation, then map, then frontmatter
  - a dispatch that passes a model other than the resolved one, and states
    its reason in the dispatch brief, wins over the map for that one dispatch
    only
  - the map wins over frontmatter, and frontmatter applies to any agent the
    map does not name

- [x] **P0**: Run-metrics records map routing as policy, not as override
  - a dispatch increments `dispatches_with_model_override` exactly when the
    model it passes differs from the lookup's resolved value for its
    `subagent_type`: the map value when mapped, no model when unmapped. A
    dispatch passing its resolved value counts 0
  - `run-metrics.json` records the configured routing as the valid agent →
    model entries that differ from frontmatter. An empty map records as empty, and
    a run collected before this feature records `null` (unmeasured)
  - `by_agent_role.<role>.models` is unchanged and remains the ground truth
    for what a role actually ran on

- [ ] **P0**: The lookup, its fallbacks and the counting are pinned by sweep cases
  - the owning sweep covers: a mapped agent, an unmapped agent, a missing
    file, an empty map, an unknown agent key, a `loop-driver` key, an
    unrecognized model value, and an unparseable block, each asserting the
    resolved value and the report line
  - `scripts/test-metrics.sh` covers a map-routed dispatch counting 0
    overrides, an off-map dispatch counting 1, a mapped agent dispatched back
    on its frontmatter model counting 1, an unmapped agent passed its own
    frontmatter model counting 1, and the recorded routing appearing in the
    packet, plus `null` on a legacy fixture
  - a sweep case asserts that every dispatching file (defined in the third
    capability) names the lookup subcommand

- [x] **P1**: The kickoff states routing that differs from defaults
  - shape C carries one line naming each agent the map routes away from its
    frontmatter, with both models. An empty or all-default map adds no line
  - the line reads from the lookup's output, not from the file directly

- [x] **P1**: The consumer template documents the key
  - `templates/spec-driven-base/.agents/project-overrides.yaml` explains
    `model_routing` next to the key: keyed by agent name, unlisted agents
    keep their frontmatter default, `loop-driver` is excluded, and invalid
    entries fall back and are reported
  - the key stays `{}` in the template, so a new consumer runs on the shipped
    defaults

## Dependencies

- `run-metrics`: owns the collector, `dispatches_with_model_override` and
  `by_agent_role.<role>.models`. Derived-done, and nothing here reopens it.
- `thin-loop-driver`: owns preflight, the kickoff's inputs and the loop's
  dispatch sites.
- `escalation-decider`: when it replaces the chief-engineer stand-in, its
  dispatch site must name the lookup too. It is related but not a
  dependency.

## Assumptions & Risks

- Assumption: every dispatching context, including a dispatched
  chief-engineer, can run a core subcommand before it dispatches.
- Assumption: the harness honours a `model` passed at dispatch over the
  target agent's frontmatter, as the operator's hand-passed overrides
  already show.
- Assumption: this repo's own values are set by the operator in its
  `project-overrides.yaml` once the feature lands, replacing the per-dispatch
  hand-passing.
- Risk: the lookup call is placed by prompts. A future dispatch site that
  does not name it silently runs on frontmatter. The detector is
  `by_agent_role.<role>.models` disagreeing with the recorded routing.
- Risk: an agent renamed in the plugin turns a consumer's key into an
  unknown key. It falls back and is reported at the next preflight, not
  silently.

## Success Metrics

- In a run with a non-empty `model_routing`, every dispatched role's
  `by_agent_role.<role>.models` contains only its routed model, with no
  hand-passed `model` needed.
- `dispatches_with_model_override` reads 0 on a run whose only model choices
  come from `model_routing`.
- The sweep cases named in the sixth capability pin the lookup, its
  fallbacks and the counting on every change.

## Implementation Context

This feature PRD is portable and project-agnostic. During implementation, consult the project's `gspec/profile.md` (target users, positioning), `gspec/style.md` (design system), `gspec/stack.md` (technology choices), and `gspec/practices.md` (development standards) to resolve project-specific context.

## Deferred Decisions

- **Which script hosts the lookup** — `runstate.sh` or a new core script.
  Either satisfies the capabilities as long as there is one definition of the
  lookup in code.
- **When the collector reads the routing it compares against** — a snapshot
  taken at run start, or the file as it stands at collect time. The snapshot
  is safer if config changes mid-run. The choice belongs to the architecture
  step and does not change the counting rule.
- **Which list validation checks model values against, and who maintains
  it** — the harness publishes no queryable list, so validation needs a
  maintained copy. Where it lives and how it tracks the harness belongs to
  the architecture step.
