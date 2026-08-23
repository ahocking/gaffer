---
spec-version: v2
---

# Feature: coercive-pause-enforcement

A hard, agent-choice-proof stop for the pause sentinel.

Today (ADR 0017, ADR 0018) pause is **cooperative**. The authoritative mechanism
is the prompt-poll (`runstate.sh pause-status`) that the loop, chief-engineer and
implementer run at safe boundaries. `hooks/pause-check.sh` is best-effort
reinforcement that injects a context-only advisory.

Delivery of that advisory to subagents is verified — a 2026-07-19 probe confirmed
`PreToolUse` `additionalContext` reaches a dispatched subagent's model. But a
correct agent treats injected context as untrusted data (the probe's subagents
read the advisory and declined its embedded "stop"), so it cannot force a halt.

ADR 0017 defers the coercive form explicitly, **gated on evidence**: build it when
parallel runs show lanes overshooting their poll checkpoints. That gate is the
reason this feature is specced but not planned — decomposing it before the
evidence exists would be building against a hypothesis.

## Capabilities

- [ ] **P2**: A pause request can stop a lane regardless of agent cooperation
  - a coercive `PreToolUse` `deny` gated on `agent_id`, so it binds subagents and spares the orchestrator
  - must not weaken or interact with the guardrail's own decisions
  - the prompt-poll stays authoritative; this is a floor under it, never a replacement

- [ ] **P2**: The trigger for building this is measured, not assumed
  - evidence that lanes overshoot poll checkpoints under `--parallel`, captured before implementation starts
  - if the evidence does not appear, the correct outcome is to close this feature unbuilt and record why
</content>
